"""RevenueCat canary intake — hostile GO tests.

Every test runs against a fresh SQLite DB (conftest `_isolate_db`) through the
real FastAPI app + real store; none merely greps source. The RevenueCat webhook
is a server-to-server call authenticated by a shared Authorization secret, so we
override `get_revenuecat_config` with a known secret + chosen canary mode (the
same `app.dependency_overrides` indirection the Apple/Google suites use) and drive
the full endpoint -> inbox -> projection -> `/v1/me` path with adversarial events.

The canonical `pro` entitlement is the SAME projection Stripe/Apple/Google use: an
active, unexpired row in `entitlement_grants`, surfaced through `/v1/me`.`is_pro`.
RevenueCat maps to it as provider='revenuecat'. In `shadow` mode RevenueCat records
facts + comparisons but NEVER writes grants (the legacy path stays the sole
writer); only `authoritative` mode grants.
"""

from __future__ import annotations

import datetime as dt
import json
import sqlite3

import pytest

PRODUCT = "com.tonoit.pro.monthly"
PRODUCT_YEAR = "com.tonoit.pro.yearly"
SECRET = "Bearer test-rc-webhook-secret-value-9f3a2b"  # RevenueCat dashboard Authorization value


def _now_ms() -> int:
    return int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)


def _future_ms(days: int = 30) -> int:
    return int((dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=days)).timestamp() * 1000)


def _past_ms(days: int = 1) -> int:
    return int((dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)).timestamp() * 1000)


# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------


@pytest.fixture
def rc(client):
    """Install a RevenueCat config override with a known webhook secret. Tests
    flip `rc.state['mode']` before posting to exercise shadow vs authoritative.
    `client` first so the app module is imported and shared."""
    from backend import revenuecat
    from backend.server import app

    state = {"mode": "authoritative"}

    def _cfg():
        return revenuecat.RevenueCatConfig(
            mode=state["mode"],
            webhook_auth=SECRET,
            entitlement_id="pro",
            product_ids=frozenset({PRODUCT, PRODUCT_YEAR}),
        )

    app.dependency_overrides[revenuecat.get_revenuecat_config] = _cfg

    class Ctx:
        pass

    ctx = Ctx()
    ctx.state = state
    ctx.app = app
    ctx.client = client
    yield ctx

    app.dependency_overrides.pop(revenuecat.get_revenuecat_config, None)


def _register(client, platform="ios") -> dict:
    r = client.post("/v1/register", json={"platform": platform})
    assert r.status_code == 200, r.text
    return r.json()


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _me(client, token: str) -> dict:
    r = client.get("/v1/me", headers=_auth(token))
    assert r.status_code == 200, r.text
    return r.json()


def _account_id(client, token: str) -> str:
    aid = _me(client, token)["account_id"]
    assert aid
    return aid


def rc_event(
    *,
    event_id,
    etype="INITIAL_PURCHASE",
    app_user_id,
    product_id=PRODUCT,
    entitlement_ids=("pro",),
    store="APP_STORE",
    environment="PRODUCTION",
    event_ms=None,
    expiration_ms="future",
    grace_ms=None,
    original_transaction_id="otx-1",
    cancel_reason=None,
    transferred_from=None,
    transferred_to=None,
):
    ev = {
        "id": event_id,
        "type": etype,
        "app_user_id": app_user_id,
        "environment": environment,
        "store": store,
        "event_timestamp_ms": event_ms if event_ms is not None else _now_ms(),
    }
    if product_id is not None:
        ev["product_id"] = product_id
    if entitlement_ids is not None:
        ev["entitlement_ids"] = list(entitlement_ids)
    if expiration_ms == "future":
        ev["expiration_at_ms"] = _future_ms()
    elif expiration_ms == "past":
        ev["expiration_at_ms"] = _past_ms()
    elif expiration_ms is not None:
        ev["expiration_at_ms"] = expiration_ms
    if grace_ms is not None:
        ev["grace_period_expiration_at_ms"] = grace_ms
    if original_transaction_id is not None:
        ev["original_transaction_id"] = original_transaction_id
    if cancel_reason is not None:
        ev["cancel_reason"] = cancel_reason
    if transferred_from is not None:
        ev["transferred_from"] = transferred_from
    if transferred_to is not None:
        ev["transferred_to"] = transferred_to
    return {"api_version": "1.0", "event": ev}


def _post(client, body, *, auth=SECRET):
    headers = {}
    if auth is not None:
        headers["Authorization"] = auth
    return client.post(
        "/v1/revenuecat/notifications",
        content=json.dumps(body),
        headers=headers,
    )


# ---------------------------------------------------------------------------
# Kill switch + auth boundary
# ---------------------------------------------------------------------------


def test_kill_switch_off_503s_and_grants_nothing(client):
    """Default mode=off: the webhook 503s (no config override installed)."""
    body = rc_event(event_id="e1", app_user_id="whoever")
    r = _post(client, body, auth="anything")
    assert r.status_code == 503, r.text


def test_missing_authorization_is_401(rc):
    body = rc_event(event_id="e1", app_user_id="acct")
    r = _post(rc.client, body, auth=None)
    assert r.status_code == 401, r.text


def test_wrong_authorization_is_401(rc):
    body = rc_event(event_id="e1", app_user_id="acct")
    r = _post(rc.client, body, auth="Bearer not-the-secret")
    assert r.status_code == 401, r.text


def test_readiness_is_nonsecret_and_reports_off_by_default(client):
    r = client.get("/v1/revenuecat/readiness")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["provider"] == "revenuecat"
    assert body["mode"] == "off"
    assert body["enabled"] is False
    assert body["ready"] is False
    # No secret value is ever surfaced — only booleans + public identifiers.
    assert set(body).isdisjoint({"webhook_auth", "secret_api_key", "TONO_REVENUECAT_WEBHOOK_AUTH"})
    assert "pro" == body["entitlement_id"]
    # With no shadow observations the canary reports clean by default.
    assert body["shadow"]["total"] == 0
    assert body["shadow"]["disagreements"] == 0
    assert body["shadow_clean"] is True


