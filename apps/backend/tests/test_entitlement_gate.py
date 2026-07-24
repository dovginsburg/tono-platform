"""Hostile tests for the shared server-authoritative rewrite entitlement gate.

Binding contract: consumer rewrites are unlimited ONLY during an active 14-day
trial or paid subscription (or a durable founder grant). There is NO free daily
tier. Expired / canceled / non-entitled callers fail closed. Registration and
sign-in are entitlement PRINCIPALS, not grants.

These tests prove, on BOTH authenticated rewrite endpoints (``/api/analyze`` and
``/api/analyze/variant``) and across EVERY variant axis, that:
  * a fresh registered (never-entitled) device fails closed;
  * a canceled subscription fails closed;
  * an expired subscription and an expired coupon fail closed;
  * the denial is a DISTINCT honest 402 — never the IP-rate-limit 429;
  * the gate fires BEFORE any provider invocation (provider stubbed to explode);
  * no ``FREE_DAILY_LIMIT`` env value can reopen access;
  * active / trialing / durable-founder controls PASS;
  * every rewrite route is wired to the one shared gate.

All tests run against the mock provider + an isolated per-test DB (conftest).
"""

from __future__ import annotations

import datetime as _dt
import inspect

import pytest

# Every axis the selected-variant endpoint serves (server VARIANT_ALLOWLIST).
ALL_VARIANT_AXES = [
    "warmer", "clearer", "funnier", "safer",
    "affectionate", "professional", "concise", "custom",
]


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _register(client) -> dict:
    r = client.post("/v1/register", json={"platform": "ios", "app_version": "0.2.0"})
    assert r.status_code == 200, r.text
    return r.json()


def _set_subscription(device_id: str, status: str) -> None:
    from backend.store import get_store

    get_store().update_subscription(
        device_id=device_id,
        customer_id=None,
        subscription_id=f"sub_{device_id}",
        status=status,
        renews_at=None,
    )


def _set_coupon(device_id: str, expires_at: _dt.datetime) -> None:
    """Set a device-level coupon Pro expiry directly (mirrors how a redeemed
    coupon / durable founder grant lands on the users row)."""
    from backend.store import get_store

    iso = expires_at.astimezone(_dt.timezone.utc).isoformat(timespec="seconds")
    get_store()._conn.execute(
        "UPDATE users SET coupon_pro_expires_at = ? WHERE device_id = ?",
        (iso, device_id),
    )


def _analyze(client, token: str, text: str = "Per my last message, please respond."):
    return client.post("/api/analyze", headers=_auth(token), json={"text": text})


def _variant(client, token: str, axis: str, text: str = "hi there"):
    body = {"text": text, "axis": axis}
    if axis == "custom":
        body["custom_prompt"] = "make it sound calmer"
    return client.post("/api/analyze/variant", headers=_auth(token), json=body)


def _assert_entitlement_denied(r) -> None:
    """A distinct honest 402 — never overloaded onto the IP-rate-limit 429."""
    assert r.status_code == 402, r.text
    err = r.json()["error"]
    assert err["code"] == 402
    assert err["reason"] == "entitlement_required"
    # Must not masquerade as a rate/daily message.
    blob = str(err).lower()
    assert "daily" not in blob
    assert "too many requests" not in blob


# ---------------------------------------------------------------------------
# Fail-closed matrix: fresh / canceled / expired-sub / expired-coupon
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "make_state",
    [
        pytest.param(lambda dev: None, id="fresh_registered_no_entitlement"),
        pytest.param(lambda dev: _set_subscription(dev, "canceled"), id="canceled"),
        pytest.param(lambda dev: _set_subscription(dev, "expired"), id="expired_subscription"),
        pytest.param(
            lambda dev: _set_coupon(dev, _dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(days=1)),
            id="expired_coupon",
        ),
    ],
)
def test_non_entitled_fails_closed_on_analyze(client, make_state):
    reg = _register(client)
    make_state(reg["device_id"])
    _assert_entitlement_denied(_analyze(client, reg["api_token"]))


@pytest.mark.parametrize(
    "make_state",
    [
        pytest.param(lambda dev: None, id="fresh_registered_no_entitlement"),
        pytest.param(lambda dev: _set_subscription(dev, "canceled"), id="canceled"),
        pytest.param(lambda dev: _set_subscription(dev, "expired"), id="expired_subscription"),
        pytest.param(
            lambda dev: _set_coupon(dev, _dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(days=1)),
            id="expired_coupon",
        ),
    ],
)
def test_non_entitled_fails_closed_on_variant_every_axis(client, make_state):
    reg = _register(client)
    make_state(reg["device_id"])
    for axis in ALL_VARIANT_AXES:
        r = _variant(client, reg["api_token"], axis)
        _assert_entitlement_denied(r)


# ---------------------------------------------------------------------------
# Gate fires BEFORE any provider invocation (both endpoints)
# ---------------------------------------------------------------------------


