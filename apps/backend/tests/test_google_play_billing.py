"""Google Play server-side entitlement contract — hostile GO tests.

Every test runs against a fresh SQLite DB (conftest `_isolate_db`) through the
real FastAPI app and the real store; none of them merely greps source.

Google Play purchase tokens are opaque and carry no self-verifiable claims, so
there is no signing chain to stand up (unlike Apple). Security lives entirely in
the authenticated server-to-server Developer API call and the OIDC-authenticated
RTDN push. We therefore inject a fake Developer API verifier and a fake push
authenticator via `app.dependency_overrides` — the same indirection app_store's
suite uses — and drive the full endpoint + store + projection path with
adversarial provider states.

The canonical `pro` entitlement these tests assert on is the SAME projection
Stripe and Apple use: an active, unexpired row in `entitlement_grants`, surfaced
through `/v1/me`.`is_pro`.
"""

from __future__ import annotations

import base64
import datetime as dt
import json
import os
import sqlite3
import uuid

import pytest

PRODUCT = "com.tonoit.pro.monthly"
PRODUCT_YEAR = "com.tonoit.pro.yearly"
BASE_PLAN = "pro-monthly"
BASE_PLAN_YEAR = "pro-yearly"
PACKAGE = "com.tono.myapp"

STATE_ACTIVE = "SUBSCRIPTION_STATE_ACTIVE"
STATE_CANCELED = "SUBSCRIPTION_STATE_CANCELED"
STATE_GRACE = "SUBSCRIPTION_STATE_IN_GRACE_PERIOD"
STATE_ON_HOLD = "SUBSCRIPTION_STATE_ON_HOLD"
STATE_PAUSED = "SUBSCRIPTION_STATE_PAUSED"
STATE_EXPIRED = "SUBSCRIPTION_STATE_EXPIRED"

NTYPE_RECOVERED = 1
NTYPE_RENEWED = 2
NTYPE_CANCELED = 3
NTYPE_PURCHASED = 4
NTYPE_ON_HOLD = 5
NTYPE_REVOKED = 12
NTYPE_EXPIRED = 13


# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------


def _future_rfc3339(days: int = 30) -> str:
    return (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=days)).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def _past_rfc3339(days: int = 1) -> str:
    return (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def raw_sub(
    *,
    state=STATE_ACTIVE,
    product=PRODUCT,
    base_plan=BASE_PLAN,
    obfuscated=None,
    expiry=None,
    linked=None,
    acknowledged=False,
    test=False,
    with_offer=True,
):
    """Build a verified SubscriptionPurchaseV2-shaped dict the way the Developer
    API returns it."""
    line_item = {
        "productId": product,
        "expiryTime": expiry if expiry is not None else _future_rfc3339(),
    }
    if with_offer:
        line_item["offerDetails"] = {"basePlanId": base_plan, "offerTags": []}
    payload = {
        "subscriptionState": state,
        "lineItems": [line_item],
        "acknowledgementState": (
            "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED"
            if acknowledged
            else "ACKNOWLEDGEMENT_STATE_PENDING"
        ),
    }
    if obfuscated is not None:
        payload["externalAccountIdentifiers"] = {"obfuscatedExternalAccountId": obfuscated}
    if linked is not None:
        payload["linkedPurchaseToken"] = linked
    if test:
        payload["testPurchase"] = {}
    return payload


class FakeVerifier:
    def __init__(self):
        self.subs: dict[str, dict] = {}
        self.not_found: set[str] = set()
        self.unavailable: set[str] = set()
        self.acked: list[tuple[str, str]] = []
        self.ack_fail: set[str] = set()

    def get_subscription_v2(self, package_name, token):
        from backend import google_play

        assert package_name == PACKAGE
        if token in self.unavailable:
            raise google_play.GooglePlayUnavailable("transient")
        if token in self.not_found:
            raise google_play.GooglePlayNotFound("gone")
        return self.subs[token]

    def acknowledge(self, package_name, subscription_id, token):
        from backend import google_play

        if token in self.ack_fail:
            raise google_play.GooglePlayUnavailable("ack transient")
        self.acked.append((subscription_id, token))


class FakePushAuth:
    def __init__(self, ok=True):
        self.ok = ok

    def verify(self, request):
        from backend import google_play

        if not self.ok:
            raise google_play.GooglePushAuthError("rejected")


# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------


@pytest.fixture
def gp(client):
    """Install the fake Developer API verifier + push authenticator + a config
    whose base-plan allow-set is populated (so grants are possible). `client`
    first so the app module is imported and shared."""
    from backend import google_play
    from backend.server import app

    verifier = FakeVerifier()
    auth = FakePushAuth(ok=True)
    config = google_play.GooglePlayConfig(
        package_name=PACKAGE,
        subscription_ids=frozenset({PRODUCT, PRODUCT_YEAR}),
        base_plan_ids=frozenset({BASE_PLAN, BASE_PLAN_YEAR}),
    )

    app.dependency_overrides[google_play.get_google_play_verifier] = lambda: verifier
    app.dependency_overrides[google_play.get_google_push_authenticator] = lambda: auth
    app.dependency_overrides[google_play.get_google_play_config] = lambda: config

    class Ctx:
        pass

    ctx = Ctx()
    ctx.verifier = verifier
    ctx.auth = auth
    ctx.config = config
    ctx.app = app
    yield ctx

    for dep in (
        google_play.get_google_play_verifier,
        google_play.get_google_push_authenticator,
        google_play.get_google_play_config,
    ):
        app.dependency_overrides.pop(dep, None)


def _register(client) -> dict:
    r = client.post("/v1/register", json={"platform": "android"})
    assert r.status_code == 200, r.text
    return r.json()


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _me(client, token: str) -> dict:
    r = client.get("/v1/me", headers=_auth(token))
    assert r.status_code == 200, r.text
    return r.json()


def _sync(client, token: str, purchase_token: str, subscription_id=PRODUCT):
    return client.post(
        "/v1/google-play/subscription",
        json={"purchase_token": purchase_token, "subscription_id": subscription_id},
        headers=_auth(token),
    )


def rtdn_envelope(
    *,
    message_id,
    token,
    ntype=NTYPE_RENEWED,
    subscription_id=PRODUCT,
    package=PACKAGE,
    version="1.0",
    event_ms=None,
    test=False,
):
    payload = {
        "version": version,
        "packageName": package,
        "eventTimeMillis": str(event_ms if event_ms is not None else _now_ms()),
    }
    if test:
        payload["testNotification"] = {"version": "1.0"}
    else:
        payload["subscriptionNotification"] = {
            "version": "1.0",
            "notificationType": ntype,
            "purchaseToken": token,
            "subscriptionId": subscription_id,
        }
    data = base64.b64encode(json.dumps(payload).encode()).decode()
    return {
        "message": {"data": data, "messageId": str(message_id)},
        "subscription": "projects/tono/subscriptions/rtdn",
    }


def _notify(client, envelope):
    return client.post("/v1/google-play/notifications", json=envelope)


def _now_ms() -> int:
    return int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)


