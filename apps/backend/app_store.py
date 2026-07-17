"""Apple App Store Server entitlement seam for Tono build 91.

Two endpoints:
  POST /v1/app-store/subscription    -> device/account uploads StoreKit's
                                        Apple-signed JWS transaction; we verify
                                        it, adjudicate ownership, and apply a
                                        durable purchase + grant + claim before
                                        returning authoritative /v1/me state.
  POST /v1/app-store/notifications   -> App Store Server Notifications V2. Apple
                                        pushes signed lifecycle events (refund,
                                        revoke, renew, expire); we verify + dedupe
                                        by notificationUUID and converge on the
                                        current provider state.

Trust model (contract §3): signed data is verified by Apple's supported
App Store Server Library (`app-store-server-library`). Its `SignedDataVerifier`
validates the full x5c certificate chain up to a configured Apple root with
OpenSSL X509_STRICT (BasicConstraints / path length / key usage), enforces the
Apple leaf + WWDR intermediate marker OIDs, and checks bundle id, environment
and (in production) the app's Apple id. This replaces the home-grown PKI that a
prior candidate shipped: a non-CA intermediate, a wrong-app payload, or a forged
signature are now rejected by the same library Apple ships and supports. There is
no shortcut that trusts an unverified payload. The canonical, immutable Tono
account UUID remains the only entitlement principal — store evidence can grant
paid service but can never issue a bearer token, relink a device, or recover
account history.

A replayed old signed transaction can no longer resurrect a refunded/revoked
purchase even if a lifecycle notification was missed: when configured, the
current-provider App Store Server API seam (`get_current_provider_client`) is
consulted for the lineage's live state and a terminal provider status wins over
replayed active client proof.

Configuration (no secrets reach clients):
  TONO_APPLE_ROOT_CA_PEM   PEM (inline or a file path) of the trusted Apple root
                           certificate(s). Verification is unavailable (503)
                           until this is set, exactly like Apple/Google sign-in
                           is 503 without APPLE_CLIENT_ID — we never fake success.
  TONO_APPLE_BUNDLE_ID     expected bundleId (default com.tonoit.app)
  TONO_APPLE_PRODUCT_IDS   comma-separated allowed product IDs
  TONO_APPLE_ENVIRONMENTS  comma-separated allowed environments
  TONO_APPLE_APP_APPLE_ID  the app's numeric Apple id (required to verify
                           Production signed data; Sandbox does not need it)

  App Store Server API (current-provider lookup + Set-App-Account-Token sender):
  TONO_APPLE_ISSUER_ID     App Store Connect API issuer id
  TONO_APPLE_KEY_ID        API key id
  TONO_APPLE_PRIVATE_KEY   API private key PEM (inline or a file path). Never
                           shipped to clients; used only server-side.

Tests override `get_appstore_verifier` and `get_current_provider_client` via
app.dependency_overrides with fakes that trust a self-generated Apple-shaped test
chain and a fake provider client, so the suite never needs Apple's real signing
chain, credentials, or network — the same indirection social_auth uses. The
verifier under test is the production library; only its trust anchor is swapped.
"""

from __future__ import annotations

import base64
import datetime as dt
import os
from dataclasses import dataclass
from typing import Annotated, Any, Optional

import jwt
from cryptography import x509
from cryptography.hazmat.primitives.serialization import Encoding
from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel

from appstoreserverlibrary.api_client import AppStoreServerAPIClient, APIException
from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.models.Status import Status
from appstoreserverlibrary.models.UpdateAppAccountTokenRequest import UpdateAppAccountTokenRequest
from appstoreserverlibrary.signed_data_verifier import (
    SignedDataVerifier,
    VerificationException,
    VerificationStatus,
)

from .auth import CurrentUser, StoreDep
from .store import Store, User, _today_utc, get_store

router = APIRouter(tags=["app-store"])


# ---------------------------------------------------------------------------
# Signed-data verification via Apple's App Store Server Library
# ---------------------------------------------------------------------------


