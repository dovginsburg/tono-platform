"""Stripe Checkout + webhook handling for Tono Pro.

Pricing (from SCOPE.md §5; updated commit 3421b51):
  - $3/mo consumer Pro
  - $29/yr annual

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
from typing import Annotated, Optional

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


class CheckoutResponse(BaseModel):
    url: str
    session_id: str


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


@router.post("/checkout", response_model=CheckoutResponse)
async def create_checkout_session(
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

    price_id = _price_for("pro", body.interval)
    if not price_id:
        raise HTTPException(
            503,
            f"Stripe price for pro/{body.interval} is not configured "
            f"(set STRIPE_PRICE_PRO_{'MONTHLY' if body.interval == 'month' else 'YEARLY'}).",
        )

    stripe.api_key = _secret()

    # Signed-in devices bill the ACCOUNT (so the subscription covers every
    # device linked to it); anonymous devices bill themselves, same as
    # before accounts existed. Reuse the existing Stripe customer if there
    # is one; otherwise let Checkout create it and attach it below.
    account = user.account
    customer_id = account.stripe_customer_id if account else user.stripe_customer_id
    metadata = {"tono_device_id": user.device_id}
    if account:
        metadata["tono_account_id"] = account.id

    if not customer_id:
        customer = stripe.Customer.create(metadata=metadata)
        customer_id = customer["id"]
        if account:
            await store.attach_account_stripe_customer(account.id, customer_id)
        else:
            await store.attach_stripe_customer(user.device_id, customer_id)

    success_url = f"{_public_base_url(request)}/v1/checkout/return?status=success"
    cancel_url = f"{_public_base_url(request)}/v1/checkout/return?status=cancel"

    session = stripe.checkout.Session.create(
        mode="subscription",
        customer=customer_id,
        line_items=[{"price": price_id, "quantity": 1}],
        success_url=success_url,
        cancel_url=cancel_url,
        # Always the device that started checkout — `tono_account_id` in
        # metadata (set above, when signed in) is the disambiguating signal
        # the webhook handler uses to decide account- vs device-level billing.
        client_reference_id=user.device_id,
        metadata=metadata,
        subscription_data={"metadata": metadata},
    )

    return CheckoutResponse(url=session["url"], session_id=session["id"])


@router.post("/portal", response_model=PortalResponse)
def create_portal_session(
    request: Request,
    user: CurrentUser,
) -> PortalResponse:
    if not _is_configured():
        raise HTTPException(503, "Stripe is not configured on this server.")
    customer_id = user.account.stripe_customer_id if user.account else user.stripe_customer_id
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
    if not await store.record_stripe_event(event["id"], event["type"], json.dumps(event)):
        return {"received": True, "duplicate": True}

    etype = event["type"]
    obj = event["data"]["object"]

    if etype in (
        "checkout.session.completed",
        "customer.subscription.created",
        "customer.subscription.updated",
        "customer.subscription.deleted",
    ):
        await _handle_subscription_event(store, etype, obj)
    else:
        logger.info("Stripe webhook: ignoring type=%s", etype)

    return {"received": True}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


async def _handle_subscription_event(store: Store, etype: str, obj: dict) -> None:
    """Translate a Stripe subscription event into an account or device
    row update.

    ``tono_account_id`` in metadata (set at Checkout time — see
    create_checkout_session) means this subscription bills a signed-in
    account; Stripe carries subscription metadata for the life of the
    subscription, so later `customer.subscription.*` events still have it.
    Its absence means an anonymous, device-billed purchase — the pre-
    accounts behavior, unchanged.

    Two lookup paths within each case:
      - checkout.session.completed: device_id is in ``client_reference_id``
        (set when we created the session).
      - customer.subscription.*: ids come from metadata, falling back to
        looking up by ``obj.customer`` if metadata is somehow missing
        (e.g. a subscription created outside our Checkout flow).
    """

    account_id: Optional[str] = None
    device_id: Optional[str] = None
    customer_id: Optional[str] = None
    subscription_id: Optional[str] = None
    status_str: Optional[str] = None
    renews_at: Optional[str] = None

    if etype == "checkout.session.completed":
        account_id = _meta(obj, "tono_account_id")
        device_id = obj.get("client_reference_id") or _meta(obj, "tono_device_id")
        customer_id = obj.get("customer")
        subscription_id = obj.get("subscription")
        # Pull the subscription to get the real status + renewal date.
        if subscription_id:
            sub = stripe.Subscription.retrieve(subscription_id)
            status_str = sub.get("status")
            renews_at = _iso(sub.get("current_period_end"))
        else:
            status_str = "active"
    else:
        account_id = _meta(obj, "tono_account_id")
        customer_id = obj.get("customer")
        subscription_id = obj.get("id")
        status_str = obj.get("status")
        renews_at = _iso(obj.get("current_period_end"))
        device_id = _meta(obj, "tono_device_id")

    if status_str == "canceled" or etype == "customer.subscription.deleted":
        status_str, subscription_id, renews_at = "canceled", None, None

    if account_id or not device_id:
        # Either we know for certain this is account-billed, or we have
        # neither id and must fall back to customer_id — try the accounts
        # table first (a no-match UPDATE is a silent no-op, so trying both
        # tables when we're unsure which one owns this customer is safe).
        await store.update_account_subscription(
            account_id=account_id,
            customer_id=customer_id,
            subscription_id=subscription_id,
            status=status_str,
            renews_at=renews_at,
        )
    if not account_id:
        await store.update_subscription(
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
