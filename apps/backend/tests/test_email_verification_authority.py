"""Email-verification authority — the live 403 and its fix.

Production evidence (2026-08-03): a synthetic signup was confirmed (the
Supabase ``auth.users`` row had ``email_confirmed_at`` set; a direct
``/auth/v1/token?grant_type=password`` returned 200 with an access token whose
``user.email_confirmed_at`` was non-null), yet ``POST /v1/auth/email/login``
returned 403 ``email_verification_required``.

Root cause: the login's gate 2 read ``claims.email_verified``, which the
verifier derived ONLY from an in-token ``email_verified`` claim — a claim a
real Supabase password JWT does NOT carry (its ``email_verified`` lives in
user-writable ``user_metadata``, which we refuse to trust). So a genuinely
confirmed address computed as unverified.

The fix keeps every cryptographic guarantee and the "never trust
``user_metadata``" boundary, and adds the one authoritative source: GoTrue's
own authenticated ``GET /auth/v1/user`` (``email_confirmed_at``), with
fail-closed subject/email consistency checks.

These tests use REAL Supabase-shaped payloads and the REAL verifier. The only
seam substituted is the raw HTTP GET of the user record
(``supabase_auth._http_get_supabase_user``), so no network is touched — exactly
as the JWKS/verifier seams are stubbed elsewhere.
"""

from __future__ import annotations

import datetime as dt

import httpx
import jwt
import pytest


# --------------------------------------------------------------------------
# Config + real-Supabase-shaped payload builders
# --------------------------------------------------------------------------

_SECRET = "test-supabase-jwt-secret-0123456789"
_URL = "https://proj.supabase.co"
_ISS = "https://proj.supabase.co/auth/v1"
_AUD = "authenticated"
_ANON = "anon-publishable-key-abcdef"


def _configure(monkeypatch) -> None:
    """HS256 verification (real crypto) + a resolvable user endpoint + apikey.

    SUPABASE_URL alone derives the issuer AND the ``/auth/v1/user`` URL, so this
    mirrors a real single-project deployment."""
    monkeypatch.setenv("SUPABASE_JWT_SECRET", _SECRET)
    monkeypatch.setenv("SUPABASE_URL", _URL)
    monkeypatch.setenv("SUPABASE_AUD", _AUD)
    monkeypatch.setenv("SUPABASE_ANON_KEY", _ANON)
    monkeypatch.delenv("SUPABASE_ISSUER", raising=False)
    monkeypatch.delenv("SUPABASE_JWKS_URL", raising=False)
    monkeypatch.delenv("SUPABASE_USER_URL", raising=False)


def _password_jwt(*, sub: str, email: str, **overrides) -> str:
    """A password-grant access token shaped like a REAL Supabase one.

    Claim keys exactly match a production password JWT: aal, amr, app_metadata,
    aud, email, exp, iat, is_anonymous, iss, phone, role, session_id, sub,
    user_metadata. There is deliberately NO top-level ``email_verified`` — the
    exact shape that made a confirmed address read as unverified. ``app_metadata``
    carries only provider info (no ``email_verified``); ``user_metadata`` carries
    the user-writable ``email_verified`` we must ignore.
    """
    now = dt.datetime.now(dt.timezone.utc)
    payload = {
        "aal": "aal1",
        "amr": [{"method": "password", "timestamp": int(now.timestamp())}],
        "app_metadata": {"provider": "email", "providers": ["email"]},
        "aud": _AUD,
        "email": email,
        "exp": now + dt.timedelta(hours=1),
        "iat": now,
        "is_anonymous": False,
        "iss": _ISS,
        "phone": "",
        "role": "authenticated",
        "session_id": "11111111-2222-3333-4444-555555555555",
        "sub": sub,
        "user_metadata": {
            "email": email,
            "email_verified": True,  # user-writable — MUST NOT be trusted
            "phone_verified": False,
            "sub": sub,
        },
    }
    payload.update(overrides)
    return jwt.encode(payload, _SECRET, algorithm="HS256")


