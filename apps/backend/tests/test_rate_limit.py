#!/usr/bin/env python3
"""Tests for the rate limiter (post-Path-A: source's simpler IP-level limiter).

Run with: pytest tests/test_rate_limit.py
or standalone: python3 tests/test_rate_limit.py

The rewrite routes are capped per-IP at IP_RATE_LIMIT_PER_MIN (default 20)
over a 60s sliding window, via backend.server._check_ip_rate.

That cap is now served by the SHARED limiter in backend.rate_limit (scope
"analyze") — the same one /v1/register uses. server.py previously carried a
second, parallel sliding-window implementation whose bucket dict was never
evicted; because the bucket key comes from the client-supplied
X-Forwarded-For header, that dict grew without bound. (An earlier revision of
this docstring claimed backend.rate_limit "no longer exists" — it did exist and
was live on /v1/register the whole time; the two limiters had simply drifted.)

These tests verify what the limiter ACTUALLY does, plus the eviction that
keeps bucket memory bounded.
"""

from __future__ import annotations

import importlib
import os
import sys

import pytest


# Env values are read BEFORE the test module's body runs, so we can't
# import backend.server at module level — the Store singleton would
# capture the default TONO_DB_PATH. Import lazily inside a fixture that
# runs AFTER env is set.


@pytest.fixture
def rate_limit_setup(monkeypatch, tmp_path):
    """Configure env BEFORE importing backend.server, then import fresh."""
    monkeypatch.setenv("TONO_DB_PATH", str(tmp_path / "tono_rate.db"))
    monkeypatch.setenv("TONO_PROVIDER", "mock")
    monkeypatch.setenv("FREE_DAILY_LIMIT", "1000")
    monkeypatch.setenv("TONO_ADMIN_SECRET", "test-secret")
    # Source's limiter: IP_RATE_LIMIT_PER_MIN defaults to 20. Set to 3 for tests.
    monkeypatch.setenv("IP_RATE_LIMIT_PER_MIN", "3")

    # Purge cached modules so the new env values take effect
    for n in list(sys.modules):
        if n.startswith("backend."):
            del sys.modules[n]

    import backend.server as srv
    from fastapi.testclient import TestClient

    # Reset the shared limiter's buckets so each test starts fresh.
    import backend.rate_limit as _rl
    _rl._ip_buckets.clear()
    _rl._keyed_buckets.clear()
    _rl._last_eviction = 0.0

    yield srv, TestClient


def _register_entitled(client):
    """Register a device and grant it an active subscription. The per-IP cap on
    /v1/analyze runs AFTER the shared entitlement gate, so an entitled principal
    is required to reach (and therefore test) the limiter at all."""
    reg = client.post("/v1/register", json={"platform": "ios"})
    assert reg.status_code == 200, reg.text
    reg = reg.json()
    from backend.store import get_store

    get_store().update_subscription(
        device_id=reg["device_id"],
        customer_id=None,
        subscription_id=f"sub_{reg['device_id']}",
        status="active",
        renews_at=None,
    )
    return reg


def test_v1_analyze_is_ip_rate_limited(rate_limit_setup):
    """The LLM passthrough is entitlement-gated first, then capped per-IP. An
    entitled principal passes the gate; verify the IP cap fires at the limit."""
    srv, TestClient = rate_limit_setup
    with TestClient(srv.app) as client:
        auth = {"Authorization": f"Bearer {_register_entitled(client)['api_token']}"}
        body = {"draft": "Hello there"}
        # 3 calls = at limit (IP_RATE_LIMIT_PER_MIN=3 in fixture)
        for i in range(3):
            r = client.post("/v1/analyze", json=body, headers=auth)
            assert r.status_code == 200, f"call {i+1} got {r.status_code}: {r.text}"
        # 4th = 429
        r = client.post("/v1/analyze", json=body, headers=auth)
        assert r.status_code == 429, r.text
        # Source limiter shape: detail string + Retry-After header (lowercase OK)
        assert "retry-after" in {k.lower() for k in r.headers.keys()}


