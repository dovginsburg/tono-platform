"""Tests for the canonical web account slice: Supabase-token sign-in
(/v1/auth/web), account-bound checkout, and account deletion.

Two layers:
  - JWT verification is exercised for real against a locally-configured
    HS256 secret (valid / expired / wrong-audience / bad-signature), so the
    fail-closed cryptographic path is covered without any network to the
    Supabase JWKS endpoint.
  - Endpoint behavior (convergence, non-merge, unverified email, checkout
    binding, deletion) uses app.dependency_overrides on the verifier, the
    same seam Apple/Google tests use.
"""

from __future__ import annotations

import datetime as dt

import jwt
import pytest


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _override_web(app, sub: str, email: str | None = "person@example.com", verified: bool = True):
    import backend.supabase_auth as supabase_auth

    async def fake_verifier(_token: str):
        return supabase_auth.SupabaseClaims(sub=sub, email=email, email_verified=verified)

    app.dependency_overrides[supabase_auth.get_supabase_verifier] = lambda: fake_verifier


def _web_signin(client, token_marker: str = "supabase-jwt"):
    return client.post("/v1/auth/web", json={"access_token": token_marker})


# --------------------------------------------------------------------------
# JWT verification (real HS256 path — fail closed)
# --------------------------------------------------------------------------

_SECRET = "test-supabase-jwt-secret-0123456789"
_ISS = "https://proj.supabase.co/auth/v1"
_AUD = "authenticated"


def _configure_hs256(monkeypatch):
    monkeypatch.setenv("SUPABASE_JWT_SECRET", _SECRET)
    monkeypatch.setenv("SUPABASE_ISSUER", _ISS)
    monkeypatch.setenv("SUPABASE_AUD", _AUD)


def _make_token(**overrides) -> str:
    secret = overrides.pop("__secret", _SECRET)
    now = dt.datetime.now(dt.timezone.utc)
    payload = {
        "sub": "supabase-user-1",
        "email": "verified@example.com",
        "email_verified": True,
        "aud": _AUD,
        "iss": _ISS,
        "iat": now,
        "exp": now + dt.timedelta(hours=1),
    }
    payload.update(overrides)
    return jwt.encode(payload, secret, algorithm="HS256")


def _run(coro):
    import asyncio

    return asyncio.run(coro)


def test_valid_token_verifies(monkeypatch):
    _configure_hs256(monkeypatch)
    import backend.supabase_auth as supabase_auth

    claims = _run(supabase_auth.verify_supabase_access_token(_make_token()))
    assert claims.sub == "supabase-user-1"
    assert claims.email == "verified@example.com"
    assert claims.email_verified is True


def test_expired_token_rejected(monkeypatch):
    _configure_hs256(monkeypatch)
    import backend.supabase_auth as supabase_auth
    from fastapi import HTTPException

    past = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=2)
    tok = _make_token(exp=past, iat=past - dt.timedelta(hours=1))
    with pytest.raises(HTTPException) as ei:
        _run(supabase_auth.verify_supabase_access_token(tok))
    assert ei.value.status_code == 401


def test_wrong_audience_rejected(monkeypatch):
    _configure_hs256(monkeypatch)
    import backend.supabase_auth as supabase_auth
    from fastapi import HTTPException

    tok = _make_token(aud="some-other-audience")
    with pytest.raises(HTTPException) as ei:
        _run(supabase_auth.verify_supabase_access_token(tok))
    assert ei.value.status_code == 401


def test_bad_signature_rejected(monkeypatch):
    _configure_hs256(monkeypatch)
    import backend.supabase_auth as supabase_auth
    from fastapi import HTTPException

    tok = _make_token(__secret="a-different-secret-entirely-999999")
    with pytest.raises(HTTPException) as ei:
        _run(supabase_auth.verify_supabase_access_token(tok))
    assert ei.value.status_code == 401


def test_unconfigured_fails_closed(monkeypatch):
    monkeypatch.delenv("SUPABASE_JWT_SECRET", raising=False)
    monkeypatch.delenv("SUPABASE_URL", raising=False)
    monkeypatch.delenv("SUPABASE_JWKS_URL", raising=False)
    import backend.supabase_auth as supabase_auth
    from fastapi import HTTPException

    with pytest.raises(HTTPException) as ei:
        _run(supabase_auth.verify_supabase_access_token("anything"))
    assert ei.value.status_code == 503


def test_anonymous_supabase_session_rejected(monkeypatch):
    _configure_hs256(monkeypatch)
    import backend.supabase_auth as supabase_auth
    from fastapi import HTTPException

    tok = _make_token(is_anonymous=True)
    with pytest.raises(HTTPException) as ei:
        _run(supabase_auth.verify_supabase_access_token(tok))
    assert ei.value.status_code == 401


