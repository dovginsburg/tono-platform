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

Error handling contract:
  - Bad signature        -> 400 (Stripe stops retrying)
  - Duplicate processed  -> 200 {duplicate: true} (idempotent ACK)
  - Duplicate pending    -> process again (previous attempt failed)
  - Handler failure      -> 500 (Stripe retries every hour for up to 3 days)
  - Unhandled event type -> 200 (explicit ACK so Stripe stops retrying)

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

from . import catalog
from .auth import CurrentUser, OptionalCurrentUser
from .store import Store, get_store

logger = logging.getLogger(__name__)

# Historical env-var-name mapping, kept as a fail-safe if the committed
# commercial catalog can't be read. test_commercial_catalog pins these equal to
# the catalog so the price-env-var names can never drift from the single source
# of truth.
_STRIPE_PRICE_ENV_FALLBACK = {
    "month": "STRIPE_PRICE_PRO_MONTHLY",
    "year": "STRIPE_PRICE_PRO_YEARLY",
}


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------


def _secret() -> Optional[str]:
    return os.environ.get("STRIPE_SECRET_KEY")


def _webhook_secret() -> Optional[str]:
    return os.environ.get("STRIPE_WEBHOOK_SECRET")


def _price_for(plan: str, interval: str) -> Optional[str]:
    """Resolve the Stripe Price ID for a plan + interval from env vars, using the
    env-var NAME declared in the versioned commercial catalog (single source of
    truth). Returns None if the plan/interval is unknown."""

    if plan != "pro" or interval not in ("month", "year"):
        return None
    env = None
    try:
        env = catalog.stripe_price_env_var(interval)
    except catalog.CatalogError:
        env = None
    if not env:
        env = _STRIPE_PRICE_ENV_FALLBACK.get(interval)
    return os.environ.get(env, "") if env else None


def _public_base_url(request: Request) -> str:
    # Production redirects must never derive from the attacker-controlled Host
    # header. Local development may explicitly configure its own base URL.
    from urllib.parse import urlparse
    configured = os.environ.get("PUBLIC_BASE_URL")
    if configured:
        parsed = urlparse(configured)
        if parsed.scheme == "https" and parsed.netloc:
            return configured.rstrip("/")
    return "https://tonoit.com"


def _safe_return_url(request: Request, requested: Optional[str], default_path: str) -> str:
    """Resolve where Stripe returns the user after the billing portal.

    A caller-supplied ``requested`` URL is honoured only when it is https and its
    host matches the configured public base URL host (or a tonoit.com host) — so
    an attacker can't turn our portal link into an open redirect. Otherwise we
    fall back to the on-brand web account page. The previous default
    (``/v1/checkout/return``) was a 404 with no route behind it.
    """
    from urllib.parse import urlparse

    base = _public_base_url(request).rstrip("/")
    default = f"{base}{default_path}"

    if not requested:
        return default
    try:
        parsed = urlparse(requested)
    except ValueError:
        return default
    if parsed.scheme != "https" or not parsed.netloc:
        return default
    allowed_hosts = set()
    base_host = urlparse(base).netloc
    if base_host:
        allowed_hosts.add(base_host)
    host = parsed.netloc
    if host in allowed_hosts or host == "tonoit.com" or host.endswith(".tonoit.com"):
        return requested
    return default


def _portal_return_url(request: Request, requested: Optional[str]) -> str:
    return _safe_return_url(request, requested, "/app/account")


def _resolve_stripe_customer(store: Store, user) -> Optional[str]:
    """The ONE Stripe-customer resolution order for a caller's account.

    Shared by /v1/checkout and /v1/portal so the two can never disagree about
    which customer a person owns. Order, most to least authoritative:

      1. ``stripe_customer_bindings`` — the authoritative table. ``_bind_customer_tx``
         inserts here first and only then COALESCEs onto ``accounts``, so the
         binding is correct even when the mutable column is stale or was cleared.
      2. ``accounts.stripe_customer_id`` — the mutable projection, kept for
         backward compatibility and for rows written before the binding table.
      3. ``users.stripe_customer_id`` — legacy only. No current code path writes
         this column (``update_subscription`` sets plan/status/renews_at; the
         customer arrives via ``attach_stripe_customer`` -> the account), so it
         is a last-resort read for pre-migration rows, never the primary source.

    The account is the entitlement principal for ANONYMOUS auto-accounts too
    (contract §1), so resolution deliberately does NOT gate on
    ``account.is_identified``: gating there made the portal read the always-NULL
    legacy column and 400 for an anonymous account holding a live subscription.
    ``user.account`` is the calling device's own account, so no cross-account
    customer is ever reachable through this helper.
    """
    account = getattr(user, "account", None)
    account_id = account.id if account is not None else getattr(user, "account_id", None)
    if account_id:
        bound = store.get_stripe_customer_binding(account_id)
        if bound:
            return bound
    if account is not None and account.stripe_customer_id:
        return account.stripe_customer_id
    return getattr(user, "stripe_customer_id", None)


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