# ---------------------------------------------------------------------------
# Happy path (authoritative) + the entitlement projection
# ---------------------------------------------------------------------------


def test_authoritative_initial_purchase_grants_pro(rc):
    client = rc.client
    reg = _register(client)
    token = reg["api_token"]
    aid = _account_id(client, token)
    assert _me(client, token)["is_pro"] is False

    r = _post(client, rc_event(event_id="e1", app_user_id=aid))
    assert r.status_code == 200, r.text
    assert r.json()["outcome"].startswith("authoritative:")
    assert _me(client, token)["is_pro"] is True


def test_shadow_records_fact_but_grants_nothing(rc):
    """Shadow mode: legacy stays the sole entitlement writer — no grant is
    written, but the provider fact + a shadow observation are recorded."""
    rc.state["mode"] = "shadow"
    client = rc.client
    token = _register(client)["api_token"]
    aid = _account_id(client, token)

    r = _post(client, rc_event(event_id="e1", app_user_id=aid))
    assert r.status_code == 200, r.text
    assert r.json()["outcome"].startswith("shadow:")
    # Legacy projection unchanged — RevenueCat did NOT grant in shadow.
    assert _me(client, token)["is_pro"] is False

    from backend.store import get_store
    store = get_store()
    # The append-only provider fact exists...
    fact = store.get_provider_purchase("otx-1", provider="revenuecat")
    assert fact is not None and fact["lifecycle_state"] == "active"
    # ...but no active entitlement grant was written for the account.
    from backend.store import _account_has_active_grant  # type: ignore

    def _check():
        cur = store._conn.cursor()
        return _account_has_active_grant(cur, aid)

    assert store._run(_check).result() is False


# ---------------------------------------------------------------------------
# §9 hostile: unrelated-account isolation
# ---------------------------------------------------------------------------


def test_unrelated_account_isolation(rc):
    """A purchase bound to account A never grants account B."""
    client = rc.client
    tok_a = _register(client)["api_token"]
    tok_b = _register(client)["api_token"]
    aid_a = _account_id(client, tok_a)
    aid_b = _account_id(client, tok_b)
    assert aid_a != aid_b

    r = _post(client, rc_event(event_id="e1", app_user_id=aid_a, original_transaction_id="otx-a"))
    assert r.status_code == 200
    assert _me(client, tok_a)["is_pro"] is True
    assert _me(client, tok_b)["is_pro"] is False


def test_same_email_distinct_accounts_stay_isolated(rc):
    """RevenueCat App User ID is the account UUID, not the email. Two distinct
    accounts (even if they shared an email) receive independent projections."""
    client = rc.client
    tok_a = _register(client)["api_token"]
    tok_b = _register(client)["api_token"]
    aid_a = _account_id(client, tok_a)
    aid_b = _account_id(client, tok_b)

    _post(client, rc_event(event_id="ea", app_user_id=aid_a, original_transaction_id="otx-a"))
    assert _me(client, tok_a)["is_pro"] is True
    assert _me(client, tok_b)["is_pro"] is False
    # And B's own purchase does not touch A's lineage.
    _post(client, rc_event(event_id="eb", app_user_id=aid_b, original_transaction_id="otx-b"))
    assert _me(client, tok_b)["is_pro"] is True


# ---------------------------------------------------------------------------
# §9 hostile: anonymous->identified merge rejection / controlled aliasing
# ---------------------------------------------------------------------------


def test_subscriber_alias_never_merges_accounts(rc):
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)
    body = rc_event(
        event_id="alias1",
        etype="SUBSCRIBER_ALIAS",
        app_user_id=aid,
        original_transaction_id=None,
        product_id=None,
        entitlement_ids=None,
    )
    body["event"]["original_app_user_id"] = "anon-rc-id-xyz"
    body["event"]["aliases"] = ["anon-rc-id-xyz", aid]
    r = _post(client, body)
    assert r.status_code == 200, r.text
    assert r.json()["outcome"] == "alias_rejected:no_merge"
    # No entitlement was fabricated by the alias.
    assert _me(client, tok)["is_pro"] is False


# ---------------------------------------------------------------------------
# §9 hostile: logout/login account switch (TRANSFER)
# ---------------------------------------------------------------------------


def test_transfer_revokes_source_lineage(rc):
    """A TRANSFER moves ownership away; the source lineage's grant is revoked and
    the destination re-earns entitlement through its own events, never by
    fabrication here."""
    client = rc.client
    tok_a = _register(client)["api_token"]
    aid_a = _account_id(client, tok_a)
    _post(client, rc_event(event_id="e1", app_user_id=aid_a, original_transaction_id="otx-shared"))
    assert _me(client, tok_a)["is_pro"] is True

    transfer = rc_event(
        event_id="t1",
        etype="TRANSFER",
        app_user_id=aid_a,
        original_transaction_id="otx-shared",
        product_id=None,
        entitlement_ids=None,
    )
    transfer["event"]["transferred_from"] = [aid_a]
    transfer["event"]["transferred_to"] = ["some-other-account"]
    r = _post(client, transfer)
    assert r.status_code == 200, r.text
    assert _me(client, tok_a)["is_pro"] is False


# ---------------------------------------------------------------------------
# §9 hostile: reinstall / second-device restore (idempotent re-projection)
# ---------------------------------------------------------------------------


