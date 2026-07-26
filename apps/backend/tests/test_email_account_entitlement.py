"""Build 114 — the account path where it touches money, and the mutations that
would quietly break it.

`test_email_accounts.py` proves the registration lifecycle. This file proves the
three things that cost a person money or access when they regress:

  1. the purchase principal is the canonical account UUID, and an email login
     converges on exactly that UUID — so a subscription follows the person
     across a reinstall, a second device, and a platform;
  2. signing in REFRESHES the entitlement the account already owns, which is how
     a same-account 402 resolves without a second purchase;
  3. an operational failure (expired link, outage, dead transport) is never
     dressed up as delivery, and a sign-out is actually a sign-out.

The last section is deliberately different in kind. Every test there installs
the REVERTED implementation — the plausible wrong version, or the pre-Build-114
one — and asserts that the guarantee measurably breaks. That is what makes the
rest of this suite red-capable rather than decorative: if a guard is load
bearing, removing it has to be observable.

Nothing here reaches a network. The Apple signing chain is the local fixture
`test_mobile_billing` already establishes, and the auth provider boundary is the
same fake `test_email_accounts` uses.
"""

from __future__ import annotations

import uuid

import pytest

# Reuse the local Apple signing chain + the production library verifier pointed
# at it. Imported as a fixture, so the entitlement assertions below run against
# the real verification path rather than a stub of it.
from .test_mobile_billing import apple  # noqa: F401
from .test_email_accounts import (  # noqa: F401
    FakeEmailAuth,
    PASSWORD,
    _click_verification_link,
    _headers,
    _register_device,
    _wire,
    fake_auth,
)


def _sync_apple(client, token: str, jws: str):
    return client.post(
        "/v1/app-store/subscription",
        json={"signed_transaction_info": jws},
        headers=_headers(token),
    )


def _coach(client, token: str):
    """The gated private surface. 402 = entitlement required, 200 = allowed."""
    return client.post(
        "/api/analyze/variant",
        json={"text": "could you take a look at this when you get a chance", "axis": "warmer"},
        headers=_headers(token),
    )


def _signup_and_verify(client, fake, email: str, *, token: str | None = None) -> dict:
    """Register, open the emailed link for real, then sign in.

    Every entitlement assertion in this file runs through here, so the step in
    the middle decides what they are worth. It used to be `fake.confirm(email)`
    alone — the provider's half of a verification and none of the product's —
    which meant the account these tests asserted about was never the account a
    real person ends up on. `_click_verification_link` performs the bearer-less
    browser exchange the emailed link actually triggers, so a purchase bound
    before registration is measured against the account that really carries it.
    """
    headers = _headers(token) if token else {}
    r = client.post(
        "/v1/auth/email/register",
        json={
            "email": email,
            "password": PASSWORD,
            "source_surface": "ios",
            "app_version": "114",
        },
        headers=headers,
    )
    assert r.status_code == 202, r.text
    _click_verification_link(client, fake, email)
    r = client.post(
        "/v1/auth/email/login",
        json={
            "email": email,
            "password": PASSWORD,
            "source_surface": "ios",
            "app_version": "114",
        },
        headers=headers,
    )
    assert r.status_code == 200, r.text
    return r.json()


# ---------------------------------------------------------------------------
# The purchase principal is the canonical person, and email login lands on it
# ---------------------------------------------------------------------------


def test_purchase_binds_the_canonical_account_an_email_login_resolves(
    client, fake_auth, apple
):
    """The whole point of requiring a confirmed address before buying.

    A purchase binds `appAccountToken` to the canonical account UUID. If an email
    login resolved to any OTHER account, that binding would be unreachable and
    the person would have to buy the subscription again. So this asserts the two
    halves meet: the UUID the purchase was bound to is the UUID the login
    returns.
    """
    device = _register_device(client)
    session = _signup_and_verify(client, fake_auth, "buyer@example.com", token=device["api_token"])
    account_id = session["account_id"]

    # Not Pro yet — a confirmed address is not a purchase.
    assert session["is_pro"] is False

    # Apple confirms a subscription whose ownership token IS the canonical UUID.
    assert _sync_apple(
        client, session["api_token"], apple.sign_transaction(appAccountToken=account_id)
    ).status_code == 200

    me = client.get("/v1/me", headers=_headers(session["api_token"])).json()
    assert me["is_pro"] is True
    assert me["account_id"] == account_id
    # And the account-path projection is truthful about the identity alongside it.
    assert me["email"] == "buyer@example.com"
    assert me["email_verified_at"] is not None
    assert me["lifecycle_state"] == "verified"
    assert _coach(client, session["api_token"]).status_code == 200