class PortalRequest(BaseModel):
    # Optional caller-supplied return URL (where Stripe sends the user after
    # they close the billing portal). Validated against an allowlist before use;
    # anything untrusted falls back to the on-brand account page.
    return_url: Optional[str] = None


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

    # Money must bind to an account. A checkout with no bearer would create a
    # Stripe session with no client_reference_id and no account metadata, so
    # the webhook could never attach the subscription to a person (the P0 that
    # let anonymous web purchases float free). Refuse it — the web app signs
    # the browser in first (POST /v1/auth/web) and forwards that bearer.
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="authentication required to start checkout",
            headers={"WWW-Authenticate": 'Bearer realm="tono"'},
        )

    price_id = _price_for("pro", body.interval)
    if not price_id:
        raise HTTPException(
            503,
            f"Stripe price for pro/{body.interval} is not configured "
            f"(set STRIPE_PRICE_PRO_{'MONTHLY' if body.interval == 'month' else 'YEARLY'}).",
        )

    stripe.api_key = _secret()

    # Reserve before any Stripe-side creation. This is intentionally
    # fail-closed: a Stripe timeout/error retains the durable reservation,
    # because the provider may have accepted a request whose response we lost.
    if user.account is None:
        raise HTTPException(409, "canonical account missing")
    account_id = user.account.id

    # Cross-platform double-charge guard. Entitlement is keyed on the canonical
    # account UUID, and every rail projects into the SAME entitlement_grants
    # ledger: iOS StoreKit and Android Play Billing land there via RevenueCat,
    # Apple ASSN direct, or Google RTDN; Stripe lands there via the web webhook.
    # So a person who paid on iOS and then signs in on the web is ALREADY Pro on
    # this account — starting a Stripe subscription would bill them a second time
    # for service they already have. Refuse before any Stripe object or trial
    # reservation is created. An EXPIRED grant does not count (the helper filters
    # to active+unexpired), so a lapsed subscriber can still resubscribe, and a
    # Stripe subscriber changing plans/cancelling uses the billing portal.
    if store.account_entitlement_active(account_id):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                "This account already has an active Tono Pro subscription. "
                "Manage it where you purchased it (the App Store, Google Play, "
                "or your Tono billing portal)."
            ),
        )

    customer_id = _resolve_stripe_customer(store, user)
    include_trial = store.reserve_stripe_trial(
        account_id=account_id,
        customer_id=customer_id,
    )

    # Authenticated anonymous installs and signed-in people both possess a
    # canonical account UUID. There is intentionally no dormant unauthenticated
    # checkout branch that a later refactor could accidentally make trialing.
    if not customer_id:
        customer = stripe.Customer.create(metadata={
            "tono_device_id": user.device_id,
            "tono_account_id": account_id,
        })
        customer_id = customer["id"]
        if not store.attach_account_stripe_customer(account_id, customer_id):
            customer_id = store.get_stripe_customer_binding(account_id)
            if not customer_id:
                raise HTTPException(409, "Stripe customer attachment conflict")
        if include_trial and not store.reserve_customer_scope_for_account(
            account_id, customer_id
        ):
            include_trial = False
    metadata = {
        "tono_device_id": user.device_id,
        "tono_source": "app",
        "tono_account_id": account_id,
    }
    # client_reference_id carries the canonical Tono ACCOUNT uuid — the single
    # entitlement principal — NOT the device id (Ezra correction #2). The device
    # id is retained only as non-authorizing `tono_device_id` metadata. The
    # webhook resolves the account from `tono_account_id` metadata (set on every
    # session, old and new), so legacy sessions that put the device id in
    # client_reference_id still bind correctly.
    client_reference_id = account_id

    # PUBLIC_BASE_URL wins over the request host so deployments behind
    # Railway's proxy don't surface ``*.up.railway.app`` in the user's
    # browser. The static-site caller passes ``PUBLIC_BASE_URL=https://
    # tonoit.com`` in the env, which keeps the success URL on-brand.
    success_url = _safe_return_url(request, body.success_url, "/welcome-pro?s=1")
    cancel_url = _safe_return_url(request, body.cancel_url, "/pricing")

    # Single trial authority for web checkout: request the canonical free-trial
    # length (from the commercial catalog — 14 days) at Checkout time via
    # ``trial_period_days``. This is the ONLY place the web trial is set, so the
    # "14-day free trial" copy is code-backed, not reliant on undocumented
    # console config. Provider-console gate (do NOT mutate from here): the Stripe
    # Price object must stay trial-less, otherwise Stripe would stack a second
    # trial. Asserted trial-length + single-source by the payments tests.
    session_kwargs: dict[str, Any] = dict(
        mode="subscription",
        line_items=[{"price": price_id, "quantity": 1}],
        success_url=success_url,
        cancel_url=cancel_url,
        # UNIFIED WEB CHECKOUT — card + Apple Pay + Google Pay.
        #
        # ``payment_method_types`` is deliberately NOT set. Passing it (this
        # previously pinned ``["card"]``) opts the session OUT of Stripe's
        # automatic payment methods and freezes the accepted set in code.
        # Omitting it means Stripe applies the dashboard-configured automatic
        # payment methods and filters them per request by eligibility —
        # currency, amount, customer country, and the buyer's browser/device.
        #
        # Wallet model, stated exactly because it is easy to get wrong:
        #   * Apple Pay on the WEB is a Stripe wallet rendered on the hosted
        #     Checkout page. It is NOT StoreKit. It settles through Stripe and
        #     lands on the same ``checkout.session.completed`` /
        #     ``customer.subscription.*`` webhooks as any card.
        #   * Google Pay on the WEB is likewise a Stripe wallet. It is NOT
        #     Google Play Billing. Play Billing is Android-native only and must
        #     never be presented as a website payment method.
        #   * Both wallets are card-backed, so a browser/device that cannot
        #     offer them simply falls back to the card form — there is no
        #     separate code path, and no wallet-only dead end.
        #
        # Enablement is provider-side (Stripe Dashboard → Payment methods).
        # Stripe-hosted Checkout runs on checkout.stripe.com, so Apple Pay needs
        # no merchant domain registration here; registering a payment method
        # domain only becomes necessary if the flow moves to an embedded
        # Payment/Express Checkout Element on tonoit.com.
        subscription_data={"metadata": metadata},
        metadata=metadata,
    )
    if include_trial:
        session_kwargs["subscription_data"]["trial_period_days"] = catalog.trial_days()
    if customer_id is not None:
        session_kwargs["customer"] = customer_id
        if client_reference_id is not None:
            session_kwargs["client_reference_id"] = client_reference_id
    session = stripe.checkout.Session.create(**session_kwargs)
    if include_trial:
        store.attach_trial_session(account_id, session["id"])

    return CheckoutResponse(url=session["url"], session_id=session["id"])


