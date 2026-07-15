"""Server-authoritative App Store and Google Play billing validation."""

from __future__ import annotations

import base64
import datetime as dt
import hashlib
import hmac
import json
import os
import uuid
from collections.abc import Awaitable, Callable
from typing import Annotated, Any, Optional
from urllib.parse import quote

from fastapi import APIRouter, Depends, HTTPException
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel

from .auth import CurrentUser, StoreDep
from .store import MobilePurchaseConflictError, Store, User

router = APIRouter(prefix="/v1", tags=["billing"])

APPLE_BUNDLE_ID = "com.tonoit.app"
DEFAULT_PRODUCTS = frozenset(
    {"com.tonoit.pro.monthly", "com.tonoit.pro.yearly"}
)
AppleVerifier = Callable[[str], Awaitable[Any]]


class AppleSubscriptionRequest(BaseModel):
    signed_transaction_info: str
    product_id: Optional[str] = None  # legacy hint; never authoritative


class AppleNotificationRequest(BaseModel):
    signedPayload: str


class GoogleSubscriptionRequest(BaseModel):
    package_name: Optional[str] = None  # legacy hint; configured package is authoritative
    product_id: Optional[str] = None  # legacy hint; lineItems.productId is authoritative
    purchase_token: str


class GooglePubSubMessage(BaseModel):
    data: str
    messageId: str


class GoogleNotificationRequest(BaseModel):
    message: GooglePubSubMessage


def _allowed_products(provider: str) -> frozenset[str]:
    key = f"TONO_{provider.upper()}_PRODUCT_IDS"
    configured = os.environ.get(key)
    if not configured:
        return DEFAULT_PRODUCTS
    return frozenset(item.strip() for item in configured.split(",") if item.strip())


def _apple_environment_name() -> str:
    value = os.environ.get("TONO_APPLE_ENVIRONMENT", "Production")
    if value not in ("Production", "Sandbox"):
        raise HTTPException(503, "TONO_APPLE_ENVIRONMENT must be Production or Sandbox")
    return value


def _apple_signed_data_verifier():
    try:
        from appstoreserverlibrary.models.Environment import Environment
        from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier
    except ImportError as exc:
        raise HTTPException(503, "App Store validation dependency is unavailable") from exc

    cert_paths = [
        path for path in os.environ.get("TONO_APPLE_ROOT_CERTIFICATES", "").split(os.pathsep)
        if path
    ]
    if not cert_paths:
        raise HTTPException(503, "App Store root certificates are not configured")
    try:
        roots = []
        for path in cert_paths:
            with open(path, "rb") as certificate:
                roots.append(certificate.read())
        environment = (
            Environment.PRODUCTION
            if _apple_environment_name() == "Production"
            else Environment.SANDBOX
        )
        app_apple_id_raw = os.environ.get("TONO_APPLE_APP_ID")
        app_apple_id = int(app_apple_id_raw) if app_apple_id_raw else None
        return SignedDataVerifier(
            roots,
            os.environ.get("TONO_APPLE_ONLINE_CHECKS", "true").lower() != "false",
            environment,
            os.environ.get("TONO_APPLE_BUNDLE_ID", APPLE_BUNDLE_ID),
            app_apple_id,
        )
    except (OSError, TypeError, ValueError) as exc:
        raise HTTPException(503, "App Store validation configuration is invalid") from exc


def get_apple_transaction_verifier() -> AppleVerifier:
    verifier = _apple_signed_data_verifier()

    async def verify(signed_data: str):
        return await run_in_threadpool(
            verifier.verify_and_decode_signed_transaction, signed_data
        )

    return verify


def get_apple_notification_verifier() -> AppleVerifier:
    verifier = _apple_signed_data_verifier()

    async def verify(signed_data: str):
        return await run_in_threadpool(verifier.verify_and_decode_notification, signed_data)

    return verify


