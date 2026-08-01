"""Hostile tests for the Stripe lifecycle/projection slice (build-100).

Scenarios:
  1.  Bad signature → zero DB writes (400, no stripe_events row)
  2.  Duplicate processed → 200 duplicate, no double update
  3.  Handler failure → 500 retryable; retry succeeds; duplicate_pending re-runs
  4.  Checkout with missing account → graceful log, no orphan grant
  5.  Renewal via invoice.payment_succeeded → account stays Pro, period updated
  6.  Failed payment → past_due grace (still Pro) → unpaid → revoke
  7.  Cancellation end-of-period (subscription.deleted) → access revoked
  8.  Immediate cancellation → access revoked immediately
  9.  Full refund → lifecycle=refunded, access revoked
  10. Partial refund → access unchanged
  11. Dispute funds_withdrawn → access revoked
  12. Dispute funds_reinstated → access restored
  13. Provider outage then reconciliation healing
  14. No cross-account claim (different subscription doesn't bleed)
  15. Out-of-order stale event cannot resurrect active subscription
  16. Out-of-order stale active event cannot resurrect terminal subscription
"""

from __future__ import annotations

import json
from typing import Optional
from unittest.mock import MagicMock

import pytest


def test_stripe_sdk_event_is_normalized_for_durable_inbox():
    from backend.payments import _stripe_event_to_dict

    class Event:
        def to_dict_recursive(self):
            return {"id": "evt_real", "type": "customer.subscription.updated", "data": {"object": {"id": "sub_real"}}}

    normalized = _stripe_event_to_dict(Event())
    assert normalized["id"] == "evt_real"
    assert json.loads(json.dumps(normalized))["data"]["object"]["id"] == "sub_real"


def test_unserializable_verified_stripe_event_fails_retryably():
    from backend.payments import _stripe_event_to_dict

    class BrokenEvent:
        def to_dict_recursive(self):
            raise TypeError("broken")

    with pytest.raises(TypeError):
        _stripe_event_to_dict(BrokenEvent())


# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------


def _register(client) -> dict:
    r = client.post("/v1/register", json={})
    assert r.status_code == 200, r.text
    return r.json()


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _configure_stripe(monkeypatch) -> None:
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_fake")
    monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", "whsec_fake")
    monkeypatch.setenv("STRIPE_PRICE_PRO_MONTHLY", "price_fake_month")


def _sign_in_apple(client, app, token: str, sub: str) -> str:
    import backend.social_auth as social_auth

    async def fake_verifier(_token: str):
        return social_auth.IdentityClaims(sub=sub, email=f"{sub}@example.com")

    app.dependency_overrides[social_auth.get_apple_verifier] = lambda: fake_verifier
    r = client.post(
        "/v1/auth/apple", json={"identity_token": "t"}, headers=_auth(token)
    )
    assert r.status_code == 200, r.text
    return r.json()["account_id"]


def _post_webhook(client, monkeypatch, payments_mod, event_id, etype, obj_data,
                  sub_retrieve=None):
    """Post a fake Stripe webhook event and return the response."""
    event = {
        "id": event_id,
        "type": etype,
        "data": {"object": obj_data},
    }
    monkeypatch.setattr(
        payments_mod.stripe.Webhook, "construct_event", lambda *a, **k: event
    )
    if sub_retrieve is not None:
        monkeypatch.setattr(
            payments_mod.stripe.Subscription, "retrieve", sub_retrieve
        )
    return client.post(
        "/v1/stripe/webhook",
        content=b"{}",
        headers={"stripe-signature": "sig_fake", "Content-Type": "application/json"},
    )


_FUTURE_PERIOD_END = 4102444800   # 2100-01-01 unix timestamp
_PAST_PERIOD_END = 1000000000     # 2001-09-09 (already expired)


def _sub_obj(
    sub_id="sub_test_1",
    customer_id="cus_test_1",
    status="active",
    period_end=_FUTURE_PERIOD_END,
    account_id: Optional[str] = None,
    device_id: Optional[str] = None,
) -> dict:
    metadata = {}
    if account_id:
        metadata["tono_account_id"] = account_id
    if device_id:
        metadata["tono_device_id"] = device_id
    return {
        "id": sub_id,
        "customer": customer_id,
        "status": status,
        "current_period_end": period_end,
        "metadata": metadata,
        "items": {"data": [{"price": {"product": "prod_stripe_pro"}}]},
    }


def _fake_sub_retrieve(status="active", period_end=_FUTURE_PERIOD_END):
    def _retrieve(_id):
        return {
            "status": status,
            "current_period_end": period_end,
            "items": {"data": [{"price": {"product": "prod_stripe_pro"}}]},
        }
    return _retrieve


