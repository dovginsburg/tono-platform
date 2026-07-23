"""Google Play server-side entitlement seam for Tono (Android).

This is the Android analogue of ``app_store.py``. Three surfaces:

  POST /v1/google-play/subscription   -> an authenticated device uploads the
                                         opaque Play purchase token; we verify it
                                         SERVER-SIDE through the Google Play
                                         Developer API, adjudicate ownership
                                         against the canonical account UUID, apply
                                         a durable purchase + grant, acknowledge,
                                         and return authoritative /v1/me state.
  POST /v1/google-play/notifications  -> Real-time Developer Notifications (RTDN)
                                         delivered over a Google Cloud Pub/Sub
                                         push subscription. The push is
                                         authenticated (OIDC id-token or a
                                         documented shared-secret boundary); we
                                         decode + validate the DeveloperNotification
                                         envelope, dedupe by Pub/Sub messageId,
                                         then RE-QUERY the Developer API as the
                                         sole entitlement authority and reconcile.
  GET  /v1/google-play/readiness      -> non-secret booleans an operator/monitor
                                         can poll to see which credentials are
                                         wired (never any secret value).

Trust model (contract §2/§4): the purchase token is opaque and carries NO
self-verifiable claims — security comes entirely from the authenticated
server-to-server Developer API call. We therefore NEVER trust a client- or
notification-supplied product/plan/expiry/acknowledgement claim; every field
that gates entitlement is read from the verified ``purchases.subscriptionsv2.get``
response. The RTDN payload is treated as a hint that something changed, never as
authority — we always re-query. The canonical, immutable Tono account UUID
remains the only entitlement principal; obfuscatedExternalAccountId binds the
purchase to it, and absent that, a first-claim lineage lock prevents a token
from being replayed across accounts.

Fail-closed configuration (no secret ever reaches a client):
  TONO_GOOGLE_SERVICE_ACCOUNT_JSON  Play Developer API service-account key
                                    (inline JSON or a file path). Verification is
                                    unavailable (503) until set — exactly like
                                    Apple verification is 503 without its root CA.
  TONO_GOOGLE_PACKAGE_NAME          expected Android package (default from the
                                    versioned commercial catalog: com.tono.myapp)
  TONO_GOOGLE_SUBSCRIPTION_IDS      comma-separated allowed subscription ids
                                    (default from the catalog)
  TONO_GOOGLE_BASE_PLAN_IDS         comma-separated allowed base-plan ids. The
                                    exact console ids are NOT invented in-repo; a
                                    purchase whose base plan is absent from this
                                    set fails closed and never grants (contract §6).
  RTDN push authentication (one of):
  TONO_GOOGLE_PUBSUB_AUDIENCE +     verify the Pub/Sub OIDC id-token audience and
  TONO_GOOGLE_PUBSUB_SA_EMAIL         signing service-account email (preferred).
  TONO_GOOGLE_PUBSUB_SHARED_TOKEN   documented shared-secret boundary: Pub/Sub is
                                    configured to append ?token=... and we compare
                                    it in constant time. Used only when OIDC is
                                    not configured.

Tests override ``get_google_play_verifier`` and ``get_google_push_authenticator``
via ``app.dependency_overrides`` with fakes, so the suite never needs Google's
network, a real service account, or a live Pub/Sub OIDC token — the same
indirection app_store.py / social_auth.py use.
"""

from __future__ import annotations

import datetime as dt
import hmac
import json
import os
from dataclasses import dataclass, field
from typing import Annotated, Any, Optional

from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel

from . import catalog
from .app_store import compute_me_fields
from .auth import CurrentUser, StoreDep
from .store import Store

router = APIRouter(tags=["google-play"])

_ANDROIDPUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher"

# Historical literal defaults, kept as a fail-safe if the committed commercial
# catalog can't be read. test_commercial_catalog pins them equal to the catalog
# so they can never drift from the single source of truth.
_GOOGLE_PACKAGE_FALLBACK = "com.tono.myapp"
_GOOGLE_SUBSCRIPTION_IDS_FALLBACK = "com.tonoit.pro.monthly,com.tonoit.pro.yearly"