def test_gate_precedes_provider_call_on_analyze(client, monkeypatch):
    from backend import server

    def _explode(*_a, **_k):
        raise AssertionError("provider invoked despite failed entitlement gate")

    monkeypatch.setattr(server, "mock_analyze", _explode)
    reg = _register(client)  # not entitled
    _assert_entitlement_denied(_analyze(client, reg["api_token"]))


def test_gate_precedes_provider_call_on_variant(client, monkeypatch):
    from backend import server

    async def _explode(*_a, **_k):
        raise AssertionError("provider invoked despite failed entitlement gate")

    # The variant endpoint's single provider entry point.
    monkeypatch.setattr(server, "invoke_single_variant", _explode)
    reg = _register(client)  # not entitled
    for axis in ALL_VARIANT_AXES:
        _assert_entitlement_denied(_variant(client, reg["api_token"], axis))


# ---------------------------------------------------------------------------
# No FREE_DAILY_LIMIT env value can reopen access
# ---------------------------------------------------------------------------


def test_free_daily_limit_env_cannot_restore_access(client, monkeypatch):
    monkeypatch.setenv("FREE_DAILY_LIMIT", "100000")
    reg = _register(client)
    _assert_entitlement_denied(_analyze(client, reg["api_token"]))
    for axis in ALL_VARIANT_AXES:
        _assert_entitlement_denied(_variant(client, reg["api_token"], axis))


# ---------------------------------------------------------------------------
# Entitlement denial precedes / != the per-IP 429 (never 429 for non-entitled)
# ---------------------------------------------------------------------------


def test_entitlement_denial_never_surfaces_as_ip_rate_429(client):
    """25 rapid requests from one IP on a non-entitled device: EVERY response is
    the honest 402 and NONE is the IP-rate 429 (the gate runs first, so a
    non-entitled caller never even touches the per-IP window)."""
    reg = _register(client)
    codes = set()
    for _ in range(25):
        codes.add(_analyze(client, reg["api_token"]).status_code)
        codes.add(_variant(client, reg["api_token"], "clearer").status_code)
    assert codes == {402}, codes


# ---------------------------------------------------------------------------
# Entitled controls PASS: active / trialing / durable founder (both endpoints)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "make_state",
    [
        pytest.param(lambda dev: _set_subscription(dev, "active"), id="active_paid"),
        pytest.param(lambda dev: _set_subscription(dev, "trialing"), id="active_trial"),
        pytest.param(
            # Durable founder grant = far-future coupon expiry (contract §6).
            lambda dev: _set_coupon(dev, _dt.datetime.now(_dt.timezone.utc) + _dt.timedelta(days=3650)),
            id="durable_founder_coupon",
        ),
    ],
)
def test_entitled_controls_pass_on_analyze(client, make_state):
    reg = _register(client)
    make_state(reg["device_id"])
    r = _analyze(client, reg["api_token"])
    assert r.status_code == 200, r.text
    assert r.json()["daily_limit"] == -1  # unlimited, never a free-tier number


@pytest.mark.parametrize(
    "make_state",
    [
        pytest.param(lambda dev: _set_subscription(dev, "active"), id="active_paid"),
        pytest.param(lambda dev: _set_subscription(dev, "trialing"), id="active_trial"),
        pytest.param(
            lambda dev: _set_coupon(dev, _dt.datetime.now(_dt.timezone.utc) + _dt.timedelta(days=3650)),
            id="durable_founder_coupon",
        ),
    ],
)
def test_entitled_controls_pass_on_variant_every_axis(client, make_state):
    reg = _register(client)
    make_state(reg["device_id"])
    for axis in ALL_VARIANT_AXES:
        r = _variant(client, reg["api_token"], axis)
        # Entitled => the endpoint runs (HTTP 200 strict envelope), never 402.
        assert r.status_code == 200, f"axis {axis}: {r.text}"
        assert r.json()["status"] in ("ok", "blocked")


# ---------------------------------------------------------------------------
# past_due is the documented auto-renew GRACE window (still entitled)
# ---------------------------------------------------------------------------


def test_past_due_grace_still_entitled(client):
    reg = _register(client)
    _set_subscription(reg["device_id"], "past_due")
    assert _analyze(client, reg["api_token"]).status_code == 200
    assert _variant(client, reg["api_token"], "safer").status_code == 200


# ---------------------------------------------------------------------------
# Router coverage: every rewrite route is wired to the ONE shared gate
# ---------------------------------------------------------------------------


def test_every_rewrite_route_calls_entitlement_gate():
    """Both authenticated rewrite handlers must call the single shared gate.
    Guards against a future rewrite route silently bypassing entitlement."""
    from backend import server

    for handler in (server.api_analyze, server.api_analyze_variant):
        src = inspect.getsource(handler)
        assert "_require_rewrite_entitlement(user)" in src, (
            f"{handler.__name__} does not call the shared entitlement gate"
        )