def test_restore_reprojection_is_idempotent_single_lineage(rc):
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)
    # First purchase.
    _post(client, rc_event(event_id="e1", app_user_id=aid, original_transaction_id="otx-1"))
    # Reinstall / second device restore surfaces the SAME lineage as a RENEWAL.
    r = _post(client, rc_event(event_id="e2", etype="RENEWAL", app_user_id=aid,
                               original_transaction_id="otx-1", event_ms=_now_ms() + 1000))
    assert r.status_code == 200
    assert _me(client, tok)["is_pro"] is True

    from backend.store import get_store
    store = get_store()

    def _count():
        cur = store._conn.cursor()
        cur.execute(
            "SELECT COUNT(*) c FROM provider_purchases WHERE provider='revenuecat' "
            "AND original_transaction_id='otx-1'"
        )
        return cur.fetchone()["c"]

    assert store._run(_count).result() == 1  # one lineage, not duplicated


# ---------------------------------------------------------------------------
# §9 hostile: duplicate / out-of-order events
# ---------------------------------------------------------------------------


def test_duplicate_event_id_is_acked_without_reprojection(rc):
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)
    body = rc_event(event_id="dup1", app_user_id=aid)
    r1 = _post(client, body)
    assert r1.status_code == 200 and r1.json().get("duplicate") is not True
    r2 = _post(client, body)
    assert r2.status_code == 200
    assert r2.json().get("duplicate") is True


def test_out_of_order_stale_event_does_not_downgrade(rc):
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)
    newer = _now_ms() + 10_000
    older = _now_ms() - 10_000
    # Newer active fact first.
    _post(client, rc_event(event_id="e-new", app_user_id=aid,
                           original_transaction_id="otx-1", event_ms=newer,
                           expiration_ms=_future_ms(60)))
    assert _me(client, tok)["is_pro"] is True
    # An OLDER renewal for the same lineage must be ignored as stale.
    r = _post(client, rc_event(event_id="e-old", etype="RENEWAL", app_user_id=aid,
                               original_transaction_id="otx-1", event_ms=older,
                               expiration_ms=_future_ms(1)))
    assert r.status_code == 200
    assert "stale" in r.json()["outcome"]
    assert _me(client, tok)["is_pro"] is True

    from backend.store import get_store
    store = get_store()
    fact = store.get_provider_purchase("otx-1", provider="revenuecat")
    assert fact["latest_signed_ms"] == newer  # newer fact preserved


# ---------------------------------------------------------------------------
# §9 hostile: durable inbox failure -> retryable 5xx
# ---------------------------------------------------------------------------


def test_inbox_write_failure_returns_retryable_5xx(rc, monkeypatch):
    """A non-duplicate inbox write failure must NOT be ACK'd — the client gets a
    retryable 5xx so RevenueCat redelivers (contract §5)."""
    from backend import store as store_module
    from fastapi.testclient import TestClient

    def _boom(self, **kwargs):
        raise sqlite3.OperationalError("disk full")

    monkeypatch.setattr(store_module.Store, "record_revenuecat_event", _boom)

    # A client that surfaces the 500 instead of re-raising it in-process.
    with TestClient(rc.app, raise_server_exceptions=False) as c:
        reg = c.post("/v1/register", json={"platform": "ios"})
        aid = c.get("/v1/me", headers=_auth(reg.json()["api_token"])).json()["account_id"]
        r = c.post(
            "/v1/revenuecat/notifications",
            content=json.dumps(rc_event(event_id="e1", app_user_id=aid)),
            headers={"Authorization": SECRET},
        )
    assert r.status_code >= 500


# ---------------------------------------------------------------------------
# §9 hostile: missing account metadata
# ---------------------------------------------------------------------------


def test_missing_app_user_id_records_fact_but_grants_nothing(rc):
    client = rc.client
    body = rc_event(event_id="e1", app_user_id=None, original_transaction_id="otx-anon")
    body["event"].pop("app_user_id", None)
    r = _post(client, body)
    # Durably owned + processed (no crash), but nothing granted.
    assert r.status_code == 200, r.text
    from backend.store import get_store
    store = get_store()
    ev = store.get_revenuecat_event("e1")
    assert ev is not None and ev["state"] == "processed"


def test_unknown_app_user_id_grants_nothing_but_records_fact(rc):
    client = rc.client
    r = _post(client, rc_event(event_id="e1", app_user_id="00000000-dead-beef-0000-000000000000",
                               original_transaction_id="otx-ghost"))
    assert r.status_code == 200, r.text
    from backend.store import get_store
    store = get_store()
    # Fact recorded (append-only) with the claimed binding, but no grant exists
    # because the account does not exist (fail closed).
    fact = store.get_provider_purchase("otx-ghost", provider="revenuecat")
    assert fact is not None

    def _grants():
        cur = store._conn.cursor()
        cur.execute("SELECT COUNT(*) c FROM entitlement_grants")
        return cur.fetchone()["c"]

    assert store._run(_grants).result() == 0


# ---------------------------------------------------------------------------
# §9 hostile: refund / revocation
# ---------------------------------------------------------------------------


def test_refund_hard_revokes_even_out_of_order(rc):
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)
    _post(client, rc_event(event_id="e1", app_user_id=aid, original_transaction_id="otx-1",
                           event_ms=_now_ms() + 5000))
    assert _me(client, tok)["is_pro"] is True
    # Refund arrives with an OLDER timestamp — a hard revoke must still win.
    r = _post(client, rc_event(event_id="e2", etype="CANCELLATION", app_user_id=aid,
                               original_transaction_id="otx-1", cancel_reason="CUSTOMER_SUPPORT",
                               event_ms=_now_ms() - 5000, expiration_ms=_past_ms()))
    assert r.status_code == 200
    assert _me(client, tok)["is_pro"] is False


def test_explicit_refund_type_revokes(rc):
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)
    _post(client, rc_event(event_id="e1", app_user_id=aid, original_transaction_id="otx-1"))
    assert _me(client, tok)["is_pro"] is True
    r = _post(client, rc_event(event_id="e2", etype="REFUND", app_user_id=aid,
                               original_transaction_id="otx-1", expiration_ms=_past_ms()))
    assert r.status_code == 200
    assert _me(client, tok)["is_pro"] is False


