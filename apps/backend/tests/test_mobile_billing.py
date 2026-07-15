"""Hostile billing tests: provider data, not client claims, controls Pro."""

from __future__ import annotations

import base64
import hashlib
import json
from types import SimpleNamespace

APPLE_MONTHLY = "com.tonoit.pro.monthly"
APPLE_YEARLY = "com.tonoit.pro.yearly"


def _register(client, suffix: str = "1") -> dict[str, str]:
    response = client.post(
        "/v1/register",
        json={"device_id": f"00000000-0000-0000-0000-0000000000{suffix.zfill(2)}"},
    )
    assert response.status_code == 200
    return response.json()


def _auth(registration: dict[str, str]) -> dict[str, str]:
    return {"Authorization": f"Bearer {registration['api_token']}"}


def test_apple_sandbox_transaction_is_rejected_in_production_lane(client, monkeypatch):
    from backend import mobile_billing
    from backend.server import app

    monkeypatch.setenv("TONO_APPLE_ENVIRONMENT", "Production")
    registration = _register(client)

    async def fake_verify(_: str):
        return SimpleNamespace(
            bundleId="com.tonoit.app",
            environment="Sandbox",
            originalTransactionId="apple-original-1",
            transactionId="apple-transaction-1",
            productId="com.tonoit.pro.monthly",
            expiresDate=4102444800000,
            revocationDate=None,
        )

    app.dependency_overrides[mobile_billing.get_apple_transaction_verifier] = lambda: fake_verify
    try:
        response = client.post(
            "/v1/app-store/subscription",
            json={"signed_transaction_info": "sandbox-jws"},
            headers=_auth(registration),
        )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 400
    assert response.json()["error"]["message"] == "Apple transaction environment mismatch"


def test_apple_sandbox_transaction_is_accepted_in_explicit_testflight_lane(client, monkeypatch):
    from backend import mobile_billing
    from backend.server import app

    monkeypatch.setenv("TONO_APPLE_ENVIRONMENT", "Sandbox")
    registration = _register(client)

    async def fake_verify(_: str):
        return _apple_transaction(
            environment="Sandbox", appAccountToken=registration["device_id"]
        )

    app.dependency_overrides[mobile_billing.get_apple_transaction_verifier] = lambda: fake_verify
    try:
        response = client.post(
            "/v1/app-store/subscription",
            json={"signed_transaction_info": "testflight-jws"},
            headers=_auth(registration),
        )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200
    assert response.json()["is_pro"] is True


def test_apple_wrong_bundle_is_rejected(client, monkeypatch):
    from backend import mobile_billing
    from backend.server import app

    monkeypatch.setenv("TONO_APPLE_ENVIRONMENT", "Production")
    registration = _register(client)

    async def fake_verify(_: str):
        return _apple_transaction(bundleId="com.attacker.app")

    app.dependency_overrides[mobile_billing.get_apple_transaction_verifier] = lambda: fake_verify
    try:
        response = client.post(
            "/v1/app-store/subscription",
            json={"signed_transaction_info": "wrong-bundle-jws"},
            headers=_auth(registration),
        )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 400
    assert response.json()["error"]["message"] == "Apple transaction app mismatch"


def test_apple_ignores_forged_client_product(client, monkeypatch):
    from backend import mobile_billing
    from backend.server import app

    monkeypatch.setenv("TONO_APPLE_ENVIRONMENT", "Production")
    registration = _register(client)

    async def fake_verify(_: str):
        return _apple_transaction(
            productId=APPLE_MONTHLY, appAccountToken=registration["device_id"]
        )

    app.dependency_overrides[mobile_billing.get_apple_transaction_verifier] = lambda: fake_verify
    try:
        response = client.post(
            "/v1/app-store/subscription",
            json={"signed_transaction_info": "valid-jws", "product_id": APPLE_YEARLY},
            headers=_auth(registration),
        )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200
    assert response.json()["product_id"] == APPLE_MONTHLY