def test_a_purchase_bound_to_a_device_id_is_refused_as_evidence(client, fake_auth, apple):
    """A device id is not a person.

    Build 91 established that the entitlement principal is the account UUID.
    Build 114 must not weaken it: an email account makes the UUID recoverable,
    which only matters if the UUID is what purchases actually bind to.
    """
    device = _register_device(client)
    session = _signup_and_verify(client, fake_auth, "wrongtoken@example.com", token=device["api_token"])

    r = _sync_apple(
        client, session["api_token"], apple.sign_transaction(appAccountToken=device["device_id"])
    )
    # Refused, and the refusal names the real reason: the token points at
    # something that is not this caller's canonical account.
    assert r.status_code == 409, r.text
    assert "different account" in r.json()["error"]["message"]
    assert client.get("/v1/me", headers=_headers(session["api_token"])).json()["is_pro"] is False


# ---------------------------------------------------------------------------
# Login refreshes the account's entitlement — the same-account 402
# ---------------------------------------------------------------------------


def test_login_resolves_a_same_account_402_without_a_second_purchase(
    client, fake_auth, apple
):
    """The reinstall case, end to end.

    A person subscribes on one install. The app is removed, so the device-local
    account UUID is gone. The fresh install registers as a NEW anonymous device
    and is correctly refused (402) — it has no entitlement of its own. Signing in
    must converge that device onto the original canonical account and return the
    entitlement it already owns, in the login response itself, with no restore
    tap and no second purchase.
    """
    first_install = _register_device(client)
    session = _signup_and_verify(
        client, fake_auth, "returning@example.com", token=first_install["api_token"]
    )
    account_id = session["account_id"]
    assert _sync_apple(
        client, session["api_token"], apple.sign_transaction(appAccountToken=account_id)
    ).status_code == 200
    assert _coach(client, session["api_token"]).status_code == 200

    # A fresh install: new device, new anonymous account, no entitlement.
    reinstall = _register_device(client)
    assert reinstall["account_id"] != account_id
    assert _coach(client, reinstall["api_token"]).status_code == 402

    # Signing in must fix it in ONE call.
    r = client.post(
        "/v1/auth/email/login",
        json={"email": "returning@example.com", "password": PASSWORD},
        headers=_headers(reinstall["api_token"]),
    )
    assert r.status_code == 200, r.text
    recovered = r.json()
    assert recovered["account_id"] == account_id, "the login must land on the SAME person"
    # The refresh is in the login response, not something the client has to
    # discover on a later poll.
    assert recovered["is_pro"] is True

    # And the login response agrees with `/v1/me` exactly. That equality is the
    # real invariant: `is_pro` is the entitlement answer, and both surfaces must
    # compute it through the one projection. `plan` legitimately stays "free"
    # for an Apple/Play subscriber — a provider entitlement attaches as a GRANT
    # rather than by rewriting the account's plan column — so pinning `plan`
    # here would pin the wrong thing.
    me = client.get("/v1/me", headers=_headers(recovered["api_token"])).json()
    assert (recovered["is_pro"], recovered["plan"]) == (me["is_pro"], me["plan"])

    # And the 402 is gone for this device.
    assert _coach(client, recovered["api_token"]).status_code == 200


def test_a_second_device_shares_the_entitlement_without_re_purchasing(
    client, fake_auth, apple
):
    """Second device, same person. Both bearers must be Pro at once."""
    phone = _register_device(client)
    session = _signup_and_verify(client, fake_auth, "twodevices@example.com", token=phone["api_token"])
    assert _sync_apple(
        client, session["api_token"], apple.sign_transaction(appAccountToken=session["account_id"])
    ).status_code == 200

    tablet = _register_device(client)
    assert _coach(client, tablet["api_token"]).status_code == 402
    second = client.post(
        "/v1/auth/email/login",
        json={"email": "twodevices@example.com", "password": PASSWORD},
        headers=_headers(tablet["api_token"]),
    ).json()

    assert second["account_id"] == session["account_id"]
    assert second["is_pro"] is True
    # The first device did not lose anything by the second signing in.
    assert client.get("/v1/me", headers=_headers(session["api_token"])).json()["is_pro"] is True
    assert _coach(client, second["api_token"]).status_code == 200