def _db_scalar(sql: str, params=()) -> int:
    con = sqlite3.connect(os.environ["TONO_DB_PATH"])
    try:
        row = con.execute(sql, params).fetchone()
        return row[0] if row else 0
    finally:
        con.close()


# ===========================================================================
# Happy path + acknowledgement
# ===========================================================================


def test_active_purchase_grants_pro_and_acknowledges(client, gp):
    reg = _register(client)
    token = "tok-active-1"
    gp.verifier.subs[token] = raw_sub(obfuscated=reg["account_id"])

    r = _sync(client, reg["api_token"], token)
    assert r.status_code == 200, r.text
    assert r.json()["is_pro"] is True
    assert r.json()["daily_limit"] == -1
    # Acknowledged exactly once, only after the grant.
    assert gp.verifier.acked == [(PRODUCT, token)]
    # No pending ack op left behind.
    assert _db_scalar(
        "SELECT COUNT(*) FROM provider_operations WHERE op_kind='acknowledge' AND state='pending'"
    ) == 0
    # Durable provider projection exists with provider='google'.
    assert _db_scalar(
        "SELECT COUNT(*) FROM provider_purchases WHERE provider='google' AND lifecycle_state='active'"
    ) == 1


def test_already_acknowledged_purchase_does_not_reacknowledge(client, gp):
    reg = _register(client)
    token = "tok-acked"
    gp.verifier.subs[token] = raw_sub(obfuscated=reg["account_id"], acknowledged=True)
    r = _sync(client, reg["api_token"], token)
    assert r.status_code == 200
    assert r.json()["is_pro"] is True
    assert gp.verifier.acked == []  # never re-acknowledged


def test_client_product_claim_is_ignored_verified_product_wins(client, gp):
    reg = _register(client)
    token = "tok-liar"
    # Client lies that it bought yearly; the verified API says monthly.
    gp.verifier.subs[token] = raw_sub(product=PRODUCT, obfuscated=reg["account_id"])
    r = client.post(
        "/v1/google-play/subscription",
        json={"purchase_token": token, "subscription_id": PRODUCT_YEAR},
        headers=_auth(reg["api_token"]),
    )
    assert r.status_code == 200
    assert r.json()["is_pro"] is True
    stored = _db_scalar(
        "SELECT COUNT(*) FROM provider_purchases WHERE product_id=? AND provider='google'",
        (PRODUCT,),
    )
    assert stored == 1


# ===========================================================================
# Ownership binding / cross-account replay
# ===========================================================================


def test_token_replay_across_accounts_conflicts_via_obfuscated(client, gp):
    a = _register(client)
    b = _register(client)
    token = "tok-bound-A"
    # Purchase is bound to A via obfuscatedExternalAccountId.
    gp.verifier.subs[token] = raw_sub(obfuscated=a["account_id"])
    assert _sync(client, a["api_token"], token).status_code == 200
    # B replays the same token -> deterministic conflict, never a grant.
    r = _sync(client, b["api_token"], token)
    assert r.status_code == 409, r.text
    assert _me(client, b["api_token"])["is_pro"] is False