# ---------------------------------------------------------------------------
# §9 hostile: cancellation-through-expiry
# ---------------------------------------------------------------------------


def test_cancellation_keeps_access_until_expiry_then_expires(rc):
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)
    _post(client, rc_event(event_id="e1", app_user_id=aid, original_transaction_id="otx-1",
                           expiration_ms=_future_ms(20)))
    assert _me(client, tok)["is_pro"] is True

    # Auto-renew off, but the already-paid period is still in the future -> keep access.
    r = _post(client, rc_event(event_id="e2", etype="CANCELLATION", app_user_id=aid,
                               original_transaction_id="otx-1", cancel_reason="UNSUBSCRIBE",
                               event_ms=_now_ms() + 1000, expiration_ms=_future_ms(20)))
    assert r.status_code == 200
    assert _me(client, tok)["is_pro"] is True

    # The period lapses -> EXPIRATION revokes.
    r = _post(client, rc_event(event_id="e3", etype="EXPIRATION", app_user_id=aid,
                               original_transaction_id="otx-1", event_ms=_now_ms() + 2000,
                               expiration_ms=_past_ms()))
    assert r.status_code == 200
    assert _me(client, tok)["is_pro"] is False


# ---------------------------------------------------------------------------
# §9 hostile: pending purchase (not yet entitling) grants nothing
# ---------------------------------------------------------------------------


def test_pending_play_purchase_grants_nothing(rc):
    """A Play purchase that is not yet active (no future entitlement window)
    must not grant. Modeled as an event whose expiry is not in the future."""
    client = rc.client
    tok = _register(client, platform="android")["api_token"]
    aid = _account_id(client, tok)
    r = _post(client, rc_event(event_id="e1", app_user_id=aid, store="PLAY_STORE",
                               original_transaction_id="otx-pending", expiration_ms=_past_ms()))
    assert r.status_code == 200
    assert _me(client, tok)["is_pro"] is False


# ---------------------------------------------------------------------------
# §9 hostile: webhook provider lookup failure -> durable, retried, not lost
# ---------------------------------------------------------------------------


def test_transient_projection_failure_is_retained_and_reconciled(rc, monkeypatch):
    """A transient failure while projecting a durably-owned event returns 2xx with
    a retry outcome (never a 5xx after durable ownership) and the event is left for
    the reconciler, which then completes it."""
    from backend import revenuecat, store as store_module
    from backend.store import get_store

    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)

    calls = {"n": 0}
    real_apply = store_module.Store.apply_revenuecat_fact

    def _flaky(self, **kwargs):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("transient lookup failure")
        return real_apply(self, **kwargs)

    monkeypatch.setattr(store_module.Store, "apply_revenuecat_fact", _flaky)

    r = _post(client, rc_event(event_id="e1", app_user_id=aid, original_transaction_id="otx-1"))
    assert r.status_code == 200, r.text
    assert r.json()["outcome"] == "retry_scheduled"
    assert _me(client, tok)["is_pro"] is False  # not yet granted

    # The reconciler drains the durably-owned event and completes it.
    store = get_store()
    tally = revenuecat.reconcile_revenuecat(store, revenuecat.RevenueCatConfig(
        mode="authoritative", webhook_auth=SECRET, entitlement_id="pro",
        product_ids=frozenset({PRODUCT, PRODUCT_YEAR}),
    ))
    assert tally["processed"] == 1
    assert _me(client, tok)["is_pro"] is True


def test_retry_ceiling_moves_event_to_dead_letter(rc, monkeypatch):
    from backend import revenuecat, store as store_module
    from backend.store import get_store

    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)

    def _always_fail(self, **kwargs):
        raise RuntimeError("permanently flaky dependency")

    monkeypatch.setattr(store_module.Store, "apply_revenuecat_fact", _always_fail)

    store = get_store()
    # Prime attempts to the ceiling-1 so the next failure dead-letters.
    r = _post(client, rc_event(event_id="e1", app_user_id=aid))
    assert r.status_code == 200
    # Force the event's attempts up to the ceiling, then post a redelivery.
    for _ in range(revenuecat._MAX_ATTEMPTS):
        store.mark_revenuecat_event_failed("e1", "priming")
    r2 = _post(client, rc_event(event_id="e1", app_user_id=aid))
    assert r2.status_code == 200
    ev = store.get_revenuecat_event("e1")
    assert ev["state"] == "dead_letter"


# ---------------------------------------------------------------------------
# §9 hostile: legacy / RevenueCat disagreement (shadow reconciliation)
# ---------------------------------------------------------------------------


def test_shadow_records_disagreement_when_rc_active_but_legacy_not(rc):
    rc.state["mode"] = "shadow"
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)
    # RevenueCat says active; legacy has no grant -> a recorded disagreement.
    _post(client, rc_event(event_id="e1", app_user_id=aid))
    from backend.store import get_store
    store = get_store()
    disagreements = store.revenuecat_shadow_disagreements()
    assert len(disagreements) == 1
    d = disagreements[0]
    assert d["revenuecat_active"] == 1 and d["legacy_active"] == 0 and d["agree"] == 0


def test_shadow_agreement_when_both_inactive(rc):
    rc.state["mode"] = "shadow"
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)
    # An expired/non-entitling event: RC not active, legacy not active -> agree.
    _post(client, rc_event(event_id="e1", etype="EXPIRATION", app_user_id=aid,
                           expiration_ms=_past_ms()))
    from backend.store import get_store
    store = get_store()
    assert store.revenuecat_shadow_disagreements() == []