# ---------------------------------------------------------------------------
# Test 1: Bad signature → zero DB writes
# ---------------------------------------------------------------------------


def test_bad_signature_zero_writes(client, monkeypatch):
    import stripe as stripe_lib

    import backend.payments as payments_mod

    _configure_stripe(monkeypatch)

    monkeypatch.setattr(
        payments_mod.stripe.Webhook,
        "construct_event",
        lambda *a, **k: (_ for _ in ()).throw(
            stripe_lib.error.SignatureVerificationError("bad sig", "sig_hdr")
        ),
    )

    r = client.post(
        "/v1/stripe/webhook",
        content=b'{"bad": "sig"}',
        headers={"stripe-signature": "bad_sig", "Content-Type": "application/json"},
    )
    assert r.status_code == 400

    from backend.store import get_store
    store = get_store()

    def _count_events():
        import sqlite3
        conn = sqlite3.connect(store.path)
        conn.row_factory = sqlite3.Row
        row = conn.execute("SELECT COUNT(*) as c FROM stripe_events").fetchone()
        conn.close()
        return row["c"]

    assert _count_events() == 0, "bad signature must write zero stripe_events rows"


# ---------------------------------------------------------------------------
# Test 2: Duplicate → 200, no double update
# ---------------------------------------------------------------------------


def test_duplicate_event_idempotent(client, monkeypatch):
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="apple-dup-1")
    store = get_store()
    store.attach_account_stripe_customer(account_id, "cus_dup_1")

    import backend.payments as payments_mod

    obj = _sub_obj("sub_dup_1", "cus_dup_1", account_id=account_id)

    # First delivery — processes and marks done
    r1 = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_dup_1", "customer.subscription.updated", obj,
        sub_retrieve=_fake_sub_retrieve(),
    )
    assert r1.status_code == 200
    assert r1.json().get("duplicate") is not True

    acct = store.get_account(account_id)
    assert acct.is_pro is True

    # Second delivery of the same event
    r2 = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_dup_1", "customer.subscription.updated", obj,
        sub_retrieve=_fake_sub_retrieve(),
    )
    assert r2.status_code == 200
    assert r2.json().get("duplicate") is True

    # Still Pro — no double-cancel or state corruption
    acct2 = store.get_account(account_id)
    assert acct2.is_pro is True


# ---------------------------------------------------------------------------
# Test 3: Handler failure → 500 (retryable); retry succeeds
# ---------------------------------------------------------------------------


def test_handler_failure_returns_5xx_then_retry_succeeds(client, monkeypatch):
    """First call fails (handler error) → 500 Stripe retries.
    Second call is 'duplicate_pending' → re-processes → 200."""
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="apple-retry-1")
    store = get_store()

    import backend.payments as payments_mod

    obj = _sub_obj("sub_retry_1", "cus_retry_1", account_id=account_id)
    event_id = "evt_retry_1"

    call_count = [0]

    def failing_then_passing_sub_retrieve(_id):
        call_count[0] += 1
        if call_count[0] == 1:
            raise RuntimeError("simulated Stripe outage")
        return {
            "status": "active",
            "current_period_end": _FUTURE_PERIOD_END,
            "items": {"data": []},
        }

    # First POST — handler raises → 500
    event_v1 = {"id": event_id, "type": "checkout.session.completed",
                 "data": {"object": {**obj, "subscription": "sub_retry_1",
                                     "client_reference_id": device["device_id"]}}}
    monkeypatch.setattr(
        payments_mod.stripe.Webhook, "construct_event", lambda *a, **k: event_v1
    )
    monkeypatch.setattr(
        payments_mod.stripe.Subscription, "retrieve", failing_then_passing_sub_retrieve
    )

    r1 = client.post(
        "/v1/stripe/webhook", content=b"{}",
        headers={"stripe-signature": "sig", "Content-Type": "application/json"},
    )
    assert r1.status_code == 500

    # Account should NOT be Pro yet — handler failed
    acct = store.get_account(account_id)
    assert acct.is_pro is False

    # Second POST (same event_id) — stripe_events row exists with processed_at=NULL
    # → 'duplicate_pending' → handler runs again → success
    r2 = client.post(
        "/v1/stripe/webhook", content=b"{}",
        headers={"stripe-signature": "sig", "Content-Type": "application/json"},
    )
    assert r2.status_code == 200
    assert r2.json().get("duplicate") is not True

    acct2 = store.get_account(account_id)
    assert acct2.is_pro is True


