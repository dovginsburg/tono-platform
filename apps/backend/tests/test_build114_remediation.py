"""Build 114 remediation — the sequence the product actually instructs, and the
audit fields a stranger used to be able to rewrite.

Every test here was RED on the rejected Build 114 tree (4302236) and is green on
this one. That is the point of the file: the original suite asserted the
anonymous-upgrade invariant with the verification step SIMULATED as a
provider-side flag flip, so it could not fail for the defect it claimed to
cover. What was missing was one call — the one the person's own mail app makes:

    POST /v1/auth/web        (no Authorization header, from a browser)

Inserting it turns "the same canonical UUID survives registration" from a claim
into a measurement.

Nothing here reaches a network. The provider boundary is the same fake
`test_email_accounts` establishes, and the Apple signing chain is the local
fixture `test_mobile_billing` already provides.
"""

from __future__ import annotations

import pytest

from .test_mobile_billing import apple  # noqa: F401
from .test_email_accounts import (  # noqa: F401
    FakeEmailAuth,
    PASSWORD,
    _headers,
    _register_device,
    _wire,
    fake_auth,
)


def _verification_click(client, email: str, *, app_version: str = "web-114"):
    """The step the shipped UI instructs and the rejected suite never made.

    "Open the link on this device, then come back and sign in" — the link opens
    in a BROWSER, from a mail app. It carries no Tono bearer and no app session;
    all it can present is the token the provider issued for the address it just
    proved. This is that request, byte for byte what
    `apps/web/src/app/auth/callback/route.ts` sends.
    """
    return client.post(
        "/v1/auth/web",
        json={"access_token": f"token-for:{email}", "app_version": app_version},
    )


def _coach(client, token: str):
    return client.post(
        "/api/analyze/variant",
        json={"text": "could you take a look at this when you get a chance", "axis": "warmer"},
        headers=_headers(token),
    )


# ---------------------------------------------------------------------------
# P1-1 — the verification click must not orphan the caller's account
# ---------------------------------------------------------------------------


def test_the_real_verification_click_keeps_the_callers_canonical_account(client, fake_auth):
    """Anonymous account A -> register with A's bearer -> REAL callback ->
    native login. A must survive all three, because everything the person has
    is on it.

    On the rejected tree the browser minted a second canonical account and the
    later app login landed there instead, so A was orphaned on every native
    registration — holding `pending` and its address forever, and double-counting
    the person in the registration ledger.
    """
    device = _register_device(client)
    anonymous_account = device["account_id"]

    assert client.post(
        "/v1/auth/email/register",
        json={
            "email": "person@example.com",
            "password": PASSWORD,
            "source_surface": "ios",
            "app_version": "114",
        },
        headers=_headers(device["api_token"]),
    ).status_code == 202

    # The person taps the link in their mail app.
    fake_auth.confirm("person@example.com")
    web = _verification_click(client, "person@example.com")
    assert web.status_code == 200, web.text
    assert web.json()["account_id"] == anonymous_account, (
        "the verification click must complete the registration that started it, "
        "not mint a second canonical person"
    )

    # Back in the app.
    session = client.post(
        "/v1/auth/email/login",
        json={
            "email": "person@example.com",
            "password": PASSWORD,
            "source_surface": "ios",
            "app_version": "114",
        },
        headers=_headers(device["api_token"]),
    )
    assert session.status_code == 200, session.text
    assert session.json()["account_id"] == anonymous_account
    assert session.json()["email_verified"] is True

    # One human, one registration row — not two, and none stuck pending.
    from backend.store import get_store

    store = get_store()
    metrics = store.registration_metrics()
    assert metrics["registrations_total"] == 1, metrics
    assert metrics["by_lifecycle_state"] == {"verified": 1}, metrics
    assert [a.id for a in store.find_accounts_by_email("person@example.com")] == [
        anonymous_account
    ]
    row = store.get_registration(anonymous_account)
    assert row["lifecycle_state"] == "verified"
    assert row["verified_at"]


