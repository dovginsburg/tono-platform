"""End-to-end tests for the Tono backend API.

Covers:
  - /health (sanity)
  - /v1/register (device + token issuance)
  - /v1/me (auth + plan + usage)
  - /api/analyze happy path (auth, schema, mock provider)
  - /api/analyze rate limit (10 -> 3 in tests -> 429)
  - /api/analyze rejects missing/empty text
  - /api/analyze rejects missing/invalid bearer token
  - token rotation
  - /v1/analyze still works unauthenticated (back-compat)
  - /admin/coupon/create + /v1/coupon/redeem (happy path + error cases)
  - /admin/stats (auth guard)
"""

from __future__ import annotations

import os

import pytest


def _register(
    client,
    device_id: str | None = None,
    *,
    device_credential: str | None = None,
    bearer_token: str | None = None,
) -> dict:
    body = {"platform": "ios", "app_version": "0.2.0"}
    if device_id:
        body["device_id"] = device_id
    if device_credential:
        body["device_credential"] = device_credential
    headers = _auth(bearer_token) if bearer_token else None
    r = client.post("/v1/register", json=body, headers=headers)
    assert r.status_code == 200, r.text
    return r.json()


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _grant_active_subscription(registration: dict) -> None:
    from backend.store import get_store

    get_store().update_subscription(
        device_id=registration["device_id"],
        customer_id=None,
        subscription_id=f"sub_{registration['device_id']}",
        status="active",
        renews_at=None,
    )


# ---------------------------------------------------------------------------
# Sanity
# ---------------------------------------------------------------------------


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    j = r.json()
    assert j["status"] == "ok"
    assert "version" in j
    assert "free_daily_limit" not in j
    # Stripe off in test env.
    assert j["stripe_configured"] is False


def test_v1_analyze_unauthenticated_still_works(client):
    """The original passthrough is preserved for the iOS Playground tab."""

    r = client.post(
        "/v1/analyze",
        json={"draft": "Sounds good. Let me know when you can."},
    )
    assert r.status_code == 200, r.text
    j = r.json()
    assert "risk_level" in j
    assert "perception" in j
    assert "risk_reason" in j
    assert "suggestions" in j
    # The mock flags "let me know" without "by" as ambiguous.
    assert "ambiguous ask" in j["flags"]
    # And it should produce exactly the 4 axis suggestions by default.
    assert {s["axis"] for s in j["suggestions"]} == {
        "warmer",
        "clearer",
        "funnier",
        "safer",
    }


def test_v1_analyze_read_mode(client):
    """Read mode returns interpretation with no suggestions."""
    r = client.post(
        "/v1/analyze",
        json={"draft": "as per my last message", "mode": "read"},
    )
    assert r.status_code == 200, r.text
    j = r.json()
    assert j["risk_level"] == "high"
    assert "passive-aggressive" in j["flags"]
    assert j["suggestions"] == []
    assert "risk_reason" in j


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------


def test_register_then_me(client):
    reg = _register(client)
    assert reg["plan"] == "free"
    assert reg["is_pro"] is False
    assert len(reg["api_token"]) >= 32
    assert reg["device_id"]

    r = client.get("/v1/me", headers=_auth(reg["api_token"]))
    assert r.status_code == 200, r.text
    me = r.json()
    assert me["device_id"] == reg["device_id"]
    assert "used_today" not in me
    assert "daily_limit" not in me


def test_register_idempotent_with_device_credential(client):
    a = _register(client)
    b = _register(
        client,
        device_id=a["device_id"],
        device_credential=a["device_credential"],
    )
    assert a["device_id"] == b["device_id"]
    assert a["api_token"] == b["api_token"]
    assert b["device_credential"] is None


def test_public_device_id_alone_cannot_retrieve_token(client):
    registered = _register(client)
    response = client.post(
        "/v1/register",
        json={"device_id": registered["device_id"], "platform": "ios"},
    )
    assert response.status_code == 409
    assert registered["api_token"] not in response.text


