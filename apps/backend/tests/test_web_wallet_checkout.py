"""Unified web checkout: card + Apple Pay + Google Pay via Stripe.

Owner directive (2026-07-25): every Amazed Labs product website offers one web
checkout where eligible buyers can pay by card, Apple Pay, or Google Pay.

The distinctions these tests exist to keep true:

  * Apple Pay on the WEB is a **Stripe wallet** on the hosted Checkout page.
    It is NOT StoreKit. It settles through Stripe and arrives on the same
    webhooks as a card.
  * Google Pay on the WEB is a **Stripe wallet**. It is NOT Google Play
    Billing. Play Billing is Android-native and must never be offered or
    labelled as a website payment method.
  * Both wallets are card-backed, so an ineligible browser/device falls back to
    the card form. There is no separate wallet code path to break.
  * iOS StoreKit and Android Play Billing stay separate native purchase
    sources that converge on the ONE server-authoritative entitlement.

Wallet *rendering* is Stripe's, on Stripe's domain — untestable from here. What
IS testable, and what these tests pin, is the code path that decides which
payment methods Stripe is allowed to offer, and that a wallet purchase is
indistinguishable from a card purchase everywhere downstream.
"""

from __future__ import annotations

import json

import pytest


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _register(client) -> dict:
    r = client.post("/v1/register", json={"platform": "web", "app_version": "0.2.0"})
    assert r.status_code == 200, r.text
    return r.json()


def _configure_stripe(monkeypatch):
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_fake")
    monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", "whsec_fake")
    monkeypatch.setenv("STRIPE_PRICE_PRO_MONTHLY", "price_fake_month")
    monkeypatch.setenv("STRIPE_PRICE_PRO_YEARLY", "price_fake_year")


class _FakeCustomer(dict):
    pass


@pytest.fixture
def stripe_capture(monkeypatch):
    """Capture the exact kwargs handed to stripe.checkout.Session.create."""
    import backend.payments as payments_mod

    captured: dict = {}

    def fake_customer_create(metadata=None, **kwargs):
        return _FakeCustomer(id="cus_wallet_1")

    def fake_session_create(**kwargs):
        captured.clear()
        captured.update(kwargs)
        return {"url": "https://checkout.stripe.com/c/pay/cs_wallet", "id": "cs_wallet_1"}

    monkeypatch.setattr(payments_mod.stripe.Customer, "create", fake_customer_create)
    monkeypatch.setattr(payments_mod.stripe.checkout.Session, "create", fake_session_create)
    return captured


def _checkout(client, token, interval="month"):
    return client.post("/v1/checkout", json={"interval": interval}, headers=_auth(token))


# --------------------------------------------------------------------------
# The code path that decides which payment methods Stripe may offer
# --------------------------------------------------------------------------


def test_checkout_uses_automatic_payment_methods_not_a_hardcoded_list(
    client, monkeypatch, stripe_capture
):
    """The session must NOT pin ``payment_method_types``.

    Pinning it opts the session out of Stripe's automatic payment methods and
    freezes the accepted set in code, so a wallet enabled in the dashboard can
    never reach the buyer. Omitting it lets Stripe apply the dashboard set and
    filter per request by currency/amount/country/browser eligibility.
    """
    _configure_stripe(monkeypatch)
    reg = _register(client)
    assert _checkout(client, reg["api_token"]).status_code == 200

    assert "payment_method_types" not in stripe_capture, (
        "checkout pins payment_method_types=%r, which disables automatic payment "
        "methods — Apple Pay / Google Pay enabled in the Stripe Dashboard would "
        "never be offered" % (stripe_capture.get("payment_method_types"),)
    )


def test_checkout_never_names_a_wallet_as_a_payment_method_type(
    client, monkeypatch, stripe_capture
):
    """``apple_pay`` / ``google_pay`` are not valid ``payment_method_types``
    values — they are wallets over ``card``. Passing them is a hard Stripe API
    error, so guard against a well-meaning 'fix' that adds them."""
    _configure_stripe(monkeypatch)
    reg = _register(client)
    assert _checkout(client, reg["api_token"]).status_code == 200

    blob = json.dumps(stripe_capture, default=str).lower()
    for bogus in ("apple_pay", "google_pay", "applepay", "googlepay"):
        assert f'"{bogus}"' not in blob, (
            f"{bogus} passed to Stripe as a payment method type; wallets are "
            "surfaced over card, never enumerated"
        )