# RTDN subscriptionNotification.notificationType values we care about. We do NOT
# trust the type for entitlement (we re-query), but REVOKED must escalate to a
# hard-terminal revoke even if a lagging Developer API read still looks active.
_NTYPE_SUBSCRIPTION_REVOKED = 12
_NTYPE_SUBSCRIPTION_EXPIRED = 13

# Google Play subscriptionState -> our normalized decision. Access follows the
# provider truth: ACTIVE/GRACE entitle; CANCELED entitles only while the paid
# period it already covers has not lapsed (canceled-at-period-end); ON_HOLD/
# PAUSED/PENDING are recoverable non-entitled states; EXPIRED is soft-terminal.
_STATE_ACTIVE = "SUBSCRIPTION_STATE_ACTIVE"
_STATE_CANCELED = "SUBSCRIPTION_STATE_CANCELED"
_STATE_IN_GRACE = "SUBSCRIPTION_STATE_IN_GRACE_PERIOD"
_STATE_ON_HOLD = "SUBSCRIPTION_STATE_ON_HOLD"
_STATE_PAUSED = "SUBSCRIPTION_STATE_PAUSED"
_STATE_PENDING = "SUBSCRIPTION_STATE_PENDING"
_STATE_EXPIRED = "SUBSCRIPTION_STATE_EXPIRED"


# ---------------------------------------------------------------------------
# Typed errors -> HTTP contract
# ---------------------------------------------------------------------------


class GooglePlayValidationError(Exception):
    """Verified provider state that is malformed / for the wrong package /
    product / base plan, or otherwise cannot be trusted to grant. -> 422."""


class GooglePlayUnavailable(Exception):
    """The Developer API could not be reached or trusted (transport, auth,
    5xx, rate-limit). Callers fail closed with a retryable 503 rather than
    granting on stale or absent provider state."""


class GooglePlayNotFound(Exception):
    """The Developer API reports the purchase token is unknown/purged (404/410).
    Treated as invalid evidence on the direct path and as a terminal revoke on
    the notification path — never as a grant."""


class GooglePushAuthError(Exception):
    """The RTDN push request failed authentication. -> 401/403; we never process
    an unauthenticated push."""


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


def _default_google_subscription_ids() -> str:
    try:
        ids = sorted(catalog.google_play_subscription_ids())
        if ids:
            return ",".join(ids)
    except catalog.CatalogError:
        pass
    return _GOOGLE_SUBSCRIPTION_IDS_FALLBACK


def _default_google_package_name() -> str:
    try:
        pkg = catalog.google_play_package_name()
        if pkg:
            return pkg
    except catalog.CatalogError:
        pass
    return _GOOGLE_PACKAGE_FALLBACK


def _csv_frozenset(raw: str) -> frozenset[str]:
    return frozenset(p.strip() for p in raw.split(",") if p.strip())


@dataclass
class GooglePlayConfig:
    package_name: str
    subscription_ids: frozenset[str]
    # The allowed base-plan ids. Empty (unconfigured) means base-plan validation
    # can NEVER pass, so a verified purchase cannot grant until the operator
    # supplies the console ids — the intended fail-closed gate (contract §6).
    base_plan_ids: frozenset[str] = field(default_factory=frozenset)


def get_google_play_config() -> GooglePlayConfig:
    return GooglePlayConfig(
        package_name=os.environ.get("TONO_GOOGLE_PACKAGE_NAME", _default_google_package_name()),
        subscription_ids=_csv_frozenset(
            os.environ.get("TONO_GOOGLE_SUBSCRIPTION_IDS", _default_google_subscription_ids())
        ),
        base_plan_ids=_csv_frozenset(os.environ.get("TONO_GOOGLE_BASE_PLAN_IDS", "")),
    )


GooglePlayConfigDep = Annotated[GooglePlayConfig, Depends(get_google_play_config)]


# ---------------------------------------------------------------------------
# Developer API verifier seam (overridable in tests)
# ---------------------------------------------------------------------------