def test_register_rejects_non_uuid_identifier(client):
    response = client.post(
        "/v1/register",
        json={"device_id": "caller-controlled-id", "platform": "ios"},
    )
    assert response.status_code == 422


def test_concurrent_duplicate_registration_is_stable(client):
    from concurrent.futures import ThreadPoolExecutor

    registered = _register(client)
    body = {
        "device_id": registered["device_id"],
        "device_credential": registered["device_credential"],
        "platform": "ios",
    }
    with ThreadPoolExecutor(max_workers=8) as executor:
        responses = list(executor.map(lambda _: client.post("/v1/register", json=body), range(8)))
    assert {response.status_code for response in responses} == {200}
    assert {response.json()["api_token"] for response in responses} == {registered["api_token"]}


def test_legacy_bearer_migration_rotates_with_bounded_grace(client):
    from backend.store import get_store

    registered = _register(client)
    store = get_store()
    store._conn.execute(
        "UPDATE users SET device_credential_hash=NULL WHERE device_id=?",
        (registered["device_id"],),
    )
    migrated = _register(
        client,
        registered["device_id"],
        bearer_token=registered["api_token"],
    )
    assert migrated["api_token"] != registered["api_token"]
    assert migrated["device_credential"]
    assert client.get("/v1/me", headers=_auth(registered["api_token"])).status_code == 200
    store._conn.execute(
        "UPDATE users SET previous_api_token_expires_at=? WHERE device_id=?",
        ("2000-01-01T00:00:00+00:00", registered["device_id"]),
    )
    assert client.get("/v1/me", headers=_auth(registered["api_token"])).status_code == 401
    assert client.get("/v1/me", headers=_auth(migrated["api_token"])).status_code == 200


def test_register_rate_limit_is_scoped_per_ip(client, monkeypatch):
    from backend import server

    monkeypatch.setitem(server.rate_limit.RATE_SCOPES, "register", 2)
    for _ in range(2):
        assert client.post("/v1/register", json={"platform": "ios"}).status_code == 200
    blocked = client.post("/v1/register", json={"platform": "ios"})
    assert blocked.status_code == 429
    assert blocked.headers["Retry-After"] == "60"
    assert client.post(
        "/v1/register",
        headers={"X-Forwarded-For": "198.51.100.25"},
        json={"platform": "ios"},
    ).status_code == 200


def test_me_requires_bearer(client):
    r = client.get("/v1/me")
    assert r.status_code == 401


def test_me_rejects_bad_token(client):
    r = client.get("/v1/me", headers=_auth("definitely-not-a-real-token"))
    assert r.status_code == 401


# ---------------------------------------------------------------------------
# /api/analyze
# ---------------------------------------------------------------------------


def test_api_analyze_happy_path(client):
    reg = _register(client)
    _grant_active_subscription(reg)
    r = client.post(
        "/api/analyze",
        headers=_auth(reg["api_token"]),
        json={"text": "Per my last message, please respond."},
    )
    assert r.status_code == 200, r.text
    j = r.json()
    assert j["risk_level"] == "high"
    assert "passive-aggressive" in j["flags"]
    assert j["plan"] == "pro"
    assert "used_today" not in j
    assert "daily_limit" not in j
    # The "safer" rewrite should drop the passive-aggressive phrase.
    safer = next(s for s in j["suggestions"] if s["axis"] == "safer")
    assert "per my last" not in safer["text"].lower()


def test_api_analyze_enforces_canonical_coach_axes(client):
    reg = _register(client)
    _grant_active_subscription(reg)
    r = client.post(
        "/api/analyze",
        headers=_auth(reg["api_token"]),
        json={"text": "Hi", "axes": ["warmer"]},
    )
    assert r.status_code == 200, r.text
    j = r.json()
    assert [s["axis"] for s in j["suggestions"]] == [
        "warmer", "clearer", "funnier", "safer"
    ]