class GooglePlayClient:
    """Small official-auth adapter around Android Publisher REST endpoints."""

    def __init__(self) -> None:
        try:
            import google.auth
            from google.auth.transport.requests import AuthorizedSession
        except ImportError as exc:
            raise HTTPException(503, "Google Play validation dependency is unavailable") from exc
        credentials_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
        try:
            if credentials_path:
                from google.oauth2 import service_account

                credentials = service_account.Credentials.from_service_account_file(
                    credentials_path,
                    scopes=["https://www.googleapis.com/auth/androidpublisher"],
                )
            else:
                credentials, _ = google.auth.default(
                    scopes=["https://www.googleapis.com/auth/androidpublisher"]
                )
            self._session = AuthorizedSession(credentials)
        except Exception as exc:
            raise HTTPException(503, "Google Play credentials are not configured") from exc

    def get_subscription(self, package_name: str, purchase_token: str) -> dict[str, Any]:
        url = (
            "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/"
            f"{quote(package_name, safe='')}/purchases/subscriptionsv2/tokens/"
            f"{quote(purchase_token, safe='')}"
        )
        response = self._session.get(url, timeout=15)
        response.raise_for_status()
        return response.json()

    def acknowledge_subscription(
        self, package_name: str, product_id: str, purchase_token: str
    ) -> None:
        url = (
            "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/"
            f"{quote(package_name, safe='')}/purchases/subscriptions/"
            f"{quote(product_id, safe='')}/tokens/{quote(purchase_token, safe='')}:acknowledge"
        )
        response = self._session.post(url, json={}, timeout=15)
        response.raise_for_status()


def get_google_play_client() -> GooglePlayClient:
    return GooglePlayClient()


def _milliseconds_to_iso(value: Optional[int]) -> Optional[str]:
    if value is None:
        return None
    return dt.datetime.fromtimestamp(value / 1000, tz=dt.timezone.utc).isoformat()


def _owner(user: User) -> tuple[str, str]:
    return ("account", user.account_id) if user.account_id else ("device", user.device_id)


def _apple_purchase_values(transaction: Any) -> dict[str, Any]:
    product_id = getattr(transaction, "productId", None)
    if not product_id or product_id not in _allowed_products("apple"):
        raise HTTPException(400, "Apple product is not a Tono product")
    purchase_key = getattr(transaction, "originalTransactionId", None)
    transaction_id = getattr(transaction, "transactionId", None)
    expires_at = _milliseconds_to_iso(getattr(transaction, "expiresDate", None))
    if not purchase_key or not transaction_id or not expires_at:
        raise HTTPException(400, "Apple transaction is incomplete")
    provider_event_at = getattr(transaction, "signedDate", None)
    if not isinstance(provider_event_at, int) or provider_event_at <= 0:
        raise HTTPException(400, "Apple transaction signed date is missing")
    active = (
        getattr(transaction, "revocationDate", None) is None
        and expires_at > dt.datetime.now(dt.timezone.utc).isoformat()
    )
    return {
        "purchase_key": purchase_key,
        "transaction_id": transaction_id,
        "product_id": product_id,
        "expires_at": expires_at,
        "purchase_status": "active" if active else "revoked",
        "provider_event_at": provider_event_at,
    }


def _validate_apple_identity(transaction: Any) -> None:
    environment = getattr(transaction, "environment", None)
    if getattr(environment, "value", environment) != _apple_environment_name():
        raise HTTPException(400, "Apple transaction environment mismatch")
    expected_bundle = os.environ.get("TONO_APPLE_BUNDLE_ID", APPLE_BUNDLE_ID)
    if getattr(transaction, "bundleId", None) != expected_bundle:
        raise HTTPException(400, "Apple transaction app mismatch")


def _normalize_uuid(value: Any) -> Optional[str]:
    try:
        return str(uuid.UUID(str(value)))
    except (AttributeError, TypeError, ValueError):
        return None


