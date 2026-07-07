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
from typing import Annotated, Any, Optional

import stripe
from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel

from .auth import CurrentUser, OptionalCurrentUser
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
    # Optional email for anonymous web checkout so Stripe can prefill the
    # receipt address / create the customer without prompting. iOS flows
    # already have an account, this is just a passthrough.
    email: Optional[str] = None
    # Optional landing-page overrides. Defaults below point at tonoit.com
    # so unauthenticated website visitors land on the welcome page;
    # authenticated app flows can still override per-request.
    success_url: Optional[str] = None
    cancel_url: Optional[str] = None


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
def create_checkout_session(
    body: CheckoutRequest,
    request: Request,
    user: OptionalCurrentUser,
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

    # Two callers share this endpoint:
    #  - iOS app (authenticated, ``user`` is a real row): reuse the
    #    existing Stripe customer; the subscription is attached to that
    #    device via ``client_reference_id``.
    #  - Public website (anonymous, ``user`` is None): no customer on
    #    file. We let Stripe Checkout create the customer at session
    #    time and use ``customer_email`` so the receipt already has an
    #    address when the buyer hits the hosted page.
    #
    # Both flows set ``metadata.tono_source`` so the webhook can tell
    # app-sourced subscriptions from web-sourced ones later (web
    # subscriptions have no device row to attach to).
    if user is not None:
        customer_id = user.stripe_customer_id
        if not customer_id:
            customer = stripe.Customer.create(
                metadata={"tono_device_id": user.device_id},
            )
            customer_id = customer["id"]
            store.attach_stripe_customer(user.device_id, customer_id)
        metadata = {
            "tono_device_id": user.device_id,
            "tono_source": "app",
        }
        client_reference_id = user.device_id
    else:
        customer_id = None
        metadata = {"tono_source": "web"}
        client_reference_id = None

    # PUBLIC_BASE_URL wins over the request host so deployments behind
    # Railway's proxy don't surface ``*.up.railway.app`` in the user's
    # browser. The static-site caller passes ``PUBLIC_BASE_URL=https://
    # tonoit.com`` in the env, which keeps the success URL on-brand.
    base = os.environ.get("PUBLIC_BASE_URL") or _public_base_url(request)
    success_url = body.success_url or f"{base.rstrip('/')}/welcome-pro?s=1"
    cancel_url = body.cancel_url or f"{base.rstrip('/')}/pricing"

    session_kwargs: dict[str, Any] = dict(
        mode="subscription",
        line_items=[{"price": price_id, "quantity": 1}],
        success_url=success_url,
        cancel_url=cancel_url,
        # Enable Apple Pay / Google Pay buttons on the hosted page. With
        # automatic_payment_methods on, Stripe Checkout renders the
        # express-checkout row automatically when the wallet is
        # available in the customer's browser; the underlying
        # PaymentIntent still resolves to a card charge.
        automatic_payment_methods={"enabled": True},
        # Defensive belt-and-braces for old client integrations — keep
        # ``card`` explicit so the hosted page always has a fallback
        # path even if the merchant dashboard hasn't enabled APMs yet.
        payment_method_types=["card"],
        subscription_data={"metadata": metadata},
        metadata=metadata,
    )
    if customer_id is not None:
        session_kwargs["customer"] = customer_id
        if client_reference_id is not None:
            session_kwargs["client_reference_id"] = client_reference_id
    else:
        # Anonymous web flow — let Stripe create the customer from the
        # email we pass, or prompt for one if the request didn't carry
        # one (the static-site JS doesn't collect email up front).
        session_kwargs["customer_email"] = body.email or None

    session = stripe.checkout.Session.create(**session_kwargs)

    return CheckoutResponse(url=session["url"], session_id=session["id"])


@router.post("/portal", response_model=PortalResponse)
def create_portal_session(
    request: Request,
    user: CurrentUser,
) -> PortalResponse:
    if not _is_configured():
        raise HTTPException(503, "Stripe is not configured on this server.")
    if not user.stripe_customer_id:
        raise HTTPException(400, "No Stripe customer on file. Start checkout first.")

    stripe.api_key = _secret()
    session = stripe.billing_portal.Session.create(
        customer=user.stripe_customer_id,
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

    if etype in (
        "checkout.session.completed",
        "customer.subscription.created",
        "customer.subscription.updated",
        "customer.subscription.deleted",
    ):
        _handle_subscription_event(store, etype, obj)
    else:
        logger.info("Stripe webhook: ignoring type=%s", etype)

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
    customer_id: Optional[str] = None
    subscription_id: Optional[str] = None
    status_str: Optional[str] = None
    renews_at: Optional[str] = None

    if etype == "checkout.session.completed":
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
        customer_id = obj.get("customer")
        subscription_id = obj.get("id")
        status_str = obj.get("status")
        renews_at = _iso(obj.get("current_period_end"))
        device_id = _meta(obj, "tono_device_id")

    if status_str == "canceled" or etype == "customer.subscription.deleted":
        # Treat deletions as immediate downgrade.
        store.update_subscription(
            device_id=device_id,
            customer_id=customer_id,
            subscription_id=None,
            status="canceled",
            renews_at=None,
        )
        return

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