def test_api_analyze_treats_invalid_cached_coach_payload_as_miss(client, monkeypatch):
    from backend import server
    from backend.store import get_store

    reg = _register(client)
    _grant_active_subscription(reg)
    text = "Please help with this request."
    axes = list(server.CANONICAL_COACH_AXES)
    cache_key = server._analysis_cache_key(text, axes, None, "en")
    get_store().set_cached_response(cache_key, {
        "risk_level": "low",
        "perception": "Looks okay.",
        "subtext": "A direct request.",
        "risk_reason": "Lands cleanly.",
        "suggestions": [{"axis": "warmer", "text": text}],
        "flags": [],
    })
    provider_calls = 0

    async def valid_provider(req):
        nonlocal provider_calls
        provider_calls += 1
        return {
            "risk_level": "low",
            "perception": "Looks okay.",
            "subtext": "A direct request.",
            "risk_reason": "Lands cleanly.",
            "suggestions": [
                {"axis": axis, "text": req.draft} for axis in req.axes
            ],
            "flags": [],
        }

    monkeypatch.setattr(server, "openai_analyze", valid_provider)
    response = client.post(
        "/api/analyze",
        headers=_auth(reg["api_token"]),
        json={"text": text, "provider": "openai"},
    )

    assert response.status_code == 200, response.text
    assert provider_calls == 1
    assert [item["axis"] for item in response.json()["suggestions"]] == axes
    assert "used_today" not in response.json()
    assert "daily_limit" not in response.json()


def test_api_analyze_requires_text(client):
    reg = _register(client)
    r = client.post(
        "/api/analyze",
        headers=_auth(reg["api_token"]),
        json={"text": ""},
    )
    assert r.status_code == 400


def test_api_analyze_requires_auth(client):
    r = client.post("/api/analyze", json={"text": "hi"})
    assert r.status_code == 401


def test_api_analyze_requires_entitlement_on_first_rewrite(client):
    reg = _register(client)
    headers = _auth(reg["api_token"])
    r = client.post(
        "/api/analyze",
        headers=headers,
        json={"text": "the first unpaid rewrite must be blocked"},
    )
    assert r.status_code == 429
    assert r.json()["error"]["message"] == "active trial or subscription required"
    assert "Retry-After" not in r.headers
    assert "used_today" not in r.text
    assert "daily_limit" not in r.text


def test_api_analyze_pro_unlimited(client, monkeypatch):
    """Pro users never get rate-limited. We bypass Stripe by manually
    setting the user's plan via the store + DB."""

    from backend.store import get_store

    reg = _register(client)
    store = get_store()
    # Flip the user to pro directly. (In production this happens via
    # the Stripe webhook handler in payments.py.)
    store.update_subscription(
        device_id=reg["device_id"],
        customer_id=None,
        subscription_id="sub_fake",
        status="active",
        renews_at=None,
    )

    headers = _auth(reg["api_token"])
    for i in range(10):
        r = client.post(
            "/api/analyze",
            headers=headers,
            json={"text": f"pro msg {i}"},
        )
        assert r.status_code == 200, f"call {i}: {r.text}"
        j = r.json()
        assert j["plan"] == "pro"
        assert "used_today" not in j
        assert "daily_limit" not in j


# ---------------------------------------------------------------------------
# Rotation
# ---------------------------------------------------------------------------


def test_token_rotation_revokes_old_token(client):
    """Rotation is wired in the store but not exposed via an HTTP route in
    v0.2. We verify the store path directly + that an old token 401s
    after rotation."""

    from backend.store import get_store

    reg = _register(client)
    old = reg["api_token"]
    new = get_store().rotate_token(reg["device_id"])
    assert new and new != old

    r = client.get("/v1/me", headers=_auth(old))
    assert r.status_code == 401

    r = client.get("/v1/me", headers=_auth(new))
    assert r.status_code == 200