# ---------------------------------------------------------------------------
# Test 4: Checkout with missing account → graceful, no orphan grant
# ---------------------------------------------------------------------------


def test_checkout_missing_account_no_orphan_grant(client, monkeypatch):
    """Webhook with a tono_account_id that doesn't exist must not crash,
    must not write a dangling entitlement_grant, and must return 200."""
    _configure_stripe(monkeypatch)

    import backend.payments as payments_mod
    from backend.store import get_store

    ghost_account_id = "00000000-dead-beef-0000-000000000000"
    obj = {
        "id": "sub_ghost_1",
        "customer": "cus_ghost_1",
        "status": "active",
        "current_period_end": _FUTURE_PERIOD_END,
        "metadata": {"tono_account_id": ghost_account_id},
        "items": {"data": []},
    }

    r = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_ghost_1", "customer.subscription.updated", obj,
        sub_retrieve=_fake_sub_retrieve(),
    )
    assert r.status_code == 200

    store = get_store()
    # No entitlement grants for the non-existent account
    grants = store.list_entitlement_grants(ghost_account_id)
    assert grants == [], "must not write grants to non-existent account"


# ---------------------------------------------------------------------------
# Test 5: Renewal via invoice.payment_succeeded → still Pro, period updated
# ---------------------------------------------------------------------------


def test_renewal_invoice_payment_succeeded(client, monkeypatch):
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="apple-renew-1")
    store = get_store()
    store.attach_account_stripe_customer(account_id, "cus_renew_1")
    store.update_account_subscription(
        account_id=account_id,
        customer_id="cus_renew_1",
        subscription_id="sub_renew_1",
        status="active",
        renews_at="2026-01-01T00:00:00+00:00",
    )

    import backend.payments as payments_mod

    new_period_end = _FUTURE_PERIOD_END + 30 * 86400  # next month

    invoice_obj = {
        "subscription": "sub_renew_1",
        "customer": "cus_renew_1",
        "status": "paid",
    }

    r = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_invoice_renew_1", "invoice.payment_succeeded", invoice_obj,
        sub_retrieve=lambda _id: {
            "status": "active",
            "current_period_end": new_period_end,
            "items": {"data": []},
        },
    )
    assert r.status_code == 200

    acct = store.get_account(account_id)
    assert acct.is_pro is True
    assert acct.subscription_status == "active"

    purchase = store.get_stripe_purchase("sub_renew_1")
    assert purchase is not None
    assert purchase["lifecycle_state"] == "active"
    assert purchase["latest_signed_ms"] == new_period_end * 1000


# ---------------------------------------------------------------------------
# Test 6: Failed payment → past_due grace (Pro) → unpaid → not Pro
# ---------------------------------------------------------------------------


def test_failed_payment_grace_then_revoke(client, monkeypatch):
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="apple-fail-pay-1")
    store = get_store()
    store.attach_account_stripe_customer(account_id, "cus_failpay_1")

    import backend.payments as payments_mod

    # Step 1: establish active subscription
    r = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_failpay_active", "customer.subscription.updated",
        _sub_obj("sub_failpay_1", "cus_failpay_1", "active",
                 account_id=account_id),
        sub_retrieve=_fake_sub_retrieve("active"),
    )
    assert r.status_code == 200
    assert store.get_account(account_id).is_pro is True

    # Step 2: payment fails → invoice.payment_failed → stripe status goes to past_due
    invoice_obj = {"subscription": "sub_failpay_1", "customer": "cus_failpay_1"}
    r2 = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_failpay_failed", "invoice.payment_failed", invoice_obj,
        sub_retrieve=_fake_sub_retrieve("past_due"),
    )
    assert r2.status_code == 200
    # Grace period — still Pro (past_due maps to 'active' lifecycle)
    acct2 = store.get_account(account_id)
    assert acct2.is_pro is True
    purchase = store.get_stripe_purchase("sub_failpay_1")
    assert purchase["lifecycle_state"] == "active"

    # Step 3: dunning exhausted → subscription goes unpaid → revoke
    period_end_2 = _FUTURE_PERIOD_END + 60 * 86400  # later period_end
    r3 = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_failpay_unpaid", "customer.subscription.updated",
        _sub_obj("sub_failpay_1", "cus_failpay_1", "unpaid",
                 period_end=period_end_2, account_id=account_id),
        sub_retrieve=_fake_sub_retrieve("unpaid", period_end_2),
    )
    assert r3.status_code == 200
    acct3 = store.get_account(account_id)
    assert acct3.is_pro is False
    purchase3 = store.get_stripe_purchase("sub_failpay_1")
    assert purchase3["lifecycle_state"] == "expired"