def test_history_usage_and_entitlement_survive_the_verification_click(client, fake_auth, apple):
    """The consumer promise this build makes in writing — "confirming an email
    keeps your subscription and your saved style recoverable" — measured across
    the real callback rather than around it."""
    device = _register_device(client)
    account_id = device["account_id"]

    # Something worth keeping: a subscription bound to the canonical UUID, and
    # usage recorded against it.
    assert client.post(
        "/v1/app-store/subscription",
        json={"signed_transaction_info": apple.sign_transaction(appAccountToken=account_id)},
        headers=_headers(device["api_token"]),
    ).status_code == 200
    assert _coach(client, device["api_token"]).status_code == 200

    assert client.post(
        "/v1/auth/email/register",
        json={"email": "keeper@example.com", "password": PASSWORD,
              "source_surface": "ios", "app_version": "114"},
        headers=_headers(device["api_token"]),
    ).status_code == 202

    fake_auth.confirm("keeper@example.com")
    assert _verification_click(client, "keeper@example.com").status_code == 200

    session = client.post(
        "/v1/auth/email/login",
        json={"email": "keeper@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    ).json()

    assert session["account_id"] == account_id
    # The subscription followed the person: no second purchase, no Restore tap.
    assert session["is_pro"] is True
    assert _coach(client, session["api_token"]).status_code == 200

    # And the account's own history is one continuous story, not two.
    events = client.get(
        "/v1/account/registration-events", headers=_headers(session["api_token"])
    ).json()
    kinds = [e["event_type"] for e in events["events"]]
    assert kinds[0] == "signup_requested"
    assert "verification_completed" in kinds
    assert events["account_id"] == account_id


def test_the_browser_that_opens_the_link_does_not_outrank_the_registering_account(
    client, fake_auth
):
    """The browser is a stranger with an account of its own.

    `/v1/auth/web` mints a per-browser device (and therefore an anonymous
    account) to carry the request. That throwaway must never win the identity
    over the account that actually started the registration — otherwise the fix
    would simply move the orphaning one step sideways.
    """
    device = _register_device(client)
    registering_account = device["account_id"]

    client.post(
        "/v1/auth/email/register",
        json={"email": "browser@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )
    fake_auth.confirm("browser@example.com")

    web = _verification_click(client, "browser@example.com").json()
    assert web["account_id"] == registering_account
    # The browser got its own DEVICE, as it must — it just did not get its own
    # person.
    assert web["device_id"] != device["device_id"]

    from backend.store import get_store

    assert [a.id for a in get_store().find_accounts_by_email("browser@example.com")] == [
        registering_account
    ]


def test_a_web_first_registration_still_converges_on_one_account(client, fake_auth):
    """The web path has no pre-existing account to preserve, so the claim is
    simply absent and the browser's own account is upgraded in place. This is
    the guard that the new resolution step did not break the surface that was
    already working."""
    fake_auth.users["webonly@example.com"] = {"password": PASSWORD, "confirmed": True}

    first = _verification_click(client, "webonly@example.com").json()
    second = _verification_click(client, "webonly@example.com").json()

    assert first["account_id"] == second["account_id"]
    assert first["device_id"] != second["device_id"]

    # And a native login lands on the same person.
    session = client.post(
        "/v1/auth/email/login",
        json={"email": "webonly@example.com", "password": PASSWORD},
    ).json()
    assert session["account_id"] == first["account_id"]


def test_a_stranger_cannot_claim_a_registration_that_already_exists(client, fake_auth):
    """The hostile shape of the new claim.

    Someone types an address that is ALREADY registered. The provider refuses to
    create anything, so no subject comes back and no claim is recorded — the
    real owner's binding is untouched and the verification they are waiting for
    still belongs to them. This is why the claim keys on the provider SUBJECT
    rather than on the address: an address is something anyone can type.
    """
    victim_device = _register_device(client)
    victim_account = victim_device["account_id"]
    client.post(
        "/v1/auth/email/register",
        json={"email": "victim@example.com", "password": PASSWORD},
        headers=_headers(victim_device["api_token"]),
    )

    attacker_device = _register_device(client)
    attacker_account = attacker_device["account_id"]
    # Same address, from a different device. The provider answers "already
    # registered", which the server must keep answering as `verification_pending`.
    assert client.post(
        "/v1/auth/email/register",
        json={"email": "victim@example.com", "password": "another-password-9"},
        headers=_headers(attacker_device["api_token"]),
    ).status_code == 202

    fake_auth.confirm("victim@example.com")
    landed = _verification_click(client, "victim@example.com").json()

    assert landed["account_id"] == victim_account
    assert landed["account_id"] != attacker_account

    from backend.store import get_store

    assert get_store().get_account(attacker_account).lifecycle_state != "verified"


def test_a_second_registration_cannot_displace_an_existing_claim(client, fake_auth):
    """First claim wins, at the store.

    Even when the provider hands back the SAME subject for a repeat signup, a
    later caller must not be able to take over the pending registration and
    inherit the verification the first one is waiting for.
    """
    from backend.store import get_store

    store = get_store()
    first = store.create_bare_account()
    second = store.create_bare_account()

    store.begin_email_registration(
        account_id=first.id, email="claim@example.com", provider_subject="subject-x"
    )
    store.begin_email_registration(
        account_id=second.id, email="claim@example.com", provider_subject="subject-x"
    )

    assert store.claim_pending_registration_account("subject-x") == first.id
    assert store.get_registration(second.id)["provider_subject"] is None


def test_an_identified_account_never_hands_its_identity_to_a_stale_claim(client, fake_auth):
    """A claim is redeemable only while the claimant is still anonymous.

    Once an account has an identity of its own it is a specific person, and a
    leftover claim row must not be able to route someone else's proven address
    onto it.
    """
    from backend.store import get_store

    store = get_store()
    account = store.create_bare_account()
    store.begin_email_registration(
        account_id=account.id, email="stale@example.com", provider_subject="subject-stale"
    )
    assert store.claim_pending_registration_account("subject-stale") == account.id

    store.mark_email_verified(account_id=account.id, email="stale@example.com")
    assert store.claim_pending_registration_account("subject-stale") is None

    # A tombstoned claimant is equally unredeemable.
    gone = store.create_bare_account()
    store.begin_email_registration(
        account_id=gone.id, email="gone@example.com", provider_subject="subject-gone"
    )
    store.delete_account(gone.id)
    assert store.claim_pending_registration_account("subject-gone") is None


# ---------------------------------------------------------------------------
# P2-1 / P2-2 — audit fields a stranger could rewrite
# ---------------------------------------------------------------------------


def _registration_of(client, email: str) -> dict:
    from backend.store import get_store

    store = get_store()
    accounts = store.find_accounts_by_email(email)
    assert len(accounts) == 1, accounts
    return store.get_registration(accounts[0].id)


@pytest.mark.parametrize("path", ["/v1/auth/email/reset", "/v1/auth/email/resend"])
def test_an_unauthenticated_caller_cannot_rewrite_another_accounts_audit_row(
    client, fake_auth, path
):
    """Reproduced on the rejected tree: a victim registered from
    `('ios', '114')`, one bearer-less POST naming `android`/`666` returned 202,
    and the victim's row became `('android', '666')`.

    These endpoints must stay reachable with no bearer — a person who has
    forgotten their password cannot be asked to prove who they are first — so
    the fix is not authentication. It is that an unauthenticated claim about
    which app this is describes nothing the server observed, and is therefore
    not written onto anybody's row.
    """
    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={"email": "audit@example.com", "password": PASSWORD,
              "source_surface": "ios", "app_version": "114"},
        headers=_headers(device["api_token"]),
    )
    before = _registration_of(client, "audit@example.com")
    assert (before["source_surface"], before["app_build"]) == ("ios", "114")

    hostile = client.post(
        path, json={"email": "audit@example.com", "source_surface": "android", "app_version": "666"}
    )
    assert hostile.status_code == 202, hostile.text  # still anti-enumerating

    after = _registration_of(client, "audit@example.com")
    assert (after["source_surface"], after["app_build"]) == ("ios", "114")
    assert after["last_seen_surface"] != "android"
    assert after["last_seen_app_build"] != "666"

    # The event is still audited — it really happened — but as unattributed.
    events = client.get(
        "/v1/account/registration-events", headers=_headers(device["api_token"])
    ).json()["events"]
    hostile_events = [e for e in events if e["event_type"] != "signup_requested"]
    assert hostile_events, "the request must still leave a trace"
    for event in hostile_events:
        assert event["source_surface"] == "unknown", event
        assert event["app_build"] is None, event


def test_registration_source_is_immutable_and_recency_lives_elsewhere(client, fake_auth):
    """`source_surface` is named for where a registration STARTED.

    On the rejected tree it was last-writer-wins, so a registration begun on iOS
    and verified in a browser reported whichever surface wrote last — and
    `/admin/registrations` reported that as source. Recency is a real question,
    so it gets its own real answer.
    """
    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={"email": "surface@example.com", "password": PASSWORD,
              "source_surface": "ios", "app_version": "114"},
        headers=_headers(device["api_token"]),
    )
    fake_auth.confirm("surface@example.com")
    assert _verification_click(client, "surface@example.com").status_code == 200

    row = _registration_of(client, "surface@example.com")
    assert row["source_surface"] == "ios", "the registration started on iOS"
    assert row["app_build"] == "114"
    assert row["last_seen_surface"] == "web", "and it was last seen in a browser"
    assert row["last_seen_app_build"] == "web-114"

    # A later native sign-in moves last-seen back, and still not source.
    client.post(
        "/v1/auth/email/login",
        json={"email": "surface@example.com", "password": PASSWORD,
              "source_surface": "android", "app_version": "115"},
    )
    row = _registration_of(client, "surface@example.com")
    assert row["source_surface"] == "ios"
    assert row["app_build"] == "114"
    assert row["last_seen_surface"] == "android"
    assert row["last_seen_app_build"] == "115"


def test_an_attested_caller_still_records_its_own_surface(client, fake_auth):
    """The guard on the test above: dropping unattested claims must not have
    thrown away the real signal. A caller presenting a bearer for the account
    it is describing is attributed normally."""
    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={"email": "attested@example.com", "password": PASSWORD,
              "source_surface": "ios", "app_version": "114"},
        headers=_headers(device["api_token"]),
    )
    client.post(
        "/v1/auth/email/resend",
        json={"email": "attested@example.com", "source_surface": "ios", "app_version": "116"},
        headers=_headers(device["api_token"]),
    )

    row = _registration_of(client, "attested@example.com")
    assert row["last_seen_surface"] == "ios"
    assert row["last_seen_app_build"] == "116"
    assert row["source_surface"] == "ios"
    assert row["app_build"] == "114", "source build is still the one it started on"


def test_the_optional_bearer_changes_nothing_observable(client, fake_auth):
    """Attestation must not have created a new oracle. The response to a reset
    is identical with a bearer, without one, and for an address that does not
    exist at all."""
    device = _register_device(client)
    fake_auth.users["known@example.com"] = {"password": PASSWORD, "confirmed": True}

    answers = [
        client.post("/v1/auth/email/reset", json={"email": "known@example.com"}),
        client.post(
            "/v1/auth/email/reset",
            json={"email": "known@example.com"},
            headers=_headers(device["api_token"]),
        ),
        client.post("/v1/auth/email/reset", json={"email": "nobody@example.com"}),
    ]
    assert {r.status_code for r in answers} == {202}
    assert {r.text for r in answers} == {'{"status":"verification_pending"}'}


# ---------------------------------------------------------------------------
# P3-1 — the web sign-in must project the same entitlement a native login does
# ---------------------------------------------------------------------------


def test_web_sign_in_reports_the_entitlement_a_mobile_subscriber_actually_holds(
    client, fake_auth, apple
):
    """A provider (App Store / Play) subscription attaches to the canonical
    account as an entitlement GRANT, which `Account.is_pro` does not read.

    `/v1/auth/web` returned that raw projection, so every mobile subscriber who
    signed in on the website was told `is_pro: false` — the identical defect the
    email login already documents and fixes, left in place on its sibling.
    """
    device = _register_device(client)
    account_id = device["account_id"]
    assert client.post(
        "/v1/app-store/subscription",
        json={"signed_transaction_info": apple.sign_transaction(appAccountToken=account_id)},
        headers=_headers(device["api_token"]),
    ).status_code == 200

    client.post(
        "/v1/auth/email/register",
        json={"email": "subscriber@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )
    fake_auth.confirm("subscriber@example.com")

    web = _verification_click(client, "subscriber@example.com").json()
    assert web["account_id"] == account_id
    assert web["is_pro"] is True, "the browser must not be told the subscription is gone"
    # The web sign-in and `/v1/me` must be the same projection, not two.
    me = client.get("/v1/me", headers=_headers(web["api_token"])).json()
    assert (web["is_pro"], web["plan"]) == (me["is_pro"], me["plan"])
    # And the bearer it returns really does open the gated surface.
    assert _coach(client, web["api_token"]).status_code == 200


# ---------------------------------------------------------------------------
# P3-2 — a signed-out device is re-registerable, and that is not a way back in
# ---------------------------------------------------------------------------


def test_a_signed_out_device_can_register_again_and_lands_nowhere_near_its_old_account(
    client, fake_auth
):
    """Sign-out nulls the credential and rotates the bearer, so nothing can ever
    prove itself back into that row. On the rejected tree that left the device id
    answering 409 forever: a client that keeps its device id across a sign-out
    could never register again, and the row accreted.

    Re-issuing the slot is safe precisely because it is empty — the account is
    already unlinked and the entitlement mirror cleared — so the claimant gets a
    brand-new anonymous device and nothing else.
    """
    device = _register_device(client)
    original_account = device["account_id"]

    assert client.post(
        "/v1/auth/email/logout", headers=_headers(device["api_token"])
    ).status_code == 200

    again = client.post(
        "/v1/register",
        json={
            "device_id": device["device_id"],
            "device_credential": device["device_credential"],
        },
    )
    assert again.status_code == 200, again.text
    reissued = again.json()
    assert reissued["device_id"] == device["device_id"]
    assert reissued["account_id"] != original_account
    assert reissued["is_pro"] is False
    assert reissued["api_token"] != device["api_token"]
    assert reissued["device_credential"] != device["device_credential"]
    # The old bearer stays dead.
    assert client.get("/v1/me", headers=_headers(device["api_token"])).status_code == 401


def test_re_registration_does_not_inherit_a_stale_device_entitlement(client, fake_auth):
    """The device row carries its own plan/subscription mirror for the anonymous
    case. If sign-out left `plan='pro'` there, re-issuing the slot would hand the
    next claimant an entitlement nobody bought."""
    from backend.store import get_store

    device = _register_device(client)
    store = get_store()
    store.update_subscription(
        device_id=device["device_id"],
        subscription_id="sub_stale",
        status="active",
        renews_at="2030-01-01T00:00:00Z",
    )
    assert client.get("/v1/me", headers=_headers(device["api_token"])).json()["is_pro"] is True

    client.post("/v1/auth/email/logout", headers=_headers(device["api_token"]))
    reissued = client.post(
        "/v1/register",
        json={
            "device_id": device["device_id"],
            "device_credential": device["device_credential"],
        },
    ).json()

    assert reissued["is_pro"] is False
    assert reissued["plan"] == "free"
    assert _coach(client, reissued["api_token"]).status_code == 402


def test_a_live_device_still_needs_proof_to_re_register(client, fake_auth):
    """The guard on the two tests above. Re-issue is reachable ONLY from a
    retired row; a device that was never signed out still has to present its
    credential, and a wrong one is still refused."""
    device = _register_device(client)

    assert client.post(
        "/v1/register",
        json={"device_id": device["device_id"], "device_credential": "wrong-" + "x" * 60},
    ).status_code == 409

    ok = client.post(
        "/v1/register",
        json={
            "device_id": device["device_id"],
            "device_credential": device["device_credential"],
        },
    )
    assert ok.status_code == 200
    assert ok.json()["account_id"] == device["account_id"], (
        "a live device re-registering must come back to its own account"
    )
