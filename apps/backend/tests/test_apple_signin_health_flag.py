"""The public /health endpoint must report whether native Sign in with Apple
is configured — presence only, never the value.

This is the post-deploy canary for the exact failure this repair addresses: a
running process that predates APPLE_CLIENT_ID in its environment answers
/v1/auth/apple with 503 "Apple sign-in not configured". `apple_configured`
already existed but keys off the App Store receipt root CA
(TONO_APPLE_ROOT_CA_PEM) — a DIFFERENT gate — so it cannot confirm the sign-in
audience loaded. `apple_signin_configured` closes that gap without forging a
real Apple identity token, and without leaking the client id's value.
"""

from __future__ import annotations


def test_health_reports_apple_signin_presence(client, monkeypatch):
    monkeypatch.delenv("APPLE_CLIENT_ID", raising=False)
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["apple_signin_configured"] is False

    # Once the sign-in audience is present, the canary flips to True at request
    # time (the handler reads os.environ live), so a fresh deploy that finally
    # carries APPLE_CLIENT_ID is observable over plain HTTP.
    monkeypatch.setenv("APPLE_CLIENT_ID", "com.tonoit.app")
    r2 = client.get("/health")
    assert r2.status_code == 200
    assert r2.json()["apple_signin_configured"] is True


def test_health_never_leaks_apple_client_id_value(client, monkeypatch):
    """Presence is reported as a bool; the client id value never appears in the
    response body (it is a public bundle id, but /health stays value-free)."""
    monkeypatch.setenv("APPLE_CLIENT_ID", "com.tonoit.app")
    r = client.get("/health")
    assert r.status_code == 200
    assert "com.tonoit.app" not in r.text


def test_apple_signin_gate_is_distinct_from_receipt_ca(client, monkeypatch):
    """`apple_configured` (receipt root CA) and `apple_signin_configured`
    (sign-in audience) are independent axes: the receipt CA can be present while
    the sign-in audience is not — which is precisely the outage shape."""
    monkeypatch.setenv("TONO_APPLE_ROOT_CA_PEM", "-----BEGIN CERTIFICATE-----\nx\n-----END CERTIFICATE-----")
    monkeypatch.delenv("APPLE_CLIENT_ID", raising=False)
    body = client.get("/health").json()
    assert body["apple_configured"] is True
    assert body["apple_signin_configured"] is False
