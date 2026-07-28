"""Build-117 [g1] Apple App Store readiness probe (non-secret observability).

Mirrors the Google Play readiness contract: a non-secret ``GET`` probe that
lets an operator/monitor see which Apple credentials are wired without ever
exposing a secret value. The full /v1/app-store/* contract still fails closed
(503) when the PEM is missing — this probe merely makes the configuration
shape observable so the operator can tell at a glance whether the deploy is
the one breaking the live iOS paywall.

Configuration model:
  TONO_APPLE_ROOT_CA_PEM       PEM (inline or file path) of the trusted Apple root
  TONO_APPLE_APP_APPLE_ID      the app's numeric Apple id (required for Production)
  TONO_APPLE_ISSUER_ID         App Store Connect API issuer id
  TONO_APPLE_KEY_ID            App Store Connect API key id
  TONO_APPLE_PRIVATE_KEY       App Store Connect API private key (PEM)
"""

from __future__ import annotations

import json
import os

import pytest


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def clear_apple_env(monkeypatch):
    """Strip every Apple env var so each test starts from a clean baseline."""
    for key in (
        "TONO_APPLE_ROOT_CA_PEM",
        "TONO_APPLE_APP_APPLE_ID",
        "TONO_APPLE_ISSUER_ID",
        "TONO_APPLE_KEY_ID",
        "TONO_APPLE_PRIVATE_KEY",
        "TONO_APPLE_BUNDLE_ID",
        "TONO_APPLE_ENVIRONMENTS",
        "TONO_APPLE_PRODUCT_IDS",
    ):
        monkeypatch.delenv(key, raising=False)


# ---------------------------------------------------------------------------
# 1. Bare baseline: nothing configured -> not ready, no secrets leak.
# ---------------------------------------------------------------------------


def test_readiness_reports_unconfigured_when_no_apple_env(client, clear_apple_env):
    r = client.get("/v1/app-store/readiness")
    assert r.status_code == 200
    body = r.json()
    assert body["provider"] == "app_store"
    assert body["verification_configured"] is False
    assert body["production_verification_enabled"] is False
    assert body["sandbox_verification_enabled"] is False
    assert body["provider_api_configured"] is False
    assert body["set_token_sender_configured"] is False
    assert body["app_apple_id_configured"] is False
    assert body["ready"] is False

    # No secret material leaks even with no PEM at all.
    blob = json.dumps(body)
    for forbidden in (
        "BEGIN",
        "PRIVATE",
        "PRIVATE KEY",
        "issuer",
        "key_id",
    ):
        assert forbidden not in blob, f"unexpected {forbidden!r} in readiness body"


def test_readiness_exposes_non_secret_identifiers(client, clear_apple_env):
    r = client.get("/v1/app-store/readiness")
    body = r.json()
    # Already-public identifiers that operators need to see configuration drift.
    assert isinstance(body["bundle_id"], str) and body["bundle_id"]
    assert isinstance(body["product_ids"], list) and body["product_ids"]
    assert isinstance(body["environments"], list) and body["environments"]
    assert isinstance(body["catalog_version"], str) and body["catalog_version"]


# ---------------------------------------------------------------------------
# 2. PEM-only configuration -> verification_configured=true, sandbox enabled,
#    production disabled (no app Apple id), not ready because provider API
#    is missing AND no environments were left to use without it (we
#    deliberately cover the Sandbox-only-ready path in test 5 below).
# ---------------------------------------------------------------------------


def test_readiness_pem_only_enables_sandbox_not_production(client, clear_apple_env, monkeypatch):
    monkeypatch.setenv("TONO_APPLE_ROOT_CA_PEM", "-----BEGIN CERTIFICATE-----\nMIIBfake...\n-----END CERTIFICATE-----\n")

    r = client.get("/v1/app-store/readiness")
    assert r.status_code == 200
    body = r.json()
    assert body["verification_configured"] is True
    assert body["sandbox_verification_enabled"] is True
    assert body["production_verification_enabled"] is False
    assert body["app_apple_id_configured"] is False
    # The PEM bytes MUST NOT appear in the response.
    assert "BEGIN CERTIFICATE" not in json.dumps(body)


