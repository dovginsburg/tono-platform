"""Build 114 — email registration, verification, login, reset, logout.

These tests drive the REAL production endpoints, the real store, and the real
lifecycle state machine. The only thing overridden is the boundary to the auth
provider (`email_auth.get_email_auth_client`) and the Supabase token verifier —
exactly the seams `social_auth` and `supabase_auth` already establish, so no
test needs network access, a real Supabase project, or a real password.

What is deliberately NOT stubbed: normalization, the anti-enumeration
responses, the rate limiters, the canonical-account resolution, the entitlement
projection, and the audit trail. Those are the contract, so a mutation to any
of them has to turn something here red.
"""

from __future__ import annotations

import pytest


# ---------------------------------------------------------------------------
# Fakes for the provider boundary
# ---------------------------------------------------------------------------


class FakeEmailAuth:
    """Stands in for Supabase Auth.

    Models the three behaviours that actually change what a person sees:
    an address it knows, an address it doesn't, and a project that is down.
    Passwords are compared literally — this fake stores them only to prove the
    server never does.
    """

    def __init__(self, subject_for=None):
        self.users: dict[str, dict] = {}
        self.sent: list[tuple[str, str]] = []  # (kind, email)
        self.fail_with = None  # an EmailAuthOutcome to raise on every call
        # Supabase returns the new user's own id on signup, even while it
        # withholds a session pending confirmation. Modelled here because the
        # anonymous upgrade depends on it: the server records it as a claim so
        # the browser that opens the emailed link can be resolved back to the
        # account that started the registration. A fake that omitted it would
        # make the whole claim path untestable by construction.
        self.subject_for = subject_for or (lambda email: f"sub-for:{email}")

    def _maybe_fail(self):
        if self.fail_with is not None:
            import backend.email_auth as email_auth

            raise email_auth.EmailAuthError(self.fail_with)

    async def sign_up(self, *, email: str, password: str):
        import backend.email_auth as email_auth

        self._maybe_fail()
        if email in self.users:
            # Supabase answers 4xx for an already-registered address.
            raise email_auth.EmailAuthError(
                email_auth.EmailAuthOutcome.INVALID_CREDENTIALS
            )
        self.users[email] = {"password": password, "confirmed": False}
        self.sent.append(("signup", email))
        return email_auth.EmailSignUpResult(
            verification_required=True, provider_user_id=self.subject_for(email)
        )

    async def sign_in(self, *, email: str, password: str):
        import backend.email_auth as email_auth

        self._maybe_fail()
        user = self.users.get(email)
        if user is None or user["password"] != password:
            raise email_auth.EmailAuthError(
                email_auth.EmailAuthOutcome.INVALID_CREDENTIALS
            )
        if not user["confirmed"]:
            raise email_auth.EmailAuthError(
                email_auth.EmailAuthOutcome.VERIFICATION_REQUIRED
            )
        return email_auth.EmailAuthSession(access_token=f"token-for:{email}")

    async def resend_verification(self, *, email: str):
        import backend.email_auth as email_auth

        self._maybe_fail()
        if email not in self.users:
            raise email_auth.EmailAuthError(
                email_auth.EmailAuthOutcome.INVALID_CREDENTIALS
            )
        self.sent.append(("resend", email))

    async def request_password_reset(self, *, email: str):
        import backend.email_auth as email_auth

        self._maybe_fail()
        if email not in self.users:
            raise email_auth.EmailAuthError(
                email_auth.EmailAuthOutcome.INVALID_CREDENTIALS
            )
        self.sent.append(("reset", email))

    # test helpers -----------------------------------------------------
    def confirm(self, email: str) -> None:
        self.users[email]["confirmed"] = True


def _wire(app, fake: FakeEmailAuth, *, subject_for=None):
    """Install the fake provider and a matching token verifier.

    `subject_for` maps an address to the provider subject, so a test can model
    "same person, two addresses" or "two subjects, one address spelling"
    without touching production code.
    """
    import backend.email_auth as email_auth
    import backend.supabase_auth as supabase_auth

    app.dependency_overrides[email_auth.get_email_auth_client] = lambda: fake

    subject_for = subject_for or (lambda email: f"sub-for:{email}")
    # The signup response and the token verifier must agree about who the
    # provider thinks this is, or the claim recorded at registration would
    # never match the identity presented at verification — which is exactly the
    # bug this models, and it must come from production code, not the fake.
    fake.subject_for = subject_for

    async def fake_verifier(token: str):
        assert token.startswith("token-for:"), token
        email = token.split("token-for:", 1)[1]
        return supabase_auth.SupabaseClaims(
            sub=subject_for(email), email=email, email_verified=True
        )

    app.dependency_overrides[supabase_auth.get_supabase_verifier] = lambda: fake_verifier
    return fake


@pytest.fixture
def fake_auth(client):
    from backend.server import app

    return _wire(app, FakeEmailAuth())


def _register_device(client) -> dict:
    r = client.post("/v1/register", json={})
    assert r.status_code == 200, r.text
    return r.json()


def _headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


PASSWORD = "correct-horse-battery"


def _click_verification_link(client, fake, email: str) -> dict:
    """What tapping the link in the confirmation email ACTUALLY does.

    This is the step the Build 114 suite left out, and leaving it out is what
    made a green suite compatible with the account-orphaning defect it claimed
    to cover. Flipping the provider's confirmed flag models the provider's half
    and stops there; the product's half is that the link opens the person's
    BROWSER, which exchanges the code and posts the resulting token to
    `POST /v1/auth/web` carrying NO device bearer — because a browser that has
    never seen this person before does not have one.

    That bearer-less request is the whole difficulty: nothing in it can say
    which canonical account started the registration. Any test that skips it is
    asserting the anonymous upgrade against a request the product never makes.

    Both clients instruct exactly this ordering — "open the link on this device,
    then come back and sign in" — so it is the normal path, not an edge case.
    """
    fake.confirm(email)
    r = client.post(
        "/v1/auth/web",
        json={"access_token": f"token-for:{email}", "app_version": "web-114"},
    )
    assert r.status_code == 200, r.text
    return r.json()


# ---------------------------------------------------------------------------
# Signup -> pending -> verification -> verified login
# ---------------------------------------------------------------------------