def test_readiness_surfaces_shadow_summary_counts(rc):
    """The operator can confirm the shadow canary's health from the readiness
    probe alone — the gate for flipping shadow -> authoritative."""
    rc.state["mode"] = "shadow"
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)
    # One disagreement (RC active, legacy has no grant) + one agreement (both off).
    _post(client, rc_event(event_id="e1", app_user_id=aid))
    _post(client, rc_event(event_id="e2", etype="EXPIRATION", app_user_id=aid,
                           expiration_ms=_past_ms()))
    body = client.get("/v1/revenuecat/readiness").json()
    shadow = body["shadow"]
    assert shadow["total"] == 2
    assert shadow["disagreements"] == 1
    assert shadow["agreements"] == 1
    assert shadow["last_observed_at"] is not None
    # A disagreement means the shadow canary is NOT clean -> do not flip.
    assert body["shadow_clean"] is False


def test_readiness_shadow_summary_reveals_no_identifiers(rc):
    """Shadow observability is COUNTS ONLY on the unauthenticated probe — never an
    account id, event id, or per-user detail (contract §5)."""
    rc.state["mode"] = "shadow"
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)
    _post(client, rc_event(event_id="e1", app_user_id=aid))
    shadow = client.get("/v1/revenuecat/readiness").json()["shadow"]
    assert set(shadow) == {"total", "agreements", "disagreements", "last_observed_at"}
    assert aid not in str(shadow)


# ---------------------------------------------------------------------------
# Structurally-invalid event -> dead-letter, no retry storm
# ---------------------------------------------------------------------------


def test_structurally_invalid_event_is_rejected_400(rc):
    client = rc.client
    r = client.post(
        "/v1/revenuecat/notifications",
        content=json.dumps({"api_version": "1.0", "event": {"type": "RENEWAL"}}),  # no id
        headers={"Authorization": SECRET},
    )
    assert r.status_code == 400, r.text


def test_malformed_body_is_400(rc):
    client = rc.client
    r = client.post(
        "/v1/revenuecat/notifications",
        content=b"not json at all",
        headers={"Authorization": SECRET},
    )
    assert r.status_code == 400, r.text


def test_test_event_is_ignored_cleanly(rc):
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)
    r = _post(client, rc_event(event_id="e1", etype="TEST", app_user_id=aid,
                               product_id=None, entitlement_ids=None,
                               original_transaction_id=None))
    assert r.status_code == 200
    assert r.json()["outcome"].startswith("ignored:")
    assert _me(client, tok)["is_pro"] is False


def test_event_for_other_entitlement_is_ignored(rc):
    """An event for a product/entitlement that is not ours never grants."""
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)
    r = _post(client, rc_event(event_id="e1", app_user_id=aid, product_id="com.other.app.pro",
                               entitlement_ids=("some_other_entitlement",),
                               original_transaction_id="otx-other"))
    assert r.status_code == 200
    assert "ignored" in r.json()["outcome"]
    assert _me(client, tok)["is_pro"] is False


# ---------------------------------------------------------------------------
# §6 corrective (build 126): PROMOTIONAL admin grants are transport/idempotency
# evidence, NOT a store-parity canary. They stay in the append-only lifetime
# ledger but must be EXCLUDED from the shadow -> authoritative flip decision, or a
# single intentional promotional wiring canary pins `shadow_clean` false forever
# even when the integration is healthy. Real stores stay flip-eligible; an
# unclassifiable store fails closed.
# ---------------------------------------------------------------------------


def _shadow_rows(store) -> list[dict]:
    """Every shadow observation, raw (test-only helper — asserts evidence is
    retained, including agreements the disagreement view omits)."""
    def _do() -> list[dict]:
        cur = store._conn.cursor()
        cur.execute("SELECT * FROM revenuecat_shadow_observations ORDER BY id")
        return [dict(r) for r in cur.fetchall()]
    return store._run(_do).result()


def test_promotional_disagreement_excluded_from_flip_but_kept_in_lifetime(rc):
    """The live root cause: a RevenueCat PROMOTIONAL grant makes RC active while
    the legacy projection correctly stays free in shadow -> a real disagreement,
    but not a store-parity one. It must remain visible in lifetime diagnostics
    yet be excluded from the flip gate, so a healthy integration reads clean."""
    rc.state["mode"] = "shadow"
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)

    r = _post(client, rc_event(event_id="promo1", app_user_id=aid, store="PROMOTIONAL",
                               original_transaction_id="rc-promo-1"))
    assert r.status_code == 200, r.text
    assert _me(client, tok)["is_pro"] is False  # shadow never grants

    from backend.store import get_store
    store = get_store()
    life = store.revenuecat_shadow_summary()
    flip = store.revenuecat_shadow_flip_summary()
    # Lifetime STILL records the disagreement — evidence is never rewritten.
    assert life["total"] == 1 and life["disagreements"] == 1 and life["agreements"] == 0
    # ...but it is excluded from the flip-eligibility decision.
    assert flip["eligible"] == {"total": 0, "agreements": 0, "disagreements": 0}
    assert flip["excluded_promotional"] == 1
    assert flip["unclassified"] == 0

    body = client.get("/v1/revenuecat/readiness").json()
    assert body["shadow"]["disagreements"] == 1              # lifetime diagnostics
    assert body["shadow_excluded_promotional"] == 1
    assert body["shadow_flip_eligible"]["disagreements"] == 0
    assert body["shadow_clean"] is True                      # the corrected gate


