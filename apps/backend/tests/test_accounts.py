"""Tests for Apple/Google sign-in and cross-device account linking.

Apple/Google verification is overridden via app.dependency_overrides so
these tests never need real network access to appleid.apple.com or
googleapis.com (this sandbox has none) or a real signed identity token —
see Backend/social_auth.py's module docstring for why the indirection
exists.
"""

from __future__ import annotations

import pytest


def _register(client) -> dict:
    r = client.post("/v1/register", json={})
    assert r.status_code == 200, r.text
    return r.json()


def _auth_headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _override_apple(app, sub: str, email: str | None = "person@example.com"):
    import backend.social_auth as social_auth

    async def fake_verifier(_token: str):
        return social_auth.IdentityClaims(sub=sub, email=email)

    app.dependency_overrides[social_auth.get_apple_verifier] = lambda: fake_verifier


def _override_google(app, sub: str, email: str | None = "person@example.com"):
    import backend.social_auth as social_auth

    async def fake_verifier(_token: str):
        return social_auth.IdentityClaims(sub=sub, email=email)

    app.dependency_overrides[social_auth.get_google_verifier] = lambda: fake_verifier


def test_apple_signin_creates_account_and_links_device(client):
    from backend.server import app

    device = _register(client)
    _override_apple(app, sub="apple-uid-1")

    r = client.post(
        "/v1/auth/apple",
        json={"identity_token": "whatever"},
        headers=_auth_headers(device["api_token"]),
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["account_id"]
    assert body["plan"] == "free"
    assert body["is_pro"] is False
    assert body["email"] == "person@example.com"

    me = client.get("/v1/me", headers=_auth_headers(device["api_token"])).json()
    assert me["account_id"] == body["account_id"]


def test_apple_signin_twice_reuses_same_account(client):
    from backend.server import app

    device = _register(client)
    _override_apple(app, sub="apple-uid-2")

    first = client.post(
        "/v1/auth/apple", json={"identity_token": "t1"}, headers=_auth_headers(device["api_token"])
    ).json()
    second = client.post(
        "/v1/auth/apple", json={"identity_token": "t2"}, headers=_auth_headers(device["api_token"])
    ).json()

    assert first["account_id"] == second["account_id"]


def test_second_device_inherits_pro_from_shared_account(client):
    """The actual point of accounts: sign in on device A, upgrade to Pro,
    sign in on a brand-new device B with the same identity — device B is
    Pro immediately even though it never had its own subscription."""
    from backend.server import app
    from backend.store import get_store

    device_a = _register(client)
    _override_apple(app, sub="apple-uid-3")
    signin_a = client.post(
        "/v1/auth/apple", json={"identity_token": "t"}, headers=_auth_headers(device_a["api_token"])
    ).json()
    account_id = signin_a["account_id"]

    store = get_store()
    store.update_account_subscription(
        account_id=account_id,
        subscription_id="sub_123",
        status="active",
        renews_at="2027-01-01T00:00:00Z",
    )

    # Device A should now read as Pro.
    me_a = client.get("/v1/me", headers=_auth_headers(device_a["api_token"])).json()
    assert me_a["is_pro"] is True
    assert me_a["daily_limit"] == -1

    # A brand-new device, signing in with the SAME Apple identity, inherits Pro.
    device_b = _register(client)
    signin_b = client.post(
        "/v1/auth/apple", json={"identity_token": "t"}, headers=_auth_headers(device_b["api_token"])
    ).json()
    assert signin_b["account_id"] == account_id
    assert signin_b["is_pro"] is True

    me_b = client.get("/v1/me", headers=_auth_headers(device_b["api_token"])).json()
    assert me_b["is_pro"] is True
    assert me_b["daily_limit"] == -1


def test_google_signin_creates_account(client):
    from backend.server import app

    device = _register(client)
    _override_google(app, sub="google-uid-1", email="g@example.com")

    r = client.post(
        "/v1/auth/google",
        json={"id_token": "whatever"},
        headers=_auth_headers(device["api_token"]),
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["account_id"]
    assert body["email"] == "g@example.com"


def test_anonymous_device_gets_canonical_account_but_bills_like_a_device(client):
    """Build-91 §1: every device — even one that never signs in — gets a
    server-issued canonical account UUID (the entitlement principal). But an
    anonymous auto-account is NOT identified, so plan/is_pro/quota still resolve
    from the device's own fields exactly as before accounts existed."""
    import uuid as _uuid

    device = _register(client)
    # /v1/register returns the non-null account UUID.
    assert device["account_id"]
    assert _uuid.UUID(device["account_id"])  # well-formed

    me = client.get("/v1/me", headers=_auth_headers(device["api_token"])).json()
    assert me["account_id"] == device["account_id"]  # required non-null, stable
    assert me["plan"] == "free"
    assert me["is_pro"] is False


def test_auth_requires_bearer_token(client):
    r = client.post("/v1/auth/apple", json={"identity_token": "x"})
    assert r.status_code == 401


# ---------------------------------------------------------------------------
# Multi-provider linking: adding a second sign-in method to the SAME account,
# vs. the conflict case where that identity already belongs to someone else.
# ---------------------------------------------------------------------------


def test_linking_second_provider_joins_current_account_not_a_new_one(client):
    """Signed in with Apple; adding Google on the same device should attach
    Google to that SAME account ("add another way to sign in"), not create
    a second, disconnected account."""
    from backend.server import app

    device = _register(client)
    _override_apple(app, sub="apple-link-1")
    apple_signin = client.post(
        "/v1/auth/apple", json={"identity_token": "t"}, headers=_auth_headers(device["api_token"])
    ).json()

    _override_google(app, sub="google-link-1", email="person@example.com")
    google_signin = client.post(
        "/v1/auth/google",
        json={"id_token": "t", "link": True},
        headers=_auth_headers(device["api_token"]),
    ).json()

    assert google_signin["account_id"] == apple_signin["account_id"]


def test_explicit_link_of_identity_already_owned_by_different_account_conflicts(client):
    """Device Y is signed into account B. Someone explicitly tries to LINK
    (link=True — the "add another sign-in method" settings flow) an Apple
    identity that's already the primary identity of account A. This must
    be rejected, not silently merged — and device Y must stay linked to
    its original account B afterward."""
    from backend.server import app

    device_x = _register(client)
    _override_apple(app, sub="apple-owner-A")
    signin_a = client.post(
        "/v1/auth/apple", json={"identity_token": "t"}, headers=_auth_headers(device_x["api_token"])
    ).json()
    account_a_id = signin_a["account_id"]

    device_y = _register(client)
    _override_google(app, sub="google-owner-B")
    signin_b = client.post(
        "/v1/auth/google", json={"id_token": "t"}, headers=_auth_headers(device_y["api_token"])
    ).json()
    account_b_id = signin_b["account_id"]
    assert account_b_id != account_a_id

    # Device Y (account B) now tries to LINK Apple identity "apple-owner-A",
    # which already belongs to account A.
    r = client.post(
        "/v1/auth/apple",
        json={"identity_token": "t", "link": True},
        headers=_auth_headers(device_y["api_token"]),
    )
    assert r.status_code == 409

    # Device Y must still be linked to its original account B, unharmed.
    me_y = client.get("/v1/me", headers=_auth_headers(device_y["api_token"])).json()
    assert me_y["account_id"] == account_b_id


def test_plain_signin_to_a_different_existing_account_switches_without_conflict(client):
    """The default (link=False) is ordinary login, not "add to my account" —
    signing into a DIFFERENT pre-existing account (e.g. a shared computer,
    or someone logging out and back in as themselves) must just work, with
    no 409. This is what makes login "seamless regardless of device.\""""
    from backend.server import app

    device_x = _register(client)
    _override_apple(app, sub="apple-owner-C")
    signin_a = client.post(
        "/v1/auth/apple", json={"identity_token": "t"}, headers=_auth_headers(device_x["api_token"])
    ).json()
    account_a_id = signin_a["account_id"]

    device_y = _register(client)
    _override_google(app, sub="google-owner-D")
    signin_b = client.post(
        "/v1/auth/google", json={"id_token": "t"}, headers=_auth_headers(device_y["api_token"])
    ).json()
    account_b_id = signin_b["account_id"]

    # Device Y plain-signs-in (no `link`) with Apple identity "apple-owner-C" —
    # switches device Y from account B to account A. No conflict.
    r = client.post(
        "/v1/auth/apple", json={"identity_token": "t"}, headers=_auth_headers(device_y["api_token"])
    )
    assert r.status_code == 200, r.text
    assert r.json()["account_id"] == account_a_id

    me_y = client.get("/v1/me", headers=_auth_headers(device_y["api_token"])).json()
    assert me_y["account_id"] == account_a_id
    assert me_y["account_id"] != account_b_id


def test_reauth_with_same_identity_on_linked_device_is_not_a_conflict(client):
    """Idempotency check: signing in again with the identity you're already
    linked to must succeed, not 409 against yourself."""
    from backend.server import app

    device = _register(client)
    _override_apple(app, sub="apple-idempotent-1")
    first = client.post(
        "/v1/auth/apple", json={"identity_token": "t1"}, headers=_auth_headers(device["api_token"])
    )
    second = client.post(
        "/v1/auth/apple", json={"identity_token": "t2"}, headers=_auth_headers(device["api_token"])
    )
    assert first.status_code == 200
    assert second.status_code == 200
    assert first.json()["account_id"] == second.json()["account_id"]


# ---------------------------------------------------------------------------
# Pooled daily free-tier allowance across an account's linked devices.
# conftest sets FREE_DAILY_LIMIT=3 for the whole suite.
# ---------------------------------------------------------------------------


def test_free_daily_limit_pools_across_linked_devices(client):
    """Two devices signed into the SAME account share one daily allowance —
    not 3/day each, 3/day total. This is the actual point of pooling."""
    from backend.server import app

    device_a = _register(client)
    _override_apple(app, sub="apple-pool-1")
    account_id = client.post(
        "/v1/auth/apple", json={"identity_token": "t"}, headers=_auth_headers(device_a["api_token"])
    ).json()["account_id"]

    device_b = _register(client)
    client.post(
        "/v1/auth/apple", json={"identity_token": "t"}, headers=_auth_headers(device_b["api_token"])
    )
    me_b = client.get("/v1/me", headers=_auth_headers(device_b["api_token"])).json()
    assert me_b["account_id"] == account_id

    def analyze(device, text):
        return client.post(
            "/api/analyze",
            json={"text": text},
            headers=_auth_headers(device["api_token"]),
        )

    # 2 on device A, 1 on device B — that's the full pooled limit of 3.
    assert analyze(device_a, "first message").status_code == 200
    assert analyze(device_a, "second message").status_code == 200
    r3 = analyze(device_b, "third message")
    assert r3.status_code == 200
    assert r3.json()["used_today"] == 3
    assert r3.json()["daily_limit"] == 3

    # A 4th call from EITHER device is rate-limited — it's one shared pool.
    r4 = analyze(device_b, "fourth message")
    assert r4.status_code == 429
    r5 = analyze(device_a, "fifth message")
    assert r5.status_code == 429


def test_free_daily_limit_still_per_device_when_anonymous(client):
    """Unchanged pre-accounts behavior: two anonymous devices each get
    their own independent 3/day, since there's no account to pool through."""

    def analyze(device, text):
        return client.post(
            "/api/analyze",
            json={"text": text},
            headers=_auth_headers(device["api_token"]),
        )

    device_a = _register(client)
    device_b = _register(client)

    for _ in range(3):
        assert analyze(device_a, "msg").status_code == 200
    assert analyze(device_a, "one too many").status_code == 429

    # Device B's own allowance is untouched by device A's usage.
    assert analyze(device_b, "msg").status_code == 200