# ---------------------------------------------------------------------------
# Stripe-off behavior
# ---------------------------------------------------------------------------


def test_checkout_returns_503_when_stripe_not_configured(client):
    """Without STRIPE_SECRET_KEY, /v1/checkout must fail clearly rather
    than 500 or hang."""

    assert os.environ.get("STRIPE_SECRET_KEY", "") == ""
    reg = _register(client)
    r = client.post(
        "/v1/checkout",
        headers=_auth(reg["api_token"]),
        json={"interval": "month"},
    )
    assert r.status_code == 503
    assert "not configured" in r.json()["error"]["message"].lower()


# ---------------------------------------------------------------------------
# Coupon / promo codes
# ---------------------------------------------------------------------------

_ADMIN_SECRET = "test-admin-secret"
_ADMIN_HEADERS = {"X-Admin-Secret": _ADMIN_SECRET}


def _create_coupon(client, *, code="TONO10", days=30, max_uses=0, expires_at=None):
    return client.post(
        "/admin/coupon/create",
        headers=_ADMIN_HEADERS,
        json={"code": code, "duration_days": days, "max_uses": max_uses, "expires_at": expires_at},
    )


def test_admin_coupon_create_requires_secret(client):
    r = client.post("/admin/coupon/create", json={"code": "X", "duration_days": 7})
    assert r.status_code == 403


def test_admin_coupon_create_wrong_secret(client, monkeypatch):
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)
    r = client.post(
        "/admin/coupon/create",
        headers={"X-Admin-Secret": "wrong"},
        json={"code": "X", "duration_days": 7},
    )
    assert r.status_code == 403


def test_coupon_happy_path(client, monkeypatch):
    """Create a coupon, redeem it, verify Pro access is granted."""
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)

    # Create
    r = _create_coupon(client)
    assert r.status_code == 201
    assert r.json()["code"] == "TONO10"

    # Redeem
    reg = _register(client)
    r = client.post(
        "/v1/coupon/redeem",
        headers=_auth(reg["api_token"]),
        json={"code": "TONO10"},
    )
    assert r.status_code == 200, r.text
    j = r.json()
    assert "coupon_pro_expires_at" in j
    assert "Pro access activated" in j["message"]

    # /v1/me should now show is_pro=True
    me = client.get("/v1/me", headers=_auth(reg["api_token"])).json()
    assert me["is_pro"] is True
    assert "used_today" not in me
    assert "daily_limit" not in me


def test_coupon_redeemed_twice_rejected(client, monkeypatch):
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)
    _create_coupon(client, code="ONCE")
    reg = _register(client)
    headers = _auth(reg["api_token"])

    r = client.post("/v1/coupon/redeem", headers=headers, json={"code": "ONCE"})
    assert r.status_code == 200

    r = client.post("/v1/coupon/redeem", headers=headers, json={"code": "ONCE"})
    assert r.status_code == 400
    assert "already redeemed" in r.json()["error"]["message"].lower()


def test_coupon_invalid_code(client):
    reg = _register(client)
    r = client.post(
        "/v1/coupon/redeem",
        headers=_auth(reg["api_token"]),
        json={"code": "DOESNOTEXIST"},
    )
    assert r.status_code == 400
    assert "invalid" in r.json()["error"]["message"].lower()


def test_coupon_max_uses_enforced(client, monkeypatch):
    """A coupon with max_uses=1 rejects the second redemption."""
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)
    _create_coupon(client, code="LIMITED", max_uses=1)

    reg1 = _register(client)
    reg2 = _register(client)

    r = client.post("/v1/coupon/redeem", headers=_auth(reg1["api_token"]), json={"code": "LIMITED"})
    assert r.status_code == 200

    r = client.post("/v1/coupon/redeem", headers=_auth(reg2["api_token"]), json={"code": "LIMITED"})
    assert r.status_code == 400
    assert "usage limit" in r.json()["error"]["message"].lower()