# --------------------------------------------------------------------------
# /v1/auth/web endpoint behavior
# --------------------------------------------------------------------------


def test_web_signin_mints_device_and_account(client):
    from backend.server import app

    _override_web(app, sub="sb-1")
    r = _web_signin(client)
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

    _override_web(app, sub="sb-same")
    first = _web_signin(client).json()
    second = _web_signin(client).json()

    # Distinct browsers → distinct devices/bearers, ONE account.
    assert first["device_id"] != second["device_id"]
    assert first["api_token"] != second["api_token"]
    assert first["account_id"] == second["account_id"]


def test_different_people_do_not_merge(client):
    from backend.server import app

    _override_web(app, sub="sb-alice")
    alice = _web_signin(client).json()
    _override_web(app, sub="sb-bob")
    bob = _web_signin(client).json()

    assert alice["account_id"] != bob["account_id"]


def test_unverified_email_not_persisted(client):
    from backend.server import app

    _override_web(app, sub="sb-unverified", email="unverified@example.com", verified=False)
    body = _web_signin(client).json()
    # Email must never be stored (and therefore never drive a merge) when the
    # provider did not mark it verified.
    assert body["email"] is None


def test_provider_collision_preserves_409(client):
    """The link-into-existing-account primitive still refuses to silently merge
    two accounts that each own a Supabase subject (existing collision contract)."""
    from backend.server import app
    from backend.store import AccountConflictError, get_store

    store = get_store()
    # Account A owns sb-collide.
    a = store.upsert_account_by_provider("supabase", "sb-collide", "a@example.com")
    # A second, distinct account exists.
    b = store.upsert_account_by_provider("supabase", "sb-other", "b@example.com")
    # Trying to link sb-collide INTO account B must 409, not merge.
    with pytest.raises(AccountConflictError):
        store.upsert_account_by_provider(
            "supabase", "sb-collide", "a@example.com", link_into_account_id=b.id
        )
    assert a.id != b.id


# --------------------------------------------------------------------------
# checkout binding
# --------------------------------------------------------------------------


def test_anonymous_checkout_impossible(client, monkeypatch):
    # No bearer at all → backend refuses; no Stripe session can be created.
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_x")
    monkeypatch.setenv("STRIPE_PRICE_PRO_MONTHLY", "price_x")
    r = client.post("/v1/checkout", json={"interval": "month"})
    assert r.status_code == 401, r.text


def test_checkout_bound_to_account(client, monkeypatch):
    from backend.server import app
    import backend.payments as payments_mod

    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_x")
    monkeypatch.setenv("STRIPE_PRICE_PRO_MONTHLY", "price_x")

    _override_web(app, sub="sb-payer")
    session = _web_signin(client).json()

    captured: dict = {}

    def fake_customer_create(**kwargs):
        return {"id": "cus_fake"}

    def fake_session_create(**kwargs):
        captured.update(kwargs)
        return {"url": "https://checkout.stripe.test/s", "id": "cs_fake"}

    monkeypatch.setattr(payments_mod.stripe.Customer, "create", fake_customer_create)
    monkeypatch.setattr(payments_mod.stripe.checkout.Session, "create", fake_session_create)

    r = client.post(
        "/v1/checkout", json={"interval": "month"}, headers=_auth(session["api_token"])
    )
    assert r.status_code == 200, r.text
    # Money is bound to the account: metadata + client_reference_id are set.
    assert captured["metadata"].get("tono_account_id") == session["account_id"]
    assert captured.get("client_reference_id")


# --------------------------------------------------------------------------
# deletion
# --------------------------------------------------------------------------


def test_delete_account_revokes_and_tombstones(client):
    from backend.server import app
    from backend.store import get_store

    _override_web(app, sub="sb-delete")
    session = _web_signin(client).json()
    token = session["api_token"]
    account_id = session["account_id"]

    # Delete via the authenticated endpoint.
    r = client.delete("/v1/account", headers=_auth(token))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["deleted"] is True
    assert body["revoked_devices"] >= 1

    # The old bearer is dead.
    me = client.get("/v1/me", headers=_auth(token))
    assert me.status_code == 401

    # The account row is tombstoned: identity cleared, deleted_at set, and it
    # can no longer be resolved by its old Supabase subject.
    store = get_store()
    acct = store.get_account(account_id)
    assert acct is not None  # row preserved for billing audit
    assert acct.deleted_at is not None
    assert acct.supabase_sub is None
    assert acct.email is None
    assert acct.is_identified is False
    assert store.get_account_by_provider("supabase", "sb-delete") is None


def test_delete_requires_auth(client):
    r = client.delete("/v1/account")
    assert r.status_code == 401