def test_login_never_invents_an_entitlement_the_account_does_not_have(client, fake_auth):
    """The other direction. Refreshing must report the truth, including "no"."""
    device = _register_device(client)
    session = _signup_and_verify(client, fake_auth, "notpaying@example.com", token=device["api_token"])
    assert session["is_pro"] is False
    assert session["plan"] == "free"

    again = client.post(
        "/v1/auth/email/login",
        json={"email": "notpaying@example.com", "password": PASSWORD},
        headers=_headers(session["api_token"]),
    ).json()
    assert again["is_pro"] is False
    assert _coach(client, again["api_token"]).status_code == 402


# ---------------------------------------------------------------------------
# Expired link, outage, dead transport
# ---------------------------------------------------------------------------


def test_an_expired_link_is_a_next_step_not_a_dead_end(client, fake_auth):
    """A person who let the link expire must be able to get another one.

    Modelled the way it actually happens: the address is registered but still
    unconfirmed, so a login is refused with the verification signal, and a
    resend is accepted. Nothing about the refusal reveals whether the address
    exists, and nothing about it is terminal.
    """
    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={"email": "expired@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )

    # The link expired unopened: still unconfirmed.
    r = client.post(
        "/v1/auth/email/login",
        json={"email": "expired@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )
    assert r.status_code == 403
    assert r.json()["error"]["message"] == "email_verification_required"

    # A new link is accepted, and answered with the same shape an unknown
    # address gets.
    r = client.post("/v1/auth/email/resend", json={"email": "expired@example.com"})
    assert r.status_code == 202
    assert r.json() == {"status": "verification_pending"}
    assert ("resend", "expired@example.com") in fake_auth.sent

    # Opening the new one works, and the account is the SAME one the pending
    # registration was bound to.
    fake_auth.confirm("expired@example.com")
    session = client.post(
        "/v1/auth/email/login",
        json={"email": "expired@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    ).json()
    assert session["account_id"] == device["account_id"]
    assert session["email_verified"] is True

    # The whole detour is auditable.
    events = client.get(
        "/v1/account/registration-events", headers=_headers(session["api_token"])
    ).json()
    kinds = [e["event_type"] for e in events["events"]]
    assert "signup_requested" in kinds
    assert "verification_completed" in kinds
    assert events["lifecycle_state"] == "verified"


@pytest.mark.parametrize(
    "path,body",
    [
        ("/v1/auth/email/register", {"email": "down@example.com", "password": PASSWORD}),
        ("/v1/auth/email/resend", {"email": "down@example.com"}),
        ("/v1/auth/email/reset", {"email": "down@example.com"}),
        ("/v1/auth/email/login", {"email": "down@example.com", "password": PASSWORD}),
    ],
)
def test_an_outage_is_never_answered_as_delivery(client, fake_auth, path, body):
    """503, never 202.

    The worst possible answer to an outage is "check your email": the person
    waits for mail that will never arrive and blames their own inbox. There must
    be no branch anywhere that turns an operational failure into the accepted
    shape.
    """
    import backend.email_auth as email_auth

    fake_auth.fail_with = email_auth.EmailAuthOutcome.PROVIDER_UNAVAILABLE
    r = client.post(path, json=body)
    assert r.status_code == 503, (path, r.status_code, r.text)
    assert r.json() != {"status": "verification_pending"}
    # And nothing was recorded as sent.
    assert fake_auth.sent == []


def test_a_dead_transport_is_an_outage_and_leaks_no_host(monkeypatch):
    """A transport failure must not carry the project host into a caller.

    `httpx` puts the request URL in its exception text, so the client swallows
    the exception rather than chaining it. This asserts both halves: the outcome
    is PROVIDER_UNAVAILABLE, and the raised object holds no provider text at all.
    """
    import httpx

    import backend.email_auth as email_auth

    class DeadTransport:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

        async def post(self, *a, **kw):
            raise httpx.ConnectError("failed to connect to secret-project.supabase.co")

    monkeypatch.setattr(email_auth.httpx, "AsyncClient", lambda **kw: DeadTransport())

    provider = email_auth.SupabaseEmailAuthClient("https://secret-project.supabase.co", "k")
    with pytest.raises(email_auth.EmailAuthError) as raised:
        import asyncio

        asyncio.get_event_loop_policy().new_event_loop().run_until_complete(
            provider.sign_in(email="person@example.com", password=PASSWORD)
        )
    assert raised.value.outcome is email_auth.EmailAuthOutcome.PROVIDER_UNAVAILABLE
    # The exception is the ONLY thing a caller receives, and it names no host,
    # no address, and no password.
    text = str(raised.value) + repr(raised.value.args)
    for secret in ("supabase.co", "secret-project", "person@example.com", PASSWORD):
        assert secret not in text, f"{secret} leaked into the raised failure"


def test_rate_limiting_is_per_address_not_only_per_ip(client, fake_auth):
    """A per-address bound is what makes brute force expensive.

    A per-IP limit alone is defeated by rotating addresses; a per-address limit
    alone is defeated by rotating IPs. Both exist, and a 429 must stay a 429 —
    never a credential failure and never a paywall.
    """
    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={"email": "bruteforce@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )
    fake_auth.confirm("bruteforce@example.com")

    saw_429 = False
    for _ in range(40):
        r = client.post(
            "/v1/auth/email/login",
            json={"email": "bruteforce@example.com", "password": "wrong-guess"},
        )
        assert r.status_code in (401, 429), r.status_code
        if r.status_code == 429:
            saw_429 = True
            assert "Retry-After" in r.headers
            message = r.json()["error"]["message"].lower()
            for paywall_word in ("subscription", "subscribe", "trial", "upgrade"):
                assert paywall_word not in message, message
            assert "password" not in message, message
            break
    assert saw_429, "repeated wrong passwords for one address must eventually be bounded"


# ---------------------------------------------------------------------------
# Sign-out
# ---------------------------------------------------------------------------


def test_sign_out_cannot_be_undone_by_a_silent_re_registration(client, fake_auth, apple):
    """A sign-out that the next launch reverses is not a sign-out.

    A device keeps a durable `device_credential` so it can re-register itself
    after losing its token — right for a reinstall, wrong for a sign-out. If the
    credential survived, the very next `/v1/register` would hand this device a
    working bearer for the account it just left. On a shared phone that is a
    real leak, so this asserts the whole chain: old bearer dead, credential
    dead, and a re-registration lands somewhere else.
    """
    device = _register_device(client)
    session = _signup_and_verify(client, fake_auth, "sharedphone@example.com", token=device["api_token"])
    account_id = session["account_id"]
    assert _sync_apple(
        client, session["api_token"], apple.sign_transaction(appAccountToken=account_id)
    ).status_code == 200

    r = client.post("/v1/auth/email/logout", headers=_headers(session["api_token"]))
    assert r.status_code == 200
    assert r.json() == {"signed_out": True}

    # 1. The bearer that was just used is dead.
    assert client.get("/v1/me", headers=_headers(session["api_token"])).status_code == 401

    # 2. Replaying the OLD device id with its old credential is refused
    #    outright — the credential hash is gone, so there is no proof left to
    #    present and the device cannot re-enter the row it was signed out of.
    replay = client.post(
        "/v1/register",
        json={
            "device_id": session["device_id"],
            "device_credential": device.get("device_credential"),
        },
    )
    assert replay.status_code == 409, replay.text
    assert "recovery proof" in replay.json()["error"]["message"]

    # 3. What the app actually does after signing out (it drops its local device
    #    identity too) lands on a NEW anonymous account with no entitlement.
    again = client.post("/v1/register", json={})
    assert again.status_code == 200, again.text
    fresh = again.json()
    assert fresh["account_id"] != account_id, (
        "a signed-out device must not come back on the account it left"
    )
    assert fresh["is_pro"] is False
    assert _coach(client, fresh["api_token"]).status_code == 402

    # 4. Signing back in returns the SAME person, with the entitlement intact.
    back = client.post(
        "/v1/auth/email/login",
        json={"email": "sharedphone@example.com", "password": PASSWORD},
        headers=_headers(fresh["api_token"]),
    ).json()
    assert back["account_id"] == account_id
    assert back["is_pro"] is True

    # 5. Both the leaving and the returning are on the ledger.
    events = client.get(
        "/v1/account/registration-events", headers=_headers(back["api_token"])
    ).json()
    kinds = [e["event_type"] for e in events["events"]]
    assert "sign_out" in kinds
    assert kinds.count("sign_in") >= 2


def test_sign_out_never_touches_the_account_or_its_history(client, fake_auth):
    """Sign-out is device-scoped. Deletion is the account-scoped act, and the two
    must not be confused: a person signing out of a borrowed phone has not asked
    to lose anything."""
    device = _register_device(client)
    session = _signup_and_verify(client, fake_auth, "keepme@example.com", token=device["api_token"])
    before = client.get(
        "/v1/account/registration-events", headers=_headers(session["api_token"])
    ).json()

    client.post("/v1/auth/email/logout", headers=_headers(session["api_token"]))

    from backend.store import get_store

    account = get_store().get_account(session["account_id"])
    assert account is not None
    assert account.deleted_at is None, "sign-out must not tombstone the account"
    assert account.email == "keepme@example.com", "the proven identity must survive"
    assert account.email_is_verified is True
    # The audit trail is append-only: everything from before is still there.
    after = get_store().list_registration_events(session["account_id"])
    assert len(after) >= len(before["events"])


# ---------------------------------------------------------------------------
# The web surface writes to the SAME ledger
# ---------------------------------------------------------------------------


def test_a_web_sign_in_is_recorded_on_the_one_registration_ledger(client):
    """"Tono tracks registrations" has to mean all of them.

    Before Build 114 only the native email path wrote a registration row, so the
    entire web population was invisible to the ledger a support question or a
    growth number is read from. A web sign-in now records the same events, tagged
    with the surface it came from.
    """
    import backend.supabase_auth as supabase_auth
    from backend.server import app

    async def verifier(token: str):
        assert token == "web-token"
        return supabase_auth.SupabaseClaims(
            sub="supabase-web-subject", email="browser@example.com", email_verified=True
        )

    app.dependency_overrides[supabase_auth.get_supabase_verifier] = lambda: verifier
    try:
        r = client.post(
            "/v1/auth/web", json={"access_token": "web-token", "app_version": "web-114"}
        )
        assert r.status_code == 200, r.text
        session = r.json()

        events = client.get(
            "/v1/account/registration-events", headers=_headers(session["api_token"])
        ).json()
        assert events["lifecycle_state"] == "verified"
        assert events["email_verified"] is True
        surfaces = {e["source_surface"] for e in events["events"]}
        assert surfaces == {"web"}, surfaces
        assert {e["app_build"] for e in events["events"]} == {"web-114"}
        assert "sign_in" in [e["event_type"] for e in events["events"]]
        # No secret rides along on an event row.
        for event in events["events"]:
            assert "browser@example.com" not in str(event)
    finally:
        app.dependency_overrides.pop(supabase_auth.get_supabase_verifier, None)


def test_a_web_sign_in_and_an_email_login_are_the_same_person(client, fake_auth):
    """One address, one provider subject, one canonical account — whichever
    surface the person arrives on."""
    import backend.supabase_auth as supabase_auth
    from backend.server import app

    device = _register_device(client)
    session = _signup_and_verify(client, fake_auth, "everywhere@example.com", token=device["api_token"])

    # The website forwards a token for the SAME provider subject the email login
    # resolved (that is what `_wire`'s default `subject_for` produces).
    async def verifier(token: str):
        return supabase_auth.SupabaseClaims(
            sub="sub-for:everywhere@example.com",
            email="everywhere@example.com",
            email_verified=True,
        )

    app.dependency_overrides[supabase_auth.get_supabase_verifier] = lambda: verifier
    try:
        web = client.post("/v1/auth/web", json={"access_token": "anything"}).json()
        assert web["account_id"] == session["account_id"]
    finally:
        app.dependency_overrides.pop(supabase_auth.get_supabase_verifier, None)


# ---------------------------------------------------------------------------
# Rollback / mutation — proof the guards above are load bearing
# ---------------------------------------------------------------------------
#
# Each test installs the reverted implementation and asserts the guarantee
# measurably breaks. If a mutation here stopped being observable, the
# corresponding guard would have become decoration.


def test_mutation_stripping_plus_tags_hands_one_persons_account_to_another(
    client, monkeypatch
):
    """The silent-merge vector, demonstrated.

    `normalize_email` preserves `+` tags and dots on purpose. The "helpful"
    mutation — canonicalize them away — makes `victim+attacker@example.com` and
    `victim@example.com` the same key, so the attacker's verification claims the
    victim's registration.

    Under the real rule the two addresses are two identities. Under the mutant
    they collide. Both halves are asserted, so this fails if either the rule or
    the collision check is weakened.
    """
    import backend.email_identity as email_identity
    from backend.store import get_store

    store = get_store()

    # Under the shipped rule: two distinct mailboxes, two distinct accounts.
    victim = store.upsert_account_by_provider("supabase", "victim-sub", "victim@example.com")
    store.mark_email_verified(account_id=victim.id, email="victim@example.com")
    attacker = store.upsert_account_by_provider(
        "supabase", "attacker-sub", None
    )
    store.mark_email_verified(
        account_id=attacker.id, email="victim+attacker@example.com"
    )
    assert attacker.id != victim.id
    assert (
        store.get_account(victim.id).email_normalized
        != store.get_account(attacker.id).email_normalized
    ), "the shipped rule must keep a +tag address distinct"

    # Now the mutant. A third party registering a tagged form of an address that
    # is already verified must be REFUSED rather than merged — and it is only
    # refused because the collision check exists.
    def stripping_normalize(raw):
        if raw is None:
            raise email_identity.EmailNormalizationError("empty")
        local, _, domain = raw.strip().rpartition("@")
        if not local or not domain:
            raise email_identity.EmailNormalizationError("not an address")
        return f"{local.split('+')[0].replace('.', '').lower()}@{domain.lower()}"

    monkeypatch.setattr(email_identity, "normalize_email", stripping_normalize)

    third = store.upsert_account_by_provider("supabase", "third-sub", None)
    from backend.store import AccountConflictError

    with pytest.raises(AccountConflictError):
        # Under the mutant this normalizes onto the victim's key. The database
        # invariant is what stops it becoming a merge.
        store.mark_email_verified(
            account_id=third.id, email="victim+someone-else@example.com"
        )


def test_mutation_a_non_monotonic_state_machine_lets_a_client_unverify_an_account(
    client, fake_auth, monkeypatch
):
    """`next_state` refuses to walk `verified` back to `pending`.

    Without that, anyone holding a device bearer could un-verify the account they
    are signed into by replaying a signup event — and an un-verified account
    cannot buy, so this is a denial of the thing the person is paying for.
    """
    import backend.email_identity as email_identity
    from backend.store import get_store

    device = _register_device(client)
    session = _signup_and_verify(client, fake_auth, "monotonic@example.com", token=device["api_token"])
    store = get_store()

    # Shipped behaviour: replaying signup against a verified registration is an
    # audit fact, not a downgrade.
    store.record_registration_event(
        account_id=session["account_id"],
        event_type=email_identity.EVENT_SIGNUP_REQUESTED,
    )
    assert store.get_registration(session["account_id"])["lifecycle_state"] == "verified"

    # The mutant: a plain transition table with no monotonicity guard.
    def naive_next_state(current, event):
        return {
            email_identity.EVENT_SIGNUP_REQUESTED: email_identity.STATE_PENDING,
            email_identity.EVENT_VERIFICATION_COMPLETED: email_identity.STATE_VERIFIED,
        }.get(event, current or email_identity.STATE_PENDING)

    monkeypatch.setattr(email_identity, "next_state", naive_next_state)
    store.record_registration_event(
        account_id=session["account_id"],
        event_type=email_identity.EVENT_SIGNUP_REQUESTED,
    )
    assert store.get_registration(session["account_id"])["lifecycle_state"] == "pending", (
        "the mutation must be observable — otherwise the monotonicity guard is "
        "not what is protecting the account"
    )


def test_mutation_an_open_event_vocabulary_lets_a_client_write_free_text(client, fake_auth):
    """The event vocabulary is closed so a client can never put a token, an
    address, or a payload into the audit trail. This asserts the closure is
    enforced at the store, not merely documented."""
    from backend.store import get_store

    device = _register_device(client)
    session = _signup_and_verify(client, fake_auth, "vocab@example.com", token=device["api_token"])
    store = get_store()

    for forged in (
        "password=hunter2",
        "verification_token=abc",
        "arbitrary free text",
        "",
    ):
        with pytest.raises(ValueError):
            store.record_registration_event(
                account_id=session["account_id"], event_type=forged
            )

    # Nothing was written.
    kinds = {e["event_type"] for e in store.list_registration_events(session["account_id"])}
    assert kinds <= set(__import__("backend.email_identity", fromlist=["x"]).EVENT_TYPES)


def test_mutation_a_rotate_only_sign_out_leaves_the_device_able_to_return(
    client, fake_auth, monkeypatch
):
    """The pre-Build-114 sign-out, restored, is observably not a sign-out.

    `rotate_token` alone leaves the device credential intact, so a re-register
    walks straight back into the account. Installing that version has to break
    `test_sign_out_cannot_be_undone_by_a_silent_re_registration`'s guarantee —
    and it does.
    """
    from backend.store import Store, get_store

    device = _register_device(client)
    session = _signup_and_verify(client, fake_auth, "rotateonly@example.com", token=device["api_token"])
    account_id = session["account_id"]

    # The mutant: sign-out becomes a bare token rotation.
    monkeypatch.setattr(
        Store, "sign_out_device", lambda self, device_id: bool(self.rotate_token(device_id))
    )
    assert client.post(
        "/v1/auth/email/logout", headers=_headers(session["api_token"])
    ).status_code == 200

    back_in = client.post(
        "/v1/register",
        json={
            "device_id": session["device_id"],
            "device_credential": device.get("device_credential"),
        },
    )
    assert back_in.status_code == 200, back_in.text
    assert back_in.json()["account_id"] == account_id, (
        "the mutation must be observable — a rotate-only sign-out lets the next "
        "person on this device walk back into the account"
    )


def test_mutation_writing_email_before_verification_would_open_private_surfaces(
    client, fake_auth
):
    """`begin_email_registration` writes only `email_normalized`, never `email`.

    `email` means "proven", and `is_identified` reads it. Writing it at
    registration time would mark an unproven account as identified — which is how
    an unconfirmed device would be allowed to bind a purchase.
    """
    from backend.store import get_store

    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={"email": "unproven@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )
    store = get_store()
    account = store.get_account(device["account_id"])

    assert account.email is None, "a pending registration must not claim a proven address"
    assert account.email_normalized == "unproven@example.com", "but must be findable"
    assert account.email_verified_at is None
    assert account.is_identified is False
    assert account.lifecycle_state == "pending"

    # The mutation would be to set `email` here. Demonstrate what it would buy:
    # writing it flips `is_identified`, which is the gate everything private
    # hangs off.
    from backend.store import Account

    mutated = Account(**{**account.__dict__, "email": "unproven@example.com"})
    assert mutated.is_identified is True, (
        "the mutation must be observable — `email` is exactly what makes an "
        "account identified, which is why an unproven one must not carry it"
    )


def test_mutation_an_enumerating_register_would_reveal_a_known_address(client, fake_auth):
    """Register answers identically for a fresh and an already-taken address.

    The mutation is the natural one: let the provider's 4xx through. This asserts
    the two responses are byte-identical, so any divergence — status, body, or
    header shape — turns red.
    """
    first = client.post(
        "/v1/auth/email/register",
        json={"email": "taken@example.com", "password": PASSWORD},
    )
    assert first.status_code == 202

    # Same address again: the provider raises "already registered" internally.
    second = client.post(
        "/v1/auth/email/register",
        json={"email": "taken@example.com", "password": PASSWORD},
    )
    fresh = client.post(
        "/v1/auth/email/register",
        json={"email": f"fresh-{uuid.uuid4().hex}@example.com", "password": PASSWORD},
    )

    assert second.status_code == fresh.status_code == 202
    assert second.json() == fresh.json() == {"status": "verification_pending"}
    # Not just equal bodies — nothing in the response distinguishes them.
    assert second.content == fresh.content


# ---------------------------------------------------------------------------
# The website is the same person, with the same entitlement
# ---------------------------------------------------------------------------


def test_signing_in_on_the_web_reports_the_subscription_the_person_owns(
    client, fake_auth, apple
):
    """`auth_web` must project entitlement exactly as the native login does.

    It returned `account.is_pro`, which reads plan/subscription/coupon and
    misses a provider ENTITLEMENT GRANT entirely — so an App Store or Play
    subscriber signing in on tonoit.com was told they were not Pro. The website
    writes that answer into its plan cookie, so they landed in the editor
    looking at a paywall for a subscription they were already paying for.
    """
    device = _register_device(client)
    session = _signup_and_verify(client, fake_auth, "webpro@example.com", token=device["api_token"])
    account_id = session["account_id"]
    assert _sync_apple(
        client, session["api_token"], apple.sign_transaction(appAccountToken=account_id)
    ).status_code == 200

    me = client.get("/v1/me", headers=_headers(session["api_token"])).json()
    assert me["is_pro"] is True, f"fixture wrong: {me}"

    # The same person opens the website.
    web = client.post(
        "/v1/auth/web",
        json={"access_token": "token-for:webpro@example.com", "app_version": "web-114"},
    )
    assert web.status_code == 200, web.text
    body = web.json()
    assert body["account_id"] == account_id
    assert body["is_pro"] is True, "a paying subscriber was shown the paywall on the web"
    assert body["plan"] == me["plan"]


def test_verification_on_the_web_still_never_grants_pro(client, fake_auth):
    """The sibling guarantee: the fix must project truth, not optimism."""
    client.post(
        "/v1/auth/email/register",
        json={"email": "webfree@example.com", "password": PASSWORD},
    )
    web = _click_verification_link(client, fake_auth, "webfree@example.com")
    assert web["is_pro"] is False
    assert web["plan"] == "free"


# ---------------------------------------------------------------------------
# A signed-out device is retired, not bricked
# ---------------------------------------------------------------------------


def test_a_signed_out_device_that_kept_only_its_id_can_start_over(client, fake_auth):
    """Sign-out destroys the credential and rotates the bearer, so neither proof
    can ever succeed against that row again. Answering 409 forever left the
    device with no action available to it and the row stranded permanently.

    Starting over is safe because the row holds nothing: sign-out unlinked the
    account, and the history and entitlement stayed on the canonical account.
    So this hands back exactly what registering with no device id at all would.
    """
    device = _register_device(client)
    session = _signup_and_verify(client, fake_auth, "retired@example.com", token=device["api_token"])
    account_id = session["account_id"]

    assert client.post(
        "/v1/auth/email/logout", headers=_headers(session["api_token"])
    ).status_code == 200

    again = client.post("/v1/register", json={"device_id": session["device_id"]})
    assert again.status_code == 200, again.text
    fresh = again.json()
    assert fresh["account_id"] != account_id, "came back on the account it left"
    assert fresh["is_pro"] is False
    assert _coach(client, fresh["api_token"]).status_code == 402

    # And the person can still sign back in to the account that owns the money.
    back = client.post(
        "/v1/auth/email/login",
        json={"email": "retired@example.com", "password": PASSWORD},
        headers=_headers(fresh["api_token"]),
    ).json()
    assert back["account_id"] == account_id


def test_a_stale_credential_is_still_refused_after_sign_out(client, fake_auth):
    """Re-issuing a retired slot must not become a way back in with an old secret.

    The distinction is deliberate: presenting no proof is "this device is
    starting over"; presenting the credential from before the sign-out is "I
    still hold the secret and want back in", and on a shared phone that must
    keep its outright refusal even though what it would receive is empty.
    """
    device = _register_device(client)
    session = _signup_and_verify(client, fake_auth, "shared2@example.com", token=device["api_token"])
    assert client.post(
        "/v1/auth/email/logout", headers=_headers(session["api_token"])
    ).status_code == 200

    replay = client.post(
        "/v1/register",
        json={
            "device_id": session["device_id"],
            "device_credential": device.get("device_credential"),
        },
    )
    assert replay.status_code == 409, replay.text
    assert "recovery proof" in replay.json()["error"]["message"]


def test_mutation_without_the_pre_verification_claim_the_click_orphans_the_account(
    client, fake_auth, apple, monkeypatch
):
    """Install the pre-remediation behaviour and watch the guarantee break.

    The whole anonymous upgrade rests on ONE lookup: the browser that opens the
    emailed link has no device bearer, so the only way it can be resolved to the
    person who started the registration is the provider-subject claim recorded
    before verification. Take that lookup away — return None, exactly as a store
    with no claim recorded would — and the browser mints a second canonical
    account, the later app login lands on it, and the subscription bought
    beforehand is stranded on an account nothing points at any more.

    This is what makes the tests above load bearing rather than decorative: the
    guarantee they assert has a single mechanism, and removing it is observable.
    """
    from backend.store import Store

    device = _register_device(client)
    anonymous_account = device["account_id"]
    assert _sync_apple(
        client, device["api_token"], apple.sign_transaction(appAccountToken=anonymous_account)
    ).status_code == 200
    assert client.get("/v1/me", headers=_headers(device["api_token"])).json()["is_pro"] is True

    assert client.post(
        "/v1/auth/email/register",
        json={"email": "mutant@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    ).status_code == 202

    monkeypatch.setattr(
        Store, "claim_registration_by_provider_subject", lambda self, subject: None
    )

    web = _click_verification_link(client, fake_auth, "mutant@example.com")
    assert web["account_id"] != anonymous_account, (
        "the mutation did not take — this test is not measuring what it claims"
    )

    session = client.post(
        "/v1/auth/email/login",
        json={"email": "mutant@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    ).json()
    # The measurable damage, all three parts of it.
    assert session["account_id"] == web["account_id"] != anonymous_account
    assert session["is_pro"] is False
    assert _coach(client, session["api_token"]).status_code == 402