def _validate_apple_ownership(store: Store, user: User, transaction: Any) -> None:
    token = _normalize_uuid(getattr(transaction, "appAccountToken", None))
    allowed = {
        normalized
        for identifier in store.mobile_billing_owner_identifiers(user)
        if (normalized := _normalize_uuid(identifier)) is not None
    }
    if token is None or token not in allowed:
        raise HTTPException(403, "Apple purchase belongs to another Tono account")


def _google_obfuscated_account_id(identifier: str) -> str:
    return hashlib.sha256(f"tono:{identifier}".encode("utf-8")).hexdigest()


def _validate_google_ownership(store: Store, user: User, purchase: dict[str, Any]) -> None:
    external = purchase.get("externalAccountIdentifiers") or {}
    actual = external.get("obfuscatedExternalAccountId")
    if not isinstance(actual, str) or not any(
        hmac.compare_digest(actual, _google_obfuscated_account_id(identifier))
        for identifier in store.mobile_billing_owner_identifiers(user)
    ):
        raise HTTPException(403, "Google Play purchase belongs to another Tono account")


def _record_for_user(
    store: Store, user: User, provider: str, values: dict[str, Any]
) -> None:
    owner_kind, owner_id = _owner(user)
    try:
        store.record_mobile_purchase(
            provider=provider,
            owner_kind=owner_kind,
            owner_id=owner_id,
            **values,
        )
    except MobilePurchaseConflictError as exc:
        raise HTTPException(409, str(exc)) from exc


def _billing_response(store: Store, user: User, product_id: str) -> dict[str, Any]:
    refreshed = store.get_by_device(user.device_id)
    if refreshed is None:
        raise HTTPException(404, "device no longer exists")
    quota_source = refreshed.account if refreshed.account else refreshed
    today = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    used_today = quota_source.daily_count if quota_source.daily_day == today else 0
    return {
        "device_id": user.device_id,
        "plan": refreshed.plan_resolved,
        "is_pro": refreshed.is_pro,
        "used_today": used_today,
        "daily_limit": -1 if refreshed.is_pro else int(os.environ.get("FREE_DAILY_LIMIT", "10")),
        "account_id": refreshed.account_id,
        "subscription_status": (
            refreshed.account.mobile_subscription_status
            if refreshed.account
            else refreshed.mobile_subscription_status
        ),
        "subscription_renews_at": (
            refreshed.account.mobile_subscription_renews_at
            if refreshed.account
            else refreshed.mobile_subscription_renews_at
        ),
        "product_id": product_id,
    }


@router.post("/app-store/subscription")
async def sync_app_store_subscription(
    body: AppleSubscriptionRequest,
    user: CurrentUser,
    store: StoreDep,
    verify: Annotated[AppleVerifier, Depends(get_apple_transaction_verifier)],
) -> dict[str, Any]:
    try:
        transaction = await verify(body.signed_transaction_info)
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(400, "invalid Apple signed transaction") from exc
    _validate_apple_identity(transaction)
    _validate_apple_ownership(store, user, transaction)
    values = _apple_purchase_values(transaction)
    _record_for_user(store, user, "apple", values)
    return _billing_response(store, user, values["product_id"] or "")


@router.post("/app-store/notifications")
async def app_store_notification(
    body: AppleNotificationRequest,
    store: StoreDep,
    verify_notification: Annotated[AppleVerifier, Depends(get_apple_notification_verifier)],
    verify_transaction: Annotated[AppleVerifier, Depends(get_apple_transaction_verifier)],
) -> dict[str, Any]:
    try:
        notification = await verify_notification(body.signedPayload)
        event_id = getattr(notification, "notificationUUID", None)
        signed_transaction = getattr(getattr(notification, "data", None), "signedTransactionInfo", None)
        if not event_id:
            raise ValueError("notification UUID missing")
        if signed_transaction:
            transaction = await verify_transaction(signed_transaction)
            _validate_apple_identity(transaction)
            values = _apple_purchase_values(transaction)
            store.update_known_mobile_purchase(provider="apple", **values)
        inserted = store.record_mobile_billing_event("apple", event_id)
        return {"received": True, "duplicate": not inserted}
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(400, "invalid Apple signed notification") from exc


