"""Trial-only monetization contract.

These tests intentionally exercise the HTTP boundary: no rewrite surface may
reach a provider unless billing has produced a verified active/trialing state,
or an administrator explicitly granted a still-valid coupon.
"""

from __future__ import annotations


def _register(client) -> dict:
    response = client.post("/v1/register", json={"platform": "ios"})
    assert response.status_code == 200, response.text
    return response.json()


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _assert_paywall(response) -> None:
    assert response.status_code == 402, response.text
    assert response.json()["error"]["code"] == "paywall_required"


def test_fresh_unpaid_user_cannot_call_rewrite_or_coach(client):
    user = _register(client)
    _assert_paywall(client.post("/api/analyze", headers=_auth(user["api_token"]), json={"text": "Rewrite this"}))
    _assert_paywall(client.post("/v1/coach", headers=_auth(user["api_token"]), json={"text": "Coach this"}))
    _assert_paywall(client.post("/v1/analyze", json={"draft": "Coach this"}))


def test_trialing_user_can_call_ios_coach_compatibility_route(client):
    from backend.store import get_store

    user = _register(client)
    get_store().update_subscription(
        device_id=user["device_id"], customer_id="cus_ios",
        subscription_id="sub_ios_trial", status="trialing", renews_at="2099-01-01T00:00:00+00:00",
    )
    response = client.post(
        "/v1/coach", headers=_auth(user["api_token"]), json={"text": "Coach this"},
    )
    assert response.status_code == 200, response.text
    assert [item["axis"] for item in response.json()["rewrites"]] == [
        "warmer", "clearer", "funnier", "safer"
    ]


def test_repeated_unpaid_attempts_remain_402_while_abuse_bucket_tracks_them(client):
    from backend import server

    user = _register(client)
    headers = {**_auth(user["api_token"]), "X-Forwarded-For": "198.51.100.42"}
    for attempt in range(5):
        response = client.post("/api/analyze", headers=headers, json={"text": f"attempt {attempt}"})
        _assert_paywall(response)

    assert len(server._ip_windows["198.51.100.42"]) == 5


def test_only_trialing_active_or_valid_coupon_unlocks_rewrites(client, monkeypatch):
    from backend.store import get_store

    store = get_store()
    user = _register(client)
    headers = _auth(user["api_token"])

    for status in ("trialing", "active"):
        store.update_subscription(
            device_id=user["device_id"], customer_id="cus_verified",
            subscription_id=f"sub_{status}", status=status, renews_at="2099-01-01T00:00:00+00:00",
        )
        response = client.post("/api/analyze", headers=headers, json={"text": status})
        assert response.status_code == 200, response.text

    for status in ("past_due", "canceled", "expired", "incomplete", "mystery"):
        store.update_subscription(
            device_id=user["device_id"], customer_id="cus_verified",
            subscription_id=f"sub_{status}", status=status, renews_at=None,
        )
        _assert_paywall(client.post("/api/analyze", headers=headers, json={"text": status}))

    monkeypatch.setenv("TONO_ADMIN_SECRET", "test-admin-secret")
    created = client.post(
        "/admin/coupon/create",
        headers={"X-Admin-Secret": "test-admin-secret"},
        json={"code": "EXPLICIT30", "duration_days": 30},
    )
    assert created.status_code == 201, created.text
    redeemed = client.post(
        "/v1/coupon/redeem", headers=headers, json={"code": "EXPLICIT30"},
    )
    assert redeemed.status_code == 200, redeemed.text
    assert store.get_by_device(user["device_id"]).subscription_status == "mystery"
    coupon_response = client.post("/api/analyze", headers=headers, json={"text": "coupon"})
    assert coupon_response.status_code == 200
    assert coupon_response.json()["plan"] == "coupon"


def test_active_label_without_verified_expiry_fails_closed(client):
    from backend.store import get_store

    user = _register(client)
    get_store().update_subscription(
        device_id=user["device_id"], customer_id="cus_uncertain",
        subscription_id="sub_uncertain", status="active", renews_at=None,
    )
    _assert_paywall(client.post("/api/analyze", headers=_auth(user["api_token"]), json={"text": "uncertain"}))


def test_legacy_free_account_is_preserved_and_paywalled(client):
    from backend.store import get_store

    user = _register(client)
    store = get_store()
    before = store.get_by_device(user["device_id"])

    _assert_paywall(client.post("/api/analyze", headers=_auth(user["api_token"]), json={"text": "history stays"}))

    after = store.get_by_device(user["device_id"])
    assert after.device_id == before.device_id
    assert after.api_token == before.api_token
    assert after.plan == "free"
    assert after.subscription_status is None