def test_coupon_duplicate_code_rejected(client, monkeypatch):
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)
    _create_coupon(client, code="DUP")
    r = _create_coupon(client, code="DUP")
    assert r.status_code == 409


def test_coupon_unlocks_rewrites(client, monkeypatch):
    """An active coupon grants rewrite access without quota counters."""
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)
    _create_coupon(client, code="UNLIM")
    reg = _register(client)
    client.post("/v1/coupon/redeem", headers=_auth(reg["api_token"]), json={"code": "UNLIM"})

    headers = _auth(reg["api_token"])
    for i in range(5):
        r = client.post("/api/analyze", headers=headers, json={"text": f"msg {i}"})
        assert r.status_code == 200, f"call {i}: {r.text}"
        assert "used_today" not in r.json()
        assert "daily_limit" not in r.json()


def test_openapi_has_no_retired_quota_fields(client):
    document = client.get("/openapi.json").json()
    schemas = document["components"]["schemas"]

    assert "used_today" not in schemas["MeResponse"]["properties"]
    assert "daily_limit" not in schemas["MeResponse"]["properties"]
    assert "used_today" not in schemas["ApiAnalyzeResponse"]["properties"]
    assert "daily_limit" not in schemas["ApiAnalyzeResponse"]["properties"]


# ---------------------------------------------------------------------------
# Feature flags
# ---------------------------------------------------------------------------


def test_features_returns_defaults(client):
    """GET /v1/features returns a dict of all flags at their default values."""
    reg = _register(client)
    r = client.get("/v1/features", headers=_auth(reg["api_token"]))
    assert r.status_code == 200, r.text
    flags = r.json()
    # All 7 flags should be present
    assert "onboarding_calibration" in flags
    assert "thread_context" in flags
    assert "weekly_digest" in flags
    assert "risk_delta" in flags
    assert "memory_inference" in flags
    assert "memory_context_hints" in flags
    assert "custom_axes" in flags
    # custom_axes is off by default (pro-gated); others are on
    assert flags["custom_axes"] is False
    assert flags["thread_context"] is True
    assert flags["weekly_digest"] is True


def test_features_requires_auth(client):
    r = client.get("/v1/features")
    assert r.status_code == 401


def test_user_flag_override(client):
    """PUT /v1/features/{key} stores the user's preference."""
    reg = _register(client)
    headers = _auth(reg["api_token"])

    # Disable the weekly digest
    r = client.put("/v1/features/weekly_digest", headers=headers, json={"enabled": False})
    assert r.status_code == 200, r.text
    assert r.json()["enabled"] is False

    # The flag should now be false for this device
    flags = client.get("/v1/features", headers=headers).json()
    assert flags["weekly_digest"] is False


def test_user_flag_override_non_controllable_rejected(client):
    """Users cannot toggle flags marked as admin-only (e.g. onboarding_calibration)."""
    reg = _register(client)
    r = client.put(
        "/v1/features/onboarding_calibration",
        headers=_auth(reg["api_token"]),
        json={"enabled": False},
    )
    assert r.status_code == 403


def test_pro_gated_flag(client):
    """custom_axes returns True only for Pro users."""
    from backend.store import get_store

    reg = _register(client)
    headers = _auth(reg["api_token"])

    # Free user: custom_axes should be False
    flags = client.get("/v1/features", headers=headers).json()
    assert flags["custom_axes"] is False

    # Upgrade to Pro
    get_store().update_subscription(
        device_id=reg["device_id"],
        customer_id=None,
        subscription_id="sub_test",
        status="active",
        renews_at=None,
    )

    # Pro user: custom_axes should be True
    flags = client.get("/v1/features", headers=headers).json()
    assert flags["custom_axes"] is True