def test_ip_rate_limit_is_per_ip(rate_limit_setup):
    """Saturating /v1/analyze on one IP must NOT block a different IP.
    Source's limiter keys on client_ip (X-Forwarded-For first, then
    request.client.host), so distinct XFF headers simulate distinct IPs.
    """
    srv, TestClient = rate_limit_setup
    with TestClient(srv.app) as client:
        auth = {"Authorization": f"Bearer {_register_entitled(client)['api_token']}"}
        body = {"draft": "Hello there"}
        # Saturate IP-A via XFF header (same entitled principal, distinct IPs)
        for _ in range(3):
            r = client.post(
                "/v1/analyze", json=body,
                headers={**auth, "X-Forwarded-For": "10.0.0.1"},
            )
            assert r.status_code == 200, f"IP-A call got {r.status_code}"
        r = client.post(
            "/v1/analyze", json=body,
            headers={**auth, "X-Forwarded-For": "10.0.0.1"},
        )
        assert r.status_code == 429, "IP-A should be rate-limited"
        # IP-B is fresh (different XFF) — must NOT be rate-limited
        r = client.post(
            "/v1/analyze", json=body,
            headers={**auth, "X-Forwarded-For": "10.0.0.2"},
        )
        assert r.status_code == 200, f"IP-B should not be blocked: {r.status_code}"


def test_register_is_not_rate_limited(rate_limit_setup):
    """Source's architecture has no register-specific rate limit (that was
    pre-Path-A scope='register'). This test documents that intent — if a
    future ticket adds one, this test will fail and force the change to be
    conscious."""
    srv, TestClient = rate_limit_setup
    with TestClient(srv.app) as client:
        # 10 sequential registers — should all succeed (no register scope exists)
        for i in range(10):
            r = client.post("/v1/register", json={"platform": "ios"})
            assert r.status_code == 200, f"call {i+1} got {r.status_code}"


def test_health_and_whoami_not_rate_limited(rate_limit_setup):
    """Public endpoints must never be rate-limited (monitoring scrapers
    hit /health every 30s; whitelabel apps hit /v1/whoami)."""
    srv, TestClient = rate_limit_setup
    with TestClient(srv.app) as client:
        for _ in range(50):
            r = client.get("/health")
            assert r.status_code == 200
            r = client.get("/v1/whoami")
            assert r.status_code == 200

# ---------------------------------------------------------------------------
# Bucket memory is bounded (the defect the consolidation closed)
# ---------------------------------------------------------------------------


def test_rewrite_cap_uses_the_shared_limiter_not_a_private_window():
    """server.py must not carry a second sliding-window implementation.

    The parallel copy it used to hold never evicted its buckets, so every
    distinct X-Forwarded-For value a caller invented was retained for the life
    of the process.
    """
    import backend.rate_limit as rl
    import backend.server as srv

    assert not hasattr(srv, "_ip_windows"), (
        "server.py has reintroduced a private, non-evicting rate-limit window dict"
    )
    rl._ip_buckets.clear()
    rl._last_eviction = 0.0
    assert srv._check_ip_rate("203.0.113.7") is True
    assert (srv._IP_RATE_SCOPE, "203.0.113.7") in rl._ip_buckets, (
        "the rewrite cap must record into the shared limiter's buckets"
    )


def test_spoofed_forwarded_for_buckets_are_evicted(monkeypatch):
    """Buckets for keys that have gone quiet are dropped, so a caller rotating
    X-Forwarded-For cannot grow the dict without bound."""
    import backend.rate_limit as rl
    import backend.server as srv

    rl._ip_buckets.clear()
    rl._keyed_buckets.clear()
    rl._last_eviction = 0.0

    for i in range(500):
        srv._check_ip_rate(f"198.51.100.{i // 256}.{i % 256}")
    assert len(rl._ip_buckets) == 500

    # Jump past the eviction TTL: the next call sweeps every stale bucket and
    # leaves only the live one.
    real_time = rl.time.time
    monkeypatch.setattr(
        rl.time, "time", lambda: real_time() + rl._EVICTION_TTL_SEC + 1
    )
    srv._check_ip_rate("203.0.113.99")
    assert len(rl._ip_buckets) == 1, (
        f"stale buckets were not evicted: {len(rl._ip_buckets)} remain"
    )


def test_rewrite_cap_limit_is_still_read_at_call_time():
    """`_IP_RATE_LIMIT` stays a module attribute read per call, so tests and
    ops can raise it without reimporting the module."""
    import backend.rate_limit as rl
    import backend.server as srv

    rl._ip_buckets.clear()
    rl._last_eviction = 0.0
    original = srv._IP_RATE_LIMIT
    try:
        srv._IP_RATE_LIMIT = 2
        assert srv._check_ip_rate("192.0.2.5") is True
        assert srv._check_ip_rate("192.0.2.5") is True
        assert srv._check_ip_rate("192.0.2.5") is False, "3rd call must exceed a cap of 2"
    finally:
        srv._IP_RATE_LIMIT = original
