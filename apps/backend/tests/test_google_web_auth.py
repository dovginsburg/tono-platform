"""Tests for the DIRECT Google web sign-in slice (/v1/auth/google/web).

The website owns the Google OAuth boundary (start + callback under Tono's own
Web client id, consent screen = "Tono", callback on tonoit.com) instead of
routing Google through Supabase — whose consent screen showed the shared
project. Its callback forwards the verified Google id token here; we
INDEPENDENTLY re-verify it (web client-id audience) and converge the Google
``sub`` onto the ONE canonical account — the SAME ``google_sub`` the native app
resolves.

Two layers, mirroring test_apple_web_auth.py:
  - The web-audience Google verifier is exercised for REAL against a locally
    generated RSA key (valid / wrong-audience / wrong-issuer / expired /
    bad-signature / unconfigured), with the shared Google JWKS cache stubbed so
    no network is needed.
  - Endpoint behavior uses app.dependency_overrides on the verifier.
"""

from __future__ import annotations

import asyncio
import datetime as dt
import json

import jwt
import pytest


GOOGLE_ISSUER = "https://accounts.google.com"
WEB_CLIENT_ID = "417785080360-tonoweb.apps.googleusercontent.com"
NATIVE_CLIENT_ID = "417785080360-tononative.apps.googleusercontent.com"


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _run(coro):
    return asyncio.run(coro)


_KID = "test-google-web-kid"


def _rsa_key():
    from cryptography.hazmat.primitives.asymmetric import rsa

    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _jwk_for(private_key) -> dict:
    pub_jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(private_key.public_key()))
    pub_jwk["kid"] = _KID
    return pub_jwk


def _sign(private_key, **overrides) -> str:
    now = dt.datetime.now(dt.timezone.utc)
    payload = {
        "iss": GOOGLE_ISSUER,
        "aud": WEB_CLIENT_ID,
        "sub": "google-web-sub-1",
        "iat": now,
        "exp": now + dt.timedelta(hours=1),
        "email": "person@example.com",
        "email_verified": True,
    }
    payload.update(overrides)
    return jwt.encode(payload, private_key, algorithm="RS256", headers={"kid": _KID})


def _stub_jwks(monkeypatch, jwk: dict) -> None:
    import backend.social_auth as social_auth

    async def fake_get_key(_kid):
        return jwk

    monkeypatch.setattr(social_auth._google_jwks, "get_key", fake_get_key)


def test_web_verifier_accepts_a_valid_web_audience_token(monkeypatch):
    monkeypatch.setenv("GOOGLE_WEB_CLIENT_ID", WEB_CLIENT_ID)
    import backend.social_auth as social_auth

    key = _rsa_key()
    _stub_jwks(monkeypatch, _jwk_for(key))

    claims = _run(social_auth.verify_google_web_id_token(_sign(key, nonce="n1")))
    assert claims.sub == "google-web-sub-1"
    assert claims.email == "person@example.com"
    assert claims.email_verified is True
    assert claims.nonce == "n1"


def test_web_verifier_rejects_the_native_audience(monkeypatch):
    monkeypatch.setenv("GOOGLE_WEB_CLIENT_ID", WEB_CLIENT_ID)
    import backend.social_auth as social_auth
    from fastapi import HTTPException

    key = _rsa_key()
    _stub_jwks(monkeypatch, _jwk_for(key))

    tok = _sign(key, aud=NATIVE_CLIENT_ID)
    with pytest.raises(HTTPException) as ei:
        _run(social_auth.verify_google_web_id_token(tok))
    assert ei.value.status_code == 401


def test_web_verifier_rejects_wrong_issuer(monkeypatch):
    monkeypatch.setenv("GOOGLE_WEB_CLIENT_ID", WEB_CLIENT_ID)
    import backend.social_auth as social_auth
    from fastapi import HTTPException

    key = _rsa_key()
    _stub_jwks(monkeypatch, _jwk_for(key))

    tok = _sign(key, iss="https://evil.example.com")
    with pytest.raises(HTTPException) as ei:
        _run(social_auth.verify_google_web_id_token(tok))
    assert ei.value.status_code == 401


def test_web_verifier_rejects_expired(monkeypatch):
    monkeypatch.setenv("GOOGLE_WEB_CLIENT_ID", WEB_CLIENT_ID)
    import backend.social_auth as social_auth
    from fastapi import HTTPException

    key = _rsa_key()
    _stub_jwks(monkeypatch, _jwk_for(key))

    past = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=2)
    tok = _sign(key, exp=past, iat=past - dt.timedelta(hours=1))
    with pytest.raises(HTTPException) as ei:
        _run(social_auth.verify_google_web_id_token(tok))
    assert ei.value.status_code == 401


def test_web_verifier_rejects_bad_signature(monkeypatch):
    monkeypatch.setenv("GOOGLE_WEB_CLIENT_ID", WEB_CLIENT_ID)
    import backend.social_auth as social_auth
    from fastapi import HTTPException

    signer = _rsa_key()
    trusted = _rsa_key()
    _stub_jwks(monkeypatch, _jwk_for(trusted))

    with pytest.raises(HTTPException) as ei:
        _run(social_auth.verify_google_web_id_token(_sign(signer)))
    assert ei.value.status_code == 401