def _gotrue_user(*, sub: str, email: str, confirmed: bool) -> dict:
    """A GoTrue ``/auth/v1/user`` record shaped like the real response."""
    ts = "2026-08-03T12:00:00Z"
    return {
        "id": sub,
        "aud": _AUD,
        "role": "authenticated",
        "email": email,
        "email_confirmed_at": ts if confirmed else None,
        "confirmed_at": ts if confirmed else None,
        "phone": "",
        "app_metadata": {"provider": "email", "providers": ["email"]},
        "user_metadata": {"email": email, "email_verified": True, "sub": sub},
        "identities": [],
        "created_at": ts,
        "updated_at": ts,
    }


def _stub_user_endpoint(monkeypatch, *, response=None, raises=None, seen=None):
    """Substitute the raw authenticated GET of GoTrue's user record.

    ``response`` may be an ``httpx.Response`` (returned) or ``raises`` an
    exception (raised, e.g. a transport error). ``seen`` optionally captures the
    (url, headers) the verifier used, to assert the bearer/apikey wiring.
    """
    import backend.supabase_auth as supabase_auth

    async def fake_get(url: str, headers: dict) -> httpx.Response:
        if seen is not None:
            seen["url"] = url
            seen["headers"] = dict(headers)
        if raises is not None:
            raise raises
        return response

    monkeypatch.setattr(supabase_auth, "_http_get_supabase_user", fake_get)


def _run(coro):
    import asyncio

    return asyncio.run(coro)


# ==========================================================================
# Unit contract — verify_supabase_access_token against the REAL verifier
# ==========================================================================


def test_confirmed_password_login_verifies(monkeypatch):
    """The headline case: a real-shaped password JWT with NO top-level claim,
    whose address GoTrue reports confirmed, resolves to email_verified=True."""
    _configure(monkeypatch)
    import backend.supabase_auth as supabase_auth

    seen: dict = {}
    _stub_user_endpoint(
        monkeypatch,
        response=httpx.Response(
            200, json=_gotrue_user(sub="sb-ok", email="a@example.com", confirmed=True)
        ),
        seen=seen,
    )

    tok = _password_jwt(sub="sb-ok", email="a@example.com")
    claims = _run(supabase_auth.verify_supabase_access_token(tok))
    assert claims.sub == "sb-ok"
    assert claims.email == "a@example.com"
    assert claims.email_verified is True

    # Wiring proof: the authoritative call carried the token's OWN bearer and the
    # project apikey, and hit the derived /auth/v1/user URL.
    assert seen["url"] == f"{_URL}/auth/v1/user"
    assert seen["headers"]["Authorization"] == f"Bearer {tok}"
    assert seen["headers"]["apikey"] == _ANON


def test_unconfirmed_user_is_not_verified(monkeypatch):
    """GoTrue reports the address NOT confirmed → email_verified=False (a
    genuine 'verify your email', not a grant)."""
    _configure(monkeypatch)
    import backend.supabase_auth as supabase_auth

    _stub_user_endpoint(
        monkeypatch,
        response=httpx.Response(
            200, json=_gotrue_user(sub="sb-no", email="b@example.com", confirmed=False)
        ),
    )
    tok = _password_jwt(sub="sb-no", email="b@example.com")
    claims = _run(supabase_auth.verify_supabase_access_token(tok))
    assert claims.email_verified is False