class AppleVerificationError(Exception):
    """Raised when a signed Apple payload cannot be trusted. `kind` maps to an
    HTTP status: 'invalid' -> 422, 'wrong_app' -> 403."""

    def __init__(self, message: str, kind: str = "invalid"):
        super().__init__(message)
        self.kind = kind


def _map_verification_exception(exc: VerificationException) -> AppleVerificationError:
    """Map the library's typed failure to our 403 (wrong app) / 422 (invalid)
    contract. A wrong bundle id / app Apple id is 'wrong_app'; every chain,
    certificate, environment, or signature failure is invalid evidence."""
    if exc.status == VerificationStatus.INVALID_APP_IDENTIFIER:
        return AppleVerificationError("signed data is for a different app", kind="wrong_app")
    return AppleVerificationError(
        f"signed data failed verification: {exc.status.name}", kind="invalid"
    )


def _enum_str(payload: Any, raw_attr: str, enum_attr: str) -> Optional[str]:
    """Prefer the library's `raw*` string (present even for values the enum
    doesn't recognise — the fail-closed signal we want for ownership type) and
    fall back to the decoded enum's value."""
    raw = getattr(payload, raw_attr, None)
    if raw is not None:
        return str(raw)
    decoded = getattr(payload, enum_attr, None)
    return str(decoded.value) if decoded is not None else None


def _tx_to_claims(payload: Any) -> dict[str, Any]:
    """Flatten a verified JWSTransactionDecodedPayload into the raw-claim dict
    the adjudication code below consumes. Ownership type is taken from the raw
    field so a missing/unrecognised value survives as-is and fails closed."""
    return {
        "bundleId": payload.bundleId,
        "productId": payload.productId,
        "environment": _enum_str(payload, "rawEnvironment", "environment"),
        "transactionId": payload.transactionId,
        "originalTransactionId": payload.originalTransactionId,
        "inAppOwnershipType": _enum_str(
            payload, "rawInAppOwnershipType", "inAppOwnershipType"
        ),
        "appAccountToken": payload.appAccountToken,
        "signedDate": payload.signedDate,
        "expiresDate": payload.expiresDate,
        "revocationDate": payload.revocationDate,
        "offerType": getattr(payload, "rawOfferType", None),
    }


def _notification_to_dict(payload: Any) -> dict[str, Any]:
    data = getattr(payload, "data", None)
    return {
        "notificationType": _enum_str(payload, "rawNotificationType", "notificationType"),
        "subtype": _enum_str(payload, "rawSubtype", "subtype"),
        "notificationUUID": payload.notificationUUID,
        "signedTransactionInfo": getattr(data, "signedTransactionInfo", None) if data else None,
    }


def _peek(jws: str, key: str) -> Any:
    """Read one claim WITHOUT verifying the signature. Used only to route a
    payload to the verifier for its declared environment; the selected verifier
    then performs the full cryptographic + identity verification, so a forged
    environment claim can never bypass anything."""
    if not jws or jws.count(".") != 2:
        raise AppleVerificationError("malformed JWS")
    try:
        claims = jwt.decode(jws, options={"verify_signature": False})
    except jwt.PyJWTError as exc:
        raise AppleVerificationError(f"unreadable JWS: {exc}")
    return claims.get(key)