def test_readiness_pem_only_with_provider_api_is_ready(client, clear_apple_env, monkeypatch):
    """PEM + provider API is the production end-to-end path. Sandbox + provider
    API also counts as ready because Set-App-Account-Token can be sent for
    either environment."""
    monkeypatch.setenv("TONO_APPLE_ROOT_CA_PEM", "-----BEGIN CERTIFICATE-----\nMIIBfake...\n-----END CERTIFICATE-----\n")
    monkeypatch.setenv("TONO_APPLE_ISSUER_ID", "57246542-4C92-4DDF-9F45-F73FF46B7340")
    monkeypatch.setenv("TONO_APPLE_KEY_ID", "ABCDE12345")
    monkeypatch.setenv("TONO_APPLE_PRIVATE_KEY", "-----BEGIN PRIVATE KEY-----\nfake\n-----END PRIVATE KEY-----\n")

    r = client.get("/v1/app-store/readiness")
    body = r.json()
    assert body["verification_configured"] is True
    assert body["sandbox_verification_enabled"] is True
    assert body["provider_api_configured"] is True
    assert body["set_token_sender_configured"] is True
    assert body["ready"] is True
    # The private key MUST NOT appear in the response.
    assert "PRIVATE KEY" not in json.dumps(body)
    # The issuer id is non-secret but the readiness contract only reports
    # booleans; this asserts we kept that discipline.
    assert "57246542" not in json.dumps(body)


# ---------------------------------------------------------------------------
# 3. PEM + app Apple id -> both Production and Sandbox enabled.
# ---------------------------------------------------------------------------


def test_readiness_pem_plus_app_apple_id_enables_production(client, clear_apple_env, monkeypatch):
    monkeypatch.setenv("TONO_APPLE_ROOT_CA_PEM", "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n")
    monkeypatch.setenv("TONO_APPLE_APP_APPLE_ID", "6448311111")

    r = client.get("/v1/app-store/readiness")
    body = r.json()
    assert body["verification_configured"] is True
    assert body["app_apple_id_configured"] is True
    assert body["production_verification_enabled"] is True
    assert body["sandbox_verification_enabled"] is True


# ---------------------------------------------------------------------------
# 4. Production-only environments with no app Apple id -> the Production
#    verifier cannot be built, so neither environment is enabled; readiness
#    surfaces the misconfiguration rather than pretending it works.
# ---------------------------------------------------------------------------


def test_readiness_production_only_without_app_apple_id_disables_both(
    client, clear_apple_env, monkeypatch
):
    monkeypatch.setenv("TONO_APPLE_ROOT_CA_PEM", "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n")
    monkeypatch.setenv("TONO_APPLE_ENVIRONMENTS", "Production")

    r = client.get("/v1/app-store/readiness")
    body = r.json()
    assert body["verification_configured"] is True
    assert body["production_verification_enabled"] is False
    assert body["sandbox_verification_enabled"] is False
    assert body["ready"] is False


# ---------------------------------------------------------------------------
# 5. Sandbox-only configuration is enough to run a TestFlight round-trip
#    (the SUBSCRIBED grant is visible via the sandbox verifier alone) —
#    readiness reports True even without the provider API credentials.
# ---------------------------------------------------------------------------


def test_readiness_sandbox_only_is_ready_for_testflight(client, clear_apple_env, monkeypatch):
    monkeypatch.setenv("TONO_APPLE_ROOT_CA_PEM", "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n")
    monkeypatch.setenv("TONO_APPLE_ENVIRONMENTS", "Sandbox")

    r = client.get("/v1/app-store/readiness")
    body = r.json()
    assert body["verification_configured"] is True
    assert body["sandbox_verification_enabled"] is True
    assert body["production_verification_enabled"] is False
    assert body["provider_api_configured"] is False
    # The Sandbox-only path is what powers /v1/app-store/notifications on a
    # TestFlight build — readiness reflects that honestly.
    assert body["ready"] is True


