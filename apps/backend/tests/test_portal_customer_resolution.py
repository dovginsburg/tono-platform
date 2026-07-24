"""One customer-resolution order for BOTH /v1/checkout and /v1/portal.

The two endpoints resolved the Stripe customer differently:

    checkout: get_stripe_customer_binding(account_id)
              or account.stripe_customer_id
              or user.stripe_customer_id
    portal:   account.stripe_customer_id if identified else user.stripe_customer_id

``stripe_customer_bindings`` is the authoritative table (``_bind_customer_tx``
writes it first, then COALESCEs onto ``accounts``), and NOTHING in the current
code path ever writes ``users.stripe_customer_id`` — ``update_subscription``
sets plan/status/renews_at only, and ``attach_stripe_customer`` delegates to the
account. So the portal's non-identified branch read a column that is always NULL.

Consequence: an ANONYMOUS canonical account (contract §1 gives every device one;
``is_identified`` is False until the person signs in) could complete Stripe
checkout and hold a live subscription, then get
``400 "No Stripe customer on file. Start checkout first."`` from /v1/portal —
i.e. a paying customer with no self-serve way to update their card or cancel.
iOS reaches both endpoints directly (apps/ios/Shared/TonoBackend.swift), so this
is reachable, not theoretical.

These tests pin the two endpoints to the SAME resolution helper.
"""

from __future__ import annotations

import pytest


def _register(client) -> dict:
    r = client.post("/v1/register", json={"platform": "ios", "app_version": "0.2.0"})
    assert r.status_code == 200, r.text
    return r.json()


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _configure_stripe(monkeypatch):
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_fake")
    monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", "whsec_fake")
    monkeypatch.setenv("STRIPE_PRICE_PRO_MONTHLY", "price_fake_month")


class _FakeCustomer(dict):
    pass


def _stub_stripe(monkeypatch):
    """Stub Customer.create / checkout.Session.create / billing_portal.Session.create.
    Returns the dict that captures the portal call's kwargs."""
    import backend.payments as payments_mod

    captured: dict = {}

    def fake_customer_create(metadata=None, **kwargs):
        return _FakeCustomer(id="cus_anon_1")

    def fake_session_create(**kwargs):
        return {"url": "https://checkout.stripe.test/s", "id": "cs_anon_1"}

    def fake_portal_create(**kwargs):
        captured.update(kwargs)
        return {"url": "https://billing.stripe.test/portal"}

    monkeypatch.setattr(payments_mod.stripe.Customer, "create", fake_customer_create)
    monkeypatch.setattr(payments_mod.stripe.checkout.Session, "create", fake_session_create)
    monkeypatch.setattr(
        payments_mod.stripe.billing_portal.Session, "create", fake_portal_create
    )
    return captured


def test_anonymous_account_can_open_the_portal_after_checkout(client, monkeypatch):
    """The regression: check out on an anonymous auto-account, then open the
    portal. Before the fix this returned 400 'No Stripe customer on file'."""
    _configure_stripe(monkeypatch)
    captured = _stub_stripe(monkeypatch)
    device = _register(client)

    from backend.store import get_store

    user = get_store().get_by_device(device["device_id"])
    assert user.account is not None
    assert not user.account.is_identified, "this device must still be anonymous"

    checkout = client.post(
        "/v1/checkout", json={"interval": "month"}, headers=_auth(device["api_token"])
    )
    assert checkout.status_code == 200, checkout.text

    portal = client.post("/v1/portal", headers=_auth(device["api_token"]))
    assert portal.status_code == 200, (
        "an anonymous account that completed checkout cannot reach the billing "
        f"portal to cancel: {portal.text}"
    )
    assert captured["customer"] == "cus_anon_1"


def test_portal_reads_the_authoritative_binding_table(client, monkeypatch):
    """``stripe_customer_bindings`` is authoritative. If it holds a customer,
    the portal must use it — not fall through to a stale/NULL column."""
    _configure_stripe(monkeypatch)
    captured = _stub_stripe(monkeypatch)
    device = _register(client)

    from backend.store import get_store

    store = get_store()
    user = store.get_by_device(device["device_id"])
    assert store.attach_account_stripe_customer(user.account_id, "cus_bound_only")

    # Simulate a legacy row whose mutable column never caught up.
    store._conn.execute(
        "UPDATE accounts SET stripe_customer_id = NULL WHERE id = ?", (user.account_id,)
    )

    r = client.post("/v1/portal", headers=_auth(device["api_token"]))
    assert r.status_code == 200, r.text
    assert captured["customer"] == "cus_bound_only"


def test_portal_still_refuses_when_there_is_genuinely_no_customer(client, monkeypatch):
    """Fail-closed behaviour is preserved: a device that never checked out has
    nothing to manage and still gets the honest 400."""
    _configure_stripe(monkeypatch)
    _stub_stripe(monkeypatch)
    device = _register(client)

    r = client.post("/v1/portal", headers=_auth(device["api_token"]))
    assert r.status_code == 400
    assert "No Stripe customer on file" in r.text


def test_checkout_and_portal_share_one_resolution_helper():
    """Structural guard against the two endpoints drifting apart again."""
    import inspect

    import backend.payments as payments_mod

    checkout_src = inspect.getsource(payments_mod.create_checkout_session)
    portal_src = inspect.getsource(payments_mod.create_portal_session)
    for name, src in (("checkout", checkout_src), ("portal", portal_src)):
        assert "_resolve_stripe_customer(" in src, (
            f"{name} must resolve the Stripe customer through the shared helper"
        )
    # And neither may hand-roll the old precedence inline.
    for name, src in (("checkout", checkout_src), ("portal", portal_src)):
        assert "user.stripe_customer_id" not in src, (
            f"{name} reads the legacy users.stripe_customer_id column directly; "
            "that column is never written by any current path"
        )


def test_resolution_order_prefers_binding_then_account_then_legacy_column(client):
    """Unit-level pin on the single resolution order."""
    from backend.payments import _resolve_stripe_customer
    from backend.store import get_store

    store = get_store()
    device = store.register_device().user
    reloaded = store.get_by_device(device.device_id)
    assert _resolve_stripe_customer(store, reloaded) is None

    assert store.attach_account_stripe_customer(reloaded.account_id, "cus_binding")
    reloaded = store.get_by_device(device.device_id)
    assert _resolve_stripe_customer(store, reloaded) == "cus_binding"