def test_forged_user_metadata_alone_does_not_verify(monkeypatch):
    """The token asserts verified ONLY in user-writable user_metadata; GoTrue's
    authoritative record says the address is unconfirmed. user_metadata must be
    ignored and the authoritative source believed → email_verified=False."""
    _configure(monkeypatch)
    import backend.supabase_auth as supabase_auth

    _stub_user_endpoint(
        monkeypatch,
        response=httpx.Response(
            200,
            json=_gotrue_user(sub="sb-forge", email="victim@example.com", confirmed=False),
        ),
    )
    # user_metadata.email_verified is True by default in the builder; there is no
    # top-level claim. Only GoTrue's email_confirmed_at (null) should count.
    tok = _password_jwt(sub="sb-forge", email="victim@example.com")
    claims = _run(supabase_auth.verify_supabase_access_token(tok))
    assert claims.email_verified is False


def test_subject_mismatch_fails_closed(monkeypatch):
    """The user record describes a DIFFERENT subject than the verified token →
    401, never a verified read of a stranger's state."""
    _configure(monkeypatch)
    import backend.supabase_auth as supabase_auth
    from fastapi import HTTPException

    _stub_user_endpoint(
        monkeypatch,
        response=httpx.Response(
            200,
            json=_gotrue_user(sub="sb-OTHER", email="a@example.com", confirmed=True),
        ),
    )
    tok = _password_jwt(sub="sb-ok", email="a@example.com")
    with pytest.raises(HTTPException) as ei:
        _run(supabase_auth.verify_supabase_access_token(tok))
    assert ei.value.status_code == 401


def test_email_mismatch_fails_closed(monkeypatch):
    """The user record's email differs from the token's → 401, so one address is
    never confirmed using another's status."""
    _configure(monkeypatch)
    import backend.supabase_auth as supabase_auth
    from fastapi import HTTPException

    _stub_user_endpoint(
        monkeypatch,
        response=httpx.Response(
            200,
            json=_gotrue_user(sub="sb-ok", email="someone-else@example.com", confirmed=True),
        ),
    )
    tok = _password_jwt(sub="sb-ok", email="a@example.com")
    with pytest.raises(HTTPException) as ei:
        _run(supabase_auth.verify_supabase_access_token(tok))
    assert ei.value.status_code == 401


def test_email_match_is_case_insensitive(monkeypatch):
    """Case/whitespace differences between the token email and the record email
    are not a mismatch — GoTrue lowercases addresses."""
    _configure(monkeypatch)
    import backend.supabase_auth as supabase_auth

    _stub_user_endpoint(
        monkeypatch,
        response=httpx.Response(
            200, json=_gotrue_user(sub="sb-ok", email="a@example.com", confirmed=True)
        ),
    )
    tok = _password_jwt(sub="sb-ok", email="A@Example.com")
    claims = _run(supabase_auth.verify_supabase_access_token(tok))
    assert claims.email_verified is True


def test_provider_transport_outage_fails_closed(monkeypatch):
    """A transport failure reaching /auth/v1/user → 503, never a verified."""
    _configure(monkeypatch)
    import backend.supabase_auth as supabase_auth
    from fastapi import HTTPException

    _stub_user_endpoint(monkeypatch, raises=httpx.ConnectError("boom"))
    tok = _password_jwt(sub="sb-ok", email="a@example.com")
    with pytest.raises(HTTPException) as ei:
        _run(supabase_auth.verify_supabase_access_token(tok))
    assert ei.value.status_code == 503


def test_provider_5xx_fails_closed(monkeypatch):
    """A 5xx from /auth/v1/user → 503, never a verified."""
    _configure(monkeypatch)
    import backend.supabase_auth as supabase_auth
    from fastapi import HTTPException

    _stub_user_endpoint(monkeypatch, response=httpx.Response(502, text="bad gateway"))
    tok = _password_jwt(sub="sb-ok", email="a@example.com")
    with pytest.raises(HTTPException) as ei:
        _run(supabase_auth.verify_supabase_access_token(tok))
    assert ei.value.status_code == 503