def test_google_cheaper_product_substitution_cannot_grant_pro(client, monkeypatch):
    from backend import mobile_billing
    from backend.server import app

    monkeypatch.setenv("TONO_GOOGLE_PACKAGE_NAME", "com.tono.myapp")
    registration = _register(client)
    google = FakeGooglePlay({
        "subscriptionState": "SUBSCRIPTION_STATE_ACTIVE",
        "acknowledgementState": "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED",
        "externalAccountIdentifiers": {
            "obfuscatedExternalAccountId": _google_obfuscated_account_id(
                registration["device_id"]
            )
        },
        "lineItems": [{
            "productId": "com.tonoit.basic.monthly",
            "expiryTime": "2099-01-01T00:00:00Z",
        }],
    })
    app.dependency_overrides[mobile_billing.get_google_play_client] = lambda: google
    try:
        response = client.post(
            "/v1/google-play/subscription",
            json={
                "package_name": "com.tono.myapp",
                "product_id": APPLE_YEARLY,
                "purchase_token": "google-token-cheap",
            },
            headers=_auth(registration),
        )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 400
    assert response.json()["error"]["message"] == "Google Play product is not a Tono product"
    assert client.get("/v1/me", headers=_auth(registration)).json()["is_pro"] is False


def test_google_uses_authoritative_product_and_acknowledges_purchase(client, monkeypatch):
    from backend import mobile_billing
    from backend.server import app

    monkeypatch.setenv("TONO_GOOGLE_PACKAGE_NAME", "com.tono.myapp")
    registration = _register(client)
    google = FakeGooglePlay(_google_purchase(
        acknowledgement="ACKNOWLEDGEMENT_STATE_PENDING",
        owner_device_id=registration["device_id"],
    ))
    app.dependency_overrides[mobile_billing.get_google_play_client] = lambda: google
    try:
        response = client.post(
            "/v1/google-play/subscription",
            json={
                "package_name": "com.attacker.app",
                "product_id": APPLE_YEARLY,
                "purchase_token": "google-token-1",
            },
            headers=_auth(registration),
        )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200
    assert response.json()["product_id"] == APPLE_MONTHLY
    assert response.json()["is_pro"] is True
    assert google.package_names == ["com.tono.myapp"]
    assert google.acknowledged == [("com.tono.myapp", APPLE_MONTHLY, "google-token-1")]


def test_duplicate_google_token_cannot_cross_accounts(client):
    from backend import mobile_billing
    from backend.server import app
    from backend.store import get_store

    first = _register(client, "1")
    second = _register(client, "2")
    store = get_store()
    store.link_device_to_account(first["device_id"], store.create_bare_account().id)
    store.link_device_to_account(second["device_id"], store.create_bare_account().id)
    google = FakeGooglePlay(_google_purchase(owner_device_id=first["device_id"]))
    app.dependency_overrides[mobile_billing.get_google_play_client] = lambda: google
    body = {"purchase_token": "same-google-token", "product_id": APPLE_YEARLY}
    try:
        first_response = client.post(
            "/v1/google-play/subscription", json=body, headers=_auth(first)
        )
        second_response = client.post(
            "/v1/google-play/subscription", json=body, headers=_auth(second)
        )
    finally:
        app.dependency_overrides.clear()

    assert first_response.status_code == 200
    assert second_response.status_code == 403
    assert client.get("/v1/me", headers=_auth(second)).json()["is_pro"] is False


