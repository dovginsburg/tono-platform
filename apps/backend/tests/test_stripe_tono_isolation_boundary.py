"""Tono-only Stripe isolation + fail-closed boundary (Dov/Ezra binding architecture).

Encodes the per-PRODUCT Stripe isolation decision for Tono:

  * Tono uses ONE dedicated Stripe account for authenticated web Checkout/Portal.
    iOS = StoreKit, Android = Play Billing, RevenueCat reconciles store facts to
    the canonical Tono account UUID — so there is deliberately no per-surface
    Stripe account and no code path that grants Tono Pro from a foreign customer.

  * Until the exact Tono Stripe account/keys/prices/webhook are wired, the
    runtime MUST stay fail-closed: /v1/checkout and /v1/stripe/webhook answer 503
    "not configured" rather than half-processing or faking success.

  * A verified webhook event that does NOT resolve to a KNOWN Tono account (a
    sibling product's customer/subscription, or any tono_account_id absent from
    this DB) must grant NOTHING to any Tono account. Cross-product reuse of
    customers/catalog/subscribers is the exact thing this boundary forbids.

These invariants were previously under-tested: every prior Stripe test SET the
keys first (so the unconfigured path was never asserted), and the cross-account
test only covered two REAL Tono accounts — not a foreign/sibling customer that
maps to no Tono account at all.
"""

from __future__ import annotations

import uuid

import pytest


# ---------------------------------------------------------------------------
# Helpers (kept local so this boundary file does not depend on another test
# module's private helpers).
# ---------------------------------------------------------------------------


def _register(client) -> dict:
    r = client.post("/v1/register", json={})
    assert r.status_code == 200, r.text
    return r.json()


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _configure_stripe(monkeypatch) -> None:
    """Wire a fake-but-present Tono Stripe config so the webhook passes the
    503 gate and we can exercise the account-resolution isolation logic."""
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_fake_tono")
    monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", "whsec_fake_tono")
    monkeypatch.setenv("STRIPE_PRICE_PRO_MONTHLY", "price_fake_tono_month")


def _post_webhook(client, monkeypatch, payments_mod, event_id, etype, obj_data,
                  sub_retrieve=None):
    event = {"id": event_id, "type": etype, "data": {"object": obj_data}}
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


_FUTURE_PERIOD_END = 4102444800  # 2100-01-01


def _sub_obj(sub_id, customer_id, status="active",
             period_end=_FUTURE_PERIOD_END, account_id=None):
    metadata = {}
    if account_id:
        metadata["tono_account_id"] = account_id
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
# Fail-closed: missing Tono Stripe config must never half-open.
# ---------------------------------------------------------------------------


def test_checkout_is_fail_closed_when_tono_stripe_unconfigured(client):
    """No STRIPE_SECRET_KEY (the default in this suite) → /v1/checkout returns 503,
    not a partial session. Keeps the web purchase path closed until the dedicated
    Tono Stripe account is wired."""
    device = _register(client)
    r = client.post("/v1/checkout", json={"interval": "month"}, headers=_auth(device["api_token"]))
    assert r.status_code == 503, r.text
    assert "not configured" in r.text.lower()


def test_webhook_is_fail_closed_when_tono_stripe_unconfigured(client):
    """No STRIPE_WEBHOOK_SECRET → /v1/stripe/webhook returns 503 BEFORE any
    signature check or DB write. A missing webhook secret can never be treated
    as a silently-accepted event."""
    r = client.post(
        "/v1/stripe/webhook",
        content=b"{}",
        headers={"stripe-signature": "sig_fake", "Content-Type": "application/json"},
    )
    assert r.status_code == 503, r.text
    assert "not configured" in r.text.lower()


# ---------------------------------------------------------------------------
# Per-product isolation: a foreign/sibling event grants nothing to Tono.
# ---------------------------------------------------------------------------


def test_foreign_stripe_event_grants_no_tono_account(client, monkeypatch):
    """A verified subscription event carrying a tono_account_id that is NOT in
    this DB and a customer bound to NO Tono account (i.e. a sibling product's
    customer, or noise) must not make any Tono account Pro.

    This is the per-product isolation guarantee: Tono Pro is granted only when
    the event resolves to a KNOWN canonical Tono account. Cross-product customer
    reuse cannot leak an entitlement across the boundary.
    """
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    import backend.payments as payments_mod

    # A real Tono account exists and is free.
    device = _register(client)
    store = get_store()
    real_account_id = device["account_id"]
    assert store.get_account(real_account_id).is_pro is False

    foreign_account_id = str(uuid.uuid4())  # never created in this DB
    assert store.get_account(foreign_account_id) is None

    resp = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_foreign_sibling", "customer.subscription.created",
        _sub_obj("sub_foreign", "cus_sibling_product", "active",
                 account_id=foreign_account_id),
        sub_retrieve=_fake_sub_retrieve("active"),
    )
    # The webhook still ACKs (2xx) — Stripe must not be told to retry forever —
    # but no Tono account may have been granted Pro.
    assert resp.status_code == 200, resp.text

    # The real Tono account is untouched, and the foreign id never became a
    # (Pro) account.
    assert store.get_account(real_account_id).is_pro is False
    assert store.get_account(foreign_account_id) is None


def test_checkout_binds_canonical_tono_account_metadata(client, monkeypatch):
    """Checkout must stamp the canonical Tono account UUID into Stripe metadata
    (tono_account_id) so every downstream event is attributable to a Tono
    account — the account-binding authority that makes isolation enforceable.

    We intercept Stripe at the SDK boundary (no network, no object mutation) and
    assert the metadata namespace rather than creating anything in Stripe.
    """
    _configure_stripe(monkeypatch)
    import backend.payments as payments_mod

    captured = {}

    def _fake_session_create(**kwargs):
        captured.update(kwargs)
        return {"id": "cs_test_fake", "url": "https://checkout.stripe.com/c/fake"}

    # No customer yet → the handler also creates a Customer; stub it too.
    def _fake_customer_create(**kwargs):
        captured.setdefault("_customer_metadata", kwargs.get("metadata"))
        return {"id": "cus_fake_tono"}

    monkeypatch.setattr(payments_mod.stripe.checkout.Session, "create", _fake_session_create)
    monkeypatch.setattr(payments_mod.stripe.Customer, "create", _fake_customer_create)

    device = _register(client)
    r = client.post("/v1/checkout", json={"interval": "month"}, headers=_auth(device["api_token"]))
    assert r.status_code == 200, r.text

    md = captured.get("metadata") or {}
    assert md.get("tono_account_id") == device["account_id"], captured
    assert md.get("tono_source") == "app"
    # Customer (if minted) is also stamped with the canonical account id.
    cust_md = captured.get("_customer_metadata")
    if cust_md is not None:
        assert cust_md.get("tono_account_id") == device["account_id"]