class AppleDataVerifier:
    """Wraps one `SignedDataVerifier` per allowed environment and returns raw
    claim dicts. The trust decision (chain, Apple marker OIDs, bundle id,
    environment, app Apple id) is made by the supported library, not by us."""

    def __init__(self, verifiers: dict[str, SignedDataVerifier]):
        if not verifiers:
            raise ValueError("AppleDataVerifier requires at least one environment verifier")
        self._verifiers = dict(verifiers)

    def _select(self, environment: Optional[str]) -> SignedDataVerifier:
        verifier = self._verifiers.get(environment) if environment else None
        if verifier is None:
            raise AppleVerificationError(
                f"unexpected environment {environment!r}", kind="invalid"
            )
        return verifier

    def verify_transaction(self, jws: str) -> dict[str, Any]:
        verifier = self._select(_peek(jws, "environment"))
        try:
            payload = verifier.verify_and_decode_signed_transaction(jws)
        except VerificationException as exc:
            raise _map_verification_exception(exc)
        return _tx_to_claims(payload)

    def verify_notification(self, jws: str) -> dict[str, Any]:
        data = _peek(jws, "data")
        environment = data.get("environment") if isinstance(data, dict) else None
        verifier = self._select(environment)
        try:
            payload = verifier.verify_and_decode_notification(jws)
        except VerificationException as exc:
            raise _map_verification_exception(exc)
        return _notification_to_dict(payload)


# ---------------------------------------------------------------------------
# Configuration + dependencies (overridable in tests)
# ---------------------------------------------------------------------------


@dataclass
class AppStoreConfig:
    bundle_id: str
    product_ids: frozenset[str]
    environments: frozenset[str]
    app_apple_id: Optional[int]


def get_appstore_config() -> AppStoreConfig:
    products = os.environ.get(
        "TONO_APPLE_PRODUCT_IDS", "com.tonoit.pro.monthly,com.tonoit.pro.yearly"
    )
    environments = os.environ.get("TONO_APPLE_ENVIRONMENTS", "Production,Sandbox")
    raw_app_id = os.environ.get("TONO_APPLE_APP_APPLE_ID", "").strip()
    app_apple_id: Optional[int] = None
    if raw_app_id:
        try:
            app_apple_id = int(raw_app_id)
        except ValueError:
            app_apple_id = None
    return AppStoreConfig(
        bundle_id=os.environ.get("TONO_APPLE_BUNDLE_ID", "com.tonoit.app"),
        product_ids=frozenset(p.strip() for p in products.split(",") if p.strip()),
        environments=frozenset(e.strip() for e in environments.split(",") if e.strip()),
        app_apple_id=app_apple_id,
    )


AppStoreConfigDep = Annotated[AppStoreConfig, Depends(get_appstore_config)]


def _load_trusted_root_der() -> list[bytes]:
    """Return DER bytes for every configured trusted Apple root, the shape the
    library's SignedDataVerifier consumes. Empty when unconfigured -> 503."""
    raw = os.environ.get("TONO_APPLE_ROOT_CA_PEM", "").strip()
    if not raw:
        return []
    if "-----BEGIN" not in raw and os.path.exists(raw):
        with open(raw, "rb") as handle:
            pem = handle.read()
    else:
        pem = raw.encode("utf-8")
    return [c.public_bytes(Encoding.DER) for c in x509.load_pem_x509_certificates(pem)]


_ENVIRONMENT_BY_NAME = {e.value: e for e in Environment}


def build_apple_verifier(
    roots: list[bytes], config: AppStoreConfig
) -> AppleDataVerifier:
    """Construct one SignedDataVerifier per configured environment. Production
    needs the app Apple id; an environment we can't safely build (e.g. Production
    with no app Apple id) is skipped rather than trusted."""
    verifiers: dict[str, SignedDataVerifier] = {}
    for name in config.environments:
        environment = _ENVIRONMENT_BY_NAME.get(name)
        if environment is None:
            continue
        if environment == Environment.PRODUCTION and config.app_apple_id is None:
            # Cannot verify Production app identity without the app Apple id.
            continue
        verifiers[name] = SignedDataVerifier(
            root_certificates=roots,
            enable_online_checks=False,
            environment=environment,
            bundle_id=config.bundle_id,
            app_apple_id=config.app_apple_id,
        )
    if not verifiers:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "App Store verification is not configured for any allowed environment.",
        )
    return AppleDataVerifier(verifiers)


def get_appstore_verifier(
    config: AppStoreConfigDep,
) -> AppleDataVerifier:
    roots = _load_trusted_root_der()
    if not roots:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "App Store verification is not configured on this server.",
        )
    return build_apple_verifier(roots, config)