def test_provider_rejects_token_maps_to_401(monkeypatch):
    """If GoTrue itself rejects the token we cryptographically verified (401/403
    at /auth/v1/user), we surface 401 — unauthenticated, never verified."""
    _configure(monkeypatch)
    import backend.supabase_auth as supabase_auth
    from fastapi import HTTPException

    _stub_user_endpoint(monkeypatch, response=httpx.Response(401, json={"msg": "nope"}))
    tok = _password_jwt(sub="sb-ok", email="a@example.com")
    with pytest.raises(HTTPException) as ei:
        _run(supabase_auth.verify_supabase_access_token(tok))
    assert ei.value.status_code == 401


def test_provider_malformed_body_fails_closed(monkeypatch):
    """A 2xx with a non-JSON body → 503, never a verified."""
    _configure(monkeypatch)
    import backend.supabase_auth as supabase_auth
    from fastapi import HTTPException

    _stub_user_endpoint(monkeypatch, response=httpx.Response(200, content=b"<<not json>>"))
    tok = _password_jwt(sub="sb-ok", email="a@example.com")
    with pytest.raises(HTTPException) as ei:
        _run(supabase_auth.verify_supabase_access_token(tok))
    assert ei.value.status_code == 503


def test_provider_non_object_body_fails_closed(monkeypatch):
    """A 2xx whose JSON is not an object (e.g. a list) → 503."""
    _configure(monkeypatch)
    import backend.supabase_auth as supabase_auth
    from fastapi import HTTPException

    _stub_user_endpoint(monkeypatch, response=httpx.Response(200, json=["a", "b"]))
    tok = _password_jwt(sub="sb-ok", email="a@example.com")
    with pytest.raises(HTTPException) as ei:
        _run(supabase_auth.verify_supabase_access_token(tok))
    assert ei.value.status_code == 503


def test_user_endpoint_unconfigured_fails_closed(monkeypatch):
    """No SUPABASE_URL/SUPABASE_USER_URL to reach the authority → 503, never a
    silent verified. (Uses an explicit issuer so crypto still passes.)"""
    monkeypatch.setenv("SUPABASE_JWT_SECRET", _SECRET)
    monkeypatch.setenv("SUPABASE_ISSUER", _ISS)
    monkeypatch.setenv("SUPABASE_AUD", _AUD)
    monkeypatch.delenv("SUPABASE_URL", raising=False)
    monkeypatch.delenv("SUPABASE_USER_URL", raising=False)
    monkeypatch.delenv("SUPABASE_JWKS_URL", raising=False)
    import backend.supabase_auth as supabase_auth
    from fastapi import HTTPException

    tok = _password_jwt(sub="sb-ok", email="a@example.com")
    with pytest.raises(HTTPException) as ei:
        _run(supabase_auth.verify_supabase_access_token(tok))
    assert ei.value.status_code == 503


def test_in_token_top_level_claim_short_circuits_no_fetch(monkeypatch):
    """Forward-compatibility: if a token DOES carry a top-level email_verified,
    it is authoritative and no /auth/v1/user call is made (the fetch would
    raise, proving it was never reached)."""
    _configure(monkeypatch)
    import backend.supabase_auth as supabase_auth

    def _boom(*_a, **_k):
        raise AssertionError("must not fetch /auth/v1/user when in-token authority present")

    monkeypatch.setattr(supabase_auth, "_http_get_supabase_user", _boom)

    tok = _password_jwt(sub="sb-ok", email="a@example.com", email_verified=True)
    claims = _run(supabase_auth.verify_supabase_access_token(tok))
    assert claims.email_verified is True

    # An explicit top-level false is ALSO authoritative — still no fetch.
    tok_false = _password_jwt(sub="sb-ok", email="a@example.com", email_verified=False)
    claims_false = _run(supabase_auth.verify_supabase_access_token(tok_false))
    assert claims_false.email_verified is False


# ==========================================================================
# End-to-end — POST /v1/auth/email/login through the REAL verifier
# ==========================================================================


