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


def _register(client, device_id: str | None = None) -> dict:
    body = {"platform": "ios", "app_version": "0.2.0"}
    if device_id:
        body["device_id"] = device_id
    r = client.post("/v1/register", json=body)
    assert r.status_code == 200, r.text
    return r.json()


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


# ---------------------------------------------------------------------------
# Sanity
# ---------------------------------------------------------------------------


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    j = r.json()
    assert j["status"] == "ok"
    assert "version" in j
    # Free limit comes from FREE_DAILY_LIMIT (set to 3 in conftest).
    assert j["free_daily_limit"] == 3
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


def test_v1_locales_lists_supported_codes(client):
    r = client.get("/v1/locales")
    assert r.status_code == 200
    codes = {loc["code"] for loc in r.json()["locales"]}
    assert {"en", "es", "fr", "de", "ja", "pt-BR", "ar"} <= codes


def test_v1_analyze_accepts_locale_mock_ignores_it(client):
    """Mock analyzer always answers in English regardless of locale."""
    r = client.post(
        "/v1/analyze",
        json={"draft": "Sounds good.", "locale": "es"},
    )
    assert r.status_code == 200, r.text
    assert "perception" in r.json()


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
    assert me["used_today"] == 0
    assert me["daily_limit"] == 3  # FREE_DAILY_LIMIT in conftest


def test_register_idempotent(client):
    a = _register(client)
    b = _register(client, device_id=a["device_id"])
    assert a["device_id"] == b["device_id"]
    # Token stays stable on re-register of the same device_id.
    assert a["api_token"] == b["api_token"]


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
    r = client.post(
        "/api/analyze",
        headers=_auth(reg["api_token"]),
        json={"text": "Per my last message, please respond."},
    )
    assert r.status_code == 200, r.text
    j = r.json()
    assert j["risk_level"] == "high"
    assert "passive-aggressive" in j["flags"]
    assert j["used_today"] == 1
    assert j["daily_limit"] == 3
    assert j["plan"] == "free"
    # The "safer" rewrite should drop the passive-aggressive phrase.
    safer = next(s for s in j["suggestions"] if s["axis"] == "safer")
    assert "per my last" not in safer["text"].lower()


def test_api_analyze_respects_axes(client):
    reg = _register(client)
    r = client.post(
        "/api/analyze",
        headers=_auth(reg["api_token"]),
        json={"text": "Hi", "axes": ["warmer"]},
    )
    assert r.status_code == 200, r.text
    j = r.json()
    assert {s["axis"] for s in j["suggestions"]} == {"warmer"}


def test_api_analyze_custom_axis(client):
    reg = _register(client)
    r = client.post(
        "/api/analyze",
        headers=_auth(reg["api_token"]),
        json={
            "text": "Hi",
            "axes": ["warmer"],
            "custom_axes": [{"name": "assertive", "instruction": "sound confident, cut hedging"}],
        },
    )
    assert r.status_code == 200, r.text
    j = r.json()
    assert {s["axis"] for s in j["suggestions"]} == {"warmer", "assertive"}
    custom = next(s for s in j["suggestions"] if s["axis"] == "assertive")
    assert "sound confident, cut hedging" in custom["rationale"]


def test_api_analyze_custom_axis_alone_with_all_presets_off(client):
    reg = _register(client)
    r = client.post(
        "/api/analyze",
        headers=_auth(reg["api_token"]),
        json={
            "text": "Hi",
            "axes": [],
            "custom_axes": [{"name": "formal", "instruction": "use formal register"}],
        },
    )
    assert r.status_code == 200, r.text
    j = r.json()
    assert {s["axis"] for s in j["suggestions"]} == {"formal"}


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


def test_api_analyze_rate_limit(client):
    """FREE_DAILY_LIMIT=3 in conftest. 3 should succeed, 4th returns 429."""

    reg = _register(client)
    headers = _auth(reg["api_token"])

    for i in range(3):
        r = client.post(
            "/api/analyze",
            headers=headers,
            json={"text": f"message {i}"},
        )
        assert r.status_code == 200, f"call {i}: {r.text}"
        assert r.json()["used_today"] == i + 1

    r = client.post(
        "/api/analyze",
        headers=headers,
        json={"text": "this should be blocked"},
    )
    assert r.status_code == 429
    detail = r.json()["error"]["message"]
    # Detail is a dict for 429s; TestClient's HTTPException handler
    # serializes whatever detail we passed.
    assert "daily" in str(detail).lower()


# ---------------------------------------------------------------------------
# Per-IP rate limit — separate from the per-device daily quota above.
# ---------------------------------------------------------------------------


def test_ip_rate_limit_blocks_after_threshold(client, monkeypatch):
    """IP_RATE_LIMIT_PER_MIN=2: a 3rd request from the SAME apparent IP in
    the same window is blocked, regardless of the (much higher) daily
    per-device quota."""
    # `_IP_RATE_LIMIT` is read from the env once at module import time, so
    # `monkeypatch.setenv` alone wouldn't affect an already-imported
    # server module — `setattr` on the module itself is what
    # `_check_ip_rate`'s global lookup actually sees at call time.
    import Backend.server as server_mod
    monkeypatch.setattr(server_mod, "_IP_RATE_LIMIT", 2)
    reg = _register(client)
    headers = {**_auth(reg["api_token"]), "X-Forwarded-For": "203.0.113.9"}

    for i in range(2):
        r = client.post("/api/analyze", headers=headers, json={"text": f"msg {i}"})
        assert r.status_code == 200, f"call {i}: {r.text}"

    r = client.post("/api/analyze", headers=headers, json={"text": "one too many"})
    assert r.status_code == 429
    assert "IP" in r.json()["error"]["message"]


