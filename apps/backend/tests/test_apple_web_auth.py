"""Tests for the DIRECT Apple web sign-in slice (/v1/auth/apple/web).

The website owns the Apple OAuth boundary (start + callback under Tono's own
Services ID, ``tonoit.com``) instead of routing Apple through Supabase. Its
callback forwards the verified Apple identity token here; we INDEPENDENTLY
re-verify it (web Services ID audience) and converge the Apple ``sub`` onto the
ONE canonical account — the SAME ``apple_sub`` the native iOS app resolves.

Two layers, mirroring test_web_auth.py:
  - The web-audience verifier is exercised for REAL against a locally generated
    RSA key (valid / wrong-audience / wrong-issuer / expired / bad-signature /
    unconfigured), with the shared Apple JWKS cache stubbed so no network is
    needed.
  - Endpoint behavior (device+account minting, convergence, native↔web
    convergence, non-merge, unverified email, nonce, upgrade-in-place) uses
    app.dependency_overrides on the verifier — the same seam the native
    Apple/Google/web tests use.
"""

from __future__ import annotations

import asyncio
import datetime as dt
import json

import jwt
import pytest


APPLE_ISSUER = "https://appleid.apple.com"
WEB_CLIENT_ID = "tonoit.com"
NATIVE_CLIENT_ID = "com.tonoit.app"


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _run(coro):
    return asyncio.run(coro)


# --------------------------------------------------------------------------
# REAL crypto: the web-audience Apple verifier (fail closed)
# --------------------------------------------------------------------------

_KID = "test-apple-web-kid"


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
        "iss": APPLE_ISSUER,
        "aud": WEB_CLIENT_ID,
        "sub": "apple-web-sub-1",
        "iat": now,
        "exp": now + dt.timedelta(hours=1),
        "email": "person@example.com",
        "email_verified": "true",
    }
    payload.update(overrides)
    return jwt.encode(payload, private_key, algorithm="RS256", headers={"kid": _KID})


def _stub_jwks(monkeypatch, jwk: dict) -> None:
    import backend.social_auth as social_auth

    async def fake_get_key(_kid):
        return jwk

    monkeypatch.setattr(social_auth._apple_jwks, "get_key", fake_get_key)


def test_web_verifier_accepts_a_valid_tonoit_audience_token(monkeypatch):
    monkeypatch.setenv("APPLE_WEB_CLIENT_ID", WEB_CLIENT_ID)
    import backend.social_auth as social_auth

    key = _rsa_key()
    _stub_jwks(monkeypatch, _jwk_for(key))

    claims = _run(social_auth.verify_apple_web_identity_token(_sign(key)))
    assert claims.sub == "apple-web-sub-1"
    assert claims.email == "person@example.com"
    assert claims.email_verified is True


def test_web_verifier_rejects_the_native_audience(monkeypatch):
    """A token minted for the NATIVE app id must NOT verify at the web boundary."""
    monkeypatch.setenv("APPLE_WEB_CLIENT_ID", WEB_CLIENT_ID)
    import backend.social_auth as social_auth
    from fastapi import HTTPException

    key = _rsa_key()
    _stub_jwks(monkeypatch, _jwk_for(key))

    tok = _sign(key, aud=NATIVE_CLIENT_ID)
    with pytest.raises(HTTPException) as ei:
        _run(social_auth.verify_apple_web_identity_token(tok))
    assert ei.value.status_code == 401


def test_web_verifier_rejects_wrong_issuer(monkeypatch):
    monkeypatch.setenv("APPLE_WEB_CLIENT_ID", WEB_CLIENT_ID)
    import backend.social_auth as social_auth
    from fastapi import HTTPException

    key = _rsa_key()
    _stub_jwks(monkeypatch, _jwk_for(key))

    tok = _sign(key, iss="https://evil.example.com")
    with pytest.raises(HTTPException) as ei:
        _run(social_auth.verify_apple_web_identity_token(tok))
    assert ei.value.status_code == 401


def test_web_verifier_rejects_expired(monkeypatch):
    monkeypatch.setenv("APPLE_WEB_CLIENT_ID", WEB_CLIENT_ID)
    import backend.social_auth as social_auth
    from fastapi import HTTPException

    key = _rsa_key()
    _stub_jwks(monkeypatch, _jwk_for(key))

    past = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=2)
    tok = _sign(key, exp=past, iat=past - dt.timedelta(hours=1))
    with pytest.raises(HTTPException) as ei:
        _run(social_auth.verify_apple_web_identity_token(tok))
    assert ei.value.status_code == 401


def test_web_verifier_rejects_bad_signature(monkeypatch):
    monkeypatch.setenv("APPLE_WEB_CLIENT_ID", WEB_CLIENT_ID)
    import backend.social_auth as social_auth
    from fastapi import HTTPException

    signer = _rsa_key()
    trusted = _rsa_key()  # JWKS advertises a DIFFERENT key than the signer
    _stub_jwks(monkeypatch, _jwk_for(trusted))

    with pytest.raises(HTTPException) as ei:
        _run(social_auth.verify_apple_web_identity_token(_sign(signer)))
    assert ei.value.status_code == 401


def test_web_verifier_unconfigured_fails_closed(monkeypatch):
    monkeypatch.delenv("APPLE_WEB_CLIENT_ID", raising=False)
    import backend.social_auth as social_auth
    from fastapi import HTTPException

    with pytest.raises(HTTPException) as ei:
        _run(social_auth.verify_apple_web_identity_token("anything"))
    assert ei.value.status_code == 503


# --------------------------------------------------------------------------
# Endpoint behavior (verifier overridden — the same seam other auth tests use)
# --------------------------------------------------------------------------