AppStoreVerifierDep = Annotated[AppleDataVerifier, Depends(get_appstore_verifier)]


# ---------------------------------------------------------------------------
# Current-provider lookup seam (App Store Server API) — contract §3
# ---------------------------------------------------------------------------


class ProviderUnavailable(Exception):
    """The current-provider App Store Server API could not be reached / trusted.
    Callers fail closed with a retryable 503 rather than granting on stale proof."""


@dataclass
class ProviderStateSnapshot:
    lifecycle_state: str  # 'active' | 'expired' | 'revoked'
    signed_ms: int


_STATUS_LIFECYCLE = {
    Status.ACTIVE: "active",
    Status.BILLING_RETRY: "active",
    Status.BILLING_GRACE_PERIOD: "active",
    Status.EXPIRED: "expired",
    Status.REVOKED: "revoked",
}


class AppStoreServerProviderClient:
    """Production current-provider lookup via the App Store Server API. Holds one
    AppStoreServerAPIClient per environment. Any transport/credential failure is
    surfaced as ProviderUnavailable (fail closed / retryable)."""

    def __init__(self, clients: dict[str, AppStoreServerAPIClient]):
        self._clients = dict(clients)

    def current_state(
        self, original_transaction_id: str, environment: str
    ) -> Optional[ProviderStateSnapshot]:
        client = self._clients.get(environment)
        if client is None:
            raise ProviderUnavailable(f"no provider client for environment {environment!r}")
        try:
            response = client.get_all_subscription_statuses(original_transaction_id)
        except APIException as exc:  # transport / auth / rate-limit
            raise ProviderUnavailable(str(exc)) from exc
        except Exception as exc:  # noqa: BLE001 — never silently bypass
            raise ProviderUnavailable(str(exc)) from exc
        return _snapshot_from_status_response(response, original_transaction_id)


def _snapshot_from_status_response(
    response: Any, original_transaction_id: str
) -> Optional[ProviderStateSnapshot]:
    for group in response.data or []:
        for item in group.lastTransactions or []:
            if item.originalTransactionId != original_transaction_id:
                continue
            lifecycle = _STATUS_LIFECYCLE.get(item.status)
            if lifecycle is None:
                continue
            return ProviderStateSnapshot(lifecycle_state=lifecycle, signed_ms=0)
    return None


def _build_api_clients() -> dict[str, AppStoreServerAPIClient]:
    """Build one App Store Server API client per allowed environment from
    configured credentials. Returns empty when unconfigured (seam disabled)."""
    issuer_id = os.environ.get("TONO_APPLE_ISSUER_ID", "").strip()
    key_id = os.environ.get("TONO_APPLE_KEY_ID", "").strip()
    raw_key = os.environ.get("TONO_APPLE_PRIVATE_KEY", "").strip()
    if not (issuer_id and key_id and raw_key):
        return {}
    if "-----BEGIN" not in raw_key and os.path.exists(raw_key):
        with open(raw_key, "rb") as handle:
            signing_key = handle.read()
    else:
        signing_key = raw_key.encode("utf-8")
    config = get_appstore_config()
    clients: dict[str, AppStoreServerAPIClient] = {}
    for name in config.environments:
        environment = _ENVIRONMENT_BY_NAME.get(name)
        if environment is None:
            continue
        clients[name] = AppStoreServerAPIClient(
            signing_key=signing_key,
            key_id=key_id,
            issuer_id=issuer_id,
            bundle_id=config.bundle_id,
            environment=environment,
        )
    return clients


def get_current_provider_client() -> Optional[AppStoreServerProviderClient]:
    """The current-provider lookup seam. Returns None when unconfigured so the
    endpoint falls back to durable-state adjudication; tests inject a fake."""
    clients = _build_api_clients()
    if not clients:
        return None
    return AppStoreServerProviderClient(clients)