# ---------------------------------------------------------------------------
# 6. Partial provider API credentials are not a configuration. The
#    setter needs ALL three (issuer id, key id, private key) — half-wired
#    must report False rather than fail closed inside the request path.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "present,absent",
    [
        ("TONO_APPLE_ISSUER_ID", "TONO_APPLE_KEY_ID"),
        ("TONO_APPLE_ISSUER_ID", "TONO_APPLE_PRIVATE_KEY"),
        ("TONO_APPLE_KEY_ID", "TONO_APPLE_ISSUER_ID"),
    ],
)
def test_readiness_partial_provider_api_is_not_configured(
    client, clear_apple_env, monkeypatch, present, absent
):
    monkeypatch.setenv("TONO_APPLE_ROOT_CA_PEM", "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n")
    monkeypatch.setenv(present, "configured-not-read")
    # `absent` stays unset.

    r = client.get("/v1/app-store/readiness")
    body = r.json()
    assert body["verification_configured"] is True
    assert body["provider_api_configured"] is False
    assert body["set_token_sender_configured"] is False


# ---------------------------------------------------------------------------
# 7. The full wire-up: everything is configured -> ready=True, every boolean
#    flipped, no secret values leak through the response.
# ---------------------------------------------------------------------------


def test_readiness_full_wire_up_is_ready_and_no_secrets_leak(
    client, clear_apple_env, monkeypatch
):
    monkeypatch.setenv(
        "TONO_APPLE_ROOT_CA_PEM",
        "-----BEGIN CERTIFICATE-----\nMIIBmock\n-----END CERTIFICATE-----\n",
    )
    monkeypatch.setenv("TONO_APPLE_APP_APPLE_ID", "6448311111")
    monkeypatch.setenv("TONO_APPLE_ISSUER_ID", "57246542-4C92-4DDF-9F45-F73FF46B7340")
    monkeypatch.setenv("TONO_APPLE_KEY_ID", "ABCDE12345")
    monkeypatch.setenv(
        "TONO_APPLE_PRIVATE_KEY",
        "-----BEGIN PRIVATE KEY-----\nMOCKKEY\n-----END PRIVATE KEY-----\n",
    )

    r = client.get("/v1/app-store/readiness")
    body = r.json()
    assert body["provider"] == "app_store"
    assert body["verification_configured"] is True
    assert body["production_verification_enabled"] is True
    assert body["sandbox_verification_enabled"] is True
    assert body["provider_api_configured"] is True
    assert body["set_token_sender_configured"] is True
    assert body["app_apple_id_configured"] is True
    assert body["ready"] is True

    blob = json.dumps(body)
    # The secret shapes NEVER appear in the response — operators and monitors
    # must be able to share the probe output with confidence.
    for forbidden in (
        "BEGIN CERTIFICATE",
        "BEGIN PRIVATE KEY",
        "MIIBmock",
        "MOCKKEY",
        "57246542",
        "ABCDE12345",
    ):
        assert forbidden not in blob, f"{forbidden!r} leaked in readiness body"


# ---------------------------------------------------------------------------
# 8. /v1/app-store/subscription still fails closed (503) when the verifier
#    dependency is unconfigured — the readiness probe is observability, NOT
#    a bypass for the fail-closed contract.
# ---------------------------------------------------------------------------


def test_readiness_does_not_relax_subscription_fail_closed(client, clear_apple_env):
    # Anonymous registration -> /v1/me upgrade so the request is well-formed.
    reg = client.post("/v1/register", json={"platform": "ios"}).json()
    headers = {"Authorization": f"Bearer {reg['api_token']}"}
    r = client.post(
        "/v1/app-store/subscription",
        json={"signed_transaction_info": "fake.jws.token"},
        headers=headers,
    )
    # The dependency is unconfigured (no PEM) -> 503, not a synthetic 200.
    assert r.status_code == 503
    # /v1/me projection still says anonymous, not Pro — readiness did not
    # influence entitlement state.
    me = client.get("/v1/me", headers=headers).json()
    assert me["is_pro"] is False
    assert me["plan"] == "free"


# ---------------------------------------------------------------------------
# 9. Endpoint never requires auth — the readiness probe is a non-secret
#    public observability surface, parallel to /v1/google-play/readiness and
#    /health. An unauthenticated curl can answer the operator question.
# ---------------------------------------------------------------------------


def test_readiness_is_public_unauthenticated(client, clear_apple_env):
    r = client.get("/v1/app-store/readiness")
    assert r.status_code == 200
    assert r.json()["provider"] == "app_store"