def test_admin_flags_list(client, monkeypatch):
    """GET /admin/flags returns all flags; requires admin secret."""
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)

    r = client.get("/admin/flags")
    assert r.status_code == 403

    r = client.get("/admin/flags", headers=_ADMIN_HEADERS)
    assert r.status_code == 200, r.text
    flags = r.json()
    assert isinstance(flags, list)
    keys = {f["key"] for f in flags}
    assert "thread_context" in keys
    assert "custom_axes" in keys


def test_admin_flag_update(client, monkeypatch):
    """PATCH /admin/flags/{key} updates the global enabled state."""
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)

    # Turn off thread_context globally
    r = client.patch(
        "/admin/flags/thread_context",
        headers=_ADMIN_HEADERS,
        json={"enabled": False},
    )
    assert r.status_code == 200, r.text

    # A newly registered device should see it as False
    reg = _register(client)
    flags = client.get("/v1/features", headers=_auth(reg["api_token"])).json()
    assert flags["thread_context"] is False


def test_digest_endpoint(client):
    """GET /v1/digest returns the weekly stats structure including prev_axis_breakdown."""
    reg = _register(client)
    r = client.get("/v1/digest", headers=_auth(reg["api_token"]))
    assert r.status_code == 200, r.text
    j = r.json()
    assert "rewrites" in j
    assert "days_active" in j
    assert "axis_breakdown" in j
    assert "prev_axis_breakdown" in j
    assert j["rewrites"] == 0  # fresh device, no rewrites yet


# ---------------------------------------------------------------------------
# Admin stats
# ---------------------------------------------------------------------------


def test_admin_stats_requires_secret(client):
    r = client.get("/admin/stats")
    assert r.status_code == 403


def test_admin_stats_returns_counts(client, monkeypatch):
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)
    _register(client)
    r = client.get("/admin/stats", headers=_ADMIN_HEADERS)
    assert r.status_code == 200, r.text
    j = r.json()
    assert j["total_devices"] >= 1
    assert "axis_stats_30d" in j
    assert "rewrites_today" in j


# ---------------------------------------------------------------------------
# Analytics events (A3)
# ---------------------------------------------------------------------------


def test_analytics_event_accepted(client):
    """POST /v1/events with a known event name returns 204."""
    reg = _register(client)
    r = client.post(
        "/v1/events",
        headers=_auth(reg["api_token"]),
        json={
            "event": "analysis_shown",
            "ts": 1700000000,
            "risk_level": "low",
            "latency_ms": 320,
            "source": "mock",
        },
    )
    assert r.status_code == 204, r.text


def test_analytics_event_unknown_dropped_silently(client):
    """POST /v1/events with an unknown event name is accepted (204) and silently dropped."""
    reg = _register(client)
    r = client.post(
        "/v1/events",
        headers=_auth(reg["api_token"]),
        json={"event": "totally_unknown_event", "ts": 1700000000},
    )
    assert r.status_code == 204, r.text


def test_analytics_event_requires_auth(client):
    """POST /v1/events without a bearer token returns 401."""
    r = client.post(
        "/v1/events",
        json={"event": "coach_requested", "ts": 1700000000},
    )
    assert r.status_code == 401


def test_analytics_event_rejects_message_content(client):
    """A4 PRIVACY GUARDRAIL: any field outside the allowlist (e.g. message
    text, rewrite text, recipient name) is rejected with 422 — the contract
    fails loud rather than silently accepting and dropping the content."""
    reg = _register(client)
    headers = _auth(reg["api_token"])
    for leaky_field in ("message_text", "rewrite_text", "recipient", "draft"):
        r = client.post(
            "/v1/events",
            headers=headers,
            json={
                "event": "rewrite_inserted",
                "ts": 1700000000,
                "selected_axis": "warmer",
                leaky_field: "Hey, are we still on for tonight?",
            },
        )
        assert r.status_code == 422, f"{leaky_field} should be rejected, got {r.status_code}"