def test_google_cancel_notification_removes_access_and_retry_is_idempotent(client):
    from backend import mobile_billing
    from backend.server import app

    registration = _register(client)
    google = FakeGooglePlay(_google_purchase(owner_device_id=registration["device_id"]))
    app.dependency_overrides[mobile_billing.get_google_play_client] = lambda: google
    try:
        granted = client.post(
            "/v1/google-play/subscription",
            json={"purchase_token": "google-token-cancel"},
            headers=_auth(registration),
        )
        google.purchase = _google_purchase(state="SUBSCRIPTION_STATE_CANCELED")
        payload = base64.b64encode(json.dumps({
            "packageName": "com.tono.myapp",
            "subscriptionNotification": {"purchaseToken": "google-token-cancel"},
        }).encode()).decode()
        body = {"message": {"data": payload, "messageId": "google-event-1"}}
        first = client.post("/v1/google-play/notifications", json=body)
        retry = client.post("/v1/google-play/notifications", json=body)
    finally:
        app.dependency_overrides.clear()

    assert granted.json()["is_pro"] is True
    assert first.status_code == retry.status_code == 200
    assert first.json()["duplicate"] is False
    assert retry.json()["duplicate"] is True
    assert client.get("/v1/me", headers=_auth(registration)).json()["is_pro"] is False


def test_duplicate_google_notification_does_not_requery_or_change_entitlement(client):
    from backend import mobile_billing
    from backend.server import app

    registration = _register(client)
    google = FakeGooglePlay(_google_purchase(owner_device_id=registration["device_id"]))
    app.dependency_overrides[mobile_billing.get_google_play_client] = lambda: google
    try:
        granted = client.post(
            "/v1/google-play/subscription",
            json={"purchase_token": "google-token-replayed-event"},
            headers=_auth(registration),
        )
        google.purchase = _google_purchase(state="SUBSCRIPTION_STATE_CANCELED")
        payload = base64.b64encode(json.dumps({
            "packageName": "com.tono.myapp",
            "subscriptionNotification": {
                "purchaseToken": "google-token-replayed-event"
            },
        }).encode()).decode()
        body = {"message": {"data": payload, "messageId": "google-event-replayed"}}
        first = client.post("/v1/google-play/notifications", json=body)

        # A Pub/Sub redelivery must be a no-op even if Google's current snapshot
        # has advanced since the original event was handled.
        google.purchase = _google_purchase(
            owner_device_id=registration["device_id"]
        )
        retry = client.post("/v1/google-play/notifications", json=body)
    finally:
        app.dependency_overrides.clear()

    assert granted.json()["is_pro"] is True
    assert first.status_code == retry.status_code == 200
    assert first.json()["duplicate"] is False
    assert retry.json()["duplicate"] is True
    assert google.package_names == ["com.tono.myapp", "com.tono.myapp"]
    assert client.get("/v1/me", headers=_auth(registration)).json()["is_pro"] is False


def test_duplicate_apple_purchase_cannot_cross_accounts(client, monkeypatch):
    from backend import mobile_billing
    from backend.server import app
    from backend.store import get_store

    monkeypatch.setenv("TONO_APPLE_ENVIRONMENT", "Production")
    first = _register(client, "1")
    second = _register(client, "2")
    store = get_store()
    store.link_device_to_account(first["device_id"], store.create_bare_account().id)
    store.link_device_to_account(second["device_id"], store.create_bare_account().id)

    async def fake_verify(_: str):
        return _apple_transaction(appAccountToken=first["device_id"])

    app.dependency_overrides[mobile_billing.get_apple_transaction_verifier] = lambda: fake_verify
    try:
        first_response = client.post(
            "/v1/app-store/subscription",
            json={"signed_transaction_info": "same-jws"}, headers=_auth(first),
        )
        second_response = client.post(
            "/v1/app-store/subscription",
            json={"signed_transaction_info": "same-jws"}, headers=_auth(second),
        )
    finally:
        app.dependency_overrides.clear()

    assert first_response.status_code == 200
    assert second_response.status_code == 403
    assert client.get("/v1/me", headers=_auth(second)).json()["is_pro"] is False