class AndroidPublisherVerifier:
    """Production Developer API client. Wraps an ``androidpublisher`` service and
    surfaces every transport/credential/5xx failure as GooglePlayUnavailable so
    the endpoint fails closed. Built lazily from a configured service account;
    tests inject a fake with the same surface."""

    def __init__(self, service: Any):
        self._service = service

    def get_subscription_v2(self, package_name: str, token: str) -> dict[str, Any]:
        try:
            from googleapiclient.errors import HttpError  # lazy
        except Exception as exc:  # pragma: no cover - defensive
            raise GooglePlayUnavailable(f"google client library unavailable: {exc}") from exc
        try:
            return (
                self._service.purchases()
                .subscriptionsv2()
                .get(packageName=package_name, token=token)
                .execute()
            )
        except HttpError as exc:
            code = getattr(getattr(exc, "resp", None), "status", None)
            if code in (404, 410):
                raise GooglePlayNotFound(f"purchase token not found ({code})") from exc
            raise GooglePlayUnavailable(f"developer API error {code}") from exc
        except Exception as exc:  # noqa: BLE001 — never silently bypass
            raise GooglePlayUnavailable(str(exc)) from exc

    def acknowledge(self, package_name: str, subscription_id: str, token: str) -> None:
        try:
            from googleapiclient.errors import HttpError  # lazy
        except Exception as exc:  # pragma: no cover - defensive
            raise GooglePlayUnavailable(f"google client library unavailable: {exc}") from exc
        try:
            (
                self._service.purchases()
                .subscriptions()
                .acknowledge(
                    packageName=package_name,
                    subscriptionId=subscription_id,
                    token=token,
                    body={},
                )
                .execute()
            )
        except HttpError as exc:
            code = getattr(getattr(exc, "resp", None), "status", None)
            # Already acknowledged is a benign, idempotent no-op (Play returns a
            # 400 with an "already acknowledged" detail). Anything else is a
            # retriable failure that must NOT erase the granted entitlement.
            detail = str(exc).lower()
            if code == 400 and "already" in detail:
                return
            raise GooglePlayUnavailable(f"acknowledge failed ({code})") from exc
        except Exception as exc:  # noqa: BLE001
            raise GooglePlayUnavailable(str(exc)) from exc


def _build_androidpublisher_verifier() -> Optional[AndroidPublisherVerifier]:
    raw = os.environ.get("TONO_GOOGLE_SERVICE_ACCOUNT_JSON", "").strip()
    if not raw:
        return None
    try:
        from google.oauth2 import service_account  # lazy
        from googleapiclient.discovery import build  # lazy
    except Exception:  # pragma: no cover - defensive: treat as unconfigured
        return None
    if raw.startswith("{"):
        info = json.loads(raw)
        creds = service_account.Credentials.from_service_account_info(
            info, scopes=[_ANDROIDPUBLISHER_SCOPE]
        )
    elif os.path.exists(raw):
        creds = service_account.Credentials.from_service_account_file(
            raw, scopes=[_ANDROIDPUBLISHER_SCOPE]
        )
    else:
        info = json.loads(raw)
        creds = service_account.Credentials.from_service_account_info(
            info, scopes=[_ANDROIDPUBLISHER_SCOPE]
        )
    service = build("androidpublisher", "v3", credentials=creds, cache_discovery=False)
    return AndroidPublisherVerifier(service)


def get_google_play_verifier() -> AndroidPublisherVerifier:
    verifier = _build_androidpublisher_verifier()
    if verifier is None:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "Google Play verification is not configured on this server.",
        )
    return verifier


GooglePlayVerifierDep = Annotated[AndroidPublisherVerifier, Depends(get_google_play_verifier)]


# ---------------------------------------------------------------------------
# RTDN push authentication seam (overridable in tests)
# ---------------------------------------------------------------------------