def test_google_play_billing_is_never_a_web_payment_method(
    client, monkeypatch, stripe_capture
):
    """Play Billing is Android-native. It must never appear in a web checkout."""
    _configure_stripe(monkeypatch)
    reg = _register(client)
    assert _checkout(client, reg["api_token"]).status_code == 200

    blob = json.dumps(stripe_capture, default=str).lower()
    for forbidden in ("play_billing", "google_play", "googleplay", "storekit", "app_store"):
        assert forbidden not in blob, (
            f"{forbidden!r} leaked into the web Stripe checkout session; native "
            "store billing is not a website payment method"
        )


def test_web_checkout_is_stripe_hosted_so_wallets_need_no_domain_registration(
    client, monkeypatch, stripe_capture
):
    """The returned URL is Stripe-hosted. Apple Pay therefore works without
    registering tonoit.com as a payment method domain — that requirement only
    appears if the flow moves to an embedded Element on our own origin."""
    _configure_stripe(monkeypatch)
    reg = _register(client)
    r = _checkout(client, reg["api_token"])
    assert r.status_code == 200
    url = r.json()["url"]
    assert url.startswith("https://"), "checkout must be HTTPS — wallets require a secure context"
    assert "checkout.stripe.com" in url, (
        "expected Stripe-hosted Checkout; an embedded Element on our origin would "
        "additionally require Apple Pay domain registration"
    )


@pytest.mark.parametrize("interval", ["month", "year"])
def test_both_intervals_offer_the_same_unified_method_set(
    client, monkeypatch, stripe_capture, interval
):
    _configure_stripe(monkeypatch)
    reg = _register(client)
    assert _checkout(client, reg["api_token"], interval).status_code == 200
    assert "payment_method_types" not in stripe_capture
    assert stripe_capture["mode"] == "subscription"


# --------------------------------------------------------------------------
# A wallet purchase must be indistinguishable downstream
# --------------------------------------------------------------------------


def test_trial_is_requested_once_regardless_of_payment_method(
    client, monkeypatch, stripe_capture
):
    """The 14-day trial is attached to the subscription, not to a payment
    method, so a wallet buyer gets exactly one trial — never a second."""
    from backend import catalog

    _configure_stripe(monkeypatch)
    reg = _register(client)
    assert _checkout(client, reg["api_token"]).status_code == 200

    sub_data = stripe_capture["subscription_data"]
    assert sub_data["trial_period_days"] == catalog.trial_days() == 14

    # A second checkout on the same account must NOT request another trial.
    stripe_capture.clear()
    assert _checkout(client, reg["api_token"]).status_code == 200
    assert "trial_period_days" not in stripe_capture.get("subscription_data", {}), (
        "a second checkout re-requested a trial — one lifetime Stripe trial only"
    )


def test_wallet_purchase_binds_to_the_authenticated_account(
    client, monkeypatch, stripe_capture
):
    """However the buyer pays, the session carries the canonical account id, so
    the webhook can always attach the subscription to a person."""
    _configure_stripe(monkeypatch)
    reg = _register(client)
    assert _checkout(client, reg["api_token"]).status_code == 200

    assert stripe_capture["metadata"]["tono_account_id"] == reg["account_id"]
    assert stripe_capture["subscription_data"]["metadata"]["tono_account_id"] == reg["account_id"]
    assert stripe_capture["client_reference_id"] == reg["device_id"]


def test_anonymous_web_checkout_is_refused_for_every_method(client, monkeypatch):
    """No wallet convenience may create an unbound purchase."""
    _configure_stripe(monkeypatch)
    r = client.post("/v1/checkout", json={"interval": "month"})
    assert r.status_code == 401