def test_metrics_rejects_unknown_fields(client):
    """A4: /v1/metrics is fail-closed too — only declared counters accepted."""
    reg = _register(client)
    r = client.post(
        "/v1/metrics",
        headers=_auth(reg["api_token"]),
        json={"type": "daily_metrics", "end_ts": 1700000000, "message_text": "secret"},
    )
    assert r.status_code == 422


def test_analytics_all_event_names_accepted(client):
    """Every permitted event name returns 204."""
    reg = _register(client)
    headers = _auth(reg["api_token"])
    events = [
        {"event": "coach_requested", "ts": 1700000000, "mode": "coach"},
        {"event": "analysis_shown", "ts": 1700000001, "risk_level": "medium", "latency_ms": 800, "source": "llm"},
        {"event": "rewrite_inserted", "ts": 1700000002, "selected_axis": "warmer", "shown_axes": ["warmer", "clearer"]},
        {"event": "rewrite_edited_after_insert", "ts": 1700000003},
        {"event": "axis_rejected", "ts": 1700000004, "shown_axes": ["warmer", "clearer"], "picked_axis": "clearer"},
    ]
    for payload in events:
        r = client.post("/v1/events", headers=headers, json=payload)
        assert r.status_code == 204, f"Failed for event={payload['event']}: {r.text}"


# ---------------------------------------------------------------------------
# Collective improvement signal
# ---------------------------------------------------------------------------

_IMPROVEMENT_OUTCOME_PAYLOAD = {
    "event": "improvement_outcome",
    "risk_level": "high",
    "selected_axis": "safer",
    "mode": "coach",
    "msg_len_bucket": "medium",
    "rewrite_used": True,
    "edit_after": False,
}


def test_improvement_outcome_accepted(client):
    """improvement_outcome event returns 204 and is stored."""
    reg = _register(client)
    r = client.post(
        "/v1/events",
        headers=_auth(reg["api_token"]),
        json=_IMPROVEMENT_OUTCOME_PAYLOAD,
    )
    assert r.status_code == 204, r.text


def test_improvement_outcome_schema_exact(client):
    """Exact payload schema check: all three new fields accepted, no extras."""
    reg = _register(client)
    headers = _auth(reg["api_token"])
    # Verify all new fields are permitted
    r = client.post("/v1/events", headers=headers, json=_IMPROVEMENT_OUTCOME_PAYLOAD)
    assert r.status_code == 204, r.text
    # Verify an extra field (e.g. actual message length as a number) is rejected
    r2 = client.post(
        "/v1/events",
        headers=headers,
        json={**_IMPROVEMENT_OUTCOME_PAYLOAD, "message_length_raw": 147},
    )
    assert r2.status_code == 422, "Raw numeric length should be rejected by the schema"


def test_improvement_outcome_rejects_content_fields(client):
    """A4: improvement_outcome rejects any content-bearing field."""
    reg = _register(client)
    headers = _auth(reg["api_token"])
    for leaky_field in ("message_text", "draft", "rewrite_text", "recipient"):
        r = client.post(
            "/v1/events",
            headers=headers,
            json={**_IMPROVEMENT_OUTCOME_PAYLOAD, leaky_field: "secret content"},
        )
        assert r.status_code == 422, (
            f"Content field '{leaky_field}' must be rejected (got {r.status_code})"
        )


def test_improvement_outcome_optout_respected(client, monkeypatch):
    """When improve_tono flag is disabled, improvement_outcome events are not stored.

    Verified via /admin/improvement-stats with min_devices=1: opting out means
    the event never reaches the aggregate, even at the lowest k-anon floor.
    """
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)

    reg = _register(client)
    headers = _auth(reg["api_token"])

    # Opt out
    r = client.put(
        "/v1/features/improve_tono",
        headers=headers,
        json={"enabled": False},
    )
    assert r.status_code == 200, r.text

    # Send improvement event (should be silently discarded server-side)
    r = client.post("/v1/events", headers=headers, json=_IMPROVEMENT_OUTCOME_PAYLOAD)
    assert r.status_code == 204, r.text

    # Even with min_devices=1, the opted-out event should not appear in aggregates
    r2 = client.get(
        "/admin/improvement-stats",
        headers=_ADMIN_HEADERS,
        params={"days": 30, "min_devices": 1},
    )
    assert r2.status_code == 200, r2.text
    data = r2.json()
    effectiveness = data["axis_effectiveness_by_risk"]
    assert effectiveness == {}, (
        f"Opted-out event appeared in aggregates: {effectiveness}"
    )