def test_token_replay_across_accounts_conflicts_via_first_claim(client, gp):
    a = _register(client)
    b = _register(client)
    token = "tok-tokenless"
    # No obfuscated id -> first authenticated claimant (A) wins the lineage.
    gp.verifier.subs[token] = raw_sub(obfuscated=None)
    assert _sync(client, a["api_token"], token).status_code == 200
    assert _me(client, a["api_token"])["is_pro"] is True
    r = _sync(client, b["api_token"], token)
    assert r.status_code == 409
    assert _me(client, b["api_token"])["is_pro"] is False


def test_obfuscated_matching_account_grants_direct(client, gp):
    reg = _register(client)
    token = "tok-match"
    gp.verifier.subs[token] = raw_sub(obfuscated=reg["account_id"])
    assert _sync(client, reg["api_token"], token).status_code == 200
    assert _me(client, reg["api_token"])["is_pro"] is True


# ===========================================================================
# Package / product / base-plan validation (fail closed)
# ===========================================================================


def test_unknown_product_fails_closed(client, gp):
    reg = _register(client)
    token = "tok-badproduct"
    gp.verifier.subs[token] = raw_sub(product="com.evil.other", obfuscated=reg["account_id"])
    r = _sync(client, reg["api_token"], token)
    assert r.status_code == 422
    assert _me(client, reg["api_token"])["is_pro"] is False


def test_missing_base_plan_ids_cannot_grant(client, gp):
    """§6: with the base-plan allow-set unconfigured, a verified ACTIVE purchase
    must NOT grant. Proves missing console ids fail closed."""
    from backend import google_play

    # Re-point the config dep at a config with an EMPTY base-plan allow-set.
    empty = google_play.GooglePlayConfig(
        package_name=PACKAGE,
        subscription_ids=frozenset({PRODUCT, PRODUCT_YEAR}),
        base_plan_ids=frozenset(),
    )
    gp.app.dependency_overrides[google_play.get_google_play_config] = lambda: empty

    reg = _register(client)
    token = "tok-noplan"
    gp.verifier.subs[token] = raw_sub(obfuscated=reg["account_id"])
    r = _sync(client, reg["api_token"], token)
    assert r.status_code == 422, r.text
    assert _me(client, reg["api_token"])["is_pro"] is False
    assert _db_scalar("SELECT COUNT(*) FROM entitlement_grants WHERE state='active'") == 0


def test_base_plan_outside_allow_set_cannot_grant(client, gp):
    reg = _register(client)
    token = "tok-wrongplan"
    gp.verifier.subs[token] = raw_sub(base_plan="smuggled-cheap-plan", obfuscated=reg["account_id"])
    r = _sync(client, reg["api_token"], token)
    assert r.status_code == 422
    assert _me(client, reg["api_token"])["is_pro"] is False


# ===========================================================================
# State handling
# ===========================================================================


def test_expired_state_does_not_grant(client, gp):
    reg = _register(client)
    token = "tok-expired"
    gp.verifier.subs[token] = raw_sub(
        state=STATE_EXPIRED, obfuscated=reg["account_id"], expiry=_past_rfc3339()
    )
    r = _sync(client, reg["api_token"], token)
    assert r.status_code == 200
    assert r.json()["is_pro"] is False


def test_grace_period_keeps_access(client, gp):
    reg = _register(client)
    token = "tok-grace"
    gp.verifier.subs[token] = raw_sub(state=STATE_GRACE, obfuscated=reg["account_id"])
    assert _sync(client, reg["api_token"], token).status_code == 200
    assert _me(client, reg["api_token"])["is_pro"] is True


@pytest.mark.parametrize("state", [STATE_ACTIVE, STATE_GRACE])
@pytest.mark.parametrize("expiry", ["missing", _past_rfc3339(), "not-a-timestamp"])
def test_entitled_states_require_parseable_future_expiry(client, gp, state, expiry):
    reg = _register(client)
    token = f"tok-expiry-{state}-{expiry}"
    snapshot = raw_sub(state=state, obfuscated=reg["account_id"], expiry=expiry)
    if expiry == "missing":
        snapshot["lineItems"][0].pop("expiryTime")
    gp.verifier.subs[token] = snapshot
    r = _sync(client, reg["api_token"], token)
    assert r.status_code == 422
    assert _me(client, reg["api_token"])["is_pro"] is False
    assert _db_scalar(
        "SELECT COUNT(*) FROM entitlement_grants WHERE state='active' AND expires_at IS NULL"
    ) == 0


@pytest.mark.parametrize("ack_state", [None, "UNKNOWN_ACK_STATE"])
def test_unknown_or_missing_acknowledgement_state_fails_closed(client, gp, ack_state):
    reg = _register(client)
    token = f"tok-ack-state-{ack_state}"
    snapshot = raw_sub(obfuscated=reg["account_id"])
    if ack_state is None:
        snapshot.pop("acknowledgementState")
    else:
        snapshot["acknowledgementState"] = ack_state
    gp.verifier.subs[token] = snapshot
    assert _sync(client, reg["api_token"], token).status_code == 422
    assert _me(client, reg["api_token"])["is_pro"] is False


