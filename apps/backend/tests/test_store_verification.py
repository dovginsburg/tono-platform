from __future__ import annotations

import pytest


def _register(client) -> dict:
    response = client.post("/v1/register", json={})
    assert response.status_code == 200
    return response.json()


def _auth(user: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {user['api_token']}"}


@pytest.mark.parametrize("product_id", ["com.tonoit.pro.monthly", "com.tonoit.pro.yearly"])
def test_both_verified_apple_trial_products_unlock(client, monkeypatch, product_id):
    from backend import server
    from backend.store_verification import VerifiedStoreSubscription

    async def verified(_jws: str):
        return VerifiedStoreSubscription(product_id, "apple-original", "trialing", "2026-07-20T00:00:00+00:00")

    monkeypatch.setattr(server, "verify_apple_transaction", verified)
    user = _register(client)
    response = client.post(
        "/v1/apple/subscription", headers=_auth(user), json={"signed_transaction": "real-jws-placeholder"},
    )
    assert response.status_code == 200, response.text
    assert response.json()["is_pro"] is True
    assert response.json()["subscription_status"] == "trialing"


def test_restored_apple_purchase_and_expiration_fail_closed(client, monkeypatch):
    from backend import server
    from backend.store_verification import VerifiedStoreSubscription

    user = _register(client)

    async def active(_jws: str):
        return VerifiedStoreSubscription("com.tonoit.pro.yearly", "apple-restored", "active", "2027-07-13T00:00:00+00:00")

    monkeypatch.setattr(server, "verify_apple_transaction", active)
    restored = client.post("/v1/apple/subscription", headers=_auth(user), json={"signed_transaction": "restored"})
    assert restored.status_code == 200 and restored.json()["is_pro"] is True

    async def expired(_jws: str):
        return VerifiedStoreSubscription("com.tonoit.pro.yearly", "apple-restored", "expired", None)

    monkeypatch.setattr(server, "verify_apple_transaction", expired)
    ended = client.post("/v1/apple/subscription", headers=_auth(user), json={"signed_transaction": "expired"})
    assert ended.status_code == 200 and ended.json()["is_pro"] is False


@pytest.mark.parametrize(("status", "is_pro"), [("trialing", True), ("active", True), ("past_due", False), ("expired", False)])
def test_google_verification_maps_lifecycle(client, monkeypatch, status, is_pro):
    from backend import server
    from backend.store_verification import VerifiedStoreSubscription

    async def verified(package_name: str, product_id: str, purchase_token: str):
        assert package_name == "com.tono.myapp"
        assert purchase_token
        return VerifiedStoreSubscription(
            product_id, "play-token-hash", status,
            "2099-01-01T00:00:00+00:00" if is_pro else None,
        )

    monkeypatch.setattr(server, "verify_google_play_subscription", verified)
    user = _register(client)
    response = client.post(
        "/v1/google-play/subscription",
        headers=_auth(user),
        json={
            "package_name": "com.tono.myapp",
            "product_id": "com.tonoit.pro.monthly",
            "purchase_token": "opaque-play-token",
        },
    )
    assert response.status_code == 200, response.text
    assert response.json()["is_pro"] is is_pro
    assert response.json()["subscription_status"] == status