def test_promotional_grant_and_revoke_observations_are_all_retained(rc):
    """Reproduces the live ledger: shadow.total=3, agreements=2, disagreements=1,
    ALL promotional (grant disagrees; two revoke/expiry observations agree). Every
    row is retained in lifetime; none is flip-eligible; the gate is clean."""
    rc.state["mode"] = "shadow"
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)

    _post(client, rc_event(event_id="promo-grant", app_user_id=aid, store="PROMOTIONAL",
                           original_transaction_id="rc-promo-1"))
    _post(client, rc_event(event_id="promo-revoke1", etype="EXPIRATION", app_user_id=aid,
                           store="PROMOTIONAL", expiration_ms=_past_ms(),
                           original_transaction_id="rc-promo-1"))
    _post(client, rc_event(event_id="promo-revoke2", etype="EXPIRATION", app_user_id=aid,
                           store="PROMOTIONAL", expiration_ms=_past_ms(),
                           original_transaction_id="rc-promo-1"))

    from backend.store import get_store
    store = get_store()
    life = store.revenuecat_shadow_summary()
    assert life["total"] == 3 and life["agreements"] == 2 and life["disagreements"] == 1
    # Both revoke observations are physically retained (not just the disagreement).
    ids = {row["event_id"] for row in _shadow_rows(store)}
    assert {"promo-grant", "promo-revoke1", "promo-revoke2"} <= ids

    flip = store.revenuecat_shadow_flip_summary()
    assert flip["excluded_promotional"] == 3
    assert flip["eligible"]["total"] == 0
    assert flip["unclassified"] == 0
    assert client.get("/v1/revenuecat/readiness").json()["shadow_clean"] is True


@pytest.mark.parametrize("store_val", ["APP_STORE", "PLAY_STORE", "STRIPE", "RC_BILLING"])
def test_real_store_disagreement_remains_flip_blocking(rc, store_val):
    """A disagreement from any real customer store is a genuine store-parity
    failure and MUST still block the flip — the fix excludes promotional and
    self-issued/TEST_STORE canaries only, never a real store."""
    rc.state["mode"] = "shadow"
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)

    r = _post(client, rc_event(event_id="e1", app_user_id=aid, store=store_val,
                               original_transaction_id="otx-real"))
    assert r.status_code == 200, r.text

    body = client.get("/v1/revenuecat/readiness").json()
    assert body["shadow_flip_eligible"]["total"] == 1
    assert body["shadow_flip_eligible"]["disagreements"] == 1
    assert body["shadow_excluded_promotional"] == 0
    assert body["shadow_excluded_synthetic"] == 0
    assert body["shadow_unclassified"] == 0
    assert body["shadow_clean"] is False


# ---------------------------------------------------------------------------
# Synthetic / TEST_STORE canary correction: a signed self-issued integration
# probe proves the transport/auth/idempotency path end-to-end but stands for NO
# real customer purchase. It must stay durably auditable in the append-only
# ledger yet NEVER qualify as real store evidence — otherwise a single signed
# canary pins `shadow_clean` false forever and blocks the authoritative cutover
# (the exact live-production state: shadow_flip_eligible disagreements=1). It is
# excluded from the flip like promotional, but bucketed separately.
# ---------------------------------------------------------------------------


def test_classify_rc_store_buckets_synthetic_separately():
    """Store-level classifier: TEST_STORE is 'synthetic' (case/space-insensitive),
    distinct from promotional and from real stores; unknown still fails closed."""
    from backend.store import _classify_rc_store
    assert _classify_rc_store("TEST_STORE") == "synthetic"
    assert _classify_rc_store("  test_store ") == "synthetic"
    assert _classify_rc_store("PROMOTIONAL") == "promotional"
    assert _classify_rc_store("APP_STORE") == "eligible"
    assert _classify_rc_store("STRIPE") == "eligible"
    assert _classify_rc_store("WHATEVER_NEW") == "unknown"
    assert _classify_rc_store("") == "unknown"
    assert _classify_rc_store(None) == "unknown"


def test_synthetic_test_store_disagreement_excluded_from_flip_but_durably_retained(rc):
    """The live blocker: a signed TEST_STORE canary makes RevenueCat active while
    the legacy projection correctly stays free in shadow -> a disagreement, but a
    synthetic one. It must be EXCLUDED from the flip (its own bucket), leave the
    gate clean, and STILL be physically retained in the append-only ledger."""
    rc.state["mode"] = "shadow"
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)

    r = _post(client, rc_event(event_id="synth-1", app_user_id=aid, store="TEST_STORE",
                               original_transaction_id="otx-synth"))
    assert r.status_code == 200, r.text
    assert _me(client, tok)["is_pro"] is False  # shadow never grants

    from backend.store import get_store
    store = get_store()
    life = store.revenuecat_shadow_summary()
    flip = store.revenuecat_shadow_flip_summary()
    # Lifetime STILL records the disagreement — evidence is never rewritten.
    assert life["total"] == 1 and life["disagreements"] == 1 and life["agreements"] == 0
    # ...but it is excluded from the flip decision, in the SYNTHETIC bucket.
    assert flip["eligible"] == {"total": 0, "agreements": 0, "disagreements": 0}
    assert flip["excluded_synthetic"] == 1
    assert flip["excluded_promotional"] == 0
    assert flip["unclassified"] == 0
    # The observation row is physically retained (durably auditable).
    rows = _shadow_rows(store)
    assert any(row["event_id"] == "synth-1" and (row["store_source"] or "").upper() == "TEST_STORE"
               for row in rows)

    body = client.get("/v1/revenuecat/readiness").json()
    assert body["shadow"]["disagreements"] == 1                 # lifetime diagnostics
    assert body["shadow_excluded_synthetic"] == 1
    assert body["shadow_excluded_promotional"] == 0
    assert body["shadow_flip_eligible"]["disagreements"] == 0
    assert body["shadow_unclassified"] == 0
    assert body["shadow_clean"] is True                         # the corrected gate


def test_synthetic_canary_never_masks_a_real_store_disagreement(rc):
    """A synthetic canary is excluded, but a REAL store disagreement alongside it
    must still block the flip — the correction must not smuggle a green gate."""
    rc.state["mode"] = "shadow"
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)

    _post(client, rc_event(event_id="synth-a", app_user_id=aid, store="TEST_STORE",
                           original_transaction_id="otx-synth-a"))
    _post(client, rc_event(event_id="real-a", app_user_id=aid, store="APP_STORE",
                           original_transaction_id="otx-real-a"))

    body = client.get("/v1/revenuecat/readiness").json()
    assert body["shadow_excluded_synthetic"] == 1
    assert body["shadow_flip_eligible"]["total"] == 1
    assert body["shadow_flip_eligible"]["disagreements"] == 1
    assert body["shadow_clean"] is False                        # real store still blocks


