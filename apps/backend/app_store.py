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

Trust model (contract §3): the JWS is verified by checking its x5c certificate
chain up to a configured Apple root anchor and then verifying the ES256
signature with the leaf certificate's public key. There is no shortcut that
trusts an unverified payload. The canonical, immutable Tono account UUID is the
only entitlement principal — store evidence can grant paid service but can never
issue a bearer token, relink a device, or recover account history.

Configuration (no secrets reach clients):
  TONO_APPLE_ROOT_CA_PEM   PEM (inline or a file path) of the trusted Apple root
                           certificate(s). Verification is unavailable (503)
                           until this is set, exactly like Apple/Google sign-in
                           is 503 without APPLE_CLIENT_ID — we never fake success.
  TONO_APPLE_BUNDLE_ID     expected bundleId (default com.tonoit.app)
  TONO_APPLE_PRODUCT_IDS   comma-separated allowed product IDs
  TONO_APPLE_ENVIRONMENTS  comma-separated allowed environments

Tests override `get_appstore_verifier` via app.dependency_overrides with a
verifier that trusts a self-generated test root, so the suite never needs
Apple's real signing chain or network — the same indirection social_auth uses.
"""

from __future__ import annotations

import base64
import datetime as dt
import os
from dataclasses import dataclass
from typing import Annotated, Any, Optional

import jwt
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel

from .auth import CurrentUser, StoreDep
from .store import Store, User, _today_utc, get_store

router = APIRouter(tags=["app-store"])


# ---------------------------------------------------------------------------
# JWS (JWSTransaction / signed notification) verification
# ---------------------------------------------------------------------------


class AppleVerificationError(Exception):
    """Raised when a signed Apple payload cannot be trusted. `kind` maps to an
    HTTP status: 'invalid' -> 422, 'wrong_app' -> 403."""

    def __init__(self, message: str, kind: str = "invalid"):
        super().__init__(message)
        self.kind = kind


class AppleJWSVerifier:
    """Verifies an Apple-signed JWS (a StoreKit transaction or an App Store
    Server notification) against a set of trusted root certificates."""

    def __init__(self, trusted_roots: list[x509.Certificate]):
        if not trusted_roots:
            raise ValueError("AppleJWSVerifier requires at least one trusted root")
        self._trusted_roots = list(trusted_roots)
        self._trusted_fingerprints = {_fingerprint(c) for c in trusted_roots}

    def verify(self, token: str, *, now: Optional[dt.datetime] = None) -> dict[str, Any]:
        now = now or dt.datetime.now(dt.timezone.utc)
        if not token or token.count(".") != 2:
            raise AppleVerificationError("malformed JWS")
        try:
            header = jwt.get_unverified_header(token)
        except jwt.PyJWTError as exc:
            raise AppleVerificationError(f"unreadable JWS header: {exc}")
        if header.get("alg") != "ES256":
            raise AppleVerificationError(f"unexpected JWS alg: {header.get('alg')}")
        x5c = header.get("x5c")
        if not x5c or not isinstance(x5c, list):
            raise AppleVerificationError("JWS is missing its x5c certificate chain")

        try:
            chain = [x509.load_der_x509_certificate(base64.b64decode(c)) for c in x5c]
        except Exception as exc:  # noqa: BLE001 — any malformed cert is untrusted
            raise AppleVerificationError(f"malformed certificate in x5c: {exc}")

        self._verify_chain(chain, now)

        leaf = chain[0]
        try:
            claims = jwt.decode(
                token,
                key=leaf.public_key(),
                algorithms=["ES256"],
                options={"verify_aud": False, "verify_exp": False, "verify_signature": True},
            )
        except jwt.PyJWTError as exc:
            raise AppleVerificationError(f"signature verification failed: {exc}")
        return claims

    def _verify_chain(self, chain: list[x509.Certificate], now: dt.datetime) -> None:
        # Every certificate must be inside its validity window.
        for cert in chain:
            if now < cert.not_valid_before_utc or now > cert.not_valid_after_utc:
                raise AppleVerificationError("certificate in chain is expired or not yet valid")
        # Each certificate must be signed by the next one up the chain.
        for i in range(len(chain) - 1):
            _verify_cert_signed_by(chain[i], chain[i + 1])
        # The top of the presented chain must be a trusted root, or be signed by
        # one — otherwise the whole chain is untrusted.
        top = chain[-1]
        if _fingerprint(top) in self._trusted_fingerprints:
            return
        for root in self._trusted_roots:
            if top.issuer == root.subject:
                try:
                    _verify_cert_signed_by(top, root)
                    if now < root.not_valid_before_utc or now > root.not_valid_after_utc:
                        continue
                    return
                except AppleVerificationError:
                    continue
        raise AppleVerificationError("certificate chain does not terminate at a trusted Apple root")


def _fingerprint(cert: x509.Certificate) -> bytes:
    from cryptography.hazmat.primitives import hashes

    return cert.fingerprint(hashes.SHA256())


def _verify_cert_signed_by(cert: x509.Certificate, issuer: x509.Certificate) -> None:
    pub = issuer.public_key()
    try:
        if isinstance(pub, ec.EllipticCurvePublicKey):
            pub.verify(cert.signature, cert.tbs_certificate_bytes, ec.ECDSA(cert.signature_hash_algorithm))
        else:  # pragma: no cover - Apple's chain is EC; RSA path kept for safety
            from cryptography.hazmat.primitives.asymmetric import padding

            pub.verify(
                cert.signature,
                cert.tbs_certificate_bytes,
                padding.PKCS1v15(),
                cert.signature_hash_algorithm,
            )
    except InvalidSignature as exc:
        raise AppleVerificationError("certificate chain signature is invalid") from exc


# ---------------------------------------------------------------------------
# Configuration + dependencies (overridable in tests)
# ---------------------------------------------------------------------------


@dataclass
class AppStoreConfig:
    bundle_id: str
    product_ids: frozenset[str]
    environments: frozenset[str]


def get_appstore_config() -> AppStoreConfig:
    products = os.environ.get(
        "TONO_APPLE_PRODUCT_IDS", "com.tonoit.pro.monthly,com.tonoit.pro.yearly"
    )
    environments = os.environ.get("TONO_APPLE_ENVIRONMENTS", "Production,Sandbox")
    return AppStoreConfig(
        bundle_id=os.environ.get("TONO_APPLE_BUNDLE_ID", "com.tonoit.app"),
        product_ids=frozenset(p.strip() for p in products.split(",") if p.strip()),
        environments=frozenset(e.strip() for e in environments.split(",") if e.strip()),
    )


def _load_trusted_roots() -> list[x509.Certificate]:
    raw = os.environ.get("TONO_APPLE_ROOT_CA_PEM", "").strip()
    if not raw:
        return []
    if "-----BEGIN" not in raw and os.path.exists(raw):
        with open(raw, "rb") as handle:
            pem = handle.read()
    else:
        pem = raw.encode("utf-8")
    return x509.load_pem_x509_certificates(pem)


def get_appstore_verifier() -> AppleJWSVerifier:
    roots = _load_trusted_roots()
    if not roots:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "App Store verification is not configured on this server.",
        )
    return AppleJWSVerifier(roots)


AppStoreVerifierDep = Annotated[AppleJWSVerifier, Depends(get_appstore_verifier)]
AppStoreConfigDep = Annotated[AppStoreConfig, Depends(get_appstore_config)]


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
# Endpoints
# ---------------------------------------------------------------------------


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


def _validate_transaction(claims: dict, config: AppStoreConfig) -> None:
    bundle_id = claims.get("bundleId")
    if bundle_id != config.bundle_id:
        raise AppleVerificationError(
            f"transaction bundleId {bundle_id!r} is not this app", kind="wrong_app"
        )
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


@router.post("/v1/app-store/subscription")
def sync_subscription(
    body: SubscriptionSyncRequest,
    user: CurrentUser,
    store: StoreDep,
    verifier: AppStoreVerifierDep,
    config: AppStoreConfigDep,
) -> dict[str, Any]:
    # Purchase requires the canonical account UUID — the only entitlement
    # principal. Every registered device has one (contract §1); its absence is
    # a setup error, never a silent fallback to the device id.
    if not user.account_id:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "account setup incomplete; cannot bind a purchase"
        )

    try:
        claims = verifier.verify(body.signed_transaction_info)
        _validate_transaction(claims, config)
        token = _normalize_token(claims.get("appAccountToken"))
    except AppleVerificationError as exc:
        raise _apple_error(exc)

    ownership = claims.get("inAppOwnershipType") or "PURCHASED"
    offer_type = claims.get("offerType")
    is_trial = offer_type in (1, "1")  # introductory offer => trial consumed

    try:
        result = store.apply_apple_transaction(
            account_id=user.account_id,
            original_transaction_id=str(claims["originalTransactionId"]),
            transaction_id=str(claims["transactionId"]),
            product_id=str(claims["productId"]),
            environment=str(claims["environment"]),
            ownership_type=ownership,
            app_account_token=token,
            signed_ms=_ms(claims, "signedDate") or 0,
            expires_ms=_ms(claims, "expiresDate"),
            revocation_ms=_ms(claims, "revocationDate"),
            is_trial=is_trial,
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
    try:
        payload = verifier.verify(body.signedPayload)
    except AppleVerificationError as exc:
        raise _apple_error(exc)

    notification_type = payload.get("notificationType")
    subtype = payload.get("subtype")
    notification_uuid = payload.get("notificationUUID")
    data = payload.get("data") or {}
    if not notification_uuid or not notification_type:
        raise HTTPException(422, "malformed notification")

    signed_tx = data.get("signedTransactionInfo")
    if not signed_tx:
        # Nothing transaction-scoped to converge on (e.g. TEST); acknowledge so
        # Apple stops retrying.
        return {"received": True, "outcome": "ignored"}
    try:
        tx = verifier.verify(signed_tx)
    except AppleVerificationError as exc:
        raise _apple_error(exc)

    ownership = tx.get("inAppOwnershipType") or "PURCHASED"
    beneficiary = None
    if ownership == "FAMILY_SHARED":
        # A family beneficiary revoke targets one beneficiary grant; the
        # notification carries that beneficiary's account token.
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