def test_ip_rate_limit_is_not_bypassable_by_spoofing_the_first_xff_hop(client, monkeypatch):
    """The actual point of `_get_client_ip` trusting the LAST X-Forwarded-For
    entry, not the first: a caller can set an arbitrary first hop on every
    request (as if trying to get a fresh rate-limit bucket each time), but
    as long as the trusted last hop — the one a real single-hop reverse
    proxy would append — stays the same, the limit still applies. Trusting
    the first entry instead (an earlier version of this code did) would
    make this test fail, since each spoofed value would land in its own
    bucket and the limit would never trigger."""
    import Backend.server as server_mod
    monkeypatch.setattr(server_mod, "_IP_RATE_LIMIT", 2)
    reg = _register(client)
    real_proxy_hop = "203.0.113.55"

    def spoofed_headers(fake_first_hop: str) -> dict:
        return {**_auth(reg["api_token"]), "X-Forwarded-For": f"{fake_first_hop}, {real_proxy_hop}"}

    for i in range(2):
        r = client.post(
            "/api/analyze",
            headers=spoofed_headers(f"1.2.3.{i}"),
            json={"text": f"msg {i}"},
        )
        assert r.status_code == 200, f"call {i}: {r.text}"

    r = client.post(
        "/api/analyze",
        headers=spoofed_headers("9.9.9.9"),  # a brand-new, never-seen-before "first hop"
        json={"text": "should still be blocked"},
    )
    assert r.status_code == 429


def test_ip_rate_limit_buckets_are_independent_per_real_ip(client, monkeypatch):
    """Two different real (last-hop) IPs get independent buckets — the fix
    isn't just "ignore X-Forwarded-For entirely", which would incorrectly
    lump every real user behind the proxy into one shared bucket."""
    import Backend.server as server_mod
    monkeypatch.setattr(server_mod, "_IP_RATE_LIMIT", 1)
    reg = _register(client)

    r_a = client.post(
        "/api/analyze",
        headers={**_auth(reg["api_token"]), "X-Forwarded-For": "198.51.100.1"},
        json={"text": "from ip a"},
    )
    assert r_a.status_code == 200, r_a.text

    r_b = client.post(
        "/api/analyze",
        headers={**_auth(reg["api_token"]), "X-Forwarded-For": "198.51.100.2"},
        json={"text": "from ip b"},
    )
    assert r_b.status_code == 200, r_b.text


async def test_api_analyze_pro_unlimited(client, store, monkeypatch):
    """Pro users never get rate-limited. We bypass Stripe by manually
    setting the user's plan via the store + DB."""

    reg = _register(client)
    # Flip the user to pro directly. (In production this happens via
    # the Stripe webhook handler in payments.py.)
    await store.update_subscription(
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
        assert j["daily_limit"] == -1  # unlimited


# ---------------------------------------------------------------------------
# Rotation
# ---------------------------------------------------------------------------


async def test_token_rotation_revokes_old_token(client, store):
    """Rotation is wired in the store but not exposed via an HTTP route in
    v0.2. We verify the store path directly + that an old token 401s
    after rotation."""

    reg = _register(client)
    old = reg["api_token"]
    new = await store.rotate_token(reg["device_id"])
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
    assert me["daily_limit"] == -1


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


def test_coupon_unlocks_unlimited_rewrites(client, monkeypatch):
    """A coupon-pro user should bypass the daily rate limit."""
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)
    _create_coupon(client, code="UNLIM")
    reg = _register(client)
    client.post("/v1/coupon/redeem", headers=_auth(reg["api_token"]), json={"code": "UNLIM"})

    headers = _auth(reg["api_token"])
    for i in range(5):  # well beyond FREE_DAILY_LIMIT=3 in tests
        r = client.post("/api/analyze", headers=headers, json={"text": f"msg {i}"})
        assert r.status_code == 200, f"call {i}: {r.text}"
        assert r.json()["daily_limit"] == -1


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


async def test_pro_gated_flag(client, store):
    """custom_axes returns True only for Pro users."""
    reg = _register(client)
    headers = _auth(reg["api_token"])

    # Free user: custom_axes should be False
    flags = client.get("/v1/features", headers=headers).json()
    assert flags["custom_axes"] is False

    # Upgrade to Pro
    await store.update_subscription(
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
        reg = _register(client, device_id=f"test-device-kanon-{i}")
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
        reg = _register(client, device_id=f"test-device-floor-{i}")
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


# ---------------------------------------------------------------------------
# Locale / i18n
# ---------------------------------------------------------------------------


def test_build_system_prompt_injects_language_instruction():
    from Backend.analyze import AnalyzeRequest, build_system_prompt

    en_prompt = build_system_prompt(AnalyzeRequest(draft="hi", locale="en"))
    assert "LANGUAGE:" not in en_prompt

    es_prompt = build_system_prompt(AnalyzeRequest(draft="hi", locale="es"))
    assert "LANGUAGE:" in es_prompt
    assert "Spanish" in es_prompt


def test_build_system_prompt_unknown_locale_falls_back_to_code():
    from Backend.analyze import AnalyzeRequest, build_system_prompt

    prompt = build_system_prompt(AnalyzeRequest(draft="hi", locale="xx-YY"))
    assert "xx-YY" in prompt