# ---------------------------------------------------------------------------
# Test 7 + 8: Cancellation (end-of-period & immediate)
# ---------------------------------------------------------------------------


def test_cancellation_end_of_period(client, monkeypatch):
    """customer.subscription.deleted → immediate access revoke."""
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="apple-cancel-eop-1")
    store = get_store()
    store.attach_account_stripe_customer(account_id, "cus_cancel_eop_1")

    import backend.payments as payments_mod

    # Establish active subscription
    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_cancel_eop_active", "customer.subscription.updated",
        _sub_obj("sub_cancel_eop_1", "cus_cancel_eop_1", "active",
                 account_id=account_id),
        sub_retrieve=_fake_sub_retrieve("active"),
    )
    assert store.get_account(account_id).is_pro is True

    # Stripe sends subscription.deleted when period ends after cancel_at_period_end
    r = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_cancel_eop_del", "customer.subscription.deleted",
        _sub_obj("sub_cancel_eop_1", "cus_cancel_eop_1", "canceled",
                 account_id=account_id),
        sub_retrieve=_fake_sub_retrieve("canceled"),
    )
    assert r.status_code == 200

    acct = store.get_account(account_id)
    assert acct.is_pro is False
    purchase = store.get_stripe_purchase("sub_cancel_eop_1")
    assert purchase["lifecycle_state"] == "expired"


def test_immediate_cancellation(client, monkeypatch):
    """customer.subscription.deleted with immediate effect → access revoked."""
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="apple-imm-cancel-1")
    store = get_store()
    store.attach_account_stripe_customer(account_id, "cus_imm_cancel_1")

    import backend.payments as payments_mod

    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_imm_active", "customer.subscription.created",
        _sub_obj("sub_imm_1", "cus_imm_cancel_1", "active",
                 account_id=account_id),
        sub_retrieve=_fake_sub_retrieve("active"),
    )
    assert store.get_account(account_id).is_pro is True

    r = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_imm_del", "customer.subscription.deleted",
        _sub_obj("sub_imm_1", "cus_imm_cancel_1", "canceled",
                 account_id=account_id),
        sub_retrieve=_fake_sub_retrieve("canceled"),
    )
    assert r.status_code == 200
    assert store.get_account(account_id).is_pro is False


# ---------------------------------------------------------------------------
# Test 9: Full refund → lifecycle=refunded, access revoked
# ---------------------------------------------------------------------------


def test_full_refund_revokes_access(client, monkeypatch):
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="apple-refund-1")
    store = get_store()
    store.attach_account_stripe_customer(account_id, "cus_refund_1")

    import backend.payments as payments_mod

    # Set up active subscription
    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_refund_active", "customer.subscription.created",
        _sub_obj("sub_refund_1", "cus_refund_1", "active",
                 account_id=account_id),
        sub_retrieve=_fake_sub_retrieve("active"),
    )
    assert store.get_account(account_id).is_pro is True

    # Full refund: amount_refunded == amount
    charge_obj = {
        "id": "ch_refund_1",
        "customer": "cus_refund_1",
        "invoice": "inv_refund_1",
        "amount": 399,
        "amount_refunded": 399,
    }

    # Mock Invoice.retrieve to return subscription_id, and Charge.retrieve
    monkeypatch.setattr(
        payments_mod.stripe.Invoice,
        "retrieve",
        lambda _id: {"subscription": "sub_refund_1"},
    )

    r = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_charge_refund_1", "charge.refunded", charge_obj,
    )
    assert r.status_code == 200

    acct = store.get_account(account_id)
    assert acct.is_pro is False

    purchase = store.get_stripe_purchase("sub_refund_1")
    assert purchase is not None
    assert purchase["lifecycle_state"] == "refunded"

    grants = store.list_entitlement_grants(account_id)
    active_grants = [g for g in grants if g["state"] == "active"]
    assert len(active_grants) == 0, "all grants must be revoked after full refund"


# ---------------------------------------------------------------------------
# Test 10: Partial refund → access unchanged
# ---------------------------------------------------------------------------


def test_partial_refund_keeps_access(client, monkeypatch):
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="apple-partial-1")
    store = get_store()
    store.attach_account_stripe_customer(account_id, "cus_partial_1")

    import backend.payments as payments_mod

    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_partial_active", "customer.subscription.created",
        _sub_obj("sub_partial_1", "cus_partial_1", "active",
                 account_id=account_id),
        sub_retrieve=_fake_sub_retrieve("active"),
    )
    assert store.get_account(account_id).is_pro is True

    # Partial refund: amount_refunded < amount
    charge_obj = {
        "id": "ch_partial_1",
        "customer": "cus_partial_1",
        "invoice": "inv_partial_1",
        "amount": 399,
        "amount_refunded": 100,  # partial
    }

    r = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_partial_refund", "charge.refunded", charge_obj,
    )
    assert r.status_code == 200

    acct = store.get_account(account_id)
    assert acct.is_pro is True, "partial refund must not revoke access"

    purchase = store.get_stripe_purchase("sub_partial_1")
    assert purchase["lifecycle_state"] == "active", "lifecycle unchanged for partial refund"