@router.post("/portal", response_model=PortalResponse)
def create_portal_session(
    request: Request,
    user: CurrentUser,
    store: Annotated[Store, Depends(_store_dep)],
    body: Optional[PortalRequest] = None,
) -> PortalResponse:
    if not _is_configured():
        raise HTTPException(503, "Stripe is not configured on this server.")
    # Same resolution order as /v1/checkout — see _resolve_stripe_customer.
    # Cancelling must never be harder to reach than paying.
    customer_id = _resolve_stripe_customer(store, user)
    if not customer_id:
        raise HTTPException(400, "No Stripe customer on file. Start checkout first.")

    stripe.api_key = _secret()
    session = stripe.billing_portal.Session.create(
        customer=customer_id,
        return_url=_portal_return_url(request, body.return_url if body else None),
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

    # Idempotency: durable inbox with three outcomes:
    #   'duplicate_ok'     -> already processed; ACK immediately
    #   'duplicate_pending' -> previous attempt failed; retry
    #   'new'              -> first delivery; process then mark done
    event = _stripe_event_to_dict(event)
    event_status = store.record_stripe_event(event["id"], event["type"], json.dumps(event))
    if event_status == "duplicate_ok":
        return {"received": True, "duplicate": True}

    # 'new' or 'duplicate_pending' — run the handler.
    # On success: stamp processed_at and return 200.
    # On failure: re-raise as 500 so Stripe retries (up to 3 days).
    stripe.api_key = _secret()
    try:
        _handle_all_stripe_events(store, event)
        store.mark_stripe_event_processed(event["id"])
    except HTTPException:
        raise
    except Exception as exc:
        logger.exception(
            "Stripe webhook handler error: type=%s event=%s",
            event.get("type"), event.get("id"),
        )
        raise HTTPException(
            status.HTTP_500_INTERNAL_SERVER_ERROR,
            "webhook handler error — Stripe will retry",
        ) from exc

    return {"received": True}


# ---------------------------------------------------------------------------
# Event dispatcher
# ---------------------------------------------------------------------------


def _handle_all_stripe_events(store: Store, event: dict) -> None:
    """Route a verified Stripe event to the appropriate handler."""
    etype = event["type"]
    obj = event["data"]["object"]

    if etype in (
        "checkout.session.completed",
        "customer.subscription.created",
        "customer.subscription.updated",
        "customer.subscription.deleted",
    ):
        _handle_subscription_event(store, etype, obj)
    elif etype == "checkout.session.expired":
        store.release_trial_session(obj.get("id") or "")
    elif etype in ("invoice.payment_succeeded", "invoice.payment_failed"):
        _handle_invoice_event(store, etype, obj)
    elif etype == "charge.refunded":
        _handle_charge_refunded(store, obj)
    elif etype == "charge.dispute.funds_withdrawn":
        _handle_dispute_funds_withdrawn(store, obj)
    elif etype == "charge.dispute.funds_reinstated":
        _handle_dispute_funds_reinstated(store, obj)
    elif etype == "charge.dispute.closed":
        _handle_dispute_closed(store, obj)
    else:
        # Explicit ACK for unhandled types; Stripe will not retry.
        logger.info("Stripe webhook: ignoring type=%s id=%s", etype, event.get("id"))


# ---------------------------------------------------------------------------
# Subscription lifecycle handlers
# ---------------------------------------------------------------------------


def _handle_subscription_event(store: Store, etype: str, obj: dict) -> None:
    """Handle checkout.session.completed and customer.subscription.* events.

    Writes to BOTH:
      1. provider_purchases + entitlement_grants (append-only, version-guarded)
      2. accounts.plan / subscription_status (mutable; backward compat)
    """
    device_id: Optional[str] = None
    account_id: Optional[str] = _meta(obj, "tono_account_id")
    customer_id: Optional[str] = None
    subscription_id: Optional[str] = None
    status_str: Optional[str] = None
    period_end: Optional[int] = None
    product_id: str = "stripe_pro"
    amount_minor: Optional[int] = None
    currency: Optional[str] = None

    if etype == "checkout.session.completed":
        # Account resolution is driven by tono_account_id metadata (top of fn).
        # device_id is a non-authorizing hint from metadata; client_reference_id
        # now carries the canonical ACCOUNT uuid (this build), but LEGACY
        # sessions put the DEVICE id there — treat it as a device id only when it
        # is not the account uuid we already resolved (Ezra correction #2).
        device_id = _meta(obj, "tono_device_id")
        if not device_id:
            ref = obj.get("client_reference_id")
            if ref and ref != account_id:
                device_id = ref
        customer_id = obj.get("customer")
        subscription_id = obj.get("subscription")
        if subscription_id:
            # Let exceptions propagate — the outer handler returns 500 so
            # Stripe retries; the duplicate_pending path re-runs on retry.
            sub = stripe.Subscription.retrieve(subscription_id)
            status_str = sub.get("status")
            period_end = sub.get("current_period_end")
            product_id = _product_id_from_sub(sub)
            amount_minor, currency = _price_from_sub(sub)
        else:
            logger.warning(
                "Stripe checkout completion has no subscription; refusing Pro grant "
                "(session=%s)", obj.get("id"),
            )
            return
    else:
        customer_id = obj.get("customer")
        subscription_id = obj.get("id")
        status_str = obj.get("status")
        period_end = obj.get("current_period_end")
        device_id = _meta(obj, "tono_device_id")
        product_id = _product_id_from_sub(obj)
        amount_minor, currency = _price_from_sub(obj)

    # Resolve account_id from customer if not already in metadata
    if not account_id and customer_id:
        acct = store.get_account_by_stripe_customer(customer_id)
        if acct:
            account_id = acct.id

    # Guard: event references an account that doesn't exist in our DB
    if account_id:
        if store.get_account(account_id) is None:
            logger.warning(
                "Stripe webhook: account_id=%s from metadata not found in DB; "
                "skipping provider projection (type=%s)",
                account_id, etype,
            )
            account_id = None  # fall through to mutable-column update only

    if not account_id and not device_id and not customer_id:
        logger.info(
            "Stripe webhook: subscription event has no tono_device_id "
            "and no customer id; skipping (event type=%s).",
            etype,
        )
        return

    period_end_ms = int(period_end) * 1000 if period_end else None
    is_deleted = status_str == "canceled" or etype == "customer.subscription.deleted"
    effective_status = "canceled" if is_deleted else status_str
    renews_at = _iso(period_end)

    # Price authority gate (Ezra correction #3). A subscription may GRANT Tono
    # Pro only when it bills EXACTLY one line item whose Price ID is a configured
    # canonical Tono plan price (STRIPE_PRICE_PRO_MONTHLY / _YEARLY). A wrong,
    # missing, multi-line, or foreign price grants nothing and MUST NOT mutate
    # plan — we bail before trial reservation, provider projection, and the
    # mutable-column update. The raw event stays durably recorded in
    # stripe_events as evidence. Terminal states (canceled/unpaid/…) are not in
    # the granting set, so revocation/cancellation is unaffected by this gate.
    observed_subscription = locals().get("sub", obj)
    if (
        status_str in _GRANTING_STRIPE_STATUSES
        and not is_deleted
        and _matched_canonical_price_id(observed_subscription) is None
    ):
        logger.warning(
            "Stripe webhook: subscription=%s price is not a canonical Tono plan "
            "(missing/wrong/multi-line/foreign); refusing grant, plan untouched "
            "(type=%s).",
            subscription_id, etype,
        )
        return

    # Customer ownership and trial history are independent of mutable
    # entitlement ordering. Apply them before the subscription projection so a
    # delayed trialing event after cancellation/refund still consumes history.
    if account_id and customer_id:
        if not store.attach_account_stripe_customer(account_id, customer_id):
            logger.error(
                "Stripe customer attachment conflict account=%s customer=%s",
                account_id, customer_id,
            )
            return
    observed_subscription = locals().get("sub", obj)
    if account_id and customer_id and (
        status_str == "trialing"
        or (hasattr(observed_subscription, "get")
            and observed_subscription.get("trial_end"))
        or obj.get("trial_end")
    ):
        fingerprint = _payment_method_fingerprint(observed_subscription)
        conflict = store.consume_stripe_trial(
            account_id=account_id,
            customer_id=customer_id,
            subscription_id=subscription_id or "",
            fingerprint=fingerprint,
        )
        if conflict and subscription_id:
            logger.error(
                "Duplicate Stripe trial denied account=%s customer=%s sub=%s",
                account_id, customer_id, subscription_id,
            )
            stripe.Subscription.modify(subscription_id, trial_end="now")

    # ── 1. Provider projection ──────────────────────────────────────────────
    projection_result = None
    if subscription_id and period_end_ms is not None and status_str is not None:
        projection_result = store.apply_stripe_subscription_fact(
            account_id=account_id,
            subscription_id=subscription_id,
            stripe_status=effective_status if is_deleted else status_str,
            period_end_ms=period_end_ms,
            product_id=product_id,
            amount_minor=amount_minor,
            currency=currency,
        )

    # ── 2. Mutable column update (backward compat) ──────────────────────────
    # Skip if the provider projection determined this is a stale event — a
    # terminal state (refunded/revoked/expired) already guards the purchase.
    if projection_result == "stale":
        return

    if account_id:
        store.update_account_subscription(
            account_id=account_id,
            customer_id=customer_id,
            subscription_id=None if is_deleted else subscription_id,
            status=effective_status,
            renews_at=None if is_deleted else renews_at,
        )
    else:
        store.update_subscription(
            device_id=device_id,
            customer_id=customer_id,
            subscription_id=None if is_deleted else subscription_id,
            status=effective_status,
            renews_at=None if is_deleted else renews_at,
        )


def _handle_invoice_event(store: Store, etype: str, obj: dict) -> None:
    """Handle invoice.payment_succeeded and invoice.payment_failed.

    Fetches the current subscription state from Stripe and projects it
    into the provider model + mutable columns.
    """
    subscription_id: Optional[str] = obj.get("subscription")
    customer_id: Optional[str] = obj.get("customer")

    if not subscription_id:
        logger.info("Stripe webhook: invoice event without subscription_id, ignoring")
        return

    # Fetch authoritative subscription state — raises on network failure
    # (Stripe will retry the webhook).
    sub = stripe.Subscription.retrieve(subscription_id)
    stripe_status: str = sub.get("status") or "unknown"
    period_end: Optional[int] = sub.get("current_period_end")
    period_end_ms = int(period_end) * 1000 if period_end else None
    product_id = _product_id_from_sub(sub)
    amount_minor, currency = _price_from_sub(sub)

    if period_end_ms is None:
        logger.warning(
            "Stripe invoice event: no current_period_end for sub=%s; skipping",
            subscription_id,
        )
        return

    account_id: Optional[str] = None
    if customer_id:
        acct = store.get_account_by_stripe_customer(customer_id)
        if acct:
            account_id = acct.id

    projection_result = store.apply_stripe_subscription_fact(
        account_id=account_id,
        subscription_id=subscription_id,
        stripe_status=stripe_status,
        period_end_ms=period_end_ms,
        product_id=product_id,
        amount_minor=amount_minor,
        currency=currency,
    )

    # Skip mutable update if provider projection determined this event is stale —
    # a terminal state (refunded/revoked/expired) already guards the purchase.
    if projection_result == "stale":
        return

    plan = "pro" if stripe_status in ("active", "trialing", "past_due") else "free"
    if account_id:
        store.update_account_subscription(
            account_id=account_id,
            customer_id=customer_id,
            subscription_id=subscription_id if plan == "pro" else None,
            status=stripe_status,
            renews_at=_iso(period_end) if plan == "pro" else None,
        )
    elif customer_id:
        store.update_subscription(
            device_id=None,
            customer_id=customer_id,
            subscription_id=subscription_id if plan == "pro" else None,
            status=stripe_status,
            renews_at=_iso(period_end) if plan == "pro" else None,
        )


# ---------------------------------------------------------------------------
# Charge / refund / dispute handlers
# ---------------------------------------------------------------------------


def _handle_charge_refunded(store: Store, obj: dict) -> None:
    """Full refund → revoke access immediately. Partial refund → log only."""
    customer_id: Optional[str] = obj.get("customer")
    invoice_id: Optional[str] = obj.get("invoice")
    amount: int = obj.get("amount", 0)
    amount_refunded: int = obj.get("amount_refunded", 0)

    if amount > 0 and amount_refunded < amount:
        logger.info(
            "Stripe charge.refunded: partial refund %s/%s customer=%s — no access change",
            amount_refunded, amount, customer_id,
        )
        return

    subscription_id = _resolve_subscription_from_invoice(invoice_id)
    if not subscription_id:
        logger.warning(
            "Stripe charge.refunded: cannot resolve subscription from invoice=%s; "
            "access state unchanged",
            invoice_id,
        )
        return

    account_id: Optional[str] = None
    if customer_id:
        acct = store.get_account_by_stripe_customer(customer_id)
        if acct:
            account_id = acct.id

    store.apply_stripe_terminal_fact(
        subscription_id=subscription_id,
        account_id=account_id,
        lifecycle_state="refunded",
    )
    _downgrade_mutable_columns(store, account_id, customer_id, subscription_id)


def _handle_dispute_funds_withdrawn(store: Store, obj: dict) -> None:
    """Bank reversed our funds on a dispute — revoke access immediately."""
    charge_id: Optional[str] = obj.get("charge")
    customer_id, subscription_id = _resolve_customer_and_sub_from_charge_id(charge_id)

    if not subscription_id:
        logger.warning(
            "Stripe charge.dispute.funds_withdrawn: cannot resolve subscription "
            "from charge=%s dispute=%s",
            charge_id, obj.get("id"),
        )
        return

    account_id: Optional[str] = None
    if customer_id:
        acct = store.get_account_by_stripe_customer(customer_id)
        if acct:
            account_id = acct.id

    store.apply_stripe_terminal_fact(
        subscription_id=subscription_id,
        account_id=account_id,
        lifecycle_state="revoked",
    )
    _downgrade_mutable_columns(store, account_id, customer_id, subscription_id)


def _handle_dispute_funds_reinstated(store: Store, obj: dict) -> None:
    """We won the dispute — funds returned. Reinstate if subscription is still active."""
    charge_id: Optional[str] = obj.get("charge")
    customer_id, subscription_id = _resolve_customer_and_sub_from_charge_id(charge_id)

    if not subscription_id:
        logger.info(
            "Stripe charge.dispute.funds_reinstated: no subscription to reinstate "
            "(charge=%s)", charge_id,
        )
        return

    try:
        sub = stripe.Subscription.retrieve(subscription_id)
    except Exception as e:
        logger.warning(
            "Stripe Subscription.retrieve(%s) failed during funds_reinstated: %s",
            subscription_id, e,
        )
        raise

    stripe_status: str = sub.get("status") or "unknown"
    period_end: Optional[int] = sub.get("current_period_end")
    period_end_ms = int(period_end) * 1000 if period_end else None

    if period_end_ms is None or stripe_status not in ("active", "trialing", "past_due"):
        logger.info(
            "Stripe dispute.funds_reinstated: sub=%s status=%s — not reinstating",
            subscription_id, stripe_status,
        )
        return

    account_id: Optional[str] = None
    if customer_id:
        acct = store.get_account_by_stripe_customer(customer_id)
        if acct:
            account_id = acct.id

    # force=True: dispute won → explicit reinstatement beats any terminal guard.
    _amount_minor, _currency = _price_from_sub(sub)
    store.apply_stripe_subscription_fact(
        account_id=account_id,
        subscription_id=subscription_id,
        stripe_status=stripe_status,
        period_end_ms=period_end_ms,
        product_id=_product_id_from_sub(sub),
        amount_minor=_amount_minor,
        currency=_currency,
        force=True,
    )
    if account_id:
        store.update_account_subscription(
            account_id=account_id,
            customer_id=customer_id,
            subscription_id=subscription_id,
            status=stripe_status,
            renews_at=_iso(period_end),
        )
    elif customer_id:
        store.update_subscription(
            device_id=None,
            customer_id=customer_id,
            subscription_id=subscription_id,
            status=stripe_status,
            renews_at=_iso(period_end),
        )


def _handle_dispute_closed(store: Store, obj: dict) -> None:
    """Handle charge.dispute.closed. Won → reinstate; lost is handled by funds_withdrawn."""
    if obj.get("status") == "won":
        _handle_dispute_funds_reinstated(store, obj)
    # 'lost' / 'needs_response': funds_withdrawn event already fired the revocation.


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _resolve_subscription_from_invoice(invoice_id: Optional[str]) -> Optional[str]:
    if not invoice_id:
        return None
    # Let Stripe API exceptions propagate — callers must not silently ACK on
    # retrieval failure.  Only None is returned for genuinely absent subscriptions.
    inv = stripe.Invoice.retrieve(invoice_id)
    return inv.get("subscription")


def _resolve_customer_and_sub_from_charge_id(
    charge_id: Optional[str],
) -> tuple[Optional[str], Optional[str]]:
    """Return (customer_id, subscription_id) by fetching the charge and its invoice."""
    if not charge_id:
        return None, None
    # Let Stripe API exceptions propagate so the webhook returns 5xx and Stripe
    # retries.  Only (None, None) is returned when the objects genuinely lack
    # a linked subscription — never on a transient retrieval failure.
    charge = stripe.Charge.retrieve(charge_id)
    customer_id = charge.get("customer")
    invoice_id = charge.get("invoice")
    subscription_id = _resolve_subscription_from_invoice(invoice_id)
    return customer_id, subscription_id


def _downgrade_mutable_columns(
    store: Store,
    account_id: Optional[str],
    customer_id: Optional[str],
    subscription_id: str,
) -> None:
    """Set plan=free on the mutable account/user columns after a refund/dispute."""
    if account_id:
        store.update_account_subscription(
            account_id=account_id,
            customer_id=customer_id,
            subscription_id=None,
            status="canceled",
            renews_at=None,
        )
    elif customer_id:
        store.update_subscription(
            device_id=None,
            customer_id=customer_id,
            subscription_id=None,
            status="canceled",
            renews_at=None,
        )


def _product_id_from_sub(sub: dict) -> str:
    """Extract the Stripe product ID from a subscription object's items list."""
    items = (sub.get("items") or {}).get("data") or []
    if items:
        price = items[0].get("price") or {}
        return price.get("product") or "stripe_pro"
    return "stripe_pro"


def _price_from_sub(sub: dict) -> tuple[Optional[int], Optional[str]]:
    """The plan's authoritative recurring price from a Stripe subscription's
    first line item, as (amount_minor, currency).

    Stripe already reports ``unit_amount`` in integer minor units and a
    lowercase ISO ``currency`` — we never parse a formatted string. Returns
    (None, None) when either is missing so a purchase is only ever stamped with
    a provably correct price, never a guess. This is the plan price (what the
    subscription bills each period), not a per-invoice charged total; it is the
    stable, normalized number a person recognizes as "what my plan costs".
    """
    items = (sub.get("items") or {}).get("data") or []
    if items:
        price = items[0].get("price") or {}
        unit_amount = price.get("unit_amount")
        currency = price.get("currency")
        if isinstance(unit_amount, int) and isinstance(currency, str) and currency:
            return unit_amount, currency.lower()
    return None, None


_GRANTING_STRIPE_STATUSES = frozenset(
    {"active", "trialing", "past_due", "incomplete"}
)


def _canonical_price_ids() -> set[str]:
    """The exact Stripe Price IDs allowed to grant Tono Pro: the configured
    monthly + yearly plan prices (env-var NAMES declared by the versioned
    commercial catalog). A Price ID absent from this set — wrong, foreign, or a
    sibling product's — grants nothing. Empty when unconfigured, which together
    with the fail-closed webhook 503 means no grant is possible."""
    ids: set[str] = set()
    for interval in ("month", "year"):
        pid = _price_for("pro", interval)
        if pid:
            ids.add(pid)
    return ids


def _matched_canonical_price_id(sub: dict) -> Optional[str]:
    """Return the canonical Tono Pro Price ID iff the subscription bills EXACTLY
    ONE line item whose Price ID is in the configured allowlist.

    Refuses (returns None) on a missing price id, a foreign/wrong Price ID, or a
    multi-line subscription — a multi-line sub could otherwise smuggle a foreign
    price alongside a Tono one. This is the sole price gate on granting: a
    subscription whose money does not correspond EXACTLY to one canonical Tono
    plan grants nothing.
    """
    allow = _canonical_price_ids()
    if not allow:
        return None
    items = (sub.get("items") or {}).get("data") or []
    if len(items) != 1:
        return None
    price = items[0].get("price") or {}
    pid = price.get("id")
    if isinstance(pid, str) and pid in allow:
        return pid
    return None


def _payment_method_fingerprint(sub: dict) -> Optional[str]:
    """Return Stripe's stable card fingerprint when this payment rail exposes it."""
    payment_method = sub.get("default_payment_method")
    if not payment_method:
        return None
    if isinstance(payment_method, str):
        payment_method = stripe.PaymentMethod.retrieve(payment_method)
    card = payment_method.get("card") or {}
    fingerprint = card.get("fingerprint")
    return str(fingerprint) if fingerprint else None


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


def _stripe_event_to_dict(event: Any) -> dict:
    """Normalize a verified Stripe SDK Event before durable JSON storage."""
    if isinstance(event, dict):
        return event
    for method_name in ("to_dict_recursive", "to_dict"):
        method = getattr(event, method_name, None)
        if callable(method):
            try:
                result = method()
            except Exception:
                continue
            if isinstance(result, dict):
                return result
    raise TypeError(f"verified Stripe {type(event).__name__} is not JSON serializable")