def test_canceled_at_period_end_keeps_access_until_expiry(client, gp):
    reg = _register(client)
    token = "tok-cancel"
    gp.verifier.subs[token] = raw_sub(
        state=STATE_CANCELED, obfuscated=reg["account_id"], expiry=_future_rfc3339()
    )
    assert _sync(client, reg["api_token"], token).status_code == 200
    assert _me(client, reg["api_token"])["is_pro"] is True


def test_canceled_after_expiry_does_not_grant(client, gp):
    reg = _register(client)
    token = "tok-cancel-past"
    gp.verifier.subs[token] = raw_sub(
        state=STATE_CANCELED, obfuscated=reg["account_id"], expiry=_past_rfc3339()
    )
    r = _sync(client, reg["api_token"], token)
    assert r.status_code == 200
    assert r.json()["is_pro"] is False


def test_on_hold_revokes_then_recovery_regrants(client, gp):
    reg = _register(client)
    token = "tok-hold"
    gp.verifier.subs[token] = raw_sub(obfuscated=reg["account_id"])
    assert _sync(client, reg["api_token"], token).status_code == 200
    assert _me(client, reg["api_token"])["is_pro"] is True

    # On-hold RTDN: API now reports ON_HOLD -> entitlement removed but resurrectable.
    gp.verifier.subs[token] = raw_sub(state=STATE_ON_HOLD, obfuscated=reg["account_id"])
    _notify(client, rtdn_envelope(message_id="m-hold", token=token, ntype=NTYPE_ON_HOLD,
                                  event_ms=_now_ms() + 1000))
    assert _me(client, reg["api_token"])["is_pro"] is False

    # Recovery RTDN: API reports ACTIVE again -> access restored (not terminal).
    gp.verifier.subs[token] = raw_sub(state=STATE_ACTIVE, obfuscated=reg["account_id"])
    _notify(client, rtdn_envelope(message_id="m-recover", token=token, ntype=NTYPE_RECOVERED,
                                  event_ms=_now_ms() + 2000))
    assert _me(client, reg["api_token"])["is_pro"] is True


def test_test_purchase_grants_and_is_flagged(client, gp):
    reg = _register(client)
    token = "tok-test"
    gp.verifier.subs[token] = raw_sub(obfuscated=reg["account_id"], test=True)
    assert _sync(client, reg["api_token"], token).status_code == 200
    assert _me(client, reg["api_token"])["is_pro"] is True
    env = sqlite3.connect(os.environ["TONO_DB_PATH"]).execute(
        "SELECT environment FROM provider_purchases WHERE provider='google'"
    ).fetchone()[0]
    assert env == "test"


# ===========================================================================
# Terminal precedence / stale replay
# ===========================================================================


def test_stale_active_after_revoke_never_resurrects(client, gp):
    reg = _register(client)
    token = "tok-revoke"
    gp.verifier.subs[token] = raw_sub(obfuscated=reg["account_id"])
    assert _sync(client, reg["api_token"], token).status_code == 200
    assert _me(client, reg["api_token"])["is_pro"] is True

    # Refund/revoke via RTDN (authority re-queried; type escalates to terminal).
    # The revoke carries a REALISTIC (past) event time so the later client replay
    # has a STRICTLY HIGHER timestamp — this forces the hard-terminal precedence
    # guard (not merely the out-of-order guard) to be what blocks resurrection.
    _notify(client, rtdn_envelope(message_id="m-rev", token=token, ntype=NTYPE_REVOKED,
                                  event_ms=_now_ms() - 60_000))
    assert _me(client, reg["api_token"])["is_pro"] is False

    # A replayed still-"active" client sync (now_ms > revoke time) must NOT
    # resurrect the revoked lineage.
    gp.verifier.subs[token] = raw_sub(state=STATE_ACTIVE, obfuscated=reg["account_id"])
    r = _sync(client, reg["api_token"], token)
    assert r.status_code == 200
    assert r.json()["is_pro"] is False
    assert _db_scalar(
        "SELECT COUNT(*) FROM provider_purchases WHERE lifecycle_state='revoked' AND provider='google'"
    ) == 1


def test_expired_then_stale_active_does_not_resurrect(client, gp):
    reg = _register(client)
    token = "tok-exp"
    gp.verifier.subs[token] = raw_sub(obfuscated=reg["account_id"])
    assert _sync(client, reg["api_token"], token).status_code == 200

    # Expire via RTDN at a high event time.
    gp.verifier.subs[token] = raw_sub(state=STATE_EXPIRED, obfuscated=reg["account_id"],
                                      expiry=_past_rfc3339())
    _notify(client, rtdn_envelope(message_id="m-exp", token=token, ntype=NTYPE_EXPIRED,
                                  event_ms=_now_ms() + 10_000))
    assert _me(client, reg["api_token"])["is_pro"] is False


# ===========================================================================
# RTDN: dedupe / out-of-order / authority
# ===========================================================================