def test_web_verifier_unconfigured_fails_closed(monkeypatch):
    monkeypatch.delenv("GOOGLE_WEB_CLIENT_ID", raising=False)
    import backend.social_auth as social_auth
    from fastapi import HTTPException

    with pytest.raises(HTTPException) as ei:
        _run(social_auth.verify_google_web_id_token("anything"))
    assert ei.value.status_code == 503


# --------------------------------------------------------------------------
# Endpoint behavior (verifier overridden)
# --------------------------------------------------------------------------


def _override_google_web(app, sub, email="person@example.com", verified=True, nonce=None):
    import backend.social_auth as social_auth

    async def fake_verifier(_token):
        return social_auth.IdentityClaims(
            sub=sub, email=email, nonce=nonce, email_verified=verified
        )

    app.dependency_overrides[social_auth.get_google_web_verifier] = lambda: fake_verifier


def _override_native_google(app, sub, email="person@example.com", verified=True):
    import backend.social_auth as social_auth

    async def fake_verifier(_token):
        return social_auth.IdentityClaims(sub=sub, email=email, email_verified=verified)

    app.dependency_overrides[social_auth.get_google_verifier] = lambda: fake_verifier


def _google_web_signin(client, nonce=None):
    body = {"id_token": "signed-by-google"}
    if nonce is not None:
        body["nonce"] = nonce
    return client.post("/v1/auth/google/web", json=body)


def test_google_web_mints_device_and_account(client):
    from backend.server import app

    _override_google_web(app, sub="gw-1")
    r = _google_web_signin(client)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["api_token"] and body["account_id"] and body["device_id"]
    assert body["email"] == "person@example.com"
    me = client.get("/v1/me", headers=_auth(body["api_token"]))
    assert me.status_code == 200
    assert me.json()["account_id"] == body["account_id"]


def test_second_browser_converges_to_same_account(client):
    from backend.server import app

    _override_google_web(app, sub="gw-same")
    first = _google_web_signin(client).json()
    second = _google_web_signin(client).json()
    assert first["device_id"] != second["device_id"]
    assert first["api_token"] != second["api_token"]
    assert first["account_id"] == second["account_id"]


def test_native_and_web_google_converge_on_one_account(client):
    """The SAME person's native Google sign-in and web Google sign-in resolve to
    ONE canonical account, because both key on the same stable google ``sub``."""
    from backend.server import app

    shared_sub = "google-shared-000999"
    device = client.post("/v1/register", json={}).json()
    _override_native_google(app, sub=shared_sub)
    native = client.post(
        "/v1/auth/google",
        json={"id_token": "native-token"},
        headers=_auth(device["api_token"]),
    )
    assert native.status_code == 200, native.text
    native_account = native.json()["account_id"]

    _override_google_web(app, sub=shared_sub)
    web = _google_web_signin(client).json()
    assert web["account_id"] == native_account


def test_different_google_people_do_not_merge(client):
    from backend.server import app

    _override_google_web(app, sub="gw-alice")
    alice = _google_web_signin(client).json()
    _override_google_web(app, sub="gw-bob")
    bob = _google_web_signin(client).json()
    assert alice["account_id"] != bob["account_id"]


def test_same_email_different_google_sub_does_not_silently_merge(client):
    from backend.server import app

    _override_google_web(app, sub="gw-e1", email="shared@example.com", verified=True)
    one = _google_web_signin(client).json()
    _override_google_web(app, sub="gw-e2", email="shared@example.com", verified=True)
    two = _google_web_signin(client).json()
    assert one["account_id"] != two["account_id"]


def test_unverified_email_not_persisted(client):
    from backend.server import app

    _override_google_web(app, sub="gw-unverified", email="unverified@example.com", verified=False)
    body = _google_web_signin(client).json()
    assert body["email"] is None


def test_nonce_mismatch_rejected(client):
    from backend.server import app

    _override_google_web(app, sub="gw-nonce", nonce="the-real-nonce")
    r = _google_web_signin(client, nonce="an-attacker-nonce")
    assert r.status_code == 401, r.text


def test_nonce_match_accepted(client):
    from backend.server import app

    _override_google_web(app, sub="gw-nonce-ok", nonce="matching-nonce")
    r = _google_web_signin(client, nonce="matching-nonce")
    assert r.status_code == 200, r.text


def test_unconfigured_endpoint_fails_closed(client, monkeypatch):
    monkeypatch.delenv("GOOGLE_WEB_CLIENT_ID", raising=False)
    r = _google_web_signin(client)
    assert r.status_code == 503, r.text


def test_returning_browser_upgrades_in_place(client):
    from backend.server import app

    device = client.post("/v1/register", json={}).json()
    _override_google_web(app, sub="gw-upgrade")
    r = client.post(
        "/v1/auth/google/web",
        json={"id_token": "t"},
        headers=_auth(device["api_token"]),
    )
    assert r.status_code == 200, r.text
    assert r.json()["device_id"] == device["device_id"]
