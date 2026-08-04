"""RevenueCat canary intake for Tono (build 123).

RevenueCat is the FIRST Tono canary for a unified subscription lifecycle across
iOS, Android, and web/Stripe. It is an isolated per-product project: its SDK keys,
entitlements, webhooks, aliases, and customer identity are NEVER shared with any
other product. RevenueCat does not replace Tono auth, Supabase, Vercel/Render,
Resend, OAuth/passkeys, branding, domains, or product history.

Two surfaces:

  POST /v1/revenuecat/notifications  -> RevenueCat's authenticated server webhook.
                                        We authenticate the shared Authorization
                                        header (constant-time), durably persist the
                                        event in a product-specific inbox keyed by
                                        the RevenueCat event id, then idempotently
                                        project it into the SAME provider fact +
                                        entitlement model every other provider uses
                                        (provider_purchases -> entitlement_grants,
                                        provider='revenuecat'). 2xx only after the
                                        event is durably owned (or is an exact
                                        duplicate); a non-duplicate inbox write
                                        failure returns a retryable 5xx.
  GET  /v1/revenuecat/readiness      -> non-secret booleans an operator/monitor can
                                        poll to see which config is wired.

Trust model (contract §5): the RevenueCat webhook is a server-to-server call that
RevenueCat has ALREADY verified against the underlying store (Apple/Google/Stripe);
we authenticate it with the shared Authorization secret the operator configures in
the RevenueCat dashboard. We NEVER trust a client-supplied CustomerInfo as
authorization, and we never fabricate active state. The immutable Tono account UUID
(accounts.id) is the ONLY entitlement principal — it is the RevenueCat App User ID
the clients set via Purchases.logIn(accountId); an event whose app_user_id does not
resolve to a real account records the provider fact but grants nothing (fail
closed). An optional REST re-query (when a real secret key is configured) is a
reconciliation cross-check, not a gate — the supplied credential is legacy v1 /
Test Store, so the primary authority is the authenticated webhook.

Canary boundary (contract §6): TONO_REVENUECAT_MODE gates everything.
  off            (default) -> the webhook 503s (kill switch); clients do not
                              configure the SDK. No dual authority, no source risk.
  shadow                   -> events are recorded as append-only provider facts and
                              compared against the legacy projection, but do NOT
                              write entitlement_grants. The legacy path stays the
                              SOLE deterministic entitlement writer.
  authoritative            -> RevenueCat writes grants; the legacy path is disabled
                              for RevenueCat-managed channels (documented rollback
                              boundary). Never indefinite dual authority.

Fail-closed configuration (no secret ever reaches a client):
  TONO_REVENUECAT_MODE            off | shadow | authoritative (default off)
  TONO_REVENUECAT_WEBHOOK_AUTH    the Authorization header value configured in the
                                  RevenueCat dashboard; required for shadow/
                                  authoritative or the webhook 503s.
  TONO_REVENUECAT_ENTITLEMENT_ID  the RevenueCat entitlement identifier mapped to
                                  the canonical 'pro' entitlement (default 'pro').
  TONO_REVENUECAT_SECRET_API_KEY  optional RevenueCat REST secret for the
                                  reconciliation re-query hook.
  TONO_REVENUECAT_PROJECT_ID      optional, surfaced by readiness only.

Tests override ``get_revenuecat_authenticator`` and ``get_revenuecat_config`` via
``app.dependency_overrides`` — the same indirection app_store.py / google_play.py
use — so the suite never needs a real RevenueCat secret or network.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import hmac
import json
import os
import time
from dataclasses import dataclass, field
from typing import Annotated, Any, Callable, Optional

from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel

from . import catalog
from .auth import StoreDep
from .store import Store

router = APIRouter(tags=["revenuecat"])

# Retry ceiling before a durably-owned event is moved to the dead-letter state.
_MAX_ATTEMPTS = 8

# The canonical server entitlement RevenueCat maps to. Kept as a fail-safe if the
# committed catalog can't be read; test_revenuecat pins it equal to the catalog.
_ENTITLEMENT_FALLBACK = "pro"

# RevenueCat event.type values, grouped by their effect on entitlement. We read
# the type + the verified timestamps to decide; an unknown type never grants and
# never wrongly revokes (fail safe). See RevenueCat "Webhook events" reference.
_TYPES_GRANT = frozenset({
    "INITIAL_PURCHASE",
    "RENEWAL",
    "UNCANCELLATION",
    "PRODUCT_CHANGE",
    "SUBSCRIPTION_EXTENDED",
    "NON_RENEWING_PURCHASE",
    "TEMPORARY_ENTITLEMENT_GRANT",
})
# Access continues until the already-paid period lapses (auto-renew off / dunning).
_TYPES_CONTINUE_UNTIL_EXPIRY = frozenset({"CANCELLATION", "BILLING_ISSUE"})
# Natural, soft-terminal end — versioned, cannot resurrect once newer.
_TYPES_EXPIRE = frozenset({"EXPIRATION", "SUBSCRIPTION_PAUSED"})
# Hard-terminal revocation — always wins regardless of stored version.
_TYPES_HARD_REVOKE = frozenset({"REFUND", "CHARGEBACK", "SUBSCRIPTION_REVOKED"})
# Cancellation reasons that are really an immediate refund/chargeback revoke.
_REFUND_CANCEL_REASONS = frozenset({"CUSTOMER_SUPPORT"})
# Handled by dedicated identity paths, not entitlement projection.
_TYPES_IDENTITY = frozenset({"SUBSCRIBER_ALIAS", "TRANSFER"})
# Non-actionable.
_TYPES_IGNORE = frozenset({"TEST"})


# ---------------------------------------------------------------------------
# Typed errors -> processing outcome
# ---------------------------------------------------------------------------


class RevenueCatAuthError(Exception):
    """The webhook Authorization header failed constant-time comparison. -> 401.
    We never process an unauthenticated webhook."""


class RevenueCatValidationError(Exception):
    """A structurally-invalid event that will never succeed on retry (bad shape,
    missing required fields). Dead-lettered, not retried."""


class RevenueCatTransient(Exception):
    """A recoverable failure (e.g. the optional re-query is temporarily down).
    The durably-owned event is left for the reconciler / RevenueCat redelivery."""


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


def _default_entitlement_id() -> str:
    try:
        return catalog.revenuecat_default_entitlement_id()
    except catalog.CatalogError:
        return _ENTITLEMENT_FALLBACK


def _default_product_ids() -> frozenset[str]:
    """The store product ids RevenueCat sells for Tono (shared Apple/Google ids),
    read from the catalog. Used only to label/validate; entitlement follows the
    RevenueCat entitlement id, not the raw product id."""
    try:
        return catalog.google_play_subscription_ids()
    except catalog.CatalogError:
        return frozenset({"com.tonoit.pro.monthly", "com.tonoit.pro.yearly"})


@dataclass
class RevenueCatConfig:
    mode: str  # 'off' | 'shadow' | 'authoritative'
    webhook_auth: str
    entitlement_id: str
    secret_api_key: str = ""
    project_id: str = ""
    # HMAC signing secret for the X-RevenueCat-Webhook-Signature header. Optional
    # so the seam can ship and be tested before RevenueCat's provider-side signing
    # is switched on (a human-only enablement); once this is set, a valid, fresh
    # signature becomes MANDATORY on every webhook (see the verifier). It is
    # DEFENCE IN DEPTH — the Authorization shared secret is still enforced too.
    webhook_hmac_secret: str = ""
    product_ids: frozenset[str] = field(default_factory=frozenset)

    @property
    def enabled(self) -> bool:
        return self.mode in ("shadow", "authoritative")

    @property
    def writes_grants(self) -> bool:
        return self.mode == "authoritative"


_VALID_MODES = frozenset({"off", "shadow", "authoritative"})


def get_revenuecat_config() -> RevenueCatConfig:
    """Assemble + validate config, failing closed. An unknown mode, or an enabled
    mode without a webhook secret, is a hard 503 — never a silently-open webhook."""
    mode = (os.environ.get("TONO_REVENUECAT_MODE", "off") or "off").strip().lower()
    if mode not in _VALID_MODES:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            f"TONO_REVENUECAT_MODE must be one of {sorted(_VALID_MODES)}; got {mode!r}",
        )
    webhook_auth = (os.environ.get("TONO_REVENUECAT_WEBHOOK_AUTH", "") or "").strip()
    if mode in ("shadow", "authoritative") and not webhook_auth:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "RevenueCat is enabled but TONO_REVENUECAT_WEBHOOK_AUTH is not set.",
        )
    entitlement_id = (
        os.environ.get("TONO_REVENUECAT_ENTITLEMENT_ID", "").strip() or _default_entitlement_id()
    )
    return RevenueCatConfig(
        mode=mode,
        webhook_auth=webhook_auth,
        entitlement_id=entitlement_id,
        secret_api_key=(os.environ.get("TONO_REVENUECAT_SECRET_API_KEY", "") or "").strip(),
        project_id=(os.environ.get("TONO_REVENUECAT_PROJECT_ID", "") or "").strip(),
        webhook_hmac_secret=(os.environ.get("TONO_REVENUECAT_WEBHOOK_HMAC_SECRET", "") or "").strip(),
        product_ids=_default_product_ids(),
    )


RevenueCatConfigDep = Annotated[RevenueCatConfig, Depends(get_revenuecat_config)]


def _require_enabled(config: RevenueCatConfig) -> None:
    """Kill switch: any RevenueCat surface 503s while mode is 'off'."""
    if not config.enabled:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "RevenueCat intake is disabled on this server (TONO_REVENUECAT_MODE=off).",
        )


# ---------------------------------------------------------------------------
# Webhook authentication seam (overridable in tests)
# ---------------------------------------------------------------------------


class RevenueCatWebhookAuthenticator:
    """Verify the shared Authorization header RevenueCat attaches to every webhook
    (configured in the RevenueCat dashboard). Compared in constant time so a wrong
    or absent secret can never deliver an event we act on. This is RevenueCat's
    supported webhook authorization mechanism."""

    def __init__(self, expected: str):
        self._expected = expected

    def verify(self, request: Request) -> None:
        provided = request.headers.get("authorization", "")
        if not provided or not self._expected:
            raise RevenueCatAuthError("missing webhook authorization")
        # Constant-time compare of the full header value against the configured
        # secret. RevenueCat sends the raw configured value (operators commonly set
        # a "Bearer <token>" string); we compare verbatim so it matches whatever
        # was configured, with no scheme assumptions.
        if not hmac.compare_digest(provided, self._expected):
            raise RevenueCatAuthError("webhook authorization mismatch")


def get_revenuecat_authenticator(
    config: RevenueCatConfigDep,
) -> RevenueCatWebhookAuthenticator:
    _require_enabled(config)
    if not config.webhook_auth:  # defensive; get_revenuecat_config already guards
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "RevenueCat webhook authorization is not configured on this server.",
        )
    return RevenueCatWebhookAuthenticator(config.webhook_auth)


RevenueCatAuthDep = Annotated[RevenueCatWebhookAuthenticator, Depends(get_revenuecat_authenticator)]


# ---------------------------------------------------------------------------
# Webhook HMAC signature verification (defence in depth over the Authorization
# header). Enforced whenever a signing secret is configured on this server.
# ---------------------------------------------------------------------------

# RevenueCat attaches the signature (and its timestamp) in this header. We accept
# the canonical Stripe-style compound form ``t=<unix_seconds>,v1=<hex>`` (one or
# more v1 values), and — as a fallback — a bare hex signature paired with a
# separate timestamp header, so a minor provider format change cannot silently
# turn verification off (an unparsable header fails CLOSED).
_SIGNATURE_HEADER = "x-revenuecat-webhook-signature"
_TIMESTAMP_HEADER = "x-revenuecat-webhook-timestamp"
# Replay window: a signature whose timestamp is more than this far from now (in
# either direction) is rejected, so a captured-and-replayed body cannot be
# re-submitted later even with its original valid signature.
_SIGNATURE_MAX_SKEW_SECONDS = 300  # 5 minutes


def _module_now_s() -> float:
    return time.time()


class RevenueCatSignatureError(RevenueCatAuthError):
    """The X-RevenueCat-Webhook-Signature was missing, malformed, stale, or did
    not match the HMAC of ``timestamp.raw_body`` under the configured secret.
    Always a 401 — a webhook whose signature we cannot verify is never processed.
    Subclasses RevenueCatAuthError so the endpoint's existing 401 mapping covers
    it without a second handler."""


def _parse_signature_header(raw_header: str, ts_header: str) -> tuple[int, list[str]]:
    """Parse ``t=<unix>,v1=<hex>[,v1=<hex>]`` (order-independent), or a bare hex
    signature plus a separate timestamp header. Returns (timestamp, [sig,...]).
    Raises RevenueCatSignatureError on anything it cannot parse — fail closed."""
    header = (raw_header or "").strip()
    if not header:
        raise RevenueCatSignatureError("missing webhook signature")
    ts: Optional[int] = None
    sigs: list[str] = []
    if "=" in header:
        for part in header.split(","):
            part = part.strip()
            if not part or "=" not in part:
                continue
            key, _, value = part.partition("=")
            key = key.strip().lower()
            value = value.strip()
            if key == "t":
                try:
                    ts = int(value)
                except ValueError:
                    raise RevenueCatSignatureError("malformed signature timestamp")
            elif key in ("v1", "sig", "signature") and value:
                sigs.append(value)
    else:
        # Bare signature: the timestamp must come from the dedicated header.
        sigs.append(header)
    if ts is None:
        try:
            ts = int((ts_header or "").strip())
        except (TypeError, ValueError):
            raise RevenueCatSignatureError("missing signature timestamp")
    if not sigs:
        raise RevenueCatSignatureError("no signature value present")
    return ts, sigs


class RevenueCatSignatureVerifier:
    """Verify ``HMAC-SHA256(secret, f"{timestamp}.{raw_body}")`` against the
    provided X-RevenueCat-Webhook-Signature, in constant time, within a 5-minute
    replay window. The signed message is the EXACT raw request bytes (never a
    re-serialized JSON), so byte-for-byte integrity is what is proven."""

    def __init__(self, secret: str, *, now_s: Callable[[], float] = _module_now_s,
                 max_skew_seconds: int = _SIGNATURE_MAX_SKEW_SECONDS):
        self._secret = (secret or "").encode("utf-8")
        self._now_s = now_s
        self._max_skew = max_skew_seconds

    def _expected(self, timestamp: int, raw_body: bytes) -> str:
        message = f"{timestamp}.".encode("utf-8") + raw_body
        return hmac.new(self._secret, message, hashlib.sha256).hexdigest()

    def verify(self, raw_body: bytes, headers) -> None:
        if not self._secret:
            # Defensive: a verifier is only built when a secret exists; an empty
            # secret must never "verify" anything.
            raise RevenueCatSignatureError("signature secret not configured")
        ts, sigs = _parse_signature_header(
            headers.get(_SIGNATURE_HEADER, ""), headers.get(_TIMESTAMP_HEADER, "")
        )
        skew = abs(self._now_s() - ts)
        if skew > self._max_skew:
            raise RevenueCatSignatureError("stale webhook signature (outside replay window)")
        expected = self._expected(ts, raw_body)
        # Constant-time compare against each candidate; accept if ANY matches so a
        # provider that rotates keys (two v1 values during rotation) still verifies.
        if not any(hmac.compare_digest(expected, candidate) for candidate in sigs):
            raise RevenueCatSignatureError("webhook signature mismatch")


def get_revenuecat_signature_verifier(
    config: RevenueCatConfigDep,
) -> Optional[RevenueCatSignatureVerifier]:
    """A verifier when a signing secret is configured, else None (Authorization
    remains the enforced boundary). Overridable in tests via
    ``app.dependency_overrides`` to inject a fixed clock / known secret."""
    _require_enabled(config)
    if not config.webhook_hmac_secret:
        return None
    return RevenueCatSignatureVerifier(config.webhook_hmac_secret)


RevenueCatSignatureDep = Annotated[
    Optional[RevenueCatSignatureVerifier], Depends(get_revenuecat_signature_verifier)
]


# ---------------------------------------------------------------------------
# Event parsing + entitlement decision
# ---------------------------------------------------------------------------


@dataclass
class RevenueCatEvent:
    event_id: str
    type: str
    app_user_id: Optional[str]
    original_app_user_id: Optional[str]
    aliases: list[str]
    product_id: Optional[str]
    entitlement_ids: list[str]
    store_source: Optional[str]
    environment: str  # 'PRODUCTION' | 'SANDBOX'
    event_ms: int
    expiration_ms: Optional[int]
    grace_expiration_ms: Optional[int]
    original_transaction_id: str
    cancel_reason: Optional[str]
    transferred_from: list[str]
    transferred_to: list[str]
    raw: dict[str, Any]


def _coerce_int(value: Any) -> Optional[int]:
    try:
        if value is None:
            return None
        return int(value)
    except (TypeError, ValueError):
        return None


def _as_list(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(v) for v in value if v is not None]
    if value is None:
        return []
    return [str(value)]


def parse_revenuecat_event(body: dict[str, Any]) -> RevenueCatEvent:
    """Parse the RevenueCat webhook envelope ``{"event": {...}}`` into a typed
    event. Raises RevenueCatValidationError on a shape we can never process — the
    caller dead-letters it rather than retrying forever."""
    if not isinstance(body, dict):
        raise RevenueCatValidationError("webhook body is not an object")
    event = body.get("event")
    if not isinstance(event, dict):
        raise RevenueCatValidationError("webhook body has no 'event' object")
    event_id = event.get("id")
    if not event_id or not isinstance(event_id, str):
        raise RevenueCatValidationError("event has no string 'id'")
    etype = event.get("type")
    if not etype or not isinstance(etype, str):
        raise RevenueCatValidationError("event has no string 'type'")

    app_user_id = event.get("app_user_id") or None
    original_app_user_id = event.get("original_app_user_id") or None
    # Stable lineage key: prefer the store's original transaction id; fall back to
    # the transaction id, then to a deterministic per-user/product key so a
    # non-renewing/lifetime purchase without a transaction id still has a lineage.
    otid = (
        event.get("original_transaction_id")
        or event.get("transaction_id")
        or f"rc:{app_user_id or original_app_user_id or 'unknown'}:{event.get('product_id') or 'unknown'}"
    )

    return RevenueCatEvent(
        event_id=event_id,
        type=etype,
        app_user_id=app_user_id,
        original_app_user_id=original_app_user_id,
        aliases=_as_list(event.get("aliases")),
        product_id=event.get("product_id") or event.get("new_product_id") or None,
        entitlement_ids=_as_list(event.get("entitlement_ids") or event.get("entitlement_id")),
        store_source=event.get("store") or None,
        environment=(event.get("environment") or "PRODUCTION"),
        event_ms=_coerce_int(event.get("event_timestamp_ms")) or 0,
        expiration_ms=_coerce_int(event.get("expiration_at_ms")),
        grace_expiration_ms=_coerce_int(event.get("grace_period_expiration_at_ms")),
        original_transaction_id=str(otid),
        cancel_reason=event.get("cancel_reason") or None,
        transferred_from=_as_list(event.get("transferred_from")),
        transferred_to=_as_list(event.get("transferred_to")),
        raw=event,
    )


@dataclass
class EntitlementDecision:
    lifecycle_state: str  # 'active' | 'expired' | 'refunded' | 'revoked'
    entitled: bool
    hard_terminal: bool
    expires_ms: Optional[int]


def _now_ms() -> int:
    return int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)


def decide_entitlement(event: RevenueCatEvent, config: RevenueCatConfig) -> EntitlementDecision:
    """Map an authenticated RevenueCat event to our normalized entitlement
    decision. Every field is read from the RevenueCat-verified event; a client
    CustomerInfo is never consulted. Unknown types never grant and never revoke.

    Entitlement mapping only applies when this event concerns the entitlement we
    care about — RevenueCat's entitlement id(s) must include our configured id (or
    the store product must be one of ours) — otherwise the event is not our
    concern and no entitlement change is projected.
    """
    now_ms = _now_ms()
    expiry_future = event.expiration_ms is not None and event.expiration_ms > now_ms
    grace_future = event.grace_expiration_ms is not None and event.grace_expiration_ms > now_ms

    etype = event.type

    if etype in _TYPES_HARD_REVOKE:
        return EntitlementDecision("revoked", False, True, event.expiration_ms)

    if etype in _TYPES_GRANT:
        # Non-renewing / lifetime purchases have no expiry -> perpetual grant.
        if event.expiration_ms is None:
            return EntitlementDecision("active", True, False, None)
        return EntitlementDecision(
            "active" if expiry_future else "expired", bool(expiry_future), False, event.expiration_ms
        )

    if etype in _TYPES_CONTINUE_UNTIL_EXPIRY:
        # A refund delivered as a CANCELLATION reason is an immediate hard revoke.
        if event.cancel_reason and event.cancel_reason in _REFUND_CANCEL_REASONS:
            return EntitlementDecision("revoked", False, True, event.expiration_ms)
        # Billing-issue grace: keep access while the grace window is open.
        entitled = bool(expiry_future or grace_future)
        return EntitlementDecision(
            "active" if entitled else "expired", entitled, False, event.expiration_ms
        )

    if etype in _TYPES_EXPIRE:
        return EntitlementDecision("expired", False, False, event.expiration_ms)

    # Unknown / non-entitlement type: no change.
    return EntitlementDecision("", False, False, event.expiration_ms)


def _event_concerns_our_entitlement(event: RevenueCatEvent, config: RevenueCatConfig) -> bool:
    """True when the event is about the entitlement we project. Match on the
    configured RevenueCat entitlement id, or on one of our store product ids as a
    fallback (some event types omit entitlement_ids)."""
    if config.entitlement_id in event.entitlement_ids:
        return True
    if not event.entitlement_ids and event.product_id in config.product_ids:
        return True
    # Hard-revoke / expiry events sometimes omit both; still act on them if the
    # lineage is one we already track (checked by the caller against the store).
    return False


# ---------------------------------------------------------------------------
# Endpoint: webhook intake
# ---------------------------------------------------------------------------


def _resolve_account_id(store: Store, event: RevenueCatEvent) -> Optional[str]:
    """The RevenueCat App User ID must be the canonical account UUID. Return it
    only when it names a real account; otherwise None (the fact is still recorded
    with the claimed binding, but no grant is written — fail closed)."""
    candidate = event.app_user_id or event.original_app_user_id
    if not candidate:
        return None
    if store.get_account(candidate) is not None:
        return candidate
    return None


def _project_event(store: Store, config: RevenueCatConfig, event: RevenueCatEvent) -> str:
    """Project one authenticated event. Returns a terminal outcome label. Raises
    RevenueCatValidationError (dead-letter) or RevenueCatTransient (retry)."""
    # Identity-only events never touch entitlement (controlled aliasing; never a
    # silent cross-account merge).
    if event.type in _TYPES_IDENTITY:
        return _handle_identity_event(store, config, event)
    if event.type in _TYPES_IGNORE:
        return f"ignored:{event.type.lower()}"

    resolved_account = _resolve_account_id(store, event)
    # The claimed binding (app_user_id) is recorded on the fact even when it does
    # not resolve, so a later reconcile can bind it; the grant is gated separately.
    claimed_account = event.app_user_id or event.original_app_user_id

    tracked = store.get_provider_purchase(
        event.original_transaction_id, provider="revenuecat"
    ) if hasattr(store, "get_provider_purchase") else None

    if not _event_concerns_our_entitlement(event, config) and tracked is None:
        # Not our entitlement and not a lineage we track -> nothing to project.
        return f"ignored:not_our_entitlement:{event.type.lower()}"

    decision = decide_entitlement(event, config)
    if not decision.lifecycle_state:
        return f"ignored:unknown_type:{event.type.lower()}"

    # Shadow vs authoritative: only the authoritative mode writes grants. Shadow
    # still records the append-only provider fact for reconciliation.
    write_grant = config.writes_grants
    applied = store.apply_revenuecat_fact(
        account_id=claimed_account,
        original_transaction_id=event.original_transaction_id,
        product_id=event.product_id or "revenuecat_pro",
        lifecycle_state=decision.lifecycle_state,
        entitled=decision.entitled,
        signed_ms=event.event_ms,
        expires_ms=decision.expires_ms,
        environment="production" if event.environment == "PRODUCTION" else "sandbox",
        hard_terminal=decision.hard_terminal,
        write_grant=write_grant,
    )

    # Canary comparison: RevenueCat-derived entitlement vs the legacy projection.
    legacy_active = False
    if resolved_account is not None:
        acct = store.get_account(resolved_account)
        legacy_active = bool(acct.is_pro) if acct is not None else False
    store.record_revenuecat_shadow_observation(
        event_id=event.event_id,
        account_id=resolved_account,
        revenuecat_active=decision.entitled,
        legacy_active=legacy_active,
        mode=config.mode,
        # The originating store is the flip-eligibility class key: a PROMOTIONAL
        # admin grant is excluded from the shadow->authoritative flip decision
        # (retained in lifetime diagnostics), while a real store's disagreement
        # still blocks the flip. Carried straight from the RevenueCat event.
        store_source=event.store_source,
        detail=f"{event.type}:{applied}",
    )

    account_label = "bound" if resolved_account else "no_account"
    return f"{config.mode}:{applied}:{account_label}"


def _handle_identity_event(store: Store, config: RevenueCatConfig, event: RevenueCatEvent) -> str:
    """SUBSCRIBER_ALIAS / TRANSFER. The RevenueCat App User ID is the immutable
    account UUID, so we NEVER merge two accounts from an alias. A TRANSFER revokes
    any grant on the transferred-away lineage for the source account(s); the
    destination account re-earns entitlement through its own purchase/restore
    events (or a reconcile), never by fabrication here."""
    if event.type == "SUBSCRIBER_ALIAS":
        # Controlled aliasing: reject anonymous->identified merges. We do not
        # copy or merge any entitlement across app_user_ids.
        return "alias_rejected:no_merge"

    # TRANSFER: revoke source grants for a tracked lineage (authoritative mode
    # only — shadow never mutates grants). Records nothing new for the target.
    if config.writes_grants and hasattr(store, "get_provider_purchase"):
        tracked = store.get_provider_purchase(
            event.original_transaction_id, provider="revenuecat"
        )
        if tracked is not None:
            store.apply_revenuecat_fact(
                account_id=None,
                original_transaction_id=event.original_transaction_id,
                product_id=tracked.get("product_id") or "revenuecat_pro",
                lifecycle_state="revoked",
                entitled=False,
                signed_ms=event.event_ms,
                expires_ms=None,
                environment=tracked.get("environment") or "production",
                hard_terminal=True,
                write_grant=True,
            )
            return "transfer:source_revoked"
    return "transfer:noop"


@router.post("/v1/revenuecat/notifications")
async def revenuecat_notifications(
    request: Request,
    store: StoreDep,
    config: RevenueCatConfigDep,
    authenticator: RevenueCatAuthDep,
    signature_verifier: RevenueCatSignatureDep,
) -> dict[str, Any]:
    # 1) Authenticated boundary FIRST — an unauthenticated webhook is rejected
    #    before we parse or persist anything. The Authorization shared secret is
    #    kept as defence in depth even when HMAC signing is enabled.
    try:
        authenticator.verify(request)
    except RevenueCatAuthError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, f"webhook authentication failed: {exc}")

    raw_body = await request.body()

    # 2) HMAC signature over the EXACT raw body (timestamp.raw_json), enforced
    #    whenever a signing secret is configured. Missing / malformed / stale /
    #    wrong signatures fail CLOSED here, before any parse or persist.
    if signature_verifier is not None:
        try:
            signature_verifier.verify(raw_body, request.headers)
        except RevenueCatAuthError as exc:
            raise HTTPException(
                status.HTTP_401_UNAUTHORIZED, f"webhook signature verification failed: {exc}"
            )

    try:
        body = json.loads(raw_body.decode("utf-8"))
    except Exception:  # noqa: BLE001
        raise HTTPException(400, "malformed webhook body")

    try:
        event = parse_revenuecat_event(body)
    except RevenueCatValidationError as exc:
        # Structurally invalid: RevenueCat should not retry a permanent failure.
        raise HTTPException(400, str(exc))

    # 2) Durable, product-specific inbox keyed by the RevenueCat event id. A
    #    non-duplicate INSERT failure propagates -> retryable 5xx (contract §5).
    payload_text = json.dumps(body, separators=(",", ":"))[:1_000_000]
    inbox = store.record_revenuecat_event(
        event_id=event.event_id,
        event_type=event.type,
        payload=payload_text,
        app_user_id=event.app_user_id or event.original_app_user_id,
        store_source=event.store_source,
        environment=event.environment,
        event_ms=event.event_ms,
    )
    if inbox == "duplicate_ok":
        return {"received": True, "duplicate": True, "event_id": event.event_id}

    # 3) Idempotent processing. The event is now durably owned, so a processing
    #    failure returns 2xx and is retried by the reconciler (or a RevenueCat
    #    redelivery, which hits 'duplicate_pending' and re-processes) — we never
    #    lose the event and never 5xx after durable ownership.
    try:
        outcome = _project_event(store, config, event)
    except RevenueCatValidationError as exc:
        store.mark_revenuecat_event_dead_letter(event.event_id, str(exc))
        return {"received": True, "outcome": "dead_letter", "detail": str(exc)}
    except Exception as exc:  # noqa: BLE001 — transient; keep for retry
        attempts = store.mark_revenuecat_event_failed(event.event_id, str(exc))
        if attempts >= _MAX_ATTEMPTS:
            store.mark_revenuecat_event_dead_letter(event.event_id, "retry ceiling reached")
            return {"received": True, "outcome": "dead_letter", "detail": "retry ceiling"}
        return {"received": True, "outcome": "retry_scheduled", "attempts": attempts}

    store.mark_revenuecat_event_processed(event.event_id, outcome)
    return {"received": True, "outcome": outcome, "event_id": event.event_id}


# ---------------------------------------------------------------------------
# Endpoint: readiness (non-secret)
# ---------------------------------------------------------------------------


@router.get("/v1/revenuecat/readiness")
def revenuecat_readiness(store: StoreDep) -> dict[str, Any]:
    """Non-secret readiness probe. Reveals ONLY booleans, already-public
    identifiers, and aggregate COUNTS so an operator/monitor can see which config
    is wired and whether the shadow canary is clean, without exposing any secret
    value or account identifier (contract §5/§9). Never raises on mode=off.

    Shadow reconciliation is reported as THREE non-secret views so the flip
    decision is honest about what it is (and is not) counting:
      * ``shadow`` — lifetime cumulative counts over EVERY observation, including
        RevenueCat PROMOTIONAL admin grants. Diagnostics only; NOT the flip gate.
      * ``shadow_flip_eligible`` — real store-parity canaries only (App Store /
        Play / Stripe / RC Billing / ...). This is the ONLY input to
        ``shadow_clean``.
      * ``shadow_excluded_promotional`` — count of PROMOTIONAL observations kept
        in lifetime diagnostics but excluded from the flip decision, because a
        promotional grant makes RevenueCat active with no store purchase and so
        legitimately disagrees with the free legacy projection in shadow mode.
      * ``shadow_excluded_synthetic`` — count of self-issued/TEST_STORE
        integration canaries: durably auditable transport probes that likewise
        make RevenueCat active with no real purchase, so they are excluded from
        the flip decision and never counted as real store evidence.
    ``shadow_unclassified`` counts observations whose store could not be
    classified; they FAIL CLOSED (block the flip) and are never assumed
    promotional or clean. ``shadow_clean`` is true only when there are zero
    flip-eligible disagreements AND zero unclassified observations; it degrades
    to null (never true) on any read error."""
    mode = (os.environ.get("TONO_REVENUECAT_MODE", "off") or "off").strip().lower()
    webhook_configured = bool((os.environ.get("TONO_REVENUECAT_WEBHOOK_AUTH", "") or "").strip())
    secret_configured = bool((os.environ.get("TONO_REVENUECAT_SECRET_API_KEY", "") or "").strip())
    hmac_configured = bool((os.environ.get("TONO_REVENUECAT_WEBHOOK_HMAC_SECRET", "") or "").strip())
    mode_valid = mode in _VALID_MODES
    enabled = mode in ("shadow", "authoritative")
    # Shadow-canary observability: non-secret counts only, so an operator can
    # confirm zero eligible disagreements over a window before flipping shadow ->
    # authoritative. `shadow_clean` is derived ONLY from the flip-eligible summary
    # (promotional admin grants never enter the decision) and is fail-closed: any
    # eligible disagreement OR any unclassifiable store blocks the flip. Degrades
    # to nulls / shadow_clean=None on any read error — readiness never raises and
    # never reports clean when it cannot prove cleanliness.
    try:
        shadow = store.revenuecat_shadow_summary()
        flip = store.revenuecat_shadow_flip_summary()
        flip_eligible = flip["eligible"]
        excluded_promotional = flip["excluded_promotional"]
        excluded_synthetic = flip["excluded_synthetic"]
        unclassified = flip["unclassified"]
        shadow_clean = flip_eligible["disagreements"] == 0 and unclassified == 0
    except Exception:  # noqa: BLE001 — readiness never raises; fail closed
        shadow = {"total": None, "agreements": None, "disagreements": None, "last_observed_at": None}
        flip_eligible = {"total": None, "agreements": None, "disagreements": None}
        excluded_promotional = None
        excluded_synthetic = None
        unclassified = None
        shadow_clean = None
    return {
        "provider": "revenuecat",
        "mode": mode if mode_valid else "invalid",
        "enabled": enabled,
        "webhook_auth_configured": webhook_configured,
        # Presence only — the HMAC signing secret value is never surfaced. When
        # true, a valid fresh X-RevenueCat-Webhook-Signature is MANDATORY.
        "webhook_hmac_configured": hmac_configured,
        "reconcile_requery_configured": secret_configured,
        "writes_grants": mode == "authoritative",
        "entitlement_id": _default_entitlement_id(),
        "offering": _safe_offering(),
        "product_ids": sorted(_default_product_ids()),
        "catalog_version": _safe_catalog_version(),
        # Ready to accept webhooks: an enabled, valid mode with a webhook secret.
        "ready": bool(mode_valid and enabled and webhook_configured),
        # Shadow reconciliation counts (no identifiers). `shadow` is lifetime
        # (incl. promotional) diagnostics; the flip gate is derived from the
        # eligible summary only, with unclassified stores failing closed.
        "shadow": shadow,
        "shadow_flip_eligible": flip_eligible,
        "shadow_excluded_promotional": excluded_promotional,
        "shadow_excluded_synthetic": excluded_synthetic,
        "shadow_unclassified": unclassified,
        "shadow_clean": shadow_clean,
    }


def _safe_catalog_version() -> str:
    try:
        return catalog.catalog_version()
    except catalog.CatalogError:
        return "unknown"


def _safe_offering() -> Optional[str]:
    try:
        return catalog.revenuecat_offering()
    except catalog.CatalogError:
        return None


# ---------------------------------------------------------------------------
# Reconciliation (drain the durable inbox; admin-safe)
# ---------------------------------------------------------------------------


def reconcile_revenuecat(store: Store, config: RevenueCatConfig) -> dict[str, int]:
    """Drain received/failed inbox events, re-projecting each idempotently. A
    transient failure re-marks the event failed (retriable); a permanent failure
    or the retry ceiling moves it to dead-letter. Returns a tally. Safe to call
    on startup and on a schedule; a no-op when RevenueCat is disabled."""
    processed = 0
    failed = 0
    dead = 0
    if not config.enabled:
        return {"processed": 0, "failed": 0, "dead_letter": 0}
    for row in store.list_revenuecat_events_for_retry(max_attempts=_MAX_ATTEMPTS):
        try:
            body = json.loads(row["payload"])
            event = parse_revenuecat_event(body)
        except Exception as exc:  # noqa: BLE001 — unparseable stored payload is permanent
            store.mark_revenuecat_event_dead_letter(row["event_id"], f"unparseable: {exc}")
            dead += 1
            continue
        try:
            outcome = _project_event(store, config, event)
        except RevenueCatValidationError as exc:
            store.mark_revenuecat_event_dead_letter(row["event_id"], str(exc))
            dead += 1
            continue
        except Exception as exc:  # noqa: BLE001 — transient
            attempts = store.mark_revenuecat_event_failed(row["event_id"], str(exc))
            if attempts >= _MAX_ATTEMPTS:
                store.mark_revenuecat_event_dead_letter(row["event_id"], "retry ceiling reached")
                dead += 1
            else:
                failed += 1
            continue
        store.mark_revenuecat_event_processed(row["event_id"], outcome)
        processed += 1
    return {"processed": processed, "failed": failed, "dead_letter": dead}
