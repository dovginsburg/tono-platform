"""Stripe Checkout + webhook handling for Tono Pro.

Pricing (updated 2026-07-08 to match tono-web punch list):
  - $3.99/mo consumer Pro
  - $39.99/yr annual

The endpoint surface:
  POST /v1/checkout           -> create a Stripe Checkout Session
  POST /v1/stripe/webhook     -> receive Stripe events, verify signature,
                                 update the user's plan
  POST /v1/portal             -> create a Stripe Billing Portal session so
                                 users can cancel / update card

Webhook signature verification is mandatory. We reject any event whose
``Stripe-Signature`` header doesn't match, and we use
``record_stripe_event`` for idempotency so re-deliveries don't double-
update the same user.

If ``STRIPE_SECRET_KEY`` is unset (local dev), ``/v1/checkout`` returns
a 503 with a clear "Stripe not configured" message. ``/v1/stripe/webhook``
returns 503 in the same case — there's nothing meaningful to verify
against without a secret. ``/api/analyze`` is unaffected.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Annotated, Any, Optional

import stripe
from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel

from .auth import CurrentUser
from .store import Store, get_store

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------


def _secret() -> Optional[str]:
    return os.environ.get("STRIPE_SECRET_KEY")


def _webhook_secret() -> Optional[str]:
    return os.environ.get("STRIPE_WEBHOOK_SECRET")


def _price_for(plan: str, interval: str) -> Optional[str]:
    """Resolve the Stripe Price ID for a plan + interval from env vars.
    Returns None if not configured."""

    env = {
        ("pro", "month"): "STRIPE_PRICE_PRO_MONTHLY",
        ("pro", "year"): "STRIPE_PRICE_PRO_YEARLY",
    }.get((plan, interval))
    return os.environ.get(env, "") if env else None


def _public_base_url(request: Request) -> str:
    return os.environ.get("PUBLIC_BASE_URL") or str(request.base_url).rstrip("/")


def _is_configured() -> bool:
    return bool(_secret())


router = APIRouter(prefix="/v1", tags=["payments"])


# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------


class CheckoutRequest(BaseModel):
    interval: str = "month"  # "month" | "year"
    # Optional landing-page overrides. Defaults below point at tonoit.com
    # so hosted Checkout returns to the intended product surface.
    success_url: Optional[str] = None
    cancel_url: Optional[str] = None


class CheckoutResponse(BaseModel):
    url: str
    session_id: str
    trial_eligible: bool


class OfferResponse(BaseModel):
    interval: str
    currency: str
    unit_amount: int
    trial_eligible: bool
    trial_days: int


class PortalResponse(BaseModel):
    url: str


# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------


def _store_dep() -> Store:
    return get_store()


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


def _require_account(user: CurrentUser) -> None:
    if not user.account_id or user.account is None:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Sign in to a Tono account before starting checkout.",
        )


def _trial_eligible(customer_id: str) -> bool:
    """Ask Stripe whether this customer has ever had a subscription."""
    try:
        subscriptions = stripe.Subscription.list(customer=customer_id, status="all", limit=1)
        data = subscriptions.data
    except Exception as exc:
        logger.exception("Stripe trial eligibility lookup failed for customer=%s", customer_id)
        raise HTTPException(503, "Could not verify trial eligibility.") from exc
    return not bool(data)


def _offer(interval: str, user: CurrentUser) -> OfferResponse:
    if not _is_configured():
        raise HTTPException(503, "Stripe is not configured on this server.")
    if interval not in ("month", "year"):
        raise HTTPException(400, "interval must be 'month' or 'year'")
    _require_account(user)
    price_id = _price_for("pro", interval)
    if not price_id:
        raise HTTPException(503, "Stripe price is not configured.")
    stripe.api_key = _secret()
    try:
        price = stripe.Price.retrieve(price_id)
        unit_amount = price.unit_amount
        currency = price.currency
    except Exception as exc:
        logger.exception("Stripe price lookup failed for price=%s", price_id)
        raise HTTPException(503, "Could not load the current price.") from exc
    if not isinstance(unit_amount, int) or not isinstance(currency, str):
        raise HTTPException(503, "Stripe returned an incomplete price.")
    account = user.account
    assert account is not None
    customer_id = account.stripe_customer_id
    eligible = True if not customer_id else _trial_eligible(customer_id)
    return OfferResponse(
        interval=interval,
        currency=currency.lower(),
        unit_amount=unit_amount,
        trial_eligible=eligible,
        trial_days=7 if eligible else 0,
    )


@router.get("/offer", response_model=OfferResponse)
def get_offer(interval: str, user: CurrentUser) -> OfferResponse:
    """Return Stripe-backed price and trial eligibility for the signed-in account."""
    return _offer(interval, user)


@router.post("/checkout", response_model=CheckoutResponse)
def create_checkout_session(
    body: CheckoutRequest,
    request: Request,
    user: CurrentUser,
    store: Annotated[Store, Depends(_store_dep)],
) -> CheckoutResponse:
    if not _is_configured():
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Stripe is not configured on this server.",
        )
    if body.interval not in ("month", "year"):
        raise HTTPException(400, "interval must be 'month' or 'year'")
    _require_account(user)

    price_id = _price_for("pro", body.interval)
    if not price_id:
        raise HTTPException(
            503,
            f"Stripe price for pro/{body.interval} is not configured "
            f"(set STRIPE_PRICE_PRO_{'MONTHLY' if body.interval == 'month' else 'YEARLY'}).",
        )

    stripe.api_key = _secret()

    # Checkout is account/device authenticated so the authorized purchase can
    # always be reconciled to a durable Tono identity. Hosted Checkout still
    # performs the explicit payment authorization before the trial begins.
    account_id = user.account_id
    customer_id = (
        user.account.stripe_customer_id
        if user.account is not None
        else user.stripe_customer_id
    )
    new_customer = not customer_id
    if new_customer:
        customer_metadata = {"tono_device_id": user.device_id}
        if account_id:
            customer_metadata["tono_account_id"] = account_id
        customer = stripe.Customer.create(metadata=customer_metadata)
        customer_id = customer["id"]
        if account_id:
            store.attach_account_stripe_customer(account_id, customer_id)
        else:
            store.attach_stripe_customer(user.device_id, customer_id)
    metadata = {
        "tono_device_id": user.device_id,
        "tono_source": "web",
    }
    if account_id:
        metadata["tono_account_id"] = account_id

    # PUBLIC_BASE_URL wins over the request host so deployments behind
    # Railway's proxy don't surface ``*.up.railway.app`` in the user's
    # browser. The static-site caller passes ``PUBLIC_BASE_URL=https://
    # tonoit.com`` in the env, which keeps the success URL on-brand.
    base = os.environ.get("PUBLIC_BASE_URL") or _public_base_url(request)
    success_url = body.success_url or f"{base.rstrip('/')}/welcome-pro?s=1"
    cancel_url = body.cancel_url or f"{base.rstrip('/')}/pricing"

    trial_eligible = True if new_customer else _trial_eligible(customer_id)
    subscription_data: dict[str, Any] = {"metadata": metadata}
    if trial_eligible:
        subscription_data["trial_period_days"] = 7

    session_kwargs: dict[str, Any] = dict(
        mode="subscription",
        line_items=[{"price": price_id, "quantity": 1}],
        success_url=success_url,
        cancel_url=cancel_url,
        # Hosted Checkout in subscription mode. The ``payment_method_types``
        # list intentionally ONLY contains ``card`` because the
        # ``apple_pay`` / ``google_pay`` values are not valid
        # ``payment_method_types`` for subscription Checkout (Stripe
        # returns ``Invalid payment_method_types[i]: must be one of
        # card, cashapp, link, ...``). Wallet buttons are surfaced
        # separately via the **Dashboard → Settings → Payment methods
        # → Wallets** toggles — when Apple Pay / Google Pay are enabled
        # there, the hosted Checkout page renders them automatically in
        # the express-checkout row when the buyer's browser supports
        # them. This matches how Stripe-hosted Checkout Pages work.
        payment_method_types=["card"],
        # The trial begins only after the customer authorizes this hosted
        # subscription Checkout. Keep this aligned with both store products.
        subscription_data=subscription_data,
        metadata=metadata,
        customer=customer_id,
        client_reference_id=user.device_id,
    )

    session = stripe.checkout.Session.create(**session_kwargs)

    return CheckoutResponse(
        url=session["url"],
        session_id=session["id"],
        trial_eligible=trial_eligible,
    )


@router.post("/portal", response_model=PortalResponse)
def create_portal_session(
    request: Request,
    user: CurrentUser,
) -> PortalResponse:
    if not _is_configured():
        raise HTTPException(503, "Stripe is not configured on this server.")
    customer_id = (
        user.account.stripe_customer_id
        if user.account is not None
        else user.stripe_customer_id
    )
    if not customer_id:
        raise HTTPException(400, "No Stripe customer on file. Start checkout first.")

    stripe.api_key = _secret()
    session = stripe.billing_portal.Session.create(
        customer=customer_id,
        return_url=f"{_public_base_url(request)}/v1/checkout/return",
    )
    return PortalResponse(url=session["url"])


@router.post("/stripe/webhook")
async def stripe_webhook(
    request: Request,
    store: Annotated[Store, Depends(_store_dep)],
) -> dict:
    if not _is_configured() or not _webhook_secret():
        raise HTTPException(503, "Stripe is not configured on this server.")

    payload = await request.body()
    sig = request.headers.get("stripe-signature", "")
    try:
        event = stripe.Webhook.construct_event(
            payload, sig, _webhook_secret()
        )
    except (ValueError, stripe.error.SignatureVerificationError) as e:
        logger.warning("Stripe webhook signature failed: %s", e)
        raise HTTPException(400, "invalid signature")

    # Idempotency: bail if we've already processed this event id.
    if not store.record_stripe_event(event["id"], event["type"], json.dumps(event)):
        return {"received": True, "duplicate": True}

    etype = event["type"]
    obj = event["data"]["object"]

    # The whole post-idempotency path is best-effort. ANY internal
    # failure (missing metadata, an exception in _handle_subscription_event,
    # an unreachable Stripe API call, a missing user row) must still return
    # 2xx to Stripe — otherwise Stripe retries every hour for 3 days and
    # then disables the endpoint. We log the error so it's still visible
    # in the deploy logs.
    try:
        if etype in (
            "checkout.session.completed",
            "customer.subscription.created",
            "customer.subscription.updated",
            "customer.subscription.deleted",
            "invoice.payment_failed",
        ):
            _handle_subscription_event(store, etype, obj)
        else:
            # We intentionally ACK every event type we don't handle
            # (invoice.*, customer.created, etc.) so Stripe stops
            # retrying them. They were being returned 2xx by accident
            # before — keep that contract.
            logger.info("Stripe webhook: ignoring type=%s", etype)
    except Exception as e:
        logger.exception("Stripe webhook handler error for type=%s event=%s: %s", etype, event.get("id"), e)

    return {"received": True}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _handle_subscription_event(store: Store, etype: str, obj: dict) -> None:
    """Translate a Stripe subscription event into a user row update.

    Two lookup paths:
      - checkout.session.completed: device_id is in ``client_reference_id``
        (set when we created the session).
      - customer.subscription.*: device_id is in
        ``obj.metadata.tono_device_id`` OR we fall back to looking up by
        ``obj.customer``.
    """

    device_id: Optional[str] = None
    account_id: Optional[str] = _meta(obj, "tono_account_id")
    customer_id: Optional[str] = None
    subscription_id: Optional[str] = None
    status_str: Optional[str] = None
    renews_at: Optional[str] = None

    if etype == "invoice.payment_failed":
        customer_id = obj.get("customer")
        subscription_id = obj.get("subscription")
        status_str = "past_due"
        device_id = _meta(obj, "tono_device_id")
    elif etype == "checkout.session.completed":
        device_id = obj.get("client_reference_id") or _meta(obj, "tono_device_id")
        customer_id = obj.get("customer")
        subscription_id = obj.get("subscription")
        # Pull the subscription to get the real status + renewal date.
        # This is the call most likely to fail in production. Never infer paid
        # access from Checkout completion when subscription verification is
        # uncertain; persist an incomplete state and await a verified event.
        if subscription_id:
            try:
                sub = stripe.Subscription.retrieve(subscription_id)
                status_str = sub.get("status")
                renews_at = _iso(sub.get("current_period_end"))
            except Exception as e:
                logger.warning(
                    "Stripe Subscription.retrieve(%s) failed during "
                    "checkout.session.completed; falling back to session "
                    "status. err=%s",
                    subscription_id,
                    e,
                )
                status_str = "incomplete"
                renews_at = _iso(obj.get("current_period_end"))
        else:
            status_str = "incomplete"
    else:
        customer_id = obj.get("customer")
        subscription_id = obj.get("id")
        status_str = obj.get("status")
        renews_at = _iso(obj.get("current_period_end"))
        device_id = _meta(obj, "tono_device_id")

    if status_str == "canceled" or etype == "customer.subscription.deleted":
        # Treat deletions as immediate downgrade.
        # Skip cleanly if we have nothing to look the row up by — Stripe
        # sends deletion events for subscriptions we never wrote to (e.g.
        # from a previous deployment, or a different app sharing the
        # account). 500-ing on those makes Stripe disable the endpoint.
        if not account_id and not device_id and not customer_id:
            logger.info(
                "Stripe webhook: subscription event has no tono_device_id "
                "and no customer id; skipping (event type=%s).",
                etype,
            )
            return
        if account_id:
            store.update_account_subscription(
                account_id=account_id,
                customer_id=customer_id,
                subscription_id=None,
                status="canceled",
                renews_at=None,
            )
        else:
            store.update_subscription(
                device_id=device_id,
                customer_id=customer_id,
                subscription_id=None,
                status="canceled",
                renews_at=None,
            )
        return

    if not account_id and not device_id and not customer_id:
        logger.info(
            "Stripe webhook: subscription event has no tono_device_id "
            "and no customer id; skipping (event type=%s).",
            etype,
        )
        return

    if account_id:
        if customer_id:
            store.attach_account_stripe_customer(account_id, customer_id)
        store.update_account_subscription(
            account_id=account_id,
            customer_id=customer_id,
            subscription_id=subscription_id,
            status=status_str,
            renews_at=renews_at,
        )
    else:
        store.update_subscription(
            device_id=device_id,
            customer_id=customer_id,
            subscription_id=subscription_id,
            status=status_str,
            renews_at=renews_at,
        )


def _meta(obj: dict, key: str) -> Optional[str]:
    md = obj.get("metadata") or {}
    val = md.get(key)
    return val if isinstance(val, str) else None


def _iso(ts) -> Optional[str]:
    """Convert a Stripe unix timestamp to ISO-8601 UTC, or None."""
    if ts is None:
        return None
    try:
        import datetime as dt
        return dt.datetime.fromtimestamp(int(ts), tz=dt.timezone.utc).isoformat(
            timespec="seconds"
        )
    except (TypeError, ValueError, OSError):
        return None