def _override_apple_web(app, sub, email="person@example.com", verified=True, nonce=None):
    import backend.social_auth as social_auth

    async def fake_verifier(_token):
        return social_auth.IdentityClaims(
            sub=sub, email=email, nonce=nonce, email_verified=verified
        )

    app.dependency_overrides[social_auth.get_apple_web_verifier] = lambda: fake_verifier


def _override_native_apple(app, sub, email="person@example.com", verified=True):
    import backend.social_auth as social_auth

    async def fake_verifier(_token):
        return social_auth.IdentityClaims(sub=sub, email=email, email_verified=verified)

    app.dependency_overrides[social_auth.get_apple_verifier] = lambda: fake_verifier


def _apple_web_signin(client, nonce=None):
    body = {"identity_token": "signed-by-apple"}
    if nonce is not None:
        body["nonce"] = nonce
    return client.post("/v1/auth/apple/web", json=body)


def test_apple_web_mints_device_and_account(client):
    from backend.server import app

    _override_apple_web(app, sub="aw-1")
    r = _apple_web_signin(client)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["api_token"]
    assert body["account_id"]
    assert body["device_id"]
    assert body["email"] == "person@example.com"

    # The returned bearer actually works.
    me = client.get("/v1/me", headers=_auth(body["api_token"]))
    assert me.status_code == 200
    assert me.json()["account_id"] == body["account_id"]


def test_second_browser_converges_to_same_account(client):
    from backend.server import app

    _override_apple_web(app, sub="aw-same")
    first = _apple_web_signin(client).json()
    second = _apple_web_signin(client).json()

    # Distinct browsers → distinct devices/bearers, ONE canonical account.
    assert first["device_id"] != second["device_id"]
    assert first["api_token"] != second["api_token"]
    assert first["account_id"] == second["account_id"]


def test_native_and_web_apple_converge_on_one_account(client):
    """The acceptance-critical case: the SAME person's native iOS Apple sign-in
    and web Apple sign-in resolve to ONE canonical account, because both key on
    the same stable ``apple_sub``."""
    from backend.server import app

    shared_sub = "apple-shared-000999"

    # Native iOS sign-in first (requires a device bearer).
    device = client.post("/v1/register", json={}).json()
    _override_native_apple(app, sub=shared_sub)
    native = client.post(
        "/v1/auth/apple",
        json={"identity_token": "native-token"},
        headers=_auth(device["api_token"]),
    )
    assert native.status_code == 200, native.text
    native_account = native.json()["account_id"]

    # Later, the same person signs in on the website (fresh browser, no bearer).
    _override_apple_web(app, sub=shared_sub)
    web = _apple_web_signin(client).json()

    assert web["account_id"] == native_account


def test_different_apple_people_do_not_merge(client):
    from backend.server import app

    _override_apple_web(app, sub="aw-alice")
    alice = _apple_web_signin(client).json()
    _override_apple_web(app, sub="aw-bob")
    bob = _apple_web_signin(client).json()

    assert alice["account_id"] != bob["account_id"]


def test_same_email_different_apple_sub_does_not_silently_merge(client):
    """Two DISTINCT Apple subjects that happen to share an email address are two
    different Apple identities — they must never fuse into one account by email
    text alone."""
    from backend.server import app

    _override_apple_web(app, sub="aw-e1", email="shared@example.com", verified=True)
    one = _apple_web_signin(client).json()
    _override_apple_web(app, sub="aw-e2", email="shared@example.com", verified=True)
    two = _apple_web_signin(client).json()

    assert one["account_id"] != two["account_id"]


def test_unverified_email_not_persisted(client):
    from backend.server import app

    _override_apple_web(app, sub="aw-unverified", email="unverified@example.com", verified=False)
    body = _apple_web_signin(client).json()
    # Email is never stored (and so never drives a merge) unless the provider
    # marked it verified.
    assert body["email"] is None


def test_nonce_mismatch_rejected(client):
    """When the website forwards the raw nonce, the backend re-checks it against
    the token's claim (verbatim, web-flow convention) and refuses a mismatch."""
    from backend.server import app

    _override_apple_web(app, sub="aw-nonce", nonce="the-real-nonce")
    r = _apple_web_signin(client, nonce="an-attacker-nonce")
    assert r.status_code == 401, r.text


def test_nonce_match_accepted(client):
    from backend.server import app

    _override_apple_web(app, sub="aw-nonce-ok", nonce="matching-nonce")
    r = _apple_web_signin(client, nonce="matching-nonce")
    assert r.status_code == 200, r.text


def test_unconfigured_endpoint_fails_closed(client, monkeypatch):
    """With no verifier override and no APPLE_WEB_CLIENT_ID, the real verifier
    refuses (503) before any account state is touched."""
    monkeypatch.delenv("APPLE_WEB_CLIENT_ID", raising=False)
    r = _apple_web_signin(client)
    assert r.status_code == 503, r.text


def test_returning_browser_upgrades_in_place(client):
    """A browser that already holds an anonymous device bearer keeps its device
    (and account UUID) when it completes Apple sign-in — no orphaned account."""
    from backend.server import app

    device = client.post("/v1/register", json={}).json()
    _override_apple_web(app, sub="aw-upgrade")
    r = client.post(
        "/v1/auth/apple/web",
        json={"identity_token": "t"},
        headers=_auth(device["api_token"]),
    )
    assert r.status_code == 200, r.text
    body = r.json()
    # Same device is reused (upgrade in place), not a freshly minted one.
    assert body["device_id"] == device["device_id"]