def test_duplicate_rtdn_is_deduped(client, gp):
    reg = _register(client)
    token = "tok-dup"
    gp.verifier.subs[token] = raw_sub(obfuscated=reg["account_id"])
    env = rtdn_envelope(message_id="dup-1", token=token, ntype=NTYPE_PURCHASED)
    r1 = _notify(client, env)
    r2 = _notify(client, env)
    assert r1.status_code == 200 and r2.status_code == 200
    assert r2.json()["outcome"] == "duplicate"
    assert _db_scalar(
        "SELECT COUNT(*) FROM provider_transactions WHERE provider='google' AND event_id='dup-1'"
    ) == 1


def test_out_of_order_rtdn_older_event_ignored(client, gp):
    reg = _register(client)
    token = "tok-ooo"
    gp.verifier.subs[token] = raw_sub(obfuscated=reg["account_id"])
    assert _sync(client, reg["api_token"], token).status_code == 200

    # A stale on-hold notification with a LOWER event time than the sync must not
    # win over the newer active state. Re-query still returns active here, but the
    # store's out-of-order guard protects against a stale terminal snapshot.
    gp.verifier.subs[token] = raw_sub(state=STATE_ON_HOLD, obfuscated=reg["account_id"])
    _notify(client, rtdn_envelope(message_id="ooo-1", token=token, ntype=NTYPE_ON_HOLD,
                                  event_ms=1000))
    # The older on-hold event is ignored; the active grant survives.
    assert _me(client, reg["api_token"])["is_pro"] is True


def test_rtdn_purchase_binds_via_obfuscated_before_client_sync(client, gp):
    reg = _register(client)
    token = "tok-rtdn-first"
    gp.verifier.subs[token] = raw_sub(obfuscated=reg["account_id"])
    r = _notify(client, rtdn_envelope(message_id="rf-1", token=token, ntype=NTYPE_PURCHASED))
    assert r.status_code == 200
    assert r.json()["outcome"] == "granted"
    assert _me(client, reg["api_token"])["is_pro"] is True


def test_rtdn_purchase_without_beneficiary_is_unbound(client, gp):
    _register(client)
    token = "tok-orphan"
    gp.verifier.subs[token] = raw_sub(obfuscated=None)  # no binding, no caller
    r = _notify(client, rtdn_envelope(message_id="orph-1", token=token, ntype=NTYPE_PURCHASED))
    assert r.status_code == 200
    assert r.json()["outcome"] == "unbound"
    assert _db_scalar("SELECT COUNT(*) FROM entitlement_grants WHERE state='active'") == 0


def test_rtdn_garbage_obfuscated_account_is_unbound_not_500(client, gp):
    _register(client)
    token = "tok-garbage"
    gp.verifier.subs[token] = raw_sub(obfuscated="not-a-real-account-uuid")
    r = _notify(client, rtdn_envelope(message_id="g-1", token=token, ntype=NTYPE_PURCHASED))
    assert r.status_code == 200
    assert r.json()["outcome"] == "unbound"


# ===========================================================================
# Linked purchase replacement
# ===========================================================================


def test_linked_purchase_replacement_terminates_old_lineage(client, gp):
    reg = _register(client)
    old = "tok-old"
    new = "tok-new"
    gp.verifier.subs[old] = raw_sub(obfuscated=reg["account_id"])
    assert _sync(client, reg["api_token"], old).status_code == 200
    assert _me(client, reg["api_token"])["is_pro"] is True

    # Upgrade mints a new token whose snapshot links back to the old one.
    gp.verifier.subs[new] = raw_sub(
        product=PRODUCT_YEAR, base_plan=BASE_PLAN_YEAR, obfuscated=reg["account_id"], linked=old
    )
    r = _sync(client, reg["api_token"], new, subscription_id=PRODUCT_YEAR)
    assert r.status_code == 200
    assert r.json()["is_pro"] is True

    # Old lineage is terminally replaced; a replay of the OLD token cannot grant.
    assert _db_scalar(
        "SELECT COUNT(*) FROM provider_purchases WHERE original_transaction_id=? AND lifecycle_state='replaced'",
        (old,),
    ) == 1
    gp.verifier.subs[old] = raw_sub(state=STATE_ACTIVE, obfuscated=reg["account_id"])
    r2 = _sync(client, reg["api_token"], old)
    assert r2.status_code == 200
    # Still pro (from the NEW lineage), but the old replay granted nothing new.
    assert _db_scalar(
        "SELECT COUNT(*) FROM provider_purchases WHERE original_transaction_id=? AND lifecycle_state='replaced'",
        (old,),
    ) == 1