class OidcPushAuthenticator:
    """Verify the Google-signed OIDC id-token Pub/Sub attaches to each push
    request (Authorization: Bearer). The audience and signing service-account
    email are both checked, so only our configured Pub/Sub push subscription can
    deliver a notification we will act on."""

    def __init__(self, audience: str, sa_email: Optional[str]):
        self._audience = audience
        self._sa_email = sa_email

    def verify(self, request: Request) -> None:
        header = request.headers.get("authorization", "")
        if not header.lower().startswith("bearer "):
            raise GooglePushAuthError("missing bearer id-token")
        token = header[7:].strip()
        try:
            from google.auth.transport import requests as g_requests  # lazy
            from google.oauth2 import id_token  # lazy
        except Exception as exc:  # pragma: no cover - defensive
            raise GooglePushAuthError(f"oidc verification unavailable: {exc}") from exc
        try:
            claims = id_token.verify_oauth2_token(
                token, g_requests.Request(), audience=self._audience
            )
        except Exception as exc:  # noqa: BLE001 — any failure is a rejected push
            raise GooglePushAuthError(f"invalid oidc id-token: {exc}") from exc
        if not claims.get("email_verified"):
            raise GooglePushAuthError("push id-token email not verified")
        if self._sa_email and claims.get("email") != self._sa_email:
            raise GooglePushAuthError("push id-token from unexpected service account")


class SharedTokenPushAuthenticator:
    """Documented fail-closed fallback: Pub/Sub is configured to append a secret
    ``?token=`` query param to the push endpoint and we compare it in constant
    time. Used only when OIDC is not configured."""

    def __init__(self, secret: str):
        self._secret = secret

    def verify(self, request: Request) -> None:
        provided = request.query_params.get("token", "")
        if not provided or not hmac.compare_digest(provided, self._secret):
            raise GooglePushAuthError("invalid push shared token")


def get_google_push_authenticator():
    audience = os.environ.get("TONO_GOOGLE_PUBSUB_AUDIENCE", "").strip()
    sa_email = os.environ.get("TONO_GOOGLE_PUBSUB_SA_EMAIL", "").strip() or None
    if audience:
        return OidcPushAuthenticator(audience, sa_email)
    shared = os.environ.get("TONO_GOOGLE_PUBSUB_SHARED_TOKEN", "").strip()
    if shared:
        return SharedTokenPushAuthenticator(shared)
    raise HTTPException(
        status.HTTP_503_SERVICE_UNAVAILABLE,
        "Google Play RTDN push authentication is not configured on this server.",
    )


GooglePushAuthDep = Annotated[Any, Depends(get_google_push_authenticator)]


# ---------------------------------------------------------------------------
# Normalization of the verified SubscriptionPurchaseV2 -> our decision
# ---------------------------------------------------------------------------


@dataclass
class VerifiedSubscription:
    subscription_id: str
    base_plan_id: Optional[str]
    lifecycle_state: str
    entitled: bool
    hard_terminal: bool
    expires_ms: Optional[int]
    obfuscated_account_id: Optional[str]
    linked_purchase_token: Optional[str]
    acknowledged: bool
    environment: str  # 'test' | 'production'


def _parse_rfc3339_ms(value: Optional[str]) -> Optional[int]:
    if not value:
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = dt.datetime.fromisoformat(text)
    except ValueError:
        # Trim sub-second precision Python's fromisoformat can't take, retry.
        try:
            head, _, tail = text.partition(".")
            tz = ""
            for marker in ("+", "-"):
                idx = tail.find(marker)
                if idx > 0:
                    tz = tail[idx:]
                    break
            parsed = dt.datetime.fromisoformat(head + tz)
        except ValueError:
            raise GooglePlayValidationError(f"unparseable timestamp {value!r}")
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return int(parsed.timestamp() * 1000)