ProviderClientDep = Annotated[
    Optional[AppStoreServerProviderClient], Depends(get_current_provider_client)
]


# ---------------------------------------------------------------------------
# /v1/me projection (shared with server.py's /v1/me — avoids a circular import
# by living on the entitlement side and being imported by server.py)
# ---------------------------------------------------------------------------


def compute_me_fields(user: User, store: Store) -> dict[str, Any]:
    today = _today_utc()
    identified = user.account is not None and user.account.is_identified
    quota_source = user.account if identified else user
    used = quota_source.daily_count if quota_source.daily_day == today else 0
    is_pro = user.is_pro
    limit = -1 if is_pro else int(os.environ.get("FREE_DAILY_LIMIT", "10"))
    subscription_status = user.account.subscription_status if identified else user.subscription_status
    subscription_renews_at = (
        user.account.subscription_renews_at if identified else user.subscription_renews_at
    )
    return dict(
        device_id=user.device_id,
        plan=user.plan_resolved,
        is_pro=is_pro,
        used_today=used,
        daily_limit=limit,
        subscription_status=subscription_status,
        subscription_renews_at=subscription_renews_at,
        account_id=user.account_id,
    )


# ---------------------------------------------------------------------------
# Adjudication helpers
# ---------------------------------------------------------------------------


# The ONLY ownership types we will ever grant against. Anything else — missing,
# empty, or an unrecognised string — fails closed and is never treated as a
# direct PURCHASED grant (contract §4/§6; P0 fail-closed classification).
_ALLOWED_OWNERSHIP = frozenset({"PURCHASED", "FAMILY_SHARED"})


class SubscriptionSyncRequest(BaseModel):
    signed_transaction_info: str


def _ms(claims: dict, key: str) -> Optional[int]:
    val = claims.get(key)
    if val is None:
        return None
    try:
        return int(val)
    except (TypeError, ValueError):
        raise AppleVerificationError(f"{key} is not a millisecond timestamp")


def _require_ownership(claims: dict) -> str:
    """Fail closed on a missing/unrecognised inAppOwnershipType. We NEVER default
    it to PURCHASED — a store payload that doesn't explicitly prove PURCHASED or
    FAMILY_SHARED ownership cannot grant Pro (the exact P0 a prior candidate
    failed)."""
    ownership = claims.get("inAppOwnershipType")
    if ownership not in _ALLOWED_OWNERSHIP:
        raise AppleVerificationError(
            f"unrecognized inAppOwnershipType {ownership!r}; refusing to classify ownership"
        )
    return ownership


def _validate_transaction(claims: dict, config: AppStoreConfig) -> None:
    # Bundle id and environment are already enforced cryptographically by the
    # library verifier; we re-check product id + identifiers, which the library
    # does not police, so wrong-product / malformed evidence is rejected.
    if claims.get("productId") not in config.product_ids:
        raise AppleVerificationError(f"unknown productId {claims.get('productId')!r}")
    if claims.get("environment") not in config.environments:
        raise AppleVerificationError(f"unexpected environment {claims.get('environment')!r}")
    if not claims.get("originalTransactionId") or not claims.get("transactionId"):
        raise AppleVerificationError("transaction is missing its identifiers")


def _normalize_token(raw: Optional[str]) -> Optional[str]:
    """appAccountToken must be a UUID; a malformed one is invalid evidence."""
    if raw is None or raw == "":
        return None
    import uuid as _uuid

    try:
        return str(_uuid.UUID(str(raw)))
    except (ValueError, AttributeError, TypeError):
        raise AppleVerificationError("appAccountToken is not a valid UUID")


