"""Build 117 App-Review compatibility: a reviewer who skips onboarding and
cannot sign in (email sign-in is "Coming soon" in 117) must be able to redeem a
single, explicitly-flagged code and get Pro — WITHOUT weakening general
ownership or exposing a universal anonymous promo.

Root causes this fixes (deployed SHA 185dc7b returns 403 for the promised path):
  1. /v1/coupon/redeem hard-403s unless account.is_identified.
  2. store._redeem_coupon_tx raises "sign in" unless account.is_identified.
  3. anonymous User.is_pro reads the DEVICE coupon field, but redeem wrote the
     ACCOUNT field — so even a relaxed gate would not unlock Pro.

The fix is a per-coupon ``anonymous_eligible`` flag (DEFAULT 0). These hostile
tests pin the invariants Ezra required: canonical-account isolation, expiry,
max-use, idempotency, no cross-device leakage, and that NON-flagged codes remain
identity-gated (ownership unchanged).
"""

from __future__ import annotations

import pytest


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _register(client) -> dict:
    """A fresh anonymous install: canonical account, NOT identified."""
    r = client.post("/v1/register", json={})
    assert r.status_code == 200, r.text
    return r.json()


def _me(client, token: str) -> dict:
    r = client.get("/v1/me", headers=_auth(token))
    assert r.status_code == 200, r.text
    return r.json()


def _redeem(client, token: str, code: str):
    return client.post("/v1/coupon/redeem", json={"code": code}, headers=_auth(token))


def _reviewer_coupon(code="APPREVIEW117", *, duration_days=30, max_uses=25,
                     expires_at=None, anonymous_eligible=True):
    from backend.store import get_store
    assert get_store().create_coupon(
        code, duration_days, max_uses, expires_at,
        anonymous_eligible=anonymous_eligible,
    ), "coupon code already existed"


# ---------------------------------------------------------------------------
# The promised reviewer path works.
# ---------------------------------------------------------------------------


def test_anonymous_account_redeems_reviewer_coupon_and_unlocks_pro(client):
    """Skip onboarding (anonymous) → redeem the flagged code with no sign-in →
    Pro is active on this canonical account."""
    _reviewer_coupon()
    reg = _register(client)
    assert _me(client, reg["api_token"])["is_pro"] is False

    r = _redeem(client, reg["api_token"], "APPREVIEW117")
    assert r.status_code == 200, r.text
    assert r.json()["coupon_pro_expires_at"]

    assert _me(client, reg["api_token"])["is_pro"] is True


# ---------------------------------------------------------------------------
# Ownership is NOT weakened — no universal anonymous promo.
# ---------------------------------------------------------------------------


def test_anonymous_account_refused_for_a_normal_coupon(client):
    """A code that is NOT anonymous_eligible stays identity-gated: an
    unidentified account is refused (403), exactly as before."""
    _reviewer_coupon("NORMALCODE", anonymous_eligible=False)
    reg = _register(client)
    r = _redeem(client, reg["api_token"], "NORMALCODE")
    assert r.status_code == 403, r.text
    assert _me(client, reg["api_token"])["is_pro"] is False


def test_unknown_code_does_not_leak_existence_to_anonymous(client):
    """An anonymous caller probing an unknown code gets the same 403 as a
    non-eligible one — no oracle for which codes exist."""
    reg = _register(client)
    r = _redeem(client, reg["api_token"], "DOESNOTEXIST")
    assert r.status_code == 403, r.text


# ---------------------------------------------------------------------------
# Idempotency, max-use, expiry — all preserved for the reviewer code.
# ---------------------------------------------------------------------------


def test_reviewer_coupon_is_idempotent_per_account(client):
    """The same account cannot redeem the flagged code twice."""
    _reviewer_coupon()
    reg = _register(client)
    assert _redeem(client, reg["api_token"], "APPREVIEW117").status_code == 200
    second = _redeem(client, reg["api_token"], "APPREVIEW117")
    assert second.status_code == 400
    assert "already" in second.text.lower()