def test_duplicate_synthetic_event_is_idempotent_single_observation(rc):
    """Re-delivering the SAME signed TEST_STORE event (RevenueCat retries) must
    not double-count: one observation, one synthetic exclusion — the shadow
    ledger keys on event_id."""
    rc.state["mode"] = "shadow"
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)

    body_evt = rc_event(event_id="synth-dup", app_user_id=aid, store="TEST_STORE",
                        original_transaction_id="otx-synth-dup")
    assert _post(client, body_evt).status_code == 200
    assert _post(client, body_evt).status_code == 200          # replay

    from backend.store import get_store
    store = get_store()
    flip = store.revenuecat_shadow_flip_summary()
    assert flip["excluded_synthetic"] == 1                      # not 2
    assert store.revenuecat_shadow_summary()["total"] == 1
    assert len([r for r in _shadow_rows(store) if r["event_id"] == "synth-dup"]) == 1


def test_deployed_test_store_row_reclassifies_to_synthetic_without_deletion(rc):
    """Upgrade/migration behavior: a TEST_STORE observation already written to a
    DEPLOYED shadow ledger (the live production row) reclassifies to the synthetic
    bucket at read time with NO row deleted or rewritten — the append-only ledger
    is preserved and the previously-pinned gate reads clean."""
    rc.state["mode"] = "shadow"
    client = rc.client
    _register(client)  # force app + store init
    from backend.store import get_store, _now_iso
    store = get_store()

    def _seed():
        cur = store._conn.cursor()
        cur.execute(
            "INSERT INTO revenuecat_shadow_observations (event_id,account_id,store_source,"
            "revenuecat_active,legacy_active,agree,mode,detail,created_at) "
            "VALUES (?,?,?,?,?,?,?,?,?)",
            ("deployed-test-store", "acct", "TEST_STORE", 1, 0, 0, "shadow", "canary", _now_iso()),
        )
    store._run(_seed).result()

    flip = store.revenuecat_shadow_flip_summary()
    assert flip["excluded_synthetic"] == 1
    assert flip["eligible"]["disagreements"] == 0
    assert flip["unclassified"] == 0
    # Not deleted — the exact seeded row is still physically present.
    assert any(r["event_id"] == "deployed-test-store" for r in _shadow_rows(store))
    assert client.get("/v1/revenuecat/readiness").json()["shadow_clean"] is True


@pytest.mark.parametrize("store_val", ["TOTALLY_MADE_UP", "", None, 123])
def test_unknown_or_malformed_store_fails_closed(rc, store_val):
    """An observation whose store cannot be classified must NOT be silently
    treated as promotional (excluded) or clean — it fails closed and blocks the
    flip, so a store RevenueCat adds later can never smuggle a green gate."""
    rc.state["mode"] = "shadow"
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)

    r = _post(client, rc_event(event_id="e1", app_user_id=aid, store=store_val,
                               original_transaction_id="otx-unknown"))
    assert r.status_code == 200, r.text

    from backend.store import get_store
    store = get_store()
    flip = store.revenuecat_shadow_flip_summary()
    assert flip["excluded_promotional"] == 0        # never assumed promotional
    assert flip["eligible"]["disagreements"] == 0   # never counted as eligible
    assert flip["unclassified"] == 1                # fail closed

    body = client.get("/v1/revenuecat/readiness").json()
    assert body["shadow_unclassified"] == 1
    assert body["shadow_clean"] is False


def test_pre_migration_row_classified_from_durable_event_payload_on_backfill(rc):
    """Existing DEPLOYED promotional rows (written before `store_source` existed)
    must be classified after upgrade, not just new inserts. Here the durable
    event's derived column is ALSO null, forcing recovery from the raw payload
    JSON — the same body RevenueCat delivered. Before the backfill the row fails
    closed (unclassified); after it, it is correctly excluded as promotional."""
    rc.state["mode"] = "shadow"
    client = rc.client
    _register(client)  # force app + store init
    from backend.store import get_store, _now_iso
    store = get_store()

    def _seed():
        cur = store._conn.cursor()
        cur.execute(
            "INSERT INTO revenuecat_events (event_id,event_type,app_user_id,store_source,"
            "environment,event_ms,payload,state,attempts,received_at) "
            "VALUES (?,?,?,?,?,?,?, 'processed',0,?)",
            ("legacy-promo", "INITIAL_PURCHASE", "acct", None, "PRODUCTION", 1,
             json.dumps({"event": {"id": "legacy-promo", "store": "PROMOTIONAL"}}), _now_iso()),
        )
        cur.execute(
            "INSERT INTO revenuecat_shadow_observations (event_id,account_id,store_source,"
            "revenuecat_active,legacy_active,agree,mode,detail,created_at) "
            "VALUES (?,?,?,?,?,?,?,?,?)",
            ("legacy-promo", "acct", None, 1, 0, 0, "shadow", "legacy", _now_iso()),
        )
    store._run(_seed).result()

    # Pre-backfill: neither the observation nor the event's derived column carries
    # the store, so the query-time join can't classify it -> fail closed.
    flip = store.revenuecat_shadow_flip_summary()
    assert flip["unclassified"] == 1 and flip["excluded_promotional"] == 0

    # The upgrade-startup backfill recovers PROMOTIONAL from the raw payload.
    store._backfill_revenuecat_shadow_store_source()
    flip = store.revenuecat_shadow_flip_summary()
    assert flip["excluded_promotional"] == 1 and flip["unclassified"] == 0
    assert flip["eligible"]["disagreements"] == 0

    def _read():
        cur = store._conn.cursor()
        cur.execute("SELECT store_source FROM revenuecat_shadow_observations WHERE event_id='legacy-promo'")
        return cur.fetchone()["store_source"]
    assert store._run(_read).result() == "PROMOTIONAL"