def _google_purchase_values(purchase_token: str, purchase: dict[str, Any]) -> dict[str, Any]:
    items = purchase.get("lineItems") or []
    allowed = _allowed_products("google")
    authoritative = [item for item in items if item.get("productId") in allowed]
    if not authoritative:
        raise HTTPException(400, "Google Play product is not a Tono product")
    item = max(authoritative, key=lambda candidate: candidate.get("expiryTime") or "")
    expires_at = item.get("expiryTime")
    if not expires_at:
        raise HTTPException(400, "Google Play subscription expiry is missing")
    normalized_expiry = expires_at.replace("Z", "+00:00")
    try:
        provider_event_at = int(
            dt.datetime.fromisoformat(normalized_expiry).timestamp() * 1000
        )
    except ValueError as exc:
        raise HTTPException(400, "Google Play subscription expiry is invalid") from exc
    active_states = {
        "SUBSCRIPTION_STATE_ACTIVE",
        "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
    }
    active = (
        purchase.get("subscriptionState") in active_states
        and normalized_expiry > dt.datetime.now(dt.timezone.utc).isoformat()
    )
    return {
        "purchase_key": hashlib.sha256(purchase_token.encode("utf-8")).hexdigest(),
        "transaction_id": purchase.get("latestOrderId"),
        "product_id": item["productId"],
        "expires_at": normalized_expiry,
        "purchase_status": "active" if active else "revoked",
        "provider_event_at": provider_event_at,
    }


@router.post("/google-play/subscription")
def sync_google_play_subscription(
    body: GoogleSubscriptionRequest,
    user: CurrentUser,
    store: StoreDep,
    google: Annotated[GooglePlayClient, Depends(get_google_play_client)],
) -> dict[str, Any]:
    package_name = os.environ.get("TONO_GOOGLE_PACKAGE_NAME", "com.tono.myapp")
    try:
        purchase = google.get_subscription(package_name, body.purchase_token)
        _validate_google_ownership(store, user, purchase)
        values = _google_purchase_values(body.purchase_token, purchase)
        if (
            values["purchase_status"] == "active"
            and purchase.get("acknowledgementState")
            == "ACKNOWLEDGEMENT_STATE_PENDING"
        ):
            google.acknowledge_subscription(
                package_name, values["product_id"] or "", body.purchase_token
            )
        elif (
            values["purchase_status"] == "active"
            and purchase.get("acknowledgementState")
            != "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED"
        ):
            raise HTTPException(400, "Google Play purchase is not acknowledged")
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(502, "Google Play purchase validation failed") from exc
    _record_for_user(store, user, "google", values)
    return _billing_response(store, user, values["product_id"] or "")


@router.post("/google-play/notifications")
def google_play_notification(
    body: GoogleNotificationRequest,
    store: StoreDep,
    google: Annotated[GooglePlayClient, Depends(get_google_play_client)],
) -> dict[str, Any]:
    """Resolve an RTDN token against Google before changing any entitlement."""
    try:
        decoded = json.loads(base64.b64decode(body.message.data, validate=True))
        notice = decoded.get("subscriptionNotification") or {}
        purchase_token = notice.get("purchaseToken")
        expected_package = os.environ.get("TONO_GOOGLE_PACKAGE_NAME", "com.tono.myapp")
        if decoded.get("packageName") != expected_package or not purchase_token:
            raise ValueError("notification identity missing")
        if store.has_mobile_billing_event("google", body.message.messageId):
            return {"received": True, "duplicate": True}
        purchase = google.get_subscription(expected_package, purchase_token)
        values = _google_purchase_values(purchase_token, purchase)
        inserted = store.apply_mobile_billing_event(
            provider="google", event_id=body.message.messageId, **values
        )
        return {"received": True, "duplicate": not inserted}
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(400, "invalid Google Play notification") from exc