def normalize_subscription_v2(
    raw: dict[str, Any], config: GooglePlayConfig
) -> VerifiedSubscription:
    """Turn a verified ``purchases.subscriptionsv2.get`` response into our
    normalized entitlement decision. Every gating field is read from the verified
    provider payload; a client claim is never consulted. Fails closed (422) on a
    wrong/unknown product, a base plan not in the configured allow-set, or an
    unrecognised subscription state."""

    line_items = raw.get("lineItems") or []
    if not line_items:
        raise GooglePlayValidationError("subscription has no line items")

    # Choose the line item whose product is one of ours (there is normally one).
    chosen = None
    for item in line_items:
        if item.get("productId") in config.subscription_ids:
            chosen = item
            break
    if chosen is None:
        seen = [i.get("productId") for i in line_items]
        raise GooglePlayValidationError(f"no known subscription product in {seen!r}")

    subscription_id = chosen["productId"]

    offer = chosen.get("offerDetails") or {}
    base_plan_id = offer.get("basePlanId")
    # Fail closed on the base plan: an unconfigured allow-set (or a base plan
    # outside it) can never grant (contract §6). This is what keeps a purchase
    # from granting until the operator confirms the console base-plan ids.
    if not base_plan_id or base_plan_id not in config.base_plan_ids:
        raise GooglePlayValidationError(
            f"base plan {base_plan_id!r} is not in the configured allow-set"
        )

    expires_ms = _parse_rfc3339_ms(chosen.get("expiryTime"))

    sub_state = raw.get("subscriptionState")
    now_ms = int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)
    expiry_future = expires_ms is not None and expires_ms > now_ms

    if sub_state == _STATE_ACTIVE:
        lifecycle, entitled = "active", True
    elif sub_state == _STATE_IN_GRACE:
        lifecycle, entitled = "grace", True
    elif sub_state == _STATE_CANCELED:
        # Auto-renew off. Access continues until the already-paid period lapses.
        lifecycle, entitled = "canceled", bool(expiry_future)
        if not entitled:
            lifecycle = "expired"
    elif sub_state == _STATE_ON_HOLD:
        lifecycle, entitled = "on_hold", False
    elif sub_state == _STATE_PAUSED:
        lifecycle, entitled = "paused", False
    elif sub_state == _STATE_PENDING:
        lifecycle, entitled = "pending", False
    elif sub_state == _STATE_EXPIRED:
        lifecycle, entitled = "expired", False
    else:
        raise GooglePlayValidationError(f"unrecognized subscriptionState {sub_state!r}")

    ext = raw.get("externalAccountIdentifiers") or {}
    obfuscated = ext.get("obfuscatedExternalAccountId") or None

    ack_state = raw.get("acknowledgementState")
    acknowledged = ack_state == "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED"

    environment = "test" if raw.get("testPurchase") is not None else "production"

    return VerifiedSubscription(
        subscription_id=subscription_id,
        base_plan_id=base_plan_id,
        lifecycle_state=lifecycle,
        entitled=entitled,
        hard_terminal=False,
        expires_ms=expires_ms,
        obfuscated_account_id=obfuscated,
        linked_purchase_token=raw.get("linkedPurchaseToken") or None,
        acknowledged=acknowledged,
        environment=environment,
    )


# ---------------------------------------------------------------------------
# RTDN envelope decoding
# ---------------------------------------------------------------------------


@dataclass
class SubscriptionNotification:
    notification_type: int
    purchase_token: str
    subscription_id: Optional[str]


@dataclass
class DeveloperNotification:
    version: Optional[str]
    package_name: Optional[str]
    event_time_ms: Optional[int]
    subscription: Optional[SubscriptionNotification]
    is_test: bool