# ---------------------------------------------------------------------------
# Test 11: Dispute funds_withdrawn → revoke; funds_reinstated → restore
# ---------------------------------------------------------------------------


def test_dispute_revoke_then_reinstate(client, monkeypatch):
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="apple-dispute-1")
    store = get_store()
    store.attach_account_stripe_customer(account_id, "cus_dispute_1")

    import backend.payments as payments_mod

    # Establish active subscription via checkout
    checkout_obj = {
        "client_reference_id": device["device_id"],
        "customer": "cus_dispute_1",
        "subscription": "sub_dispute_1",
        "metadata": {"tono_account_id": account_id, "tono_device_id": device["device_id"]},
    }
    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_dispute_checkout", "checkout.session.completed", checkout_obj,
        sub_retrieve=_fake_sub_retrieve("active"),
    )
    assert store.get_account(account_id).is_pro is True

    # Mock Charge.retrieve for dispute handlers
    def fake_charge_retrieve(_id):
        return {"customer": "cus_dispute_1", "invoice": "inv_dispute_1"}

    def fake_invoice_retrieve(_id):
        return {"subscription": "sub_dispute_1"}

    monkeypatch.setattr(payments_mod.stripe.Charge, "retrieve", fake_charge_retrieve)
    monkeypatch.setattr(payments_mod.stripe.Invoice, "retrieve", fake_invoice_retrieve)

    # Dispute: funds withdrawn → revoke
    dispute_obj = {"id": "dp_1", "charge": "ch_dispute_1", "status": "needs_response"}
    r_withdraw = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_dispute_withdraw", "charge.dispute.funds_withdrawn", dispute_obj,
    )
    assert r_withdraw.status_code == 200

    acct = store.get_account(account_id)
    assert acct.is_pro is False

    purchase = store.get_stripe_purchase("sub_dispute_1")
    assert purchase["lifecycle_state"] == "revoked"

    # Dispute resolved in our favor → reinstate
    r_reinstate = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_dispute_reinstate", "charge.dispute.funds_reinstated", dispute_obj,
        sub_retrieve=_fake_sub_retrieve("active", _FUTURE_PERIOD_END + 90 * 86400),
    )
    assert r_reinstate.status_code == 200

    acct2 = store.get_account(account_id)
    assert acct2.is_pro is True

    purchase2 = store.get_stripe_purchase("sub_dispute_1")
    assert purchase2["lifecycle_state"] == "active"


# ---------------------------------------------------------------------------
# Test 12: Provider outage then reconciliation healing
# ---------------------------------------------------------------------------


def test_reconciliation_heals_missed_webhook(monkeypatch, tmp_path):
    """Simulate a missed webhook: DB has active sub but status shows wrong.
    Reconciler fetches current Stripe truth and heals it."""
    import stripe as stripe_lib

    import backend.reconcile_stripe as reconciler
    from backend.store import Store

    db_path = str(tmp_path / "recon_test.db")
    monkeypatch.setenv("TONO_DB_PATH", db_path)
    store = Store(db_path)

    # Set up account with stale DB state (active but subscription missed renewal)
    import uuid
    import datetime as dt

    acct_id = str(uuid.uuid4())
    now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    store._conn.execute(
        "INSERT INTO accounts (id, plan, stripe_customer_id, stripe_subscription_id, "
        "subscription_status, created_at, updated_at) VALUES (?, 'pro', ?, ?, 'past_due', ?, ?)",
        (acct_id, "cus_recon_1", "sub_recon_1", now, now),
    )

    # Mock Stripe API to return current active state
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_fake")

    fake_sub = {
        "status": "active",
        "current_period_end": _FUTURE_PERIOD_END,
        "items": {"data": [{"price": {"product": "prod_stripe_pro"}}]},
    }

    def fake_retrieve(sub_id):
        return fake_sub

    monkeypatch.setattr(stripe_lib.Subscription, "retrieve", fake_retrieve)

    # Inject the store so reconciler uses our test DB
    monkeypatch.setattr(reconciler, "Store", lambda path: store)

    # Run reconciliation (not dry-run)
    import sys
    old_argv = sys.argv
    sys.argv = ["reconcile_stripe"]
    try:
        # Patch sys.exit to capture the exit code
        exited = []
        def fake_exit(code=0):
            exited.append(code)
            raise SystemExit(code)
        monkeypatch.setattr(sys, "exit", fake_exit)

        try:
            reconciler.main()
        except SystemExit as e:
            assert e.code == 0, f"reconciler exited with code {e.code}"
    finally:
        sys.argv = old_argv

    # DB should now reflect the healed active state
    acct = store.get_account(acct_id)
    assert acct is not None
    assert acct.subscription_status == "active"
    store.close()


