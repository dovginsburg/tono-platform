"""Account continuity across surfaces — the iOS↔web split and its guardrails.

The reported live defect: a person signs in with Google on iOS, then signs in
with Google on the website and it "does not recognize the account." The cause is
structural — iOS presents a native Google identity (canonical key
``google:<google-sub>``) while the website authenticates through Supabase, so the
web identity arrives as ``supabase:<supabase-uid>``, a different subject that
steps 1–2 of ``_resolve_provider_signin`` cannot see across. Verified-email
convergence is the bridge.

These tests pin BOTH the fix and the boundaries the contract draws around it:
convergence fires only on a provider-PROVEN address, only onto a single
unambiguous account, and it ATTACHES an identity — it never fuses two populated
accounts or rewrites a subject. The verifier seams are overridden exactly as the
sibling Apple/Google/web suites do, so no network or real token is needed.
"""

from __future__ import annotations

# NB: every backend.* import lives INSIDE a function, never at module top. The
# autouse ``_isolate_db`` fixture purges and rebuilds the backend.* modules per
# test, so a module-level binding would be a STALE function object and an
# override keyed on it would miss the app's freshly-rebuilt dependency.


def _register(client) -> dict:
    r = client.post("/v1/register", json={})
    assert r.status_code == 200, r.text
    return r.json()


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _override_google(app, sub: str, email: str, verified: bool = True) -> None:
    import backend.social_auth as social_auth

    async def fake(_token: str):
        return social_auth.IdentityClaims(sub=sub, email=email, email_verified=verified)

    app.dependency_overrides[social_auth.get_google_verifier] = lambda: fake


def _override_web(app, sub: str, email: str | None, verified: bool) -> None:
    import backend.supabase_auth as supabase_auth

    async def fake(_token: str):
        return supabase_auth.SupabaseClaims(sub=sub, email=email, email_verified=verified)

    app.dependency_overrides[supabase_auth.get_supabase_verifier] = lambda: fake


# --------------------------------------------------------------------------
# The headline fix — iOS Google, then web Google, converge to ONE account.
# --------------------------------------------------------------------------


def test_ios_google_then_web_google_same_verified_email_is_one_account(client):
    from backend.server import app

    # iOS: native Google sign-in mints the canonical account.
    ios_device = _register(client)
    _override_google(app, sub="g-alice", email="alice@example.com", verified=True)
    ios = client.post(
        "/v1/auth/google", json={"id_token": "t"}, headers=_auth(ios_device["api_token"])
    )
    assert ios.status_code == 200, ios.text
    ios_account = ios.json()["account_id"]

    # Web: a fresh browser (no bearer) signs in with Google *through Supabase*,
    # so the subject is a Supabase uid — a different identity for the same human.
    _override_web(app, sub="sb-alice", email="alice@example.com", verified=True)
    web = client.post("/v1/auth/web", json={"access_token": "jwt"})
    assert web.status_code == 200, web.text

    # Convergence: the website lands on the SAME canonical account, not a second.
    assert web.json()["account_id"] == ios_account


def test_web_first_then_ios_google_also_converges(client):
    """Symmetry: a web-first person who later signs in on iOS stays one account."""
    from backend.server import app

    _override_web(app, sub="sb-bob", email="bob@example.com", verified=True)
    web = client.post("/v1/auth/web", json={"access_token": "jwt"})
    assert web.status_code == 200, web.text
    web_account = web.json()["account_id"]

    ios_device = _register(client)
    _override_google(app, sub="g-bob", email="bob@example.com", verified=True)
    ios = client.post(
        "/v1/auth/google", json={"id_token": "t"}, headers=_auth(ios_device["api_token"])
    )
    assert ios.status_code == 200, ios.text
    assert ios.json()["account_id"] == web_account


# --------------------------------------------------------------------------
# The boundaries — an unverified address must NEVER drive a merge.
# --------------------------------------------------------------------------


def test_unverified_web_email_does_not_join_the_ios_account(client):
    from backend.server import app

    ios_device = _register(client)
    _override_google(app, sub="g-carol", email="carol@example.com", verified=True)
    ios = client.post(
        "/v1/auth/google", json={"id_token": "t"}, headers=_auth(ios_device["api_token"])
    )
    ios_account = ios.json()["account_id"]

    # Same address spelling, but the web identity's email is UNVERIFIED. The
    # server drops the address and convergence must not fire.
    _override_web(app, sub="sb-carol", email="carol@example.com", verified=False)
    web = client.post("/v1/auth/web", json={"access_token": "jwt"})
    assert web.status_code == 200, web.text
    assert web.json()["account_id"] != ios_account


def test_native_google_unverified_email_does_not_converge(client):
    """A Google token whose email_verified is false cannot merge either."""
    from backend.server import app

    _override_web(app, sub="sb-dan", email="dan@example.com", verified=True)
    web = client.post("/v1/auth/web", json={"access_token": "jwt"})
    web_account = web.json()["account_id"]

    ios_device = _register(client)
    _override_google(app, sub="g-dan", email="dan@example.com", verified=False)
    ios = client.post(
        "/v1/auth/google", json={"id_token": "t"}, headers=_auth(ios_device["api_token"])
    )
    assert ios.status_code == 200, ios.text
    assert ios.json()["account_id"] != web_account


# --------------------------------------------------------------------------
# The primitive — direct unit tests of the store's convergence resolver.
# --------------------------------------------------------------------------


def test_find_verified_email_account_attaches_to_single_owner(tmp_path):
    from backend.store import Store

    store = Store(str(tmp_path / "c.sqlite"))
    acct = store.upsert_account_by_provider("google", "g1", "solo@example.com")
    # A different provider (supabase) with the same verified address → attach.
    assert store.find_verified_email_account("supabase", "sb1", "solo@example.com") == acct.id


def test_find_verified_email_account_never_rewrites_an_owned_subject(tmp_path):
    from backend.store import Store

    store = Store(str(tmp_path / "c.sqlite"))
    store.upsert_account_by_provider("google", "g1", "solo@example.com")
    # A DIFFERENT google subject for the same email must not target that account:
    # its google_sub is already taken, and convergence never overwrites one.
    assert store.find_verified_email_account("google", "g2", "solo@example.com") is None


def test_find_verified_email_account_refuses_ambiguous_address(tmp_path):
    from backend.store import Store

    store = Store(str(tmp_path / "c.sqlite"))
    # Two distinct accounts already share a verified address (e.g. a mailbox that
    # spawned a split before convergence existed). Auto-attaching to either would
    # orphan the other's history — refuse and leave it to explicit linking.
    store.upsert_account_by_provider("apple", "a1", "dup@example.com")
    store.upsert_account_by_provider("google", "g1", "dup@example.com")
    assert store.find_verified_email_account("supabase", "sb1", "dup@example.com") is None


def test_find_verified_email_account_ignores_unverified_and_empty(tmp_path):
    from backend.store import Store

    store = Store(str(tmp_path / "c.sqlite"))
    # No account at all → nothing to join.
    assert store.find_verified_email_account("supabase", "sb1", "nobody@example.com") is None
    # A malformed / empty address never resolves.
    assert store.find_verified_email_account("supabase", "sb1", None) is None
    assert store.find_verified_email_account("supabase", "sb1", "   ") is None