def test_anonymous_mobile_purchase_moves_with_device_when_account_is_linked(client):
    from backend import mobile_billing
    from backend.server import app
    from backend.store import get_store

    registration = _register(client)
    google = FakeGooglePlay(_google_purchase(owner_device_id=registration["device_id"]))
    app.dependency_overrides[mobile_billing.get_google_play_client] = lambda: google
    try:
        granted = client.post(
            "/v1/google-play/subscription",
            json={"purchase_token": "anonymous-then-account"},
            headers=_auth(registration),
        )
        store = get_store()
        store.link_device_to_account(
            registration["device_id"], store.create_bare_account().id
        )
    finally:
        app.dependency_overrides.clear()

    assert granted.json()["is_pro"] is True
    assert client.get("/v1/me", headers=_auth(registration)).json()["is_pro"] is True


def test_apple_refund_removes_access(client, monkeypatch):
    from backend import mobile_billing
    from backend.server import app

    monkeypatch.setenv("TONO_APPLE_ENVIRONMENT", "Production")
    registration = _register(client)
    transactions = iter([
        _apple_transaction(appAccountToken=registration["device_id"]),
        _apple_transaction(
            appAccountToken=registration["device_id"],
            revocationDate=1700000000000,
            signedDate=2_000,
        ),
    ])

    async def fake_verify(_: str):
        return next(transactions)

    app.dependency_overrides[mobile_billing.get_apple_transaction_verifier] = lambda: fake_verify
    try:
        granted = client.post(
            "/v1/app-store/subscription",
            json={"signed_transaction_info": "grant-jws"}, headers=_auth(registration),
        )
        revoked = client.post(
            "/v1/app-store/subscription",
            json={"signed_transaction_info": "refund-jws"}, headers=_auth(registration),
        )
    finally:
        app.dependency_overrides.clear()

    assert granted.json()["is_pro"] is True
    assert revoked.status_code == 200
    assert revoked.json()["is_pro"] is False


def test_apple_notification_retry_is_idempotent(client, monkeypatch):
    from backend import mobile_billing
    from backend.server import app
    from backend.store import get_store

    monkeypatch.setenv("TONO_APPLE_ENVIRONMENT", "Production")
    registration = _register(client)

    async def fake_transaction(_: str):
        return _apple_transaction(appAccountToken=registration["device_id"])

    async def fake_notification(_: str):
        return SimpleNamespace(
            notificationUUID="notification-1",
            data=SimpleNamespace(signedTransactionInfo="notification-transaction-jws"),
        )

    app.dependency_overrides[mobile_billing.get_apple_transaction_verifier] = lambda: fake_transaction
    app.dependency_overrides[mobile_billing.get_apple_notification_verifier] = lambda: fake_notification
    try:
        client.post(
            "/v1/app-store/subscription",
            json={"signed_transaction_info": "grant-jws"}, headers=_auth(registration),
        )
        first = client.post("/v1/app-store/notifications", json={"signedPayload": "signed-notification"})
        retry = client.post("/v1/app-store/notifications", json={"signedPayload": "signed-notification"})
    finally:
        app.dependency_overrides.clear()

    count = get_store()._conn.execute(
        "SELECT COUNT(*) FROM mobile_billing_events WHERE provider='apple' AND event_id='notification-1'"
    ).fetchone()[0]
    assert first.status_code == retry.status_code == 200
    assert first.json()["duplicate"] is False
    assert retry.json()["duplicate"] is True
    assert count == 1


def test_attacker_cannot_first_claim_apple_purchase_bound_to_victim(client, monkeypatch):
    from backend import mobile_billing
    from backend.server import app

    monkeypatch.setenv("TONO_APPLE_ENVIRONMENT", "Production")
    attacker = _register(client, "1")
    victim = _register(client, "2")

    async def fake_verify(_: str):
        return _apple_transaction(appAccountToken=victim["device_id"])

    app.dependency_overrides[mobile_billing.get_apple_transaction_verifier] = lambda: fake_verify
    try:
        stolen = client.post(
            "/v1/app-store/subscription",
            json={"signed_transaction_info": "copied-victim-jws"},
            headers=_auth(attacker),
        )
        legitimate = client.post(
            "/v1/app-store/subscription",
            json={"signed_transaction_info": "victim-jws"},
            headers=_auth(victim),
        )
    finally:
        app.dependency_overrides.clear()

    assert stolen.status_code == 403
    assert client.get("/v1/me", headers=_auth(attacker)).json()["is_pro"] is False
    assert legitimate.status_code == 200
    assert legitimate.json()["is_pro"] is True