def test_admin_improvement_stats_requires_auth(client):
    """GET /admin/improvement-stats without admin secret returns 403."""
    r = client.get("/admin/improvement-stats")
    assert r.status_code == 403


def test_admin_improvement_stats_k_anon(client, monkeypatch):
    """k-anonymity: patterns with fewer than min_devices distinct devices are excluded."""
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)

    # Register 3 devices and send improvement events (below k-anon floor of 50)
    for i in range(3):
        reg = _register(
            client, device_id=f"00000000-0000-0000-0000-{i + 1:012d}"
        )
        client.post(
            "/v1/events",
            headers=_auth(reg["api_token"]),
            json=_IMPROVEMENT_OUTCOME_PAYLOAD,
        )

    r = client.get(
        "/admin/improvement-stats",
        headers=_ADMIN_HEADERS,
        params={"days": 30, "min_devices": 50},
    )
    assert r.status_code == 200, r.text
    data = r.json()
    # With min_devices=50, the 3 events above should NOT appear in effectiveness
    effectiveness = data["axis_effectiveness_by_risk"]
    assert effectiveness == {}, (
        f"Patterns from 3 devices leaked through k-anon floor: {effectiveness}"
    )


def test_admin_improvement_stats_k_anon_floor_configurable(client, monkeypatch):
    """k-anon floor can be lowered at query time for dev environments."""
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)

    # Register 2 distinct devices
    for i in range(2):
        reg = _register(
            client, device_id=f"10000000-0000-0000-0000-{i + 1:012d}"
        )
        client.post(
            "/v1/events",
            headers=_auth(reg["api_token"]),
            json=_IMPROVEMENT_OUTCOME_PAYLOAD,
        )

    # With floor=1, patterns should appear
    r = client.get(
        "/admin/improvement-stats",
        headers=_ADMIN_HEADERS,
        params={"days": 30, "min_devices": 1},
    )
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["min_devices_floor"] == 1
    effectiveness = data["axis_effectiveness_by_risk"]
    assert "high" in effectiveness, f"Expected 'high' risk data with floor=1: {effectiveness}"


def test_admin_age_out_events(client, monkeypatch):
    """POST /admin/maintenance/age-out-events returns deleted count."""
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)
    r = client.post(
        "/admin/maintenance/age-out-events",
        headers=_ADMIN_HEADERS,
        params={"retain_days": 90},
    )
    assert r.status_code == 200, r.text
    data = r.json()
    assert "deleted" in data
    assert isinstance(data["deleted"], int)


# ---------------------------------------------------------------------------
# Metrics ingest (A2)
# ---------------------------------------------------------------------------


def test_metrics_ingest_accepted(client):
    """POST /v1/metrics with a valid payload returns 204."""
    reg = _register(client)
    r = client.post(
        "/v1/metrics",
        headers=_auth(reg["api_token"]),
        json={
            "type": "daily",
            "end_ts": 1700000000,
            "avg_memory_mb": 18.4,
            "fg_oom": 0,
            "bg_oom": 0,
            "bg_watchdog": 0,
            "crash_count": 0,
            "hang_count": 0,
        },
    )
    assert r.status_code == 204, r.text


def test_metrics_requires_auth(client):
    """POST /v1/metrics without a bearer token returns 401."""
    r = client.post(
        "/v1/metrics",
        json={"type": "daily", "end_ts": 1700000000, "avg_memory_mb": 18.4},
    )
    assert r.status_code == 401