def test_signup_then_verify_then_login_resolves_one_canonical_account(client, fake_auth):
    device = _register_device(client)
    anonymous_account = device["account_id"]

    r = client.post(
        "/v1/auth/email/register",
        json={
            "email": "Person@Example.com",
            "password": PASSWORD,
            "source_surface": "ios",
            "app_version": "114",
        },
        headers=_headers(device["api_token"]),
    )
    assert r.status_code == 202, r.text
    assert r.json() == {"status": "verification_pending"}

    # Pending: the account exists but is NOT identified, so nothing private
    # opened just because a registration was started.
    events = client.get(
        "/v1/account/registration-events", headers=_headers(device["api_token"])
    ).json()
    assert events["account_id"] == anonymous_account
    assert events["lifecycle_state"] == "pending"
    assert events["email_verified"] is False
    assert [e["event_type"] for e in events["events"]] == ["signup_requested"]

    # The person clicks the link in their mail app. This is the REAL step, not
    # a provider flag flip: it opens a browser with no device bearer, which is
    # the one request in this flow that cannot say who it is acting for.
    web = _click_verification_link(client, fake_auth, "person@example.com")
    # The browser must land on the SAME canonical person, not a second account.
    assert web["account_id"] == anonymous_account

    r = client.post(
        "/v1/auth/email/login",
        json={
            "email": "person@example.com",
            "password": PASSWORD,
            "source_surface": "ios",
            "app_version": "114",
        },
        headers=_headers(device["api_token"]),
    )
    assert r.status_code == 200, r.text
    session = r.json()
    assert session["email_verified"] is True
    assert session["email"] == "person@example.com"
    # ANONYMOUS UPGRADE: the same canonical UUID, so history/usage/purchase
    # ownership all survive registration.
    assert session["account_id"] == anonymous_account
    # Verification is not entitlement.
    assert session["is_pro"] is False
    assert session["plan"] == "free"


# ---------------------------------------------------------------------------
# The clicked link — the step the product performs and the suite used to skip
#
# Every test in this section fails on the pre-remediation implementation. That
# is the point: the anonymous-upgrade guarantee was asserted by a test that
# modelled verification as a provider-side flag flip, so the assertion could
# not fail for the defect that broke the guarantee in production.
# ---------------------------------------------------------------------------