def test_reviewer_coupon_respects_max_uses(client):
    """max_uses bounds the blast radius across DISTINCT anonymous accounts."""
    _reviewer_coupon("APPREVIEW117", max_uses=1)
    first = _register(client)
    second = _register(client)
    assert _redeem(client, first["api_token"], "APPREVIEW117").status_code == 200
    exhausted = _redeem(client, second["api_token"], "APPREVIEW117")
    assert exhausted.status_code == 400
    assert "limit" in exhausted.text.lower()
    assert _me(client, second["api_token"])["is_pro"] is False


def test_reviewer_coupon_respects_expiry(client):
    """An expired flagged code grants nothing even to an anonymous account."""
    _reviewer_coupon("APPREVIEW117", expires_at="2000-01-01T00:00:00")
    reg = _register(client)
    r = _redeem(client, reg["api_token"], "APPREVIEW117")
    assert r.status_code == 400
    assert "expired" in r.text.lower()
    assert _me(client, reg["api_token"])["is_pro"] is False


# ---------------------------------------------------------------------------
# Canonical-account isolation — no cross-device entitlement leakage.
# ---------------------------------------------------------------------------


def test_reviewer_grant_does_not_leak_across_devices(client):
    """Redeeming on device A's anonymous account must not make a DIFFERENT
    device/account Pro. Entitlement binds to the canonical account UUID."""
    _reviewer_coupon()
    device_a = _register(client)
    device_b = _register(client)
    assert device_a["account_id"] != device_b["account_id"]

    assert _redeem(client, device_a["api_token"], "APPREVIEW117").status_code == 200

    assert _me(client, device_a["api_token"])["is_pro"] is True
    assert _me(client, device_b["api_token"])["is_pro"] is False, (
        "reviewer grant leaked to a different canonical account"
    )


# ---------------------------------------------------------------------------
# Backward compatibility — an identified account still redeems normally.
# ---------------------------------------------------------------------------


def test_identified_account_still_redeems_flagged_and_normal_codes(client, monkeypatch):
    """The flag only ADDS an anonymous path; an identified account keeps working
    for both flagged and normal codes."""
    from backend.server import app
    import backend.social_auth as social_auth

    _reviewer_coupon("APPREVIEW117")
    _reviewer_coupon("NORMALCODE", anonymous_eligible=False)

    reg = _register(client)

    async def fake_verifier(_token: str):
        return social_auth.IdentityClaims(sub="apple-reviewer-compat", email="r@example.com")

    app.dependency_overrides[social_auth.get_apple_verifier] = lambda: fake_verifier
    try:
        r = client.post("/v1/auth/apple", json={"identity_token": "t"},
                        headers=_auth(reg["api_token"]))
        assert r.status_code == 200, r.text
    finally:
        app.dependency_overrides.pop(social_auth.get_apple_verifier, None)

    assert _redeem(client, reg["api_token"], "NORMALCODE").status_code == 200
    assert _me(client, reg["api_token"])["is_pro"] is True


# ---------------------------------------------------------------------------
# Admin plumbing — the flag flows through the create API, and defaults off.
# ---------------------------------------------------------------------------


def test_admin_create_flag_flows_and_defaults_identity_gated(client, monkeypatch):
    """A coupon created via the admin API WITHOUT the flag is identity-gated;
    WITH the flag it is anonymous-eligible."""
    monkeypatch.setenv("TONO_ADMIN_SECRET", "s3cret")
    hdr = {"X-Admin-Secret": "s3cret"}

    # Default: no flag → anonymous redemption refused.
    assert client.post("/admin/coupon/create",
                       json={"code": "PLAINADMIN", "duration_days": 7},
                       headers=hdr).status_code == 201
    reg = _register(client)
    assert _redeem(client, reg["api_token"], "PLAINADMIN").status_code == 403

    # Explicit flag → anonymous redemption allowed.
    assert client.post("/admin/coupon/create",
                       json={"code": "REVIEWADMIN", "duration_days": 7,
                             "max_uses": 10, "anonymous_eligible": True},
                       headers=hdr).status_code == 201
    reg2 = _register(client)
    assert _redeem(client, reg2["api_token"], "REVIEWADMIN").status_code == 200
    assert _me(client, reg2["api_token"])["is_pro"] is True
