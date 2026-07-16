#!/usr/bin/env python3
"""Tests for the rate limiter (post-Path-A: source's simpler IP-level limiter).

Run with: pytest tests/test_rate_limit.py
or standalone: python3 tests/test_rate_limit.py

Path A replaces the pre-Path-A per-endpoint-scope limiter (analyze_pub,
register, coupon, auth, otp_lockout — implemented in backend.rate_limit.py
which no longer exists) with a single per-IP sliding-window cap on
/v1/analyze (see backend.server._check_ip_rate, _IP_RATE_LIMIT, default 20).

These tests verify what the new limiter ACTUALLY does. The per-endpoint
scoping coverage that was here before Path A (register/auth/coupon caps,
429-shape with X-RateLimit-Limit header) is intentionally dropped — that
architecture belongs to the pre-Path-A email-identity world. If we want
back per-endpoint scopes, that's a separate ticket (separate scope).
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
    monkeypatch.setenv("TONO_ADMIN_SECRET", "test-secret")
    # Source's limiter: IP_RATE_LIMIT_PER_MIN defaults to 20. Set to 3 for tests.
    monkeypatch.setenv("IP_RATE_LIMIT_PER_MIN", "3")

    # Purge cached modules so the new env values take effect
    for n in list(sys.modules):
        if n.startswith("backend."):
            del sys.modules[n]

    import backend.server as srv
    from fastapi.testclient import TestClient

    # Reset the in-server IP limiter windows so each test starts fresh.
    srv._ip_windows.clear()

    yield srv, TestClient


def test_v1_analyze_is_ip_rate_limited(rate_limit_setup):
    """The LLM passthrough was completely unlimited before; Path A's source
    limiter caps it per-IP. Verify the cap fires at the configured limit."""
    srv, TestClient = rate_limit_setup
    with TestClient(srv.app) as client:
        body = {"draft": "Hello there"}
        # 3 calls = at limit (IP_RATE_LIMIT_PER_MIN=3 in fixture)
        for i in range(3):
            r = client.post("/v1/analyze", json=body)
            assert r.status_code == 200, f"call {i+1} got {r.status_code}: {r.text}"
        # 4th = 429
        r = client.post("/v1/analyze", json=body)
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
        body = {"draft": "Hello there"}
        # Saturate IP-A via XFF header
        for _ in range(3):
            r = client.post(
                "/v1/analyze", json=body,
                headers={"X-Forwarded-For": "10.0.0.1"},
            )
            assert r.status_code == 200, f"IP-A call got {r.status_code}"
        r = client.post(
            "/v1/analyze", json=body,
            headers={"X-Forwarded-For": "10.0.0.1"},
        )
        assert r.status_code == 429, "IP-A should be rate-limited"
        # IP-B is fresh (different XFF) — must NOT be rate-limited
        r = client.post(
            "/v1/analyze", json=body,
            headers={"X-Forwarded-For": "10.0.0.2"},
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