def test_tokenless_legacy_apple_purchase_requires_explicit_cutoff(client, monkeypatch):
    from backend import mobile_billing
    from backend.server import app

    monkeypatch.setenv("TONO_APPLE_ENVIRONMENT", "Production")
    registration = _register(client)

    async def fake_verify(_: str):
        return _apple_transaction(appAccountToken=None, purchaseDate=1_000)

    app.dependency_overrides[mobile_billing.get_apple_transaction_verifier] = lambda: fake_verify
    try:
        rejected = client.post(
            "/v1/app-store/subscription",
            json={"signed_transaction_info": "legacy-jws"},
            headers=_auth(registration),
        )
        monkeypatch.setenv("TONO_APPLE_LEGACY_CLAIM_BEFORE_MS", "2000")
        migrated = client.post(
            "/v1/app-store/subscription",
            json={"signed_transaction_info": "legacy-jws"},
            headers=_auth(registration),
        )
    finally:
        app.dependency_overrides.clear()

    assert rejected.status_code == 403
    assert migrated.status_code == 200
    assert migrated.json()["is_pro"] is True


def test_attacker_cannot_first_claim_google_purchase_bound_to_victim(client):
    from backend import mobile_billing
    from backend.server import app

    attacker = _register(client, "1")
    victim = _register(client, "2")
    purchase = _google_purchase()
    purchase["externalAccountIdentifiers"] = {
        "obfuscatedExternalAccountId": _google_obfuscated_account_id(victim["device_id"])
    }
    google = FakeGooglePlay(purchase)
    app.dependency_overrides[mobile_billing.get_google_play_client] = lambda: google
    body = {"purchase_token": "copied-victim-google-token"}
    try:
        stolen = client.post(
            "/v1/google-play/subscription", json=body, headers=_auth(attacker)
        )
        legitimate = client.post(
            "/v1/google-play/subscription", json=body, headers=_auth(victim)
        )
    finally:
        app.dependency_overrides.clear()

    assert stolen.status_code == 403
    assert client.get("/v1/me", headers=_auth(attacker)).json()["is_pro"] is False
    assert legitimate.status_code == 200
    assert legitimate.json()["is_pro"] is True


def test_google_legacy_claim_requires_explicit_purchase_date_cutoff(client, monkeypatch):
    from backend import mobile_billing
    from backend.server import app

    registration = _register(client)
    google = FakeGooglePlay(_google_purchase())
    app.dependency_overrides[mobile_billing.get_google_play_client] = lambda: google
    body = {"purchase_token": "legacy-google-token"}
    try:
        rejected = client.post(
            "/v1/google-play/subscription", json=body, headers=_auth(registration)
        )
        monkeypatch.setenv("TONO_GOOGLE_LEGACY_CLAIM_BEFORE_MS", "2000")
        migrated = client.post(
            "/v1/google-play/subscription", json=body, headers=_auth(registration)
        )
    finally:
        app.dependency_overrides.clear()

    assert rejected.status_code == 403
    assert migrated.status_code == 200
    assert migrated.json()["is_pro"] is True


def test_google_legacy_cutoff_never_bypasses_mismatched_binding(client, monkeypatch):
    from backend import mobile_billing
    from backend.server import app

    registration = _register(client)
    purchase = _google_purchase(
        owner_device_id="00000000-0000-0000-0000-000000000999"
    )
    google = FakeGooglePlay(purchase)
    app.dependency_overrides[mobile_billing.get_google_play_client] = lambda: google
    monkeypatch.setenv("TONO_GOOGLE_LEGACY_CLAIM_BEFORE_MS", "2000")
    try:
        response = client.post(
            "/v1/google-play/subscription",
            json={"purchase_token": "mismatched-tokenized-google-token"},
            headers=_auth(registration),
        )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 403