# ---------------------------------------------------------------------------
# Test 13: No cross-account claim
# ---------------------------------------------------------------------------


def test_no_cross_account_claim(client, monkeypatch):
    """A webhook for account A's subscription must not affect account B."""
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)

    device_a = _register(client)
    account_a = _sign_in_apple(client, app, device_a["api_token"], sub="apple-cross-a")
    device_b = _register(client)
    account_b = _sign_in_apple(client, app, device_b["api_token"], sub="apple-cross-b")
    store = get_store()

    store.attach_account_stripe_customer(account_a, "cus_cross_a")
    store.attach_account_stripe_customer(account_b, "cus_cross_b")

    import backend.payments as payments_mod

    # Give account A a Pro subscription
    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_cross_a", "customer.subscription.created",
        _sub_obj("sub_cross_a", "cus_cross_a", "active", account_id=account_a),
        sub_retrieve=_fake_sub_retrieve("active"),
    )
    assert store.get_account(account_a).is_pro is True
    assert store.get_account(account_b).is_pro is False

    # Give account B a separate subscription
    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_cross_b", "customer.subscription.created",
        _sub_obj("sub_cross_b", "cus_cross_b", "active", account_id=account_b),
        sub_retrieve=_fake_sub_retrieve("active"),
    )
    assert store.get_account(account_b).is_pro is True

    # Cancel account A's subscription — must not affect account B
    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_cross_a_cancel", "customer.subscription.deleted",
        _sub_obj("sub_cross_a", "cus_cross_a", "canceled", account_id=account_a),
        sub_retrieve=_fake_sub_retrieve("canceled"),
    )
    assert store.get_account(account_a).is_pro is False
    assert store.get_account(account_b).is_pro is True, "account B must be unaffected"


# ---------------------------------------------------------------------------
# Test 14: Out-of-order stale event — version guard
# ---------------------------------------------------------------------------


def test_stale_active_event_does_not_override_newer(client, monkeypatch):
    """An active event with an older period_end_ms cannot override a newer stored fact."""
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="apple-stale-1")
    store = get_store()
    store.attach_account_stripe_customer(account_id, "cus_stale_1")

    import backend.payments as payments_mod

    period_newer = _FUTURE_PERIOD_END + 30 * 86400
    period_older = _FUTURE_PERIOD_END

    # Apply newer fact first
    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_stale_newer", "customer.subscription.updated",
        _sub_obj("sub_stale_1", "cus_stale_1", "active",
                 period_end=period_newer, account_id=account_id),
        sub_retrieve=_fake_sub_retrieve("active", period_newer),
    )
    purchase = store.get_stripe_purchase("sub_stale_1")
    assert purchase["latest_signed_ms"] == period_newer * 1000

    # Apply older fact — should be ignored
    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_stale_older", "customer.subscription.updated",
        _sub_obj("sub_stale_1", "cus_stale_1", "active",
                 period_end=period_older, account_id=account_id),
        sub_retrieve=_fake_sub_retrieve("active", period_older),
    )
    purchase2 = store.get_stripe_purchase("sub_stale_1")
    assert purchase2["latest_signed_ms"] == period_newer * 1000, \
        "older event must not override newer stored period_end_ms"


def test_active_event_cannot_resurrect_terminal_subscription(client, monkeypatch):
    """An active event cannot resurrect a refunded/revoked subscription."""
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="apple-resurrect-1")
    store = get_store()
    store.attach_account_stripe_customer(account_id, "cus_resurrect_1")

    import backend.payments as payments_mod

    # Establish active
    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_res_active", "customer.subscription.created",
        _sub_obj("sub_res_1", "cus_resurrect_1", "active", account_id=account_id),
        sub_retrieve=_fake_sub_retrieve("active"),
    )
    assert store.get_account(account_id).is_pro is True

    # Full refund → terminal
    monkeypatch.setattr(
        payments_mod.stripe.Invoice,
        "retrieve",
        lambda _id: {"subscription": "sub_res_1"},
    )
    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_res_refund", "charge.refunded",
        {"customer": "cus_resurrect_1", "invoice": "inv_r", "amount": 399, "amount_refunded": 399},
    )
    assert store.get_account(account_id).is_pro is False
    assert store.get_stripe_purchase("sub_res_1")["lifecycle_state"] == "refunded"

    # Replay an active event (same or older period_end) → must NOT resurrect
    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_res_replay_active", "customer.subscription.updated",
        _sub_obj("sub_res_1", "cus_resurrect_1", "active", account_id=account_id),
        sub_retrieve=_fake_sub_retrieve("active"),
    )
    assert store.get_account(account_id).is_pro is False, \
        "refunded subscription must not be resurrected by a replayed active event"
    assert store.get_stripe_purchase("sub_res_1")["lifecycle_state"] == "refunded"