def decode_developer_notification(message: dict[str, Any]) -> DeveloperNotification:
    """Base64-decode + JSON-parse the Pub/Sub message.data into a
    DeveloperNotification. Structural failures raise GooglePlayValidationError
    (the caller maps to 400) — a push we cannot even parse is never acted on."""
    import base64

    data = message.get("data")
    if not data:
        raise GooglePlayValidationError("push message has no data")
    try:
        decoded = base64.b64decode(data)
        payload = json.loads(decoded.decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        raise GooglePlayValidationError(f"undecodable notification payload: {exc}") from exc

    sub = payload.get("subscriptionNotification")
    subscription = None
    if isinstance(sub, dict):
        token = sub.get("purchaseToken")
        ntype = sub.get("notificationType")
        if not token or ntype is None:
            raise GooglePlayValidationError("subscriptionNotification missing token/type")
        try:
            ntype_int = int(ntype)
        except (TypeError, ValueError):
            raise GooglePlayValidationError("subscriptionNotification type is not an int")
        subscription = SubscriptionNotification(
            notification_type=ntype_int,
            purchase_token=str(token),
            subscription_id=sub.get("subscriptionId"),
        )

    return DeveloperNotification(
        version=payload.get("version"),
        package_name=payload.get("packageName"),
        event_time_ms=_coerce_int(payload.get("eventTimeMillis")),
        subscription=subscription,
        is_test=payload.get("testNotification") is not None,
    )


def _coerce_int(value: Any) -> Optional[int]:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


class GooglePurchaseSyncRequest(BaseModel):
    purchase_token: str
    # The client MAY send its product id for logging, but we ignore it for
    # entitlement and read the verified productId from the Developer API instead.
    subscription_id: Optional[str] = None


@router.post("/v1/google-play/subscription")
def sync_subscription(
    body: GooglePurchaseSyncRequest,
    user: CurrentUser,
    store: StoreDep,
    verifier: GooglePlayVerifierDep,
    config: GooglePlayConfigDep,
) -> dict[str, Any]:
    # Purchase requires the canonical account UUID — the only entitlement
    # principal. Its absence is a setup error, never a silent device fallback.
    if not user.account_id:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "account setup incomplete; cannot bind a purchase"
        )
    token = (body.purchase_token or "").strip()
    if not token:
        raise HTTPException(422, "missing purchase_token")

    try:
        raw = verifier.get_subscription_v2(config.package_name, token)
    except GooglePlayNotFound as exc:
        raise HTTPException(422, f"purchase token is not valid: {exc}")
    except GooglePlayUnavailable:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "Google Play verification is temporarily unavailable",
        )

    try:
        verified = normalize_subscription_v2(raw, config)
    except GooglePlayValidationError as exc:
        raise HTTPException(422, str(exc))

    now_ms = int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)
    result = store.apply_google_purchase(
        account_id=user.account_id,
        purchase_token=token,
        subscription_id=verified.subscription_id,
        obfuscated_account_id=verified.obfuscated_account_id,
        lifecycle_state=verified.lifecycle_state,
        entitled=verified.entitled,
        hard_terminal=verified.hard_terminal,
        signed_ms=now_ms,
        expires_ms=verified.expires_ms,
        environment=verified.environment,
        linked_purchase_token=verified.linked_purchase_token,
        acknowledged=verified.acknowledged,
    )

    if result.outcome == "conflict":
        raise HTTPException(status.HTTP_409_CONFLICT, "purchase belongs to a different account")

    # Acknowledge only AFTER a successful ownership binding + grant (contract §5),
    # best-effort and idempotent. A transient failure leaves the durable ack op
    # pending for the reconciler and NEVER erases the entitlement we just granted.
    if result.granted and result.acknowledge_pending:
        _best_effort_acknowledge(store, verifier, config, verified.subscription_id, token)

    fresh = store.get_by_device(user.device_id) or user
    return compute_me_fields(fresh, store)


def _best_effort_acknowledge(
    store: Store,
    verifier: AndroidPublisherVerifier,
    config: GooglePlayConfig,
    subscription_id: str,
    token: str,
) -> None:
    ops = {
        op["purchase_token"]: op
        for op in store.list_pending_google_acknowledgements()
    }
    op = ops.get(token)
    if op is None:
        return
    try:
        verifier.acknowledge(config.package_name, subscription_id, token)
    except Exception as exc:  # noqa: BLE001 — retriable; entitlement stays intact
        store.mark_provider_operation(op["op_id"], state="failed", error=str(exc))
        return
    store.mark_provider_operation(op["op_id"], state="succeeded")