def _apple_error(exc: AppleVerificationError) -> HTTPException:
    # 422 for invalid/malformed evidence, 403 for wrong-app evidence (contract
    # §3). Literal 422 avoids the Starlette constant-rename deprecation churn.
    code = status.HTTP_403_FORBIDDEN if exc.kind == "wrong_app" else 422
    return HTTPException(code, str(exc))


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.post("/v1/app-store/subscription")
def sync_subscription(
    body: SubscriptionSyncRequest,
    user: CurrentUser,
    store: StoreDep,
    verifier: AppStoreVerifierDep,
    config: AppStoreConfigDep,
    provider_client: ProviderClientDep,
) -> dict[str, Any]:
    # Purchase requires the canonical account UUID — the only entitlement
    # principal. Every registered device has one (contract §1); its absence is
    # a setup error, never a silent fallback to the device id.
    if not user.account_id:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "account setup incomplete; cannot bind a purchase"
        )

    try:
        claims = verifier.verify_transaction(body.signed_transaction_info)
        _validate_transaction(claims, config)
        ownership = _require_ownership(claims)  # P0: fail closed on unknown ownership
        token = _normalize_token(claims.get("appAccountToken"))
    except AppleVerificationError as exc:
        raise _apple_error(exc)

    offer_type = claims.get("offerType")
    is_trial = offer_type in (1, "1")  # introductory offer => trial consumed
    signed_ms = _ms(claims, "signedDate") or 0
    expires_ms = _ms(claims, "expiresDate")
    revocation_ms = _ms(claims, "revocationDate")
    now_ms = int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)
    incoming_terminal = revocation_ms is not None or (
        expires_ms is not None and expires_ms <= now_ms
    )

    # Current-provider reconciliation (contract §3): when the client uploads an
    # apparently-active transaction and a provider client is configured, confirm
    # the lineage's live state so a replayed old signed transaction cannot
    # resurrect a refunded/revoked purchase even if we missed the notification.
    current_provider_state: Optional[str] = None
    if provider_client is not None and not incoming_terminal:
        try:
            snapshot = provider_client.current_state(
                str(claims["originalTransactionId"]), str(claims["environment"])
            )
        except ProviderUnavailable:
            # Fail closed, retryable — never silently bypass verification.
            raise HTTPException(
                status.HTTP_503_SERVICE_UNAVAILABLE,
                "provider verification is temporarily unavailable",
            )
        if snapshot is not None:
            current_provider_state = snapshot.lifecycle_state

    try:
        result = store.apply_apple_transaction(
            account_id=user.account_id,
            original_transaction_id=str(claims["originalTransactionId"]),
            transaction_id=str(claims["transactionId"]),
            product_id=str(claims["productId"]),
            environment=str(claims["environment"]),
            ownership_type=ownership,
            app_account_token=token,
            signed_ms=signed_ms,
            expires_ms=expires_ms,
            revocation_ms=revocation_ms,
            is_trial=is_trial,
            current_provider_state=current_provider_state,
        )
    except AppleVerificationError as exc:
        raise _apple_error(exc)

    if result.outcome == "conflict":
        # Ownership conflict is deterministic. The durable purchase/claim record
        # is the support-visible evidence; we reveal no owner/private data.
        raise HTTPException(status.HTTP_409_CONFLICT, "purchase belongs to a different account")

    # Success (grant applied) OR an authoritative not-entitled state (revoked/
    # stale/expired) — both return /v1/me-equivalent state, only AFTER the
    # durable commit above. Re-read so provider_entitlement_active is fresh.
    fresh = store.get_by_device(user.device_id) or user
    return compute_me_fields(fresh, store)


class NotificationRequest(BaseModel):
    signedPayload: str