# ---------------------------------------------------------------------------
# Regression test 17 (QA bug 1):
# terminal refund + delayed invoice.payment_succeeded cannot regrant mutable Pro
# ---------------------------------------------------------------------------


def test_delayed_invoice_after_full_refund_does_not_regrant_pro(client, monkeypatch):
    """After a full refund (lifecycle=refunded) a late invoice.payment_succeeded
    must be treated as stale and must NOT write active plan/status back to the
    mutable account columns."""
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="apple-inv-stale-1")
    store = get_store()
    store.attach_account_stripe_customer(account_id, "cus_invstale_1")

    import backend.payments as payments_mod

    # Establish active subscription
    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_invstale_active", "customer.subscription.created",
        _sub_obj("sub_invstale_1", "cus_invstale_1", "active", account_id=account_id),
        sub_retrieve=_fake_sub_retrieve("active"),
    )
    assert store.get_account(account_id).is_pro is True

    # Full refund → lifecycle=refunded, access revoked
    monkeypatch.setattr(
        payments_mod.stripe.Invoice,
        "retrieve",
        lambda _id: {"subscription": "sub_invstale_1"},
    )
    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_invstale_refund", "charge.refunded",
        {"customer": "cus_invstale_1", "invoice": "inv_invstale_1",
         "amount": 399, "amount_refunded": 399},
    )
    assert store.get_account(account_id).is_pro is False
    assert store.get_stripe_purchase("sub_invstale_1")["lifecycle_state"] == "refunded"

    # Delayed invoice.payment_succeeded arrives (Stripe reports sub as active)
    invoice_obj = {
        "subscription": "sub_invstale_1",
        "customer": "cus_invstale_1",
        "status": "paid",
    }
    r = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_invstale_invoice", "invoice.payment_succeeded", invoice_obj,
        sub_retrieve=_fake_sub_retrieve("active", _FUTURE_PERIOD_END + 30 * 86400),
    )
    assert r.status_code == 200

    # Mutable columns must NOT be updated — stale guard holds
    acct = store.get_account(account_id)
    assert acct.is_pro is False, \
        "delayed invoice after full refund must not regrant Pro"
    assert acct.subscription_status != "active", \
        "subscription_status must not be set to active after refund"
    assert store.get_stripe_purchase("sub_invstale_1")["lifecycle_state"] == "refunded"


# ---------------------------------------------------------------------------
# Regression test 18 (QA bug 2):
# past_due dispute win reinstates access
# ---------------------------------------------------------------------------


def test_past_due_dispute_funds_reinstated_restores_access(client, monkeypatch):
    """When a dispute is won while the subscription is in past_due grace period,
    charge.dispute.funds_reinstated must reinstate Pro access."""
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="apple-pastdue-disp-1")
    store = get_store()
    store.attach_account_stripe_customer(account_id, "cus_pddisp_1")

    import backend.payments as payments_mod

    # Establish active subscription, then move to past_due via failed payment
    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_pddisp_active", "customer.subscription.created",
        _sub_obj("sub_pddisp_1", "cus_pddisp_1", "active", account_id=account_id),
        sub_retrieve=_fake_sub_retrieve("active"),
    )
    assert store.get_account(account_id).is_pro is True

    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_pddisp_failpay", "invoice.payment_failed",
        {"subscription": "sub_pddisp_1", "customer": "cus_pddisp_1"},
        sub_retrieve=_fake_sub_retrieve("past_due"),
    )
    # past_due = grace period, still Pro
    assert store.get_account(account_id).is_pro is True

    # Dispute: funds withdrawn → revoke even though sub is past_due
    def fake_charge_retrieve(_id):
        return {"customer": "cus_pddisp_1", "invoice": "inv_pddisp_1"}

    def fake_invoice_retrieve(_id):
        return {"subscription": "sub_pddisp_1"}

    monkeypatch.setattr(payments_mod.stripe.Charge, "retrieve", fake_charge_retrieve)
    monkeypatch.setattr(payments_mod.stripe.Invoice, "retrieve", fake_invoice_retrieve)

    dispute_obj = {"id": "dp_pd_1", "charge": "ch_pddisp_1", "status": "needs_response"}
    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_pddisp_withdraw", "charge.dispute.funds_withdrawn", dispute_obj,
    )
    assert store.get_account(account_id).is_pro is False
    assert store.get_stripe_purchase("sub_pddisp_1")["lifecycle_state"] == "revoked"

    # Dispute won → funds_reinstated with past_due subscription must reinstate
    r = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_pddisp_reinstate", "charge.dispute.funds_reinstated", dispute_obj,
        sub_retrieve=_fake_sub_retrieve("past_due", _FUTURE_PERIOD_END + 90 * 86400),
    )
    assert r.status_code == 200

    acct = store.get_account(account_id)
    assert acct.is_pro is True, \
        "past_due dispute win must reinstate Pro access"
    assert store.get_stripe_purchase("sub_pddisp_1")["lifecycle_state"] == "active"