@router.post("/v1/google-play/notifications")
async def google_play_notifications(
    request: Request,
    store: StoreDep,
    verifier: GooglePlayVerifierDep,
    authenticator: GooglePushAuthDep,
    config: GooglePlayConfigDep,
) -> dict[str, Any]:
    # 1) Authenticated boundary FIRST — an unauthenticated push is rejected
    #    before we parse anything (contract §4).
    try:
        authenticator.verify(request)
    except GooglePushAuthError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, f"push authentication failed: {exc}")

    try:
        envelope = await request.json()
    except Exception:  # noqa: BLE001
        raise HTTPException(400, "malformed push body")
    message = (envelope or {}).get("message")
    if not isinstance(message, dict):
        raise HTTPException(400, "push envelope has no message")
    message_id = message.get("messageId") or message.get("message_id")
    if not message_id:
        raise HTTPException(400, "push message has no messageId")

    # 2) Decode + validate the DeveloperNotification (version + package).
    try:
        notification = decode_developer_notification(message)
    except GooglePlayValidationError as exc:
        raise HTTPException(400, str(exc))
    if notification.package_name and notification.package_name != config.package_name:
        raise HTTPException(400, "notification is for a different package")
    if notification.version and notification.version != "1.0":
        raise HTTPException(400, f"unsupported notification version {notification.version!r}")

    ntype = notification.subscription.notification_type if notification.subscription else -1

    # 3) Durable idempotency inbox by Pub/Sub messageId. A duplicate delivery is
    #    acknowledged without re-projecting (contract §4/§9).
    if not store.record_provider_notification("google", str(message_id), f"type:{ntype}"):
        return {"received": True, "outcome": "duplicate"}

    if notification.is_test or notification.subscription is None:
        # A test notification (or a non-subscription notification) has nothing to
        # project; acknowledge so Pub/Sub stops retrying.
        return {"received": True, "outcome": "ignored"}

    sub = notification.subscription
    token = sub.purchase_token
    event_ms = notification.event_time_ms or 0

    # 4) Re-query the Developer API as the SOLE entitlement authority. The
    #    notification is never trusted for state (contract §4).
    try:
        raw = verifier.get_subscription_v2(config.package_name, token)
    except GooglePlayNotFound:
        outcome = _apply_terminal_revoke(store, token, event_ms, reason="not_found")
        return {"received": True, "outcome": outcome}
    except GooglePlayUnavailable:
        # Fail closed + retryable: a 503 makes Pub/Sub redeliver later.
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "Google Play verification is temporarily unavailable",
        )

    # A REVOKED notification escalates to a hard-terminal revoke even if a lagging
    # read still looks active; we still re-queried, so we honour a genuine active
    # read for every other type.
    if ntype == _NTYPE_SUBSCRIPTION_REVOKED:
        subscription_id = _resolve_subscription_id(raw, config, store, token)
        result = store.apply_google_purchase(
            account_id=None,
            purchase_token=token,
            subscription_id=subscription_id,
            obfuscated_account_id=None,
            lifecycle_state="revoked",
            entitled=False,
            hard_terminal=True,
            signed_ms=event_ms,
            expires_ms=None,
            environment="production",
        )
        return {"received": True, "outcome": result.outcome, "state": "revoked"}

    try:
        verified = normalize_subscription_v2(raw, config)
    except GooglePlayValidationError as exc:
        # Deterministic validation failure won't fix on retry; fail closed
        # (grant nothing) and acknowledge so Pub/Sub stops redelivering.
        return {"received": True, "outcome": "validation_failed", "detail": str(exc)}

    result = store.apply_google_purchase(
        account_id=None,
        purchase_token=token,
        subscription_id=verified.subscription_id,
        obfuscated_account_id=verified.obfuscated_account_id,
        lifecycle_state=verified.lifecycle_state,
        entitled=verified.entitled,
        hard_terminal=verified.hard_terminal,
        signed_ms=event_ms,
        expires_ms=verified.expires_ms,
        environment=verified.environment,
        linked_purchase_token=verified.linked_purchase_token,
        acknowledged=verified.acknowledged,
    )
    return {"received": True, "outcome": result.outcome, "state": verified.lifecycle_state}


def _resolve_subscription_id(
    raw: dict[str, Any], config: GooglePlayConfig, store: Store, token: str
) -> str:
    """Best-effort product id for a revoke: prefer the verified line item, fall
    back to the stored lineage, then to a stable sentinel so the terminal revoke
    can always be recorded (a revoke must never be dropped for lack of a label)."""
    for item in raw.get("lineItems") or []:
        if item.get("productId") in config.subscription_ids:
            return item["productId"]
    existing = store.get_provider_purchase(token, provider="google")
    if existing and existing.get("product_id"):
        return existing["product_id"]
    return "unknown"