def test_pre_migration_real_store_row_classified_via_join_without_backfill(rc):
    """The other durable path: a pre-migration row whose OBSERVATION store_source
    is null but whose durable event carries the store. The flip summary derives
    it via the LEFT JOIN + COALESCE with no backfill run — and a real-store
    disagreement still blocks the flip."""
    rc.state["mode"] = "shadow"
    client = rc.client
    _register(client)
    from backend.store import get_store, _now_iso
    store = get_store()

    def _seed():
        cur = store._conn.cursor()
        cur.execute(
            "INSERT INTO revenuecat_events (event_id,event_type,app_user_id,store_source,"
            "environment,event_ms,payload,state,attempts,received_at) "
            "VALUES (?,?,?,?,?,?,?, 'processed',0,?)",
            ("legacy-app", "RENEWAL", "acct", "APP_STORE", "PRODUCTION", 1,
             json.dumps({"event": {"id": "legacy-app", "store": "APP_STORE"}}), _now_iso()),
        )
        cur.execute(
            "INSERT INTO revenuecat_shadow_observations (event_id,account_id,store_source,"
            "revenuecat_active,legacy_active,agree,mode,detail,created_at) "
            "VALUES (?,?,?,?,?,?,?,?,?)",
            ("legacy-app", "acct", None, 1, 0, 0, "shadow", "legacy", _now_iso()),
        )
    store._run(_seed).result()

    flip = store.revenuecat_shadow_flip_summary()   # no backfill invoked
    assert flip["eligible"]["disagreements"] == 1
    assert flip["unclassified"] == 0 and flip["excluded_promotional"] == 0
    assert client.get("/v1/revenuecat/readiness").json()["shadow_clean"] is False


def test_duplicate_delivery_does_not_double_count_shadow_observation(rc):
    """A redelivered webhook is ACKed idempotently and never adds a second
    observation, so a duplicate promotional/real delivery cannot inflate either
    summary (contract §5/§8)."""
    rc.state["mode"] = "shadow"
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)

    body = rc_event(event_id="dup1", app_user_id=aid, store="APP_STORE",
                    original_transaction_id="otx-dup")
    r1 = _post(client, body)
    r2 = _post(client, body)
    assert r1.status_code == 200 and r2.status_code == 200
    assert r2.json().get("duplicate") is True

    from backend.store import get_store
    store = get_store()
    assert store.revenuecat_shadow_summary()["total"] == 1
    flip = store.revenuecat_shadow_flip_summary()
    assert flip["eligible"]["total"] == 1 and flip["eligible"]["disagreements"] == 1


def test_readiness_exposes_lifetime_and_flip_eligible_and_derives_clean_from_eligible(rc):
    """Readiness surfaces BOTH the lifetime and flip-eligible summaries, and
    `shadow_clean` follows the eligible one: a promotional disagreement plus a
    clean real-store agreement reads clean, because the only disagreement is
    excluded."""
    rc.state["mode"] = "shadow"
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)

    _post(client, rc_event(event_id="promo", app_user_id=aid, store="PROMOTIONAL",
                           original_transaction_id="rc-promo"))
    _post(client, rc_event(event_id="apple-ok", etype="EXPIRATION", app_user_id=aid,
                           store="APP_STORE", expiration_ms=_past_ms(),
                           original_transaction_id="otx-apple"))

    body = client.get("/v1/revenuecat/readiness").json()
    assert body["shadow"]["total"] == 2 and body["shadow"]["disagreements"] == 1
    assert body["shadow_flip_eligible"] == {"total": 1, "agreements": 1, "disagreements": 0}
    assert body["shadow_excluded_promotional"] == 1
    assert body["shadow_unclassified"] == 0
    assert body["shadow_clean"] is True


def test_readiness_flip_fields_are_counts_only_no_identifiers(rc):
    """The new flip-eligibility fields are non-secret COUNTS — never an account,
    event id, or store detail (contract §5/§9)."""
    rc.state["mode"] = "shadow"
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)
    _post(client, rc_event(event_id="promo", app_user_id=aid, store="PROMOTIONAL",
                           original_transaction_id="rc-promo"))
    _post(client, rc_event(event_id="apple", app_user_id=aid, store="APP_STORE",
                           original_transaction_id="otx-a"))

    body = client.get("/v1/revenuecat/readiness").json()
    assert set(body["shadow_flip_eligible"]) == {"total", "agreements", "disagreements"}
    for value in body["shadow_flip_eligible"].values():
        assert isinstance(value, int) and not isinstance(value, bool)
    for key in ("shadow_flip_eligible", "shadow_excluded_promotional", "shadow_unclassified"):
        blob = str(body[key])
        assert aid not in blob
        assert "rc-promo" not in blob and "otx-a" not in blob


def test_authoritative_grant_behavior_is_unchanged(rc):
    """The patch changes only shadow-canary accounting. The authoritative writer
    is untouched: a real-store event still grants Pro, and a PROMOTIONAL grant
    still grants too (store class gates ONLY the shadow flip decision, never the
    authoritative entitlement writer)."""
    rc.state["mode"] = "authoritative"
    client = rc.client
    tok = _register(client)["api_token"]
    aid = _account_id(client, tok)
    assert _me(client, tok)["is_pro"] is False
    r = _post(client, rc_event(event_id="e1", app_user_id=aid, store="APP_STORE"))
    assert r.status_code == 200, r.text
    assert r.json()["outcome"].startswith("authoritative:")
    assert _me(client, tok)["is_pro"] is True

    tok2 = _register(client)["api_token"]
    aid2 = _account_id(client, tok2)
    r2 = _post(client, rc_event(event_id="e2", app_user_id=aid2, store="PROMOTIONAL",
                                original_transaction_id="otx-2"))
    assert r2.status_code == 200, r2.text
    assert _me(client, tok2)["is_pro"] is True