# ---------------------------------------------------------------------------
# Regression test 19 (QA bug 3):
# Stripe API retrieval exception → 500/unprocessed → retry succeeds exactly once
# ---------------------------------------------------------------------------


def test_stripe_retrieval_exception_propagates_5xx_then_retry_succeeds(
    client, monkeypatch
):
    """A transient Stripe API error in Invoice.retrieve during charge.refunded must:
    - cause a 500 (not a silent 200 ACK)
    - leave the stripe_events row with processed_at=NULL (inbox stays pending)
    - allow a successful retry on the next delivery of the same event_id"""
    import sqlite3

    import stripe as stripe_lib

    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="apple-apiexc-1")
    store = get_store()
    store.attach_account_stripe_customer(account_id, "cus_apiexc_1")

    import backend.payments as payments_mod

    # Establish active subscription
    _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_apiexc_active", "customer.subscription.created",
        _sub_obj("sub_apiexc_1", "cus_apiexc_1", "active", account_id=account_id),
        sub_retrieve=_fake_sub_retrieve("active"),
    )
    assert store.get_account(account_id).is_pro is True

    charge_obj = {
        "id": "ch_apiexc_1",
        "customer": "cus_apiexc_1",
        "invoice": "inv_apiexc_1",
        "amount": 399,
        "amount_refunded": 399,
    }
    event_id = "evt_charge_apiexc_1"
    event = {
        "id": event_id,
        "type": "charge.refunded",
        "data": {"object": charge_obj},
    }

    call_count = [0]

    def flaky_invoice_retrieve(_id):
        call_count[0] += 1
        if call_count[0] == 1:
            raise stripe_lib.error.APIConnectionError("simulated network blip")
        return {"subscription": "sub_apiexc_1"}

    monkeypatch.setattr(
        payments_mod.stripe.Webhook, "construct_event", lambda *a, **k: event
    )
    monkeypatch.setattr(payments_mod.stripe.Invoice, "retrieve", flaky_invoice_retrieve)

    # First POST: Invoice.retrieve raises → handler throws → 500
    r1 = client.post(
        "/v1/stripe/webhook", content=b"{}",
        headers={"stripe-signature": "sig", "Content-Type": "application/json"},
    )
    assert r1.status_code == 500, "transient Stripe error must yield 500 so Stripe retries"

    # Event row must exist with processed_at=NULL (inbox stays pending)
    conn = sqlite3.connect(store.path)
    row = conn.execute(
        "SELECT processed_at FROM stripe_events WHERE event_id=?", (event_id,)
    ).fetchone()
    conn.close()
    assert row is not None, "stripe_events row must be created on first delivery"
    assert row[0] is None, "processed_at must be NULL after handler failure"

    # Access must not have changed (refund was not processed)
    assert store.get_account(account_id).is_pro is True

    # Second POST (duplicate_pending path): Invoice.retrieve succeeds → 200
    r2 = client.post(
        "/v1/stripe/webhook", content=b"{}",
        headers={"stripe-signature": "sig", "Content-Type": "application/json"},
    )
    assert r2.status_code == 200
    assert r2.json().get("duplicate") is not True

    # Access must now be revoked and purchase terminal
    assert store.get_account(account_id).is_pro is False, \
        "refund must revoke access on successful retry"
    purchase = store.get_stripe_purchase("sub_apiexc_1")
    assert purchase["lifecycle_state"] == "refunded"

    assert call_count[0] == 2, "Invoice.retrieve must be called exactly twice (fail then succeed)"