def _apply_terminal_revoke(store: Store, token: str, event_ms: int, *, reason: str) -> str:
    """Record a hard-terminal revoke for a token the Developer API no longer
    knows. Only touches an existing lineage; an unknown token has nothing to
    revoke and is reported as such (never grants)."""
    existing = store.get_provider_purchase(token, provider="google")
    if not existing:
        return "unknown_purchase"
    result = store.apply_google_purchase(
        account_id=None,
        purchase_token=token,
        subscription_id=existing.get("product_id") or "unknown",
        obfuscated_account_id=None,
        lifecycle_state="revoked",
        entitled=False,
        hard_terminal=True,
        signed_ms=event_ms,
        expires_ms=None,
        environment=existing.get("environment") or "production",
    )
    return result.outcome


@router.get("/v1/google-play/readiness")
def google_play_readiness(config: GooglePlayConfigDep) -> dict[str, Any]:
    """Non-secret readiness probe. Reveals ONLY booleans + already-public
    identifiers so an operator/monitor can see which credentials are wired
    without exposing any secret value (contract §5)."""
    push_configured = bool(
        os.environ.get("TONO_GOOGLE_PUBSUB_AUDIENCE", "").strip()
        or os.environ.get("TONO_GOOGLE_PUBSUB_SHARED_TOKEN", "").strip()
    )
    push_mode = (
        "oidc"
        if os.environ.get("TONO_GOOGLE_PUBSUB_AUDIENCE", "").strip()
        else ("shared_token" if os.environ.get("TONO_GOOGLE_PUBSUB_SHARED_TOKEN", "").strip() else "none")
    )
    ready = bool(
        os.environ.get("TONO_GOOGLE_SERVICE_ACCOUNT_JSON", "").strip()
        and push_configured
        and config.base_plan_ids
    )
    return {
        "provider": "google_play",
        "verification_configured": bool(
            os.environ.get("TONO_GOOGLE_SERVICE_ACCOUNT_JSON", "").strip()
        ),
        "push_auth_configured": push_configured,
        "push_auth_mode": push_mode,
        "base_plans_configured": bool(config.base_plan_ids),
        "package_name": config.package_name,
        "subscription_ids": sorted(config.subscription_ids),
        "catalog_version": _safe_catalog_version(),
        "ready": ready,
    }


def _safe_catalog_version() -> str:
    try:
        return catalog.catalog_version()
    except catalog.CatalogError:
        return "unknown"


# ---------------------------------------------------------------------------
# Acknowledgement reconciliation (admin-safe; contract §5)
# ---------------------------------------------------------------------------


def reconcile_google_acknowledgements(
    store: Store, verifier: AndroidPublisherVerifier, config: GooglePlayConfig
) -> dict[str, int]:
    """Drain pending/failed acknowledge ops. Each op is retried against the
    Developer API; a transient failure marks it 'failed' (retriable) and never
    touches the entitlement. Only lineages still entitled are acknowledged — a
    purchase revoked before we could acknowledge is dropped. Returns a tally."""
    acknowledged = 0
    failed = 0
    dropped = 0
    for op in store.list_pending_google_acknowledgements():
        if (op.get("lifecycle_state") or "") not in ("active", "grace", "canceled"):
            # No longer entitled -> nothing to acknowledge; retire the op.
            store.mark_provider_operation(op["op_id"], state="succeeded")
            dropped += 1
            continue
        try:
            verifier.acknowledge(config.package_name, op["subscription_id"], op["purchase_token"])
        except Exception as exc:  # noqa: BLE001 — retriable
            store.mark_provider_operation(op["op_id"], state="failed", error=str(exc))
            failed += 1
            continue
        store.mark_provider_operation(op["op_id"], state="succeeded")
        acknowledged += 1
    return {"acknowledged": acknowledged, "failed": failed, "dropped": dropped}


def get_reconcile_verifier() -> Optional[AndroidPublisherVerifier]:
    """The verifier used by the startup acknowledge reconciler, or None when the
    Developer API is unconfigured (reconcile is simply skipped)."""
    return _build_androidpublisher_verifier()
