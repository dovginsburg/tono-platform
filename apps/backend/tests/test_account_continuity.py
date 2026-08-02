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


# --- real Supabase verification (HS256) — for the trust-authority tests, which
# must exercise the ACTUAL _extract_claims, not an overridden verifier. -------

_HS_SECRET = "test-supabase-jwt-secret-0123456789"
_HS_ISS = "https://proj.supabase.co/auth/v1"
_HS_AUD = "authenticated"


def _configure_hs256(monkeypatch) -> None:
    monkeypatch.setenv("SUPABASE_JWT_SECRET", _HS_SECRET)
    monkeypatch.setenv("SUPABASE_ISSUER", _HS_ISS)
    monkeypatch.setenv("SUPABASE_AUD", _HS_AUD)


def _make_token(**overrides) -> str:
    import datetime as dt

    import jwt

    now = dt.datetime.now(dt.timezone.utc)
    payload = {
        "sub": "supabase-user",
        "email": "person@example.com",
        "email_verified": True,
        "aud": _HS_AUD,
        "iss": _HS_ISS,
        "iat": now,
        "exp": now + dt.timedelta(hours=1),
    }
    payload.update(overrides)
    return jwt.encode(payload, _HS_SECRET, algorithm="HS256")


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


# --------------------------------------------------------------------------
# Verification AUTHORITY — user-writable metadata must never grant verified
# status, so it can never drive convergence onto a stranger's account.
# --------------------------------------------------------------------------


def test_extract_claims_ignores_user_writable_metadata(monkeypatch):
    """The unit boundary: user_metadata is NOT verification authority."""
    import backend.supabase_auth as supabase_auth

    forged = supabase_auth._extract_claims(
        {"sub": "u", "email": "e@x.com", "user_metadata": {"email_verified": True}}
    )
    assert forged.email_verified is False, "user_metadata.email_verified must be ignored"

    # GoTrue-controlled sources ARE trusted.
    top = supabase_auth._extract_claims(
        {"sub": "u", "email": "e@x.com", "email_verified": True}
    )
    assert top.email_verified is True
    app = supabase_auth._extract_claims(
        {"sub": "u", "email": "e@x.com", "app_metadata": {"email_verified": True}}
    )
    assert app.email_verified is True

    # And user_metadata cannot even OVERRIDE an authoritative false.
    mixed = supabase_auth._extract_claims(
        {
            "sub": "u",
            "email": "e@x.com",
            "email_verified": False,
            "user_metadata": {"email_verified": True},
        }
    )
    assert mixed.email_verified is False


def test_forged_user_metadata_token_cannot_attach_to_a_strangers_account(client, monkeypatch):
    """End to end, through the REAL verifier: a token whose verified flag lives
    only in user-writable user_metadata cannot converge onto someone else's
    account — the account-takeover this defense-in-depth patch closes."""
    from backend.server import app

    # Victim: a native Google account with a verified address and NO supabase
    # identity yet — exactly the attachable target convergence looks for.
    victim_device = _register(client)
    _override_google(app, sub="g-victim", email="victim@example.com", verified=True)
    victim = client.post(
        "/v1/auth/google", json={"id_token": "t"}, headers=_auth(victim_device["api_token"])
    )
    victim_account = victim.json()["account_id"]

    # Attacker: a genuinely-signed Supabase token (real HS256 verification), but
    # its email_verified is asserted ONLY in user_metadata — the forgeable field.
    # GoTrue's top-level claim says the address is NOT confirmed.
    _configure_hs256(monkeypatch)
    token = _make_token(
        sub="sb-attacker",
        email="victim@example.com",
        email_verified=False,
        user_metadata={"email_verified": True},
    )
    attacker = client.post("/v1/auth/web", json={"access_token": token})
    assert attacker.status_code == 200, attacker.text
    # No attach: the attacker lands on their OWN account, never the victim's.
    assert attacker.json()["account_id"] != victim_account


def test_confirmed_web_email_does_attach_through_the_real_verifier(client, monkeypatch):
    """The positive control: an authoritatively-confirmed address (GoTrue
    top-level claim) DOES converge — the fix does not over-rotate into blocking
    legitimate continuity."""
    from backend.server import app

    victim_device = _register(client)
    _override_google(app, sub="g-real", email="real@example.com", verified=True)
    ios = client.post(
        "/v1/auth/google", json={"id_token": "t"}, headers=_auth(victim_device["api_token"])
    )
    ios_account = ios.json()["account_id"]

    _configure_hs256(monkeypatch)
    token = _make_token(sub="sb-real", email="real@example.com", email_verified=True)
    web = client.post("/v1/auth/web", json={"access_token": token})
    assert web.status_code == 200, web.text
    assert web.json()["account_id"] == ios_account


def test_email_password_login_threads_verification_and_converges(client, monkeypatch):
    """A verified email/password sign-in joins the person's existing canonical
    account — the resolver now receives its authoritative verified status."""
    from backend.server import app
    import backend.email_auth as email_auth

    # Existing account for this person, created natively (verified, no supabase sub).
    ios_device = _register(client)
    _override_google(app, sub="g-pw", email="pw@example.com", verified=True)
    ios = client.post(
        "/v1/auth/google", json={"id_token": "t"}, headers=_auth(ios_device["api_token"])
    )
    ios_account = ios.json()["account_id"]

    # Email/password login: the provider client is stubbed to accept the
    # credentials and hand back a session; the REAL token verifier then confirms
    # the GoTrue-controlled verified claim (gate 2). Both gates pass → convergence.
    _configure_hs256(monkeypatch)
    session_token = _make_token(sub="sb-pw", email="pw@example.com", email_verified=True)

    class _StubSession:
        access_token = session_token

    async def _sign_in(*, email: str, password: str):
        return _StubSession()

    class _StubClient:
        sign_in = staticmethod(_sign_in)

    app.dependency_overrides[email_auth.get_email_auth_client] = lambda: _StubClient()

    resp = client.post(
        "/v1/auth/email/login",
        json={"email": "pw@example.com", "password": "correct-horse-battery"},
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["account_id"] == ios_account