def test_the_verification_click_lands_on_the_account_that_registered(client, fake_auth):
    """One human, one canonical account, across the whole real sequence.

    Anonymous account A -> register with A's bearer -> the person opens the
    emailed link in a browser -> A comes back and signs in. A must be the
    answer at every step.
    """
    device = _register_device(client)
    anonymous_account = device["account_id"]

    assert client.post(
        "/v1/auth/email/register",
        json={
            "email": "click@example.com",
            "password": PASSWORD,
            "source_surface": "ios",
            "app_version": "114",
        },
        headers=_headers(device["api_token"]),
    ).status_code == 202

    web = _click_verification_link(client, fake_auth, "click@example.com")
    assert web["account_id"] == anonymous_account, (
        "the browser minted a second canonical account instead of resolving the "
        "registration that is already pending for this provider identity"
    )

    session = client.post(
        "/v1/auth/email/login",
        json={"email": "click@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    ).json()
    assert session["account_id"] == anonymous_account, (
        "the app landed on the browser's account, orphaning the one with the "
        "person's history"
    )


def test_the_ledger_counts_one_human_once(client, fake_auth):
    """A registration report that double-counts is worse than none.

    The orphaned account kept `email_normalized` and stayed `pending` forever,
    so one person appeared as two registrations — one pending, one verified —
    and every native signup inflated the count.
    """
    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={
            "email": "counted@example.com",
            "password": PASSWORD,
            "source_surface": "ios",
            "app_version": "114",
        },
        headers=_headers(device["api_token"]),
    )
    _click_verification_link(client, fake_auth, "counted@example.com")
    client.post(
        "/v1/auth/email/login",
        json={"email": "counted@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )

    from backend.store import get_store

    metrics = get_store().registration_metrics()
    assert metrics["registrations_total"] == 1, metrics
    assert metrics["by_lifecycle_state"] == {"verified": 1}, metrics
    # And it is attributed to where the person actually started.
    assert metrics["by_source_surface"] == {"ios": 1}, metrics


def test_a_subscription_bought_before_registering_survives_the_click(client, fake_auth):
    """The consequence that costs money.

    Both shipped clients currently gate purchase behind a confirmed address, so
    this is reached through the server rather than their UI — but the endpoints
    are live, the guarantee is the one the product's own copy makes ("confirming
    an email keeps your subscription recoverable"), and an account that pays
    before it registers must not be the account that gets abandoned.
    """
    device = _register_device(client)
    anonymous_account = device["account_id"]

    from backend.store import get_store

    get_store().apply_apple_transaction(
        account_id=anonymous_account,
        original_transaction_id="otx-early",
        transaction_id="tx-early",
        product_id="tono_pro_monthly",
        environment="Sandbox",
        ownership_type="PURCHASED",
        app_account_token=anonymous_account,
        signed_ms=1_700_000_000_000,
        expires_ms=4_100_000_000_000,
    )
    assert client.get("/v1/me", headers=_headers(device["api_token"])).json()["is_pro"] is True

    client.post(
        "/v1/auth/email/register",
        json={"email": "paid@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )
    _click_verification_link(client, fake_auth, "paid@example.com")
    session = client.post(
        "/v1/auth/email/login",
        json={"email": "paid@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    ).json()

    assert session["account_id"] == anonymous_account
    assert session["is_pro"] is True, "the subscription was stranded on the orphaned account"
    # And the gated surface actually opens, which is what the person paid for.
    assert client.post(
        "/api/analyze/variant",
        json={"text": "could you take a look at this when you get a chance", "axis": "warmer"},
        headers=_headers(device["api_token"]),
    ).status_code == 200


def test_a_browser_first_registration_still_works_without_a_claim(client, fake_auth):
    """Nobody registered from a device, so there is no claim to resolve.

    The claim must be an addition, not a precondition: a person who starts on
    the website has no prior anonymous account, and minting one for them is the
    correct answer rather than a failure.
    """
    assert client.post(
        "/v1/auth/email/register",
        json={"email": "webfirst@example.com", "password": PASSWORD},
    ).status_code == 202

    web = _click_verification_link(client, fake_auth, "webfirst@example.com")
    assert web["account_id"]
    assert web["is_pro"] is False

    # And signing in later converges on that same account.
    session = client.post(
        "/v1/auth/email/login",
        json={"email": "webfirst@example.com", "password": PASSWORD},
    ).json()
    assert session["account_id"] == web["account_id"]


def test_a_claim_never_hands_over_an_account_that_did_not_make_it(client, fake_auth):
    """Two people, two registrations, two subjects — no crossing over."""
    alice_device = _register_device(client)
    bob_device = _register_device(client)

    for device, address in ((alice_device, "alice@example.com"), (bob_device, "bob@example.com")):
        client.post(
            "/v1/auth/email/register",
            json={"email": address, "password": PASSWORD},
            headers=_headers(device["api_token"]),
        )

    alice_web = _click_verification_link(client, fake_auth, "alice@example.com")
    bob_web = _click_verification_link(client, fake_auth, "bob@example.com")

    assert alice_web["account_id"] == alice_device["account_id"]
    assert bob_web["account_id"] == bob_device["account_id"]
    assert alice_web["account_id"] != bob_web["account_id"]


def test_a_provider_that_returns_no_subject_still_registers(client, fake_auth):
    """The claim is best effort, never a new way for a signup to fail.

    The mail has already been sent by the time the subject would be recorded,
    so a provider that withholds it must degrade — not strand the person with a
    link in their inbox and an error on their screen.
    """
    import backend.email_auth as email_auth

    async def sign_up_without_subject(*, email: str, password: str):
        fake_auth.users[email] = {"password": password, "confirmed": False}
        return email_auth.EmailSignUpResult(verification_required=True)

    fake_auth.sign_up = sign_up_without_subject

    device = _register_device(client)
    assert client.post(
        "/v1/auth/email/register",
        json={"email": "nosub@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    ).status_code == 202

    # Still pending on the caller's own account, and the address is recorded.
    events = client.get(
        "/v1/account/registration-events", headers=_headers(device["api_token"])
    ).json()
    assert events["lifecycle_state"] == "pending"
    assert events["account_id"] == device["account_id"]


def test_pre_verification_login_is_refused_and_grants_nothing(client, fake_auth):
    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={"email": "pending@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )

    r = client.post(
        "/v1/auth/email/login",
        json={"email": "pending@example.com", "password": PASSWORD},
    )
    assert r.status_code == 403
    assert r.json()["error"]["message"] == "email_verification_required"

    # Still not identified, still not Pro, and the private Coach path is shut.
    me = client.get("/v1/me", headers=_headers(device["api_token"])).json()
    assert me["is_pro"] is False
    coach = client.post(
        "/api/analyze/variant",
        json={"text": "hello there", "axis": "warmer"},
        headers=_headers(device["api_token"]),
    )
    assert coach.status_code == 402


def test_verification_never_grants_pro(client, fake_auth):
    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={"email": "free@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )
    fake_auth.confirm("free@example.com")
    session = client.post(
        "/v1/auth/email/login",
        json={"email": "free@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    ).json()

    assert session["email_verified"] is True
    assert session["is_pro"] is False
    # And the entitlement gate agrees: verified but unsubscribed is 402.
    r = client.post(
        "/api/analyze/variant",
        json={"text": "please review this", "axis": "clearer"},
        headers=_headers(session["api_token"]),
    )
    assert r.status_code == 402


def test_verified_and_subscribed_can_use_coach(client, fake_auth):
    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={"email": "sub@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )
    fake_auth.confirm("sub@example.com")
    session = client.post(
        "/v1/auth/email/login",
        json={"email": "sub@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    ).json()

    from backend.store import get_store

    get_store().update_account_subscription(
        account_id=session["account_id"],
        subscription_id="sub_email_114",
        status="active",
        renews_at="2027-01-01T00:00:00Z",
    )

    me = client.get("/v1/me", headers=_headers(session["api_token"])).json()
    assert me["is_pro"] is True
    r = client.post(
        "/api/analyze/variant",
        json={"text": "can you take a look at this", "axis": "warmer"},
        headers=_headers(session["api_token"]),
    )
    assert r.status_code == 200, r.text


# ---------------------------------------------------------------------------
# Anti-enumeration
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("path", ["/v1/auth/email/resend", "/v1/auth/email/reset"])
def test_resend_and_reset_are_anti_enumerating(client, fake_auth, path):
    fake_auth.users["known@example.com"] = {"password": PASSWORD, "confirmed": True}

    known = client.post(path, json={"email": "known@example.com"})
    unknown = client.post(path, json={"email": "nobody@example.com"})

    assert known.status_code == unknown.status_code == 202
    assert known.json() == unknown.json() == {"status": "verification_pending"}


def test_register_on_existing_address_does_not_reveal_existence(client, fake_auth):
    fake_auth.users["taken@example.com"] = {"password": PASSWORD, "confirmed": True}

    fresh = client.post(
        "/v1/auth/email/register",
        json={"email": "brand-new@example.com", "password": PASSWORD},
    )
    taken = client.post(
        "/v1/auth/email/register",
        json={"email": "taken@example.com", "password": PASSWORD},
    )
    assert fresh.status_code == taken.status_code == 202
    assert fresh.json() == taken.json()


def test_provider_outage_is_never_a_false_email_sent(client, fake_auth):
    import backend.email_auth as email_auth

    fake_auth.fail_with = email_auth.EmailAuthOutcome.PROVIDER_UNAVAILABLE
    for path in (
        "/v1/auth/email/register",
        "/v1/auth/email/resend",
        "/v1/auth/email/reset",
    ):
        body = {"email": "person@example.com"}
        if "register" in path:
            body["password"] = PASSWORD
        r = client.post(path, json=body)
        assert r.status_code == 503, (path, r.status_code)
        assert "verification_pending" not in r.text
    assert fake_auth.sent == []


def test_rate_limit_stays_wait_and_retry_never_a_paywall(client, fake_auth):
    import backend.email_auth as email_auth

    fake_auth.fail_with = email_auth.EmailAuthOutcome.RATE_LIMITED
    r = client.post(
        "/v1/auth/email/login",
        json={"email": "person@example.com", "password": PASSWORD},
    )
    assert r.status_code == 429
    assert r.headers.get("Retry-After")
    assert r.status_code != 402


def test_repeated_login_attempts_are_bounded(client, fake_auth):
    fake_auth.users["target@example.com"] = {"password": PASSWORD, "confirmed": True}
    statuses = {
        client.post(
            "/v1/auth/email/login",
            json={"email": "target@example.com", "password": "wrong-guess"},
        ).status_code
        for _ in range(40)
    }
    assert 429 in statuses, "brute force must eventually be throttled"


# ---------------------------------------------------------------------------
# The audit row belongs to the account, not to whoever can spell the address
#
# `resend` and `reset` take no bearer by design: they have to work for someone
# who is locked out. That makes them the two endpoints anybody can aim at any
# address, so nothing they CLAIM may be written onto the account they name.
# ---------------------------------------------------------------------------


def _registration_row(account_id: str) -> dict:
    from backend.store import get_store

    return get_store().get_registration(account_id)


def _register_from(client, device, address, surface, build):
    assert client.post(
        "/v1/auth/email/register",
        json={
            "email": address,
            "password": PASSWORD,
            "source_surface": surface,
            "app_version": build,
        },
        headers=_headers(device["api_token"]),
    ).status_code == 202


def test_an_unauthenticated_reset_cannot_rewrite_a_victims_audit_row(client, fake_auth):
    victim = _register_device(client)
    _register_from(client, victim, "victim@example.com", "ios", "114")
    before = _registration_row(victim["account_id"])
    assert (before["source_surface"], before["app_build"]) == ("ios", "114")

    # No bearer. Anyone who can spell the address can send this.
    assert client.post(
        "/v1/auth/email/reset",
        json={"email": "victim@example.com", "source_surface": "android", "app_version": "666"},
    ).status_code == 202

    after = _registration_row(victim["account_id"])
    assert (after["source_surface"], after["app_build"]) == ("ios", "114"), (
        "an unauthenticated caller authored another account's registration facts"
    )


def test_an_unauthenticated_resend_cannot_rewrite_a_victims_audit_row(client, fake_auth):
    victim = _register_device(client)
    _register_from(client, victim, "resend-victim@example.com", "android", "114")

    assert client.post(
        "/v1/auth/email/resend",
        json={
            "email": "resend-victim@example.com",
            "source_surface": "ios",
            "app_version": "999",
        },
    ).status_code == 202

    row = _registration_row(victim["account_id"])
    assert (row["source_surface"], row["app_build"]) == ("android", "114")


def test_an_unauthenticated_caller_cannot_keep_a_stranger_looking_active(client, fake_auth):
    """`last_seen_at` is a claim about the account, so it needs attestation too."""
    victim = _register_device(client)
    _register_from(client, victim, "seen@example.com", "ios", "114")
    seen_before = _registration_row(victim["account_id"])["last_seen_at"]

    assert client.post(
        "/v1/auth/email/reset", json={"email": "seen@example.com", "source_surface": "android"}
    ).status_code == 202

    assert _registration_row(victim["account_id"])["last_seen_at"] == seen_before


def test_an_unattested_event_is_still_recorded_without_its_attribution(client, fake_auth):
    """The event happened. What it CLAIMED about the account did not."""
    victim = _register_device(client)
    _register_from(client, victim, "audited@example.com", "ios", "114")

    client.post(
        "/v1/auth/email/reset",
        json={"email": "audited@example.com", "source_surface": "android", "app_version": "666"},
    )

    events = client.get(
        "/v1/account/registration-events", headers=_headers(victim["api_token"])
    ).json()["events"]
    reset_events = [e for e in events if e["event_type"] == "password_reset_requested"]
    assert len(reset_events) == 1, "the request must still be auditable"
    assert reset_events[0]["source_surface"] == "unknown"
    assert reset_events[0]["app_build"] is None


def test_source_surface_is_where_it_started_not_who_wrote_last(client, fake_auth):
    """The column is named `source`. It has to mean source."""
    device = _register_device(client)
    _register_from(client, device, "moved@example.com", "ios", "114")
    _click_verification_link(client, fake_auth, "moved@example.com")

    # The same person signs in from the other platform.
    assert client.post(
        "/v1/auth/email/login",
        json={
            "email": "moved@example.com",
            "password": PASSWORD,
            "source_surface": "android",
            "app_version": "114",
        },
        headers=_headers(device["api_token"]),
    ).status_code == 200

    row = _registration_row(device["account_id"])
    assert row["source_surface"] == "ios", "source drifted to the most recent surface"
    assert row["last_seen_surface"] == "android", "recency has nowhere honest to live"


# ---------------------------------------------------------------------------
# Normalization / collision safety
# ---------------------------------------------------------------------------


def test_case_variants_are_the_same_identity(client, fake_auth):
    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={"email": "Mixed.Case@Example.COM", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )
    assert "mixed.case@example.com" in fake_auth.users

    fake_auth.confirm("mixed.case@example.com")
    r = client.post(
        "/v1/auth/email/login",
        json={"email": "MIXED.CASE@EXAMPLE.COM", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )
    assert r.status_code == 200, r.text
    assert r.json()["email"] == "mixed.case@example.com"


def test_plus_tag_is_a_different_mailbox(client, fake_auth):
    """A '+tag' address must NOT fold onto the bare address — folding it is a
    silent-merge vector that hands one person another person's account."""
    from backend.store import normalize_email

    assert normalize_email("victim+attacker@example.com") != normalize_email(
        "victim@example.com"
    )
    assert normalize_email("a.b@example.com") != normalize_email("ab@example.com")


def test_two_subjects_one_address_never_silently_merge(client, fake_auth):
    """Two DIFFERENT provider subjects presenting the same address spelling
    must not collapse into one account — that would hand the second person the
    first person's history and entitlement."""
    from backend.server import app
    from backend.store import AccountConflictError, get_store

    fake_auth.users["shared@example.com"] = {"password": PASSWORD, "confirmed": True}
    _wire(app, fake_auth, subject_for=lambda email: "subject-one")

    first = client.post(
        "/v1/auth/email/login",
        json={"email": "shared@example.com", "password": PASSWORD},
    ).json()

    store = get_store()
    other = store.create_bare_account()
    with pytest.raises(AccountConflictError):
        store.mark_email_verified(account_id=other.id, email="shared@example.com")

    # The first account still owns the address, unchanged.
    assert store.get_account(first["account_id"]).email == "shared@example.com"


def test_malformed_addresses_are_refused_without_provider_contact(client, fake_auth):
    for bad in ("", "   ", "not-an-address", "a@b", "two@@example.com", "a b@example.com"):
        r = client.post(
            "/v1/auth/email/register", json={"email": bad, "password": PASSWORD}
        )
        assert r.status_code == 400, (bad, r.status_code)
    assert fake_auth.sent == [], "a malformed address must never reach the provider"


def test_weak_password_is_refused_before_the_provider(client, fake_auth):
    r = client.post(
        "/v1/auth/email/register", json={"email": "person@example.com", "password": "short"}
    )
    assert r.status_code == 400
    assert fake_auth.sent == []


def test_a_second_subject_on_a_taken_address_is_told_so_not_a_500(client):
    """The store refuses to merge two provider subjects onto one address (see
    the test above). That refusal has to reach the person as an answer.

    Uncaught, `AccountConflictError` left the endpoint as a raw 500 — the one
    shape that must never reach a screen, and the least actionable one: no
    next step, and indistinguishable from the server being broken.
    """
    from backend.server import app

    fake = FakeEmailAuth()
    subjects = {"shared@example.com": "subject-one"}
    _wire(app, fake, subject_for=lambda email: subjects[email])
    fake.users["shared@example.com"] = {"password": PASSWORD, "confirmed": True}

    assert (
        client.post(
            "/v1/auth/email/login",
            json={"email": "shared@example.com", "password": PASSWORD},
        ).status_code
        == 200
    )

    subjects["shared@example.com"] = "subject-two"
    fresh = _register_device(client)
    second = client.post(
        "/v1/auth/email/login",
        json={"email": "shared@example.com", "password": PASSWORD},
        headers=_headers(fresh["api_token"]),
    )
    assert second.status_code == 409, second.text
    assert second.json()["error"]["message"] == "account_conflict"
    # The refusal describes the request, never the other account.
    assert "subject-one" not in second.text


@pytest.mark.parametrize(
    "status_code,payload,expected",
    [
        # Facts about the submitted string. Answered plainly — they enumerate
        # nothing, and swallowing them strands the person.
        (422, {"error_code": "weak_password"}, "WEAK_PASSWORD"),
        (400, {"error_code": "email_address_invalid"}, "INVALID_EMAIL"),
        (403, {"error_code": "email_address_not_authorized"}, "INVALID_EMAIL"),
        # Operational, never "we sent you an email".
        (403, {"error_code": "signup_disabled"}, "PROVIDER_UNAVAILABLE"),
        (500, {}, "PROVIDER_UNAVAILABLE"),
        # Facts about the ACCOUNT. These must stay collapsed into one outcome
        # so register/resend/reset can answer them identically.
        (422, {"error_code": "user_already_exists"}, "INVALID_CREDENTIALS"),
        (400, {"error_code": "invalid_credentials"}, "INVALID_CREDENTIALS"),
        (429, {"error_code": "over_email_send_rate_limit"}, "RATE_LIMITED"),
        (400, {"error_code": "email_not_confirmed"}, "VERIFICATION_REQUIRED"),
    ],
)
def test_provider_responses_classify_by_code_not_by_message(status_code, payload, expected):
    """The classifier reads status class and the stable `error_code` only.

    Each row also carries a human `msg` that would be wrong to show anyone;
    the outcome must not depend on it, and it must not survive into the result.
    """
    import httpx

    import backend.email_auth as email_auth

    body = dict(payload, msg="Signups not allowed for this instance (project abc123)")
    got = email_auth.SupabaseEmailAuthClient._classify(httpx.Response(status_code, json=body))
    assert got.name == expected, (payload, got)


def test_a_provider_refusal_of_the_input_is_never_answered_as_delivery(client):
    """A project that requires a digit, or whose validator rejects the domain,
    refuses the signup outright. Answering `verification_pending` there tells
    someone to watch an inbox that will never receive anything — with nothing
    to act on and no way to find out why. It is the one failure on this path a
    person cannot recover from alone.
    """
    import backend.email_auth as email_auth
    from backend.server import app

    for outcome, expected_word in (
        (email_auth.EmailAuthOutcome.WEAK_PASSWORD, "password"),
        (email_auth.EmailAuthOutcome.INVALID_EMAIL, "email"),
    ):
        fake = FakeEmailAuth()
        _wire(app, fake)
        fake.fail_with = outcome
        r = client.post(
            "/v1/auth/email/register",
            json={"email": "brand-new@example.com", "password": PASSWORD},
        )
        assert r.status_code == 400, (outcome, r.text)
        message = r.json()["error"]["message"]
        assert expected_word in message, (outcome, message)
        # Actionable, and still no provider text.
        assert "supabase" not in message.lower()
        assert fake.sent == []


def test_an_already_registered_address_still_answers_as_delivery(client):
    """The guard on the test above: reporting input refusals must not have
    reopened the enumeration channel. `user_already_exists` classifies as
    INVALID_CREDENTIALS and still gets the identical accepted answer a brand
    new address gets."""
    import backend.email_auth as email_auth
    from backend.server import app

    fake = FakeEmailAuth()
    _wire(app, fake)
    fake.fail_with = email_auth.EmailAuthOutcome.INVALID_CREDENTIALS

    r = client.post(
        "/v1/auth/email/register",
        json={"email": "brand-new@example.com", "password": PASSWORD},
    )
    assert r.status_code == 202
    assert r.json() == {"status": "verification_pending"}


# ---------------------------------------------------------------------------
# Sessions: logout, relogin, second device, reinstall
# ---------------------------------------------------------------------------


def test_logout_revokes_this_bearer_and_relogin_returns_same_account(client, fake_auth):
    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={"email": "again@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )
    fake_auth.confirm("again@example.com")
    session = client.post(
        "/v1/auth/email/login",
        json={"email": "again@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    ).json()

    out = client.post("/v1/auth/email/logout", headers=_headers(session["api_token"]))
    assert out.status_code == 200 and out.json()["signed_out"] is True

    # The old bearer is dead immediately.
    assert client.get("/v1/me", headers=_headers(session["api_token"])).status_code == 401

    # Signing back in returns the SAME canonical person.
    again = client.post(
        "/v1/auth/email/login",
        json={"email": "again@example.com", "password": PASSWORD},
    ).json()
    assert again["account_id"] == session["account_id"]


def test_second_device_and_fresh_install_resolve_the_same_person(client, fake_auth):
    first_device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={"email": "multi@example.com", "password": PASSWORD},
        headers=_headers(first_device["api_token"]),
    )
    fake_auth.confirm("multi@example.com")
    first = client.post(
        "/v1/auth/email/login",
        json={"email": "multi@example.com", "password": PASSWORD},
        headers=_headers(first_device["api_token"]),
    ).json()

    # A second device (iPad) registers its own device row, then signs in.
    second_device = _register_device(client)
    second = client.post(
        "/v1/auth/email/login",
        json={"email": "multi@example.com", "password": PASSWORD},
        headers=_headers(second_device["api_token"]),
    ).json()

    # A fresh install carries NO bearer at all — the endpoint mints a device.
    reinstall = client.post(
        "/v1/auth/email/login",
        json={"email": "multi@example.com", "password": PASSWORD},
    ).json()

    assert first["account_id"] == second["account_id"] == reinstall["account_id"]
    assert len({first["device_id"], second["device_id"], reinstall["device_id"]}) == 3


def test_registration_events_are_queryable_and_hold_no_secrets(client, fake_auth):
    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={
            "email": "audit@example.com",
            "password": PASSWORD,
            "source_surface": "android",
            "app_version": "15",
        },
        headers=_headers(device["api_token"]),
    )
    fake_auth.confirm("audit@example.com")
    session = client.post(
        "/v1/auth/email/login",
        json={
            "email": "audit@example.com",
            "password": PASSWORD,
            "source_surface": "android",
            "app_version": "15",
        },
        headers=_headers(device["api_token"]),
    ).json()

    payload = client.get(
        "/v1/account/registration-events", headers=_headers(session["api_token"])
    ).json()

    assert payload["lifecycle_state"] == "verified"
    assert payload["email_verified"] is True
    kinds = [e["event_type"] for e in payload["events"]]
    assert "signup_requested" in kinds
    assert "verification_completed" in kinds

    for event in payload["events"]:
        assert event["occurred_at"]
        assert event["source_surface"] == "android"
        assert event["app_build"] == "15"
        blob = repr(event).lower()
        for forbidden in (PASSWORD, "audit@example.com", "token", "password", "secret"):
            assert forbidden.lower() not in blob, (forbidden, event)

    # And the registration record answers the durable-state questions.
    from backend.store import get_store

    row = get_store().get_registration(session["account_id"])
    assert row["lifecycle_state"] == "verified"
    assert row["created_at"] and row["verified_at"] and row["last_sign_in_at"]
    assert row["last_seen_at"] and row["source_surface"] == "android"


def test_one_account_cannot_read_another_accounts_registration_history(client, fake_auth):
    a_device = _register_device(client)
    b_device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={"email": "a@example.com", "password": PASSWORD},
        headers=_headers(a_device["api_token"]),
    )

    a = client.get(
        "/v1/account/registration-events", headers=_headers(a_device["api_token"])
    ).json()
    b = client.get(
        "/v1/account/registration-events", headers=_headers(b_device["api_token"])
    ).json()

    assert a["account_id"] != b["account_id"]
    assert b["events"] == [], "B must not see A's registration history"
    # There is no account_id parameter to forge — scope comes from the bearer.
    forged = client.get(
        f"/v1/account/registration-events?account_id={a['account_id']}",
        headers=_headers(b_device["api_token"]),
    ).json()
    assert forged["account_id"] == b["account_id"]


def test_registration_events_require_authentication(client, fake_auth):
    assert client.get("/v1/account/registration-events").status_code == 401


# ---------------------------------------------------------------------------
# Lifecycle state machine (executed, not read)
# ---------------------------------------------------------------------------


def test_verified_registration_cannot_be_walked_back_to_pending(client, fake_auth):
    """A device bearer must not be able to un-verify the account it is signed
    into by replaying a signup event."""
    import backend.email_identity as email_identity

    assert (
        email_identity.next_state(
            email_identity.STATE_VERIFIED, email_identity.EVENT_SIGNUP_REQUESTED
        )
        == email_identity.STATE_VERIFIED
    )
    assert (
        email_identity.next_state(
            email_identity.STATE_DISABLED, email_identity.EVENT_VERIFICATION_COMPLETED
        )
        == email_identity.STATE_DISABLED
    )
    assert (
        email_identity.next_state(None, email_identity.EVENT_SIGNUP_REQUESTED)
        == email_identity.STATE_PENDING
    )
    with pytest.raises(ValueError):
        email_identity.next_state(None, "not-a-real-event")


def test_store_refuses_an_unknown_event_type(client, fake_auth):
    from backend.store import get_store

    store = get_store()
    account = store.create_bare_account()
    with pytest.raises(ValueError):
        store.record_registration_event(
            account_id=account.id, event_type="free_text_injection"
        )


def test_deleted_account_is_not_recoverable_by_email(client, fake_auth):
    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={"email": "gone@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )
    fake_auth.confirm("gone@example.com")
    session = client.post(
        "/v1/auth/email/login",
        json={"email": "gone@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    ).json()

    assert client.delete("/v1/account", headers=_headers(session["api_token"])).status_code == 200

    from backend.store import get_store

    store = get_store()
    assert store.find_accounts_by_email("gone@example.com") == []
    account = store.get_account(session["account_id"])
    assert account.deleted_at
    assert account.email is None
    assert account.email_normalized is None
    assert account.email_verified_at is None
    assert account.lifecycle_state == "disabled"
    # The registration ledger is the SECOND place the address lives. Leaving
    # it at `verified` would keep the partial unique index reserving the
    # mailbox for an account that no longer exists.
    registration = store.get_registration(session["account_id"])
    assert registration["lifecycle_state"] == "disabled"
    assert registration["email_normalized"] is None


def test_deletion_is_terminal_for_the_data_not_a_lockout_of_the_address(client, fake_auth):
    """Deleting an account must not permanently reserve the person's own
    mailbox.

    Coming back means a NEW canonical account: deletion cleared the provider
    subject, so nothing resolves to the tombstone. If the old registration row
    still held the address as `verified`, `mark_email_verified` refused the new
    account as "already belongs to a different account" — which surfaced as an
    unhandled 500 and locked the person out of their own address with no way
    back.
    """
    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={"email": "again@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )
    fake_auth.confirm("again@example.com")
    first = client.post(
        "/v1/auth/email/login",
        json={"email": "again@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    ).json()
    assert client.delete("/v1/account", headers=_headers(first["api_token"])).status_code == 200

    fresh = _register_device(client)
    again = client.post(
        "/v1/auth/email/login",
        json={"email": "again@example.com", "password": PASSWORD},
        headers=_headers(fresh["api_token"]),
    )
    assert again.status_code == 200, again.text
    reborn = again.json()

    # A genuinely new person: none of the deleted account's history follows.
    assert reborn["account_id"] != first["account_id"]
    assert reborn["email"] == "again@example.com"
    assert reborn["is_pro"] is False

    from backend.store import get_store

    store = get_store()
    assert store.get_account(first["account_id"]).deleted_at
    assert [a.id for a in store.find_accounts_by_email("again@example.com")] == [
        reborn["account_id"]
    ]


def test_email_registration_does_not_disturb_an_existing_verified_identity(client, fake_auth):
    """Re-pointing a live login identity at a different address is refused."""
    from backend.store import AccountConflictError, get_store

    store = get_store()
    account = store.create_bare_account()
    store.mark_email_verified(account_id=account.id, email="owner@example.com")

    with pytest.raises(AccountConflictError):
        store.begin_email_registration(account_id=account.id, email="attacker@example.com")

    assert store.get_account(account.id).email == "owner@example.com"


def test_me_reports_the_account_path_fields_every_client_decodes(client, fake_auth):
    """iOS `TonoMe` has decoded `email` / `email_verified_at` since 2026-07-03
    while the server returned neither. A client that cannot tell a signed-in
    person from an anonymous one cannot show the right account UI."""
    device = _register_device(client)

    anon = client.get("/v1/me", headers=_headers(device["api_token"])).json()
    assert anon["email"] is None
    assert anon["email_verified_at"] is None
    assert anon["lifecycle_state"] == "anonymous"

    client.post(
        "/v1/auth/email/register",
        json={"email": "shape@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )
    pending = client.get("/v1/me", headers=_headers(device["api_token"])).json()
    assert pending["lifecycle_state"] == "pending"
    assert pending["email"] is None, "a pending registration must not read as a proven address"

    fake_auth.confirm("shape@example.com")
    session = client.post(
        "/v1/auth/email/login",
        json={"email": "shape@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    ).json()
    verified = client.get("/v1/me", headers=_headers(session["api_token"])).json()
    assert verified["email"] == "shape@example.com"
    assert verified["email_verified_at"]
    assert verified["lifecycle_state"] == "verified"
    # Still not entitlement.
    assert verified["is_pro"] is False


def test_legacy_anonymous_client_still_registers_and_is_unaffected(client, fake_auth):
    """An old build that knows nothing about email keeps working, and its
    account is `anonymous` rather than being dragged into a pending state."""
    device = _register_device(client)
    me = client.get("/v1/me", headers=_headers(device["api_token"])).json()
    assert me["account_id"] == device["account_id"]

    from backend.store import get_store

    assert get_store().get_account(device["account_id"]).lifecycle_state == "anonymous"


# ---------------------------------------------------------------------------
# The audit trail records the two things a person would otherwise have to
# report themselves: "I was blocked because I hadn't confirmed" and "the
# provider was down when I tried".
# ---------------------------------------------------------------------------


def _events_for(client, token: str) -> list[str]:
    payload = client.get(
        "/v1/account/registration-events", headers=_headers(token)
    ).json()
    return [e["event_type"] for e in payload["events"]]


def test_a_login_blocked_for_want_of_confirmation_is_recorded(client, fake_auth):
    """Mandatory verification is only auditable if being held at it leaves a
    trace. Without this row, "I never got the email" is answerable only from
    the person's own account of events."""
    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={"email": "blocked@example.com", "password": PASSWORD, "source_surface": "ios"},
        headers=_headers(device["api_token"]),
    )

    r = client.post(
        "/v1/auth/email/login",
        json={"email": "blocked@example.com", "password": PASSWORD, "source_surface": "ios"},
    )
    assert r.status_code == 403

    kinds = _events_for(client, device["api_token"])
    assert "verification_pending_blocked" in kinds
    # And it is an audit fact only: the registration is still pending, not
    # advanced and not disabled.
    payload = client.get(
        "/v1/account/registration-events", headers=_headers(device["api_token"])
    ).json()
    assert payload["lifecycle_state"] == "pending"
    assert payload["email_verified"] is False


def test_an_outage_is_recorded_as_an_outage_and_a_rate_limit_is_not(client, fake_auth):
    """The distinction is the whole point of the row. If a throttle were
    audited as an outage, the count of "registrations an outage cost us" would
    be indistinguishable from the count of people typing too fast."""
    import backend.email_auth as email_auth

    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={"email": "outage@example.com", "password": PASSWORD},
        headers=_headers(device["api_token"]),
    )
    baseline = _events_for(client, device["api_token"])
    assert "provider_unavailable" not in baseline

    # The provider goes down.
    fake_auth.fail_with = email_auth.EmailAuthOutcome.PROVIDER_UNAVAILABLE
    r = client.post(
        "/v1/auth/email/resend", json={"email": "outage@example.com", "source_surface": "ios"}
    )
    assert r.status_code == 503
    assert _events_for(client, device["api_token"]).count("provider_unavailable") == 1

    # A throttle is NOT an outage.
    fake_auth.fail_with = email_auth.EmailAuthOutcome.RATE_LIMITED
    r = client.post(
        "/v1/auth/email/reset", json={"email": "outage@example.com", "source_surface": "ios"}
    )
    assert r.status_code == 429
    assert _events_for(client, device["api_token"]).count("provider_unavailable") == 1


def test_an_outage_on_register_is_recorded_without_an_address(client, fake_auth):
    """An outage row must be writable for a caller who has no account yet —
    that is most of them, on the surface that matters most — and it must carry
    no address, because an audit row for an unknown person is exactly where an
    identifier must not be duplicated."""
    import backend.email_auth as email_auth

    from backend.store import get_store

    fake_auth.fail_with = email_auth.EmailAuthOutcome.PROVIDER_UNAVAILABLE
    r = client.post(
        "/v1/auth/email/register",
        json={
            "email": "nobody@example.com",
            "password": PASSWORD,
            "source_surface": "android",
            "app_version": "114",
        },
    )
    assert r.status_code == 503

    store = get_store()
    rows = store._run(  # noqa: SLF001 — reading the raw audit table is the point
        lambda: [
            dict(r)
            for r in store._conn.execute(
                "SELECT * FROM account_registration_events WHERE event_type = ?",
                ("provider_unavailable",),
            ).fetchall()
        ]
    ).result()
    assert len(rows) == 1
    assert rows[0]["account_id"] is None
    assert rows[0]["source_surface"] == "android"
    assert rows[0]["app_build"] == "114"
    blob = repr(rows[0]).lower()
    for forbidden in ("nobody@example.com", PASSWORD.lower(), "password", "token"):
        assert forbidden not in blob


def test_the_event_vocabulary_contains_only_codes_the_server_can_write(client, fake_auth):
    """A closed allow-list is only honest if every code in it is reachable. A
    code nothing can ever write reads as a promise the server does not keep,
    and it is the kind of thing a later reader implements a client for."""
    import backend.email_identity as email_identity
    import backend.server as server_module
    import inspect

    source = inspect.getsource(server_module) + inspect.getsource(
        __import__("backend.store", fromlist=["x"])
    )
    for event in email_identity.EVENT_TYPES:
        constant = next(
            name
            for name, value in vars(email_identity).items()
            if name.startswith("EVENT_") and value == event
        )
        assert f"email_identity.{constant}" in source, (
            f"{constant} is in the vocabulary but nothing writes it"
        )


# ---------------------------------------------------------------------------
# Aggregate reporting — "Tono tracks registrations"
# ---------------------------------------------------------------------------

_ADMIN_SECRET = "admin-secret-for-tests"
_ADMIN_HEADERS = {"X-Admin-Secret": _ADMIN_SECRET}


def test_registrations_are_countable_by_state_surface_and_build(
    client, fake_auth, monkeypatch
):
    """Recording registrations and being able to COUNT them are different
    claims. This one is the second: an operator asking "is signup working"
    must get an answer that does not depend on knowing an account id."""
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)

    # One person who registers and confirms, from iOS.
    verified = _register_device(client)
    r = client.post(
        "/v1/auth/email/register",
        json={
            "email": "verified@example.com",
            "password": PASSWORD,
            "source_surface": "ios",
            "app_version": "114",
        },
        headers=_headers(verified["api_token"]),
    )
    assert r.status_code == 202, r.text
    fake_auth.confirm("verified@example.com")
    r = client.post(
        "/v1/auth/email/login",
        json={
            "email": "verified@example.com",
            "password": PASSWORD,
            "source_surface": "ios",
            "app_version": "114",
        },
        headers=_headers(verified["api_token"]),
    )
    assert r.status_code == 200, r.text

    # And one who registers from Android and never confirms.
    pending = _register_device(client)
    r = client.post(
        "/v1/auth/email/register",
        json={
            "email": "pending@example.com",
            "password": PASSWORD,
            "source_surface": "android",
            "app_version": "114",
        },
        headers=_headers(pending["api_token"]),
    )
    assert r.status_code == 202, r.text

    report = client.get("/admin/registrations", headers=_ADMIN_HEADERS)
    assert report.status_code == 200, report.text
    body = report.json()

    assert body["registrations_total"] == 2
    assert body["by_lifecycle_state"]["verified"] == 1
    assert body["by_lifecycle_state"]["pending"] == 1
    assert body["by_source_surface"]["ios"] == 1
    assert body["by_source_surface"]["android"] == 1
    assert body["by_app_build"]["114"] == 2
    assert body["created_in_window"] == 2
    assert body["verified_in_window"] == 1
    assert body["signed_in_in_window"] == 1
    # The event histogram is the "how did we get here" half: a registration
    # that stalls before confirmation must be visible as such.
    assert body["events_in_window"]["signup_requested"] == 2
    assert body["events_in_window"]["verification_completed"] == 1
    assert body["events_in_window"]["sign_in"] == 1


def test_the_registration_report_can_hold_no_address_or_account_id(
    client, fake_auth, monkeypatch
):
    """The PII-minimization is structural, not a filter. If a future change
    starts selecting rows instead of counts, this turns red."""
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)

    device = _register_device(client)
    client.post(
        "/v1/auth/email/register",
        json={
            "email": "someone@example.com",
            "password": PASSWORD,
            "source_surface": "ios",
            "app_version": "114",
        },
        headers=_headers(device["api_token"]),
    )

    body = client.get("/admin/registrations", headers=_ADMIN_HEADERS).json()
    blob = repr(body).lower()
    for forbidden in (
        "someone@example.com",
        "someone",
        "example.com",
        PASSWORD.lower(),
        device["device_id"].lower(),
    ):
        assert forbidden not in blob, f"the aggregate report leaked {forbidden!r}"

    # And every value in it is a count, so there is nothing else it could be.
    for histogram in (
        body["by_lifecycle_state"],
        body["by_source_surface"],
        body["by_app_build"],
        body["events_in_window"],
    ):
        assert all(isinstance(v, int) for v in histogram.values())


def test_the_registration_report_is_admin_only(client, fake_auth, monkeypatch):
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)
    assert client.get("/admin/registrations").status_code == 403
    assert (
        client.get(
            "/admin/registrations", headers={"X-Admin-Secret": "wrong"}
        ).status_code
        == 403
    )


def test_an_unconfigured_admin_secret_closes_the_report_rather_than_opening_it(
    client, fake_auth, monkeypatch
):
    """Fail closed. An empty secret must never compare equal to an empty
    header — that is the shape that turns a missing config into an open
    endpoint."""
    monkeypatch.delenv("TONO_ADMIN_SECRET", raising=False)
    assert client.get("/admin/registrations", headers={"X-Admin-Secret": ""}).status_code == 403
    assert client.get("/admin/registrations", headers=_ADMIN_HEADERS).status_code == 403


def test_the_reporting_window_is_bounded_and_never_crashes_on_a_hostile_value(
    client, fake_auth, monkeypatch
):
    """`days` is a query parameter, so it is client input. Clamped rather than
    rejected: an out-of-range window is a typo, not an attack, and answering
    with the nearest sane window beats a 400 an operator has to decode."""
    monkeypatch.setenv("TONO_ADMIN_SECRET", _ADMIN_SECRET)
    for requested, expected in ((0, 1), (-5, 1), (99999, 365), (30, 30)):
        body = client.get(
            f"/admin/registrations?days={requested}", headers=_ADMIN_HEADERS
        ).json()
        assert body["days"] == expected