def test_rejected_terminal_new_replacement_does_not_mutate_old(client, gp):
    reg = _register(client)
    old = "tok-terminal-new-old"
    new = "tok-terminal-new"
    gp.verifier.subs[old] = raw_sub(obfuscated=reg["account_id"])
    gp.verifier.subs[new] = raw_sub(obfuscated=reg["account_id"])
    assert _sync(client, reg["api_token"], old).status_code == 200
    assert _sync(client, reg["api_token"], new).status_code == 200

    # Make NEW durably hard-terminal, then replay provider-active NEW carrying
    # linkedPurchaseToken=OLD. Rejected NEW evidence must not replace OLD.
    _notify(
        client,
        rtdn_envelope(
            message_id="terminal-new-revoke",
            token=new,
            ntype=NTYPE_REVOKED,
            event_ms=_now_ms() - 60_000,
        ),
    )
    gp.verifier.subs[new] = raw_sub(obfuscated=reg["account_id"], linked=old)
    r = _notify(
        client,
        rtdn_envelope(
            message_id="terminal-new-active-replay",
            token=new,
            ntype=NTYPE_PURCHASED,
            event_ms=_now_ms(),
        ),
    )
    assert r.status_code == 200
    assert r.json()["outcome"] == "stale"
    assert _me(client, reg["api_token"])["is_pro"] is True
    assert _db_scalar(
        "SELECT COUNT(*) FROM provider_purchases "
        "WHERE original_transaction_id=? AND lifecycle_state='active'",
        (old,),
    ) == 1
    assert _db_scalar(
        "SELECT COUNT(*) FROM entitlement_grants eg "
        "JOIN provider_purchases pp ON pp.id=eg.purchase_id "
        "WHERE pp.original_transaction_id=? AND eg.state='active'",
        (old,),
    ) == 1
    assert _db_scalar(
        "SELECT COUNT(*) FROM provider_purchases "
        "WHERE original_transaction_id=? AND lifecycle_state='revoked'",
        (new,),
    ) == 1


def test_linked_replacement_grant_error_rolls_back_old_and_new(
    client, gp, monkeypatch
):
    from backend.store import get_store

    reg = _register(client)
    old = "tok-rollback-old"
    new = "tok-rollback-new"
    gp.verifier.subs[old] = raw_sub(obfuscated=reg["account_id"])
    assert _sync(client, reg["api_token"], old).status_code == 200
    gp.verifier.subs[new] = raw_sub(obfuscated=reg["account_id"], linked=old)

    store = get_store()

    def fail_grant(*_args, **_kwargs):
        raise RuntimeError("injected grant failure")

    monkeypatch.setattr(store, "_upsert_grant", fail_grant)
    with pytest.raises(RuntimeError, match="injected grant failure"):
        _sync(client, reg["api_token"], new)

    assert _db_scalar(
        "SELECT COUNT(*) FROM provider_purchases "
        "WHERE original_transaction_id=? AND lifecycle_state='active'",
        (old,),
    ) == 1
    assert _db_scalar(
        "SELECT COUNT(*) FROM entitlement_grants eg "
        "JOIN provider_purchases pp ON pp.id=eg.purchase_id "
        "WHERE pp.original_transaction_id=? AND eg.state='active'",
        (old,),
    ) == 1
    assert _db_scalar(
        "SELECT COUNT(*) FROM provider_purchases WHERE original_transaction_id=?",
        (new,),
    ) == 0


def test_cross_account_linked_replacement_conflicts_without_mutating_old(client, gp):
    account_a = _register(client)
    account_b = _register(client)
    old = "tok-cross-old"
    new = "tok-cross-new"
    gp.verifier.subs[old] = raw_sub(obfuscated=account_a["account_id"])
    assert _sync(client, account_a["api_token"], old).status_code == 200

    gp.verifier.subs[new] = raw_sub(
        product=PRODUCT_YEAR,
        base_plan=BASE_PLAN_YEAR,
        obfuscated=account_b["account_id"],
        linked=old,
    )
    r = _sync(client, account_b["api_token"], new, subscription_id=PRODUCT_YEAR)
    assert r.status_code == 409
    assert _me(client, account_a["api_token"])["is_pro"] is True
    assert _me(client, account_b["api_token"])["is_pro"] is False
    assert _db_scalar(
        "SELECT COUNT(*) FROM provider_purchases WHERE original_transaction_id=? AND lifecycle_state='active'",
        (old,),
    ) == 1
    assert _db_scalar(
        "SELECT COUNT(*) FROM provider_purchases WHERE original_transaction_id=?", (new,)
    ) == 0


# ===========================================================================
# Transient failure / push auth / not-found
# ===========================================================================


def test_developer_api_transient_failure_fails_closed_503(client, gp):
    reg = _register(client)
    token = "tok-unavail"
    gp.verifier.unavailable.add(token)
    r = _sync(client, reg["api_token"], token)
    assert r.status_code == 503
    assert _me(client, reg["api_token"])["is_pro"] is False


def test_not_found_token_on_sync_is_422(client, gp):
    reg = _register(client)
    token = "tok-404"
    gp.verifier.not_found.add(token)
    r = _sync(client, reg["api_token"], token)
    assert r.status_code == 422
    assert _me(client, reg["api_token"])["is_pro"] is False


def test_invalid_push_auth_is_rejected(client, gp):
    gp.auth.ok = False
    token = "tok-x"
    gp.verifier.subs[token] = raw_sub()
    r = _notify(client, rtdn_envelope(message_id="pa-1", token=token))
    assert r.status_code == 401
    # Nothing was recorded — the boundary rejected before any projection.
    assert _db_scalar("SELECT COUNT(*) FROM provider_transactions WHERE provider='google'") == 0