def _stub_email_client(app, access_token: str):
    """Provider accepts the credentials and hands back a session bearing
    ``access_token``; the REAL verifier then decides gate 2."""
    import backend.email_auth as email_auth

    async def _sign_in(*, email: str, password: str):
        return email_auth.EmailAuthSession(access_token=access_token)

    class _StubClient:
        sign_in = staticmethod(_sign_in)

    app.dependency_overrides[email_auth.get_email_auth_client] = lambda: _StubClient()


def test_login_succeeds_for_confirmed_address_end_to_end(client, monkeypatch):
    """The exact live failure, fixed: signup was confirmed, the provider returns
    a valid session, and login now returns 200 with a working Tono bearer
    instead of 403 email_verification_required."""
    from backend.server import app

    _configure(monkeypatch)
    tok = _password_jwt(sub="sb-live", email="live@example.com")
    _stub_email_client(app, tok)
    _stub_user_endpoint(
        monkeypatch,
        response=httpx.Response(
            200, json=_gotrue_user(sub="sb-live", email="live@example.com", confirmed=True)
        ),
    )

    r = client.post(
        "/v1/auth/email/login",
        json={"email": "live@example.com", "password": "correct-horse-battery"},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["email_verified"] is True
    assert body["api_token"]
    assert body["account_id"]

    # The bearer actually works.
    me = client.get("/v1/me", headers={"Authorization": f"Bearer {body['api_token']}"})
    assert me.status_code == 200
    assert me.json()["account_id"] == body["account_id"]


def test_login_blocks_unconfirmed_address_end_to_end(client, monkeypatch):
    """An unconfirmed address (provider hands back a session, but GoTrue reports
    email_confirmed_at null) → 403 email_verification_required, NO bearer."""
    from backend.server import app

    _configure(monkeypatch)
    tok = _password_jwt(sub="sb-pending", email="pending@example.com")
    _stub_email_client(app, tok)
    _stub_user_endpoint(
        monkeypatch,
        response=httpx.Response(
            200,
            json=_gotrue_user(sub="sb-pending", email="pending@example.com", confirmed=False),
        ),
    )

    r = client.post(
        "/v1/auth/email/login",
        json={"email": "pending@example.com", "password": "correct-horse-battery"},
    )
    assert r.status_code == 403, r.text
    assert r.json()["error"]["message"] == "email_verification_required"
    assert "api_token" not in r.json()


def test_login_forged_user_metadata_alone_blocks_end_to_end(client, monkeypatch):
    """A token whose verified flag is ONLY in user_metadata, for an address
    GoTrue reports unconfirmed → 403, NO bearer. Proves the login cannot be
    driven by the forgeable field."""
    from backend.server import app

    _configure(monkeypatch)
    tok = _password_jwt(sub="sb-forge2", email="forge@example.com")  # user_metadata verified
    _stub_email_client(app, tok)
    _stub_user_endpoint(
        monkeypatch,
        response=httpx.Response(
            200,
            json=_gotrue_user(sub="sb-forge2", email="forge@example.com", confirmed=False),
        ),
    )

    r = client.post(
        "/v1/auth/email/login",
        json={"email": "forge@example.com", "password": "correct-horse-battery"},
    )
    assert r.status_code == 403, r.text
    assert r.json()["error"]["message"] == "email_verification_required"


def test_login_fails_closed_on_provider_outage_end_to_end(client, monkeypatch):
    """If the authoritative /auth/v1/user is unreachable, login fails closed
    (no bearer) rather than trusting or guessing."""
    from backend.server import app

    _configure(monkeypatch)
    tok = _password_jwt(sub="sb-out", email="out@example.com")
    _stub_email_client(app, tok)
    _stub_user_endpoint(monkeypatch, raises=httpx.ConnectError("boom"))

    r = client.post(
        "/v1/auth/email/login",
        json={"email": "out@example.com", "password": "correct-horse-battery"},
    )
    assert r.status_code >= 400
    assert "api_token" not in r.json()