def test_wallet_subscription_grants_the_same_entitlement_as_a_card(client, monkeypatch):
    """End-to-end: a subscription created by a wallet buyer is projected onto
    the ONE canonical entitlement exactly like a card purchase. The webhook
    payload is identical — Stripe does not distinguish the wallet downstream."""
    import backend.payments as payments_mod

    _configure_stripe(monkeypatch)
    monkeypatch.setattr(
        payments_mod.stripe.Webhook,
        "construct_event",
        lambda payload, sig, secret: json.loads(payload),
    )

    reg = _register(client)
    from backend.store import get_store

    store = get_store()
    user = store.get_by_device(reg["device_id"])
    assert store.attach_account_stripe_customer(user.account_id, "cus_wallet_e2e")
    assert not store.get_by_device(reg["device_id"]).is_pro

    event = {
        "id": "evt_wallet_1",
        "type": "customer.subscription.updated",
        "data": {
            "object": {
                "id": "sub_wallet_1",
                "status": "active",
                "customer": "cus_wallet_e2e",
                "current_period_end": 4102444800,
                # Wallet payments arrive as a card payment method — this is what
                # an Apple Pay / Google Pay subscription actually looks like.
                "items": {"data": [{"price": {"product": "prod_pro"}}]},
            }
        },
    }
    r = client.post(
        "/v1/stripe/webhook",
        content=json.dumps(event),
        headers={"stripe-signature": "ok", "content-type": "application/json"},
    )
    assert r.status_code == 200, r.text
    assert store.get_by_device(reg["device_id"]).is_pro, (
        "a wallet-funded subscription did not converge on the canonical entitlement"
    )


def test_wallet_subscription_revocation_removes_entitlement(client, monkeypatch):
    """Cancel/revoke works identically for a wallet purchase."""
    import backend.payments as payments_mod

    _configure_stripe(monkeypatch)
    monkeypatch.setattr(
        payments_mod.stripe.Webhook,
        "construct_event",
        lambda payload, sig, secret: json.loads(payload),
    )

    reg = _register(client)
    from backend.store import get_store

    store = get_store()
    user = store.get_by_device(reg["device_id"])
    store.attach_account_stripe_customer(user.account_id, "cus_wallet_rev")

    def send(event_id, status):
        return client.post(
            "/v1/stripe/webhook",
            content=json.dumps({
                "id": event_id,
                "type": "customer.subscription.updated",
                "data": {"object": {
                    "id": "sub_wallet_rev", "status": status,
                    "customer": "cus_wallet_rev", "current_period_end": 4102444800,
                    "items": {"data": [{"price": {"product": "prod_pro"}}]},
                }},
            }),
            headers={"stripe-signature": "ok", "content-type": "application/json"},
        )

    assert send("evt_w_a", "active").status_code == 200
    assert store.get_by_device(reg["device_id"]).is_pro
    assert send("evt_w_b", "canceled").status_code == 200
    assert not store.get_by_device(reg["device_id"]).is_pro, (
        "canceling a wallet-funded subscription left the entitlement active"
    )


# --------------------------------------------------------------------------
# Cross-provider convergence — native stores stay native
# --------------------------------------------------------------------------


def test_catalog_keeps_web_and_native_rails_distinct(client):
    """The commercial catalog must keep Stripe as the web channel and the two
    stores as native channels, all mapping to the ONE canonical entitlement."""
    from backend import catalog

    data = catalog.load_catalog()
    providers = data["providers"]
    assert providers["stripe"]["channel"] == "web"
    assert providers["app_store"]["channel"] == "ios"
    assert providers["google_play"]["channel"] == "android"

    assert catalog.canonical_entitlement_ids() == frozenset({"pro"}), (
        "there must be exactly one canonical entitlement"
    )

    # Every provider product maps to that single entitlement.
    for name in ("stripe", "app_store", "google_play"):
        for product in providers[name]["products"]:
            assert product["entitlement"] == "pro"


def test_health_reports_web_and_native_rails_independently(client):
    """Stripe (web) readiness is reported separately from the native store
    verifiers, so a configured web rail can never imply a configured store rail."""
    body = client.get("/health").json()
    for key in ("stripe_configured", "apple_configured", "google_play_configured"):
        assert key in body
        assert isinstance(body[key], bool)