def test_delayed_older_apple_notification_cannot_regrant_after_refund(client, monkeypatch):
    from backend import mobile_billing
    from backend.server import app
    from backend.store import get_store

    monkeypatch.setenv("TONO_APPLE_ENVIRONMENT", "Production")
    registration = _register(client)
    transactions = iter([
        _apple_transaction(
            appAccountToken=registration["device_id"], signedDate=1_000
        ),
        _apple_transaction(
            appAccountToken=registration["device_id"],
            signedDate=3_000,
            revocationDate=2_900,
        ),
        _apple_transaction(
            appAccountToken=registration["device_id"], signedDate=2_000
        ),
    ])
    notification_ids = iter(["newer-refund", "delayed-older-active"])

    async def fake_transaction(_: str):
        return next(transactions)

    async def fake_notification(_: str):
        return SimpleNamespace(
            notificationUUID=next(notification_ids),
            data=SimpleNamespace(signedTransactionInfo="transaction-jws"),
        )

    app.dependency_overrides[mobile_billing.get_apple_transaction_verifier] = lambda: fake_transaction
    app.dependency_overrides[mobile_billing.get_apple_notification_verifier] = lambda: fake_notification
    try:
        granted = client.post(
            "/v1/app-store/subscription",
            json={"signed_transaction_info": "grant-jws"},
            headers=_auth(registration),
        )
        refunded = client.post(
            "/v1/app-store/notifications", json={"signedPayload": "newer-refund"}
        )
        delayed = client.post(
            "/v1/app-store/notifications", json={"signedPayload": "older-active"}
        )
    finally:
        app.dependency_overrides.clear()

    row = get_store()._conn.execute(
        "SELECT status, provider_event_at FROM mobile_purchases "
        "WHERE provider='apple' AND purchase_key='apple-original-1'"
    ).fetchone()
    assert granted.json()["is_pro"] is True
    assert refunded.status_code == delayed.status_code == 200
    assert client.get("/v1/me", headers=_auth(registration)).json()["is_pro"] is False
    assert tuple(row) == ("revoked", 3_000)


def _google_obfuscated_account_id(device_id: str) -> str:
    return hashlib.sha256(f"tono:{device_id}".encode("utf-8")).hexdigest()


def _apple_transaction(**overrides):
    values = {
        "bundleId": "com.tonoit.app",
        "environment": "Production",
        "originalTransactionId": "apple-original-1",
        "transactionId": "apple-transaction-1",
        "productId": APPLE_MONTHLY,
        "expiresDate": 4102444800000,
        "revocationDate": None,
        "signedDate": 1_000,
        "purchaseDate": 1_000,
    }
    values.update(overrides)
    return SimpleNamespace(**values)


class FakeGooglePlay:
    def __init__(self, purchase):
        self.purchase = purchase
        self.package_names = []
        self.acknowledged = []

    def get_subscription(self, package_name, purchase_token):
        self.package_names.append(package_name)
        return self.purchase

    def acknowledge_subscription(self, package_name, product_id, purchase_token):
        self.acknowledged.append((package_name, product_id, purchase_token))


def _google_purchase(
    *,
    state="SUBSCRIPTION_STATE_ACTIVE",
    acknowledgement="ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED",
    owner_device_id=None,
):
    purchase = {
        "startTime": "1970-01-01T00:00:01Z",
        "subscriptionState": state,
        "acknowledgementState": acknowledgement,
        "latestOrderId": "google-order-1",
        "lineItems": [
            {"productId": APPLE_MONTHLY, "expiryTime": "2099-01-01T00:00:00Z"}
        ],
    }
    if owner_device_id:
        purchase["externalAccountIdentifiers"] = {
            "obfuscatedExternalAccountId": _google_obfuscated_account_id(owner_device_id)
        }
    return purchase