def test_rtdn_transient_requery_failure_returns_503_for_retry(client, gp):
    reg = _register(client)
    token = "tok-rq-fail"
    gp.verifier.subs[token] = raw_sub(obfuscated=reg["account_id"])
    assert _sync(client, reg["api_token"], token).status_code == 200
    gp.verifier.unavailable.add(token)
    r = _notify(client, rtdn_envelope(message_id="rq-1", token=token, ntype=NTYPE_RENEWED,
                                      event_ms=_now_ms() + 1))
    assert r.status_code == 503


def test_rtdn_transient_failure_same_message_redelivery_projects(client, gp):
    reg = _register(client)
    token = "tok-rq-redelivery"
    gp.verifier.subs[token] = raw_sub(obfuscated=reg["account_id"])
    gp.verifier.unavailable.add(token)
    envelope = rtdn_envelope(message_id="rq-redeliver-1", token=token)
    assert _notify(client, envelope).status_code == 503
    assert _db_scalar(
        "SELECT COUNT(*) FROM provider_transactions WHERE event_id=? AND outcome LIKE 'pending:%'",
        ("rq-redeliver-1",),
    ) == 1

    gp.verifier.unavailable.remove(token)
    second = _notify(client, envelope)
    assert second.status_code == 200
    assert second.json()["outcome"] == "granted"
    assert _me(client, reg["api_token"])["is_pro"] is True
    assert _db_scalar(
        "SELECT COUNT(*) FROM provider_transactions WHERE event_id=? AND outcome LIKE 'completed:%'",
        ("rq-redeliver-1",),
    ) == 1


def test_rtdn_wrong_package_is_400(client, gp):
    token = "tok-pkg"
    gp.verifier.subs[token] = raw_sub()
    r = _notify(client, rtdn_envelope(message_id="pkg-1", token=token, package="com.other.app"))
    assert r.status_code == 400


def test_rtdn_unsupported_version_is_400(client, gp):
    token = "tok-ver"
    gp.verifier.subs[token] = raw_sub()
    r = _notify(client, rtdn_envelope(message_id="ver-1", token=token, version="2.0"))
    assert r.status_code == 400


@pytest.mark.parametrize("field", ["version", "packageName"])
def test_rtdn_missing_required_identity_field_is_400_before_inbox(client, gp, field):
    envelope = rtdn_envelope(message_id=f"missing-{field}", token="tok-missing")
    payload = json.loads(base64.b64decode(envelope["message"]["data"]))
    payload.pop(field)
    envelope["message"]["data"] = base64.b64encode(json.dumps(payload).encode()).decode()
    assert _notify(client, envelope).status_code == 400
    assert _db_scalar(
        "SELECT COUNT(*) FROM provider_transactions WHERE event_id=?",
        (f"missing-{field}",),
    ) == 0


def test_rtdn_test_notification_is_acknowledged_without_projection(client, gp):
    r = _notify(client, rtdn_envelope(message_id="t-1", token="x", test=True))
    assert r.status_code == 200
    assert r.json()["outcome"] == "ignored"
    assert _db_scalar("SELECT COUNT(*) FROM provider_purchases WHERE provider='google'") == 0


# ===========================================================================
# Acknowledgement retry
# ===========================================================================


def test_acknowledge_failure_keeps_entitlement_and_retries(client, gp):
    from backend import google_play
    from backend.store import get_store

    reg = _register(client)
    token = "tok-ackretry"
    gp.verifier.subs[token] = raw_sub(obfuscated=reg["account_id"])
    gp.verifier.ack_fail.add(token)  # first acknowledge attempt fails

    r = _sync(client, reg["api_token"], token)
    assert r.status_code == 200
    assert r.json()["is_pro"] is True  # entitlement granted despite ack failure
    # A retriable ack op survives.
    assert _db_scalar(
        "SELECT COUNT(*) FROM provider_operations WHERE op_kind='acknowledge' AND state='failed'"
    ) == 1

    # The reconciler retries; acknowledge now succeeds and the op retires.
    gp.verifier.ack_fail.discard(token)
    tally = google_play.reconcile_google_acknowledgements(get_store(), gp.verifier, gp.config)
    assert tally["acknowledged"] == 1
    assert (PRODUCT, token) in gp.verifier.acked
    assert _me(client, reg["api_token"])["is_pro"] is True


def test_reconcile_drops_ack_for_revoked_purchase(client, gp):
    from backend import google_play
    from backend.store import get_store

    reg = _register(client)
    token = "tok-ack-revoked"
    gp.verifier.subs[token] = raw_sub(obfuscated=reg["account_id"])
    gp.verifier.ack_fail.add(token)
    assert _sync(client, reg["api_token"], token).status_code == 200

    # Revoke before the ack could land.
    _notify(client, rtdn_envelope(message_id="ar-1", token=token, ntype=NTYPE_REVOKED,
                                  event_ms=_now_ms() + 1000))
    gp.verifier.ack_fail.discard(token)
    tally = google_play.reconcile_google_acknowledgements(get_store(), gp.verifier, gp.config)
    # Nothing acknowledged — the revoked lineage's ack op is retired, not sent.
    assert tally["acknowledged"] == 0
    assert tally["dropped"] == 1
    assert gp.verifier.acked == []


# ===========================================================================
# Readiness (non-secret observability)
# ===========================================================================


