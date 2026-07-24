"""Hostile tests for the shared server-authoritative rewrite entitlement gate.

Binding contract: consumer rewrites are unlimited ONLY during an active 14-day
trial or paid subscription (or a durable founder grant). There is NO free daily
tier. Expired / canceled / non-entitled callers fail closed. Registration and
sign-in are entitlement PRINCIPALS, not grants.

These tests prove, on EVERY provider-invoking rewrite route (``/api/analyze``,
``/api/analyze/variant``, and the back-compat ``/v1/analyze`` passthrough) and
across EVERY variant axis, that:
  * an anonymous (no-token) caller is rejected (401) before any provider call;
  * a fresh registered (never-entitled) device fails closed;
  * a canceled subscription fails closed;
  * an expired subscription and an expired coupon fail closed;
  * the denial is a DISTINCT honest 402 — never the IP-rate-limit 429;
  * the gate fires BEFORE any provider invocation (provider stubbed to explode);
  * no ``FREE_DAILY_LIMIT`` env value can reopen access;
  * active / trialing / durable-founder controls PASS;
  * every CONSUMER provider-invoking rewrite route is wired to the one shared
    gate — guarded BOTH by an explicit enumeration (incl. ``v1_analyze``) AND by
    a dynamic route scan, so a future consumer route cannot silently reopen the
    bypass. (The Slack B2B ``/tono`` command uses a separate signature principal
    and is explicitly carved out, not silently skipped — see the scan test.)

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


def _v1_analyze(client, token: str | None, text: str = "Per my last message, please respond.", **body_kw):
    """The back-compat ``/v1/analyze`` passthrough. ``token=None`` sends NO
    Authorization header (the anonymous-bypass case the contract forbids)."""
    body = {"draft": text}
    body.update(body_kw)
    headers = _auth(token) if token else None
    return client.post("/v1/analyze", headers=headers, json=body)


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


def _assert_unauthenticated(r) -> None:
    """A no-token caller is rejected at the auth layer (401) — it never reaches
    the entitlement gate, the per-IP window, or a provider."""
    assert r.status_code == 401, r.text


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
# ★ /v1/analyze — the back-compat passthrough is NOT an anonymous/free bypass ★
# It used to serve real rewrites to any caller with no token. It must now fail
# closed exactly like /api/analyze: 401 for anonymous, distinct 402 for a
# non-entitled principal, before any provider call. (Regression guard for the
# t_610d2ea9 QA NO-GO: V1_ANALYZE_UNAUTH_REWRITE_BYPASS.)
# ---------------------------------------------------------------------------


def test_v1_analyze_anonymous_is_rejected_before_provider(client, monkeypatch):
    """No Authorization header at all: rejected at the auth layer (401). The
    provider is stubbed to explode, proving no rewrite is ever produced for an
    anonymous caller — the exact bypass the contract forbids."""
    from backend import server

    def _explode(*_a, **_k):
        raise AssertionError("provider invoked for an anonymous /v1/analyze call")

    async def _explode_async(*_a, **_k):
        raise AssertionError("provider invoked for an anonymous /v1/analyze call")

    monkeypatch.setattr(server, "mock_analyze", _explode)
    monkeypatch.setattr(server, "mock_variant_analyze", _explode_async)
    monkeypatch.setattr(server, "anthropic_analyze", _explode_async)

    # Plain draft and the multi-variant path both stay closed to anonymous.
    _assert_unauthenticated(_v1_analyze(client, None))
    _assert_unauthenticated(
        _v1_analyze(client, None, optional_variants=["clearer", "affectionate"])
    )


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
def test_v1_analyze_non_entitled_fails_closed(client, make_state):
    """A real principal without an active entitlement gets the DISTINCT 402
    on /v1/analyze — same fail-closed shape as /api/analyze."""
    reg = _register(client)
    make_state(reg["device_id"])
    _assert_entitlement_denied(_v1_analyze(client, reg["api_token"]))
    # The multi-variant path is gated identically.
    _assert_entitlement_denied(
        _v1_analyze(client, reg["api_token"], optional_variants=["clearer"])
    )


def test_v1_analyze_gate_precedes_provider_call(client, monkeypatch):
    """Non-entitled principal: the gate fires BEFORE the provider dispatch, so
    a stubbed-to-explode provider is never reached (402, not an AssertionError)."""
    from backend import server

    def _explode(*_a, **_k):
        raise AssertionError("provider invoked despite failed entitlement gate")

    async def _explode_async(*_a, **_k):
        raise AssertionError("provider invoked despite failed entitlement gate")

    monkeypatch.setattr(server, "mock_analyze", _explode)
    monkeypatch.setattr(server, "mock_variant_analyze", _explode_async)
    monkeypatch.setattr(server, "anthropic_analyze", _explode_async)
    reg = _register(client)  # not entitled
    _assert_entitlement_denied(_v1_analyze(client, reg["api_token"]))
    _assert_entitlement_denied(
        _v1_analyze(client, reg["api_token"], optional_variants=["clearer"])
    )


def test_v1_analyze_free_daily_limit_env_cannot_restore_access(client, monkeypatch):
    """No FREE_DAILY_LIMIT value reopens the passthrough (the free tier is gone)."""
    monkeypatch.setenv("FREE_DAILY_LIMIT", "100000")
    reg = _register(client)
    _assert_entitlement_denied(_v1_analyze(client, reg["api_token"]))


def test_v1_analyze_entitlement_denial_never_surfaces_as_ip_rate_429(client):
    """25 rapid non-entitled /v1/analyze calls from one IP: EVERY response is the
    honest 402, NONE is the IP-rate 429 (the gate runs before the per-IP window)."""
    reg = _register(client)
    codes = {_v1_analyze(client, reg["api_token"]).status_code for _ in range(25)}
    assert codes == {402}, codes


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
def test_v1_analyze_entitled_controls_pass(client, make_state):
    """A principal WITH an active entitlement still gets real rewrites through
    the back-compat route (200 + the four default axis suggestions)."""
    reg = _register(client)
    make_state(reg["device_id"])
    r = _v1_analyze(client, reg["api_token"])
    assert r.status_code == 200, r.text
    axes = {s["axis"] for s in r.json()["suggestions"]}
    assert axes == {"warmer", "clearer", "funnier", "safer"}, axes


# ---------------------------------------------------------------------------
# Router coverage: EVERY provider-invoking rewrite route is wired to the ONE
# shared gate — explicit enumeration AND a dynamic scan.
# ---------------------------------------------------------------------------

# Provider entry points reachable from a route handler. If a handler's source
# mentions any of these, it can produce a rewrite and therefore MUST first call
# the shared entitlement gate.
_PROVIDER_CALL_TOKENS = (
    "anthropic_analyze(",
    "openai_analyze(",
    "mock_analyze(",
    "mock_variant_analyze(",
    "invoke_single_variant(",
)


def test_every_rewrite_route_calls_entitlement_gate():
    """Every authenticated rewrite handler — INCLUDING the back-compat
    ``v1_analyze`` passthrough — must call the single shared gate. Guards
    against a rewrite route silently bypassing entitlement (the t_610d2ea9
    NO-GO was exactly ``v1_analyze`` omitted from this enumeration)."""
    from backend import server

    for handler in (server.api_analyze, server.api_analyze_variant, server.v1_analyze):
        src = inspect.getsource(handler)
        assert "_require_rewrite_entitlement(user)" in src, (
            f"{handler.__name__} does not call the shared entitlement gate"
        )


# Provider-invoking routes NOT governed by the consumer device/account
# entitlement gate because they authenticate a DIFFERENT principal under a
# separate commercial model. Currently only the Slack ``/tono`` slash command
# (``/slack/command``): it is authenticated by Slack request signature (HMAC),
# rate-limited per Slack user, and belongs to the B2B seat track — it has no
# device-bearer ``CurrentUser`` principal that ``_require_rewrite_entitlement``
# could act on. This set is deliberately EXPLICIT (not a silent skip): a NEW
# ungated provider route that is not a consumer ``CurrentUser`` route will fail
# the test below until it is consciously classified here and reviewed, so no
# anonymous consumer rewrite path can silently reopen. The Slack route's own
# (separate) entitlement decision is a standing residual — see the bypass-fix
# receipt; it is intentionally out of scope for the consumer 14-day contract.
_NON_CONSUMER_PRINCIPAL_ROUTES = {"/slack/command"}


def test_no_provider_invoking_route_bypasses_entitlement_gate():
    """Dynamic completeness guard: scan EVERY registered route and require that
    any handler able to reach a provider on the CONSUMER principal also calls the
    shared gate. Stronger than the hardcoded list above — a NEW provider-invoking
    consumer route added later without the gate fails here, so the bypass cannot
    silently reopen. Non-consumer principals (Slack B2B) are carved out only via
    the explicit, documented allowlist above."""
    from backend import server
    from fastapi.routing import APIRoute

    discovered: dict[str, str] = {}
    offenders: list[str] = []
    for route in server.app.routes:
        if not isinstance(route, APIRoute):
            continue
        try:
            src = inspect.getsource(route.endpoint)
        except (OSError, TypeError):
            continue
        if not any(tok in src for tok in _PROVIDER_CALL_TOKENS):
            continue
        discovered[route.path] = route.endpoint.__name__
        gated = "_require_rewrite_entitlement(user)" in src
        if not gated and route.path not in _NON_CONSUMER_PRINCIPAL_ROUTES:
            offenders.append(f"{route.path} ({route.endpoint.__name__})")

    # The consumer rewrite routes MUST all be discovered (so the token list can
    # never go stale and silently cover nothing) and gated.
    assert {"/v1/analyze", "/api/analyze", "/api/analyze/variant"} <= set(discovered), (
        f"expected consumer rewrite routes not discovered by the scan: {discovered}"
    )
    assert not offenders, (
        "provider-invoking consumer routes missing the shared entitlement gate: "
        + ", ".join(offenders)
    )
    # The carve-out cannot rot: every acknowledged non-consumer route must still
    # be a real, discovered provider route.
    for path in _NON_CONSUMER_PRINCIPAL_ROUTES:
        assert path in discovered, (
            f"stale non-consumer carve-out: {path} is no longer a provider route"
        )
