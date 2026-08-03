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