def test_readiness_reports_non_secret_booleans(client, gp):
    r = client.get("/v1/google-play/readiness")
    assert r.status_code == 200
    body = r.json()
    assert body["provider"] == "google_play"
    assert body["package_name"] == PACKAGE
    assert set(body["subscription_ids"]) == {PRODUCT, PRODUCT_YEAR}
    assert body["base_plans_configured"] is True
    # No secret material leaks.
    blob = json.dumps(body)
    assert "SERVICE_ACCOUNT" not in blob and "private_key" not in blob


def test_readiness_ready_false_without_credentials(client):
    # No `gp` fixture: real dependencies, no env configured -> not ready, and the
    # config default base-plan set is empty (fail closed).
    r = client.get("/v1/google-play/readiness")
    assert r.status_code == 200
    body = r.json()
    assert body["verification_configured"] is False
    assert body["ready"] is False


def test_oidc_requires_both_fields_and_exact_verified_service_account(
    client, gp, monkeypatch
):
    from backend import google_play
    from google.oauth2 import id_token

    monkeypatch.setenv("TONO_GOOGLE_SERVICE_ACCOUNT_JSON", "configured-not-read")
    monkeypatch.setenv("TONO_GOOGLE_PUBSUB_AUDIENCE", "https://tono.example/rtdn")
    monkeypatch.delenv("TONO_GOOGLE_PUBSUB_SA_EMAIL", raising=False)
    partial = client.get("/v1/google-play/readiness").json()
    assert partial["push_auth_configured"] is False
    assert partial["ready"] is False
    with pytest.raises(Exception) as exc:
        google_play.get_google_push_authenticator()
    assert getattr(exc.value, "status_code", None) == 503

    monkeypatch.setenv(
        "TONO_GOOGLE_PUBSUB_SA_EMAIL", "expected-pusher@example.iam.gserviceaccount.com"
    )
    monkeypatch.setenv("TONO_GOOGLE_PUBSUB_SHARED_TOKEN", "configured-not-read")
    with pytest.raises(Exception) as exclusive_exc:
        google_play.get_google_push_authenticator()
    assert getattr(exclusive_exc.value, "status_code", None) == 503
    monkeypatch.delenv("TONO_GOOGLE_PUBSUB_SHARED_TOKEN")

    monkeypatch.setattr(
        id_token,
        "verify_oauth2_token",
        lambda *_args, **_kwargs: {
            "email_verified": True,
            "email": "wrong-pusher@example.iam.gserviceaccount.com",
        },
    )
    authenticator = google_play.OidcPushAuthenticator(
        "https://tono.example/rtdn", "expected-pusher@example.iam.gserviceaccount.com"
    )

    class SignedRequest:
        headers = {"authorization": "Bearer signed.mock.token"}

    with pytest.raises(google_play.GooglePushAuthError, match="unexpected service account"):
        authenticator.verify(SignedRequest())


@pytest.mark.parametrize("email_verified", ["false", 1, 0, None, False, "missing"])
def test_oidc_rejects_non_exact_true_email_verified(
    client, gp, monkeypatch, email_verified
):
    from backend import google_play
    from google.oauth2 import id_token

    audience = "https://tono.example/rtdn"
    email = "expected-pusher@example.iam.gserviceaccount.com"
    seen = {}

    def verify(_token, _request, *, audience):
        seen["audience"] = audience
        claims = {"email": email}
        if email_verified != "missing":
            claims["email_verified"] = email_verified
        return claims

    monkeypatch.setattr(id_token, "verify_oauth2_token", verify)
    authenticator = google_play.OidcPushAuthenticator(audience, email)

    class SignedRequest:
        headers = {"authorization": "Bearer signed.mock.token"}

    with pytest.raises(google_play.GooglePushAuthError, match="email not verified"):
        authenticator.verify(SignedRequest())
    assert seen["audience"] == audience


def test_oidc_accepts_exact_true_email_and_audience(client, gp, monkeypatch):
    from backend import google_play
    from google.oauth2 import id_token

    audience = "https://tono.example/rtdn"
    email = "expected-pusher@example.iam.gserviceaccount.com"
    seen = {}

    def verify(_token, _request, *, audience):
        seen["audience"] = audience
        return {"email_verified": True, "email": email}

    monkeypatch.setattr(id_token, "verify_oauth2_token", verify)
    authenticator = google_play.OidcPushAuthenticator(audience, email)

    class SignedRequest:
        headers = {"authorization": "Bearer signed.mock.token"}

    authenticator.verify(SignedRequest())
    assert seen["audience"] == audience


# ===========================================================================
# Verifier unconfigured -> 503 (fail closed, no fake installed)
# ===========================================================================


def test_verifier_unconfigured_returns_503(client):
    reg = _register(client)
    r = client.post(
        "/v1/google-play/subscription",
        json={"purchase_token": "whatever"},
        headers=_auth(reg["api_token"]),
    )
    assert r.status_code == 503


def test_sync_requires_authentication(client, gp):
    r = client.post("/v1/google-play/subscription", json={"purchase_token": "x"})
    assert r.status_code == 401