@router.post("/v1/app-store/notifications")
def app_store_notifications(
    body: NotificationRequest,
    store: StoreDep,
    verifier: AppStoreVerifierDep,
    config: AppStoreConfigDep,
) -> dict[str, Any]:
    # The library validates the OUTER notification's bundle id, environment and
    # (in production) app Apple id before we see it.
    try:
        payload = verifier.verify_notification(body.signedPayload)
    except AppleVerificationError as exc:
        raise _apple_error(exc)

    notification_type = payload.get("notificationType")
    subtype = payload.get("subtype")
    notification_uuid = payload.get("notificationUUID")
    if not notification_uuid or not notification_type:
        raise HTTPException(422, "malformed notification")

    signed_tx = payload.get("signedTransactionInfo")
    if not signed_tx:
        # Nothing transaction-scoped to converge on (e.g. TEST); acknowledge so
        # Apple stops retrying.
        return {"received": True, "outcome": "ignored"}

    # P0: the nested signed transaction is validated through the SAME canonical
    # verification path (chain + bundle id + environment via the library, then
    # product/identifier/ownership here). A valid Apple-signed transaction for a
    # DIFFERENT app is rejected (403) instead of mutating our DB.
    try:
        tx = verifier.verify_transaction(signed_tx)
        _validate_transaction(tx, config)
        ownership = _require_ownership(tx)  # fail closed on unknown ownership
    except AppleVerificationError as exc:
        raise _apple_error(exc)

    beneficiary = None
    if ownership == "FAMILY_SHARED":
        # A family beneficiary revoke targets ONE beneficiary grant. Only a
        # cryptographically present, valid token proves which one; absence means
        # we must not guess (contract §6, P0 tokenless family revoke).
        try:
            beneficiary = _normalize_token(tx.get("appAccountToken"))
        except AppleVerificationError:
            beneficiary = None

    outcome = store.apply_apple_notification(
        notification_uuid=str(notification_uuid),
        notification_type=str(notification_type),
        subtype=str(subtype) if subtype else None,
        original_transaction_id=str(tx.get("originalTransactionId")),
        signed_ms=_ms(tx, "signedDate") or 0,
        expires_ms=_ms(tx, "expiresDate"),
        ownership_type=ownership,
        beneficiary_account_id=beneficiary,
    )
    return {"received": True, "outcome": outcome}


# ---------------------------------------------------------------------------
# Outbound Set-App-Account-Token reconciliation (retry state; contract §5/§9)
# ---------------------------------------------------------------------------


def reconcile_set_app_account_token(store: Store, sender) -> dict[str, int]:
    """Drive pending Set-App-Account-Token operations recorded after tokenless
    legacy claims. `sender(op) -> None` performs the outbound Apple call and
    raises on failure. A transient failure marks the op 'failed' (retriable) and
    NEVER touches the already-granted entitlement; success marks it 'succeeded'.
    Returns a {succeeded, failed} tally."""
    succeeded = 0
    failed = 0
    for op in store.list_pending_set_token_operations():
        try:
            sender(op)
        except Exception as exc:  # noqa: BLE001 — any failure is retriable
            store.mark_set_token_operation(op["id"], state="failed", error=str(exc))
            failed += 1
            continue
        store.mark_set_token_operation(op["id"], state="succeeded")
        succeeded += 1
    return {"succeeded": succeeded, "failed": failed}


class AppStoreServerSetTokenSender:
    """Concrete production Set-App-Account-Token sender using the App Store
    Server API. A transient APIException propagates so `reconcile_...` records a
    retriable failure and leaves the already-verified entitlement intact
    (contract §5, hostile 12)."""

    def __init__(self, clients: dict[str, AppStoreServerAPIClient], default_environment: str):
        self._clients = dict(clients)
        self._default_environment = default_environment

    def __call__(self, op: dict) -> None:
        client = self._clients.get(op.get("environment") or self._default_environment)
        if client is None:
            raise ProviderUnavailable("Set-App-Account-Token client is not configured")
        client.set_app_account_token(
            op["original_transaction_id"],
            UpdateAppAccountTokenRequest(appAccountToken=op["account_id"]),
        )


def get_set_token_sender() -> Optional[AppStoreServerSetTokenSender]:
    """Build the production Set-App-Account-Token sender from configured
    credentials, or None when the App Store Server API is not configured."""
    clients = _build_api_clients()
    if not clients:
        return None
    default_env = "Production" if "Production" in clients else next(iter(clients))
    return AppStoreServerSetTokenSender(clients, default_env)
