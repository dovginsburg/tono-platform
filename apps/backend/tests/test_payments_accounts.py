"""Account-level Stripe billing: checkout/portal use the signed-in
account's customer (not the device's), and the webhook updates the
account — covering every device linked to it — rather than just the
device that started checkout.

Stripe's own API is monkeypatched (Customer.create, checkout.Session.create,
billing_portal.Session.create, Webhook.construct_event) since this sandbox
has no network path to api.stripe.com and, more importantly, these tests
are about OUR metadata/routing logic, not Stripe's SDK.
"""

from __future__ import annotations

from urllib.parse import urlencode

import pytest


def _register(client) -> dict:
    r = client.post("/v1/register", json={})
    assert r.status_code == 200, r.text
    return r.json()


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _configure_stripe(monkeypatch):
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_fake")
    monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", "whsec_fake")
    monkeypatch.setenv("STRIPE_PRICE_PRO_MONTHLY", "price_fake_month")


def _sign_in_apple(client, app, device_token: str, sub: str) -> str:
    import backend.social_auth as social_auth

    async def fake_verifier(_token: str):
        return social_auth.IdentityClaims(sub=sub, email="person@example.com")

    app.dependency_overrides[social_auth.get_apple_verifier] = lambda: fake_verifier
    r = client.post(
        "/v1/auth/apple", json={"identity_token": "t"}, headers=_auth(device_token)
    )
    assert r.status_code == 200, r.text
    return r.json()["account_id"]


class _FakeCustomer(dict):
    pass


def test_checkout_uses_account_customer_when_signed_in(client, monkeypatch):
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="apple-billing-1")

    import backend.payments as payments_mod

    created_customers = []

    def fake_customer_create(metadata=None, **kwargs):
        created_customers.append(metadata)
        return _FakeCustomer(id="cus_fake_1")

    captured_session_kwargs = {}

    def fake_session_create(**kwargs):
        captured_session_kwargs.update(kwargs)
        return {"url": "https://checkout.stripe.test/session", "id": "cs_fake_1"}

    monkeypatch.setattr(payments_mod.stripe.Customer, "create", fake_customer_create)
    monkeypatch.setattr(payments_mod.stripe.checkout.Session, "create", fake_session_create)

    r = client.post(
        "/v1/checkout", json={"interval": "month"}, headers=_auth(device["api_token"])
    )
    assert r.status_code == 200, r.text

    # The new Stripe customer was tagged with the account, not just the device...
    assert created_customers[0]["tono_account_id"] == account_id
    # ...and the checkout session's metadata carries the account id too, so
    # the webhook can route the resulting subscription to the account.
    assert captured_session_kwargs["metadata"]["tono_account_id"] == account_id
    assert captured_session_kwargs["client_reference_id"] == device["device_id"]

    # The customer id landed on the ACCOUNT, not the device row.
    store = get_store()
    account = store.get_account(account_id)
    assert account.stripe_customer_id == "cus_fake_1"
    device_row = store.get_by_device(device["device_id"])
    assert device_row.stripe_customer_id is None


def test_checkout_bills_device_when_anonymous(client, monkeypatch):
    """Unchanged pre-accounts behavior: no sign-in, no account metadata."""
    from backend.server import app  # noqa: F401 — ensures app module (and backend.payments) is loaded
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device = _register(client)

    import backend.payments as payments_mod

    def fake_customer_create(metadata=None, **kwargs):
        return _FakeCustomer(id="cus_anon_1")

    captured = {}

    def fake_session_create(**kwargs):
        captured.update(kwargs)
        return {"url": "https://checkout.stripe.test/session", "id": "cs_anon_1"}

    monkeypatch.setattr(payments_mod.stripe.Customer, "create", fake_customer_create)
    monkeypatch.setattr(payments_mod.stripe.checkout.Session, "create", fake_session_create)

    r = client.post(
        "/v1/checkout", json={"interval": "month"}, headers=_auth(device["api_token"])
    )
    assert r.status_code == 200, r.text
    assert "tono_account_id" not in captured["metadata"]

    store = get_store()
    device_row = store.get_by_device(device["device_id"])
    assert device_row.stripe_customer_id == "cus_anon_1"


def test_portal_uses_account_customer_when_signed_in(client, monkeypatch):
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="apple-billing-2")

    store = get_store()
    store.attach_account_stripe_customer(account_id, "cus_portal_1")

    import backend.payments as payments_mod

    captured = {}

    def fake_portal_create(**kwargs):
        captured.update(kwargs)
        return {"url": "https://billing.stripe.test/portal"}

    monkeypatch.setattr(payments_mod.stripe.billing_portal.Session, "create", fake_portal_create)

    r = client.post("/v1/portal", headers=_auth(device["api_token"]))
    assert r.status_code == 200, r.text
    assert captured["customer"] == "cus_portal_1"


def test_webhook_checkout_completed_updates_account_and_all_its_devices(client, monkeypatch):
    """The actual point: buying Pro on device A (signed in) makes device B
    (signed into the same account) Pro too, purely via the webhook updating
    the account — no device-level write happens for a signed-in purchase."""
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)
    device_a = _register(client)
    account_id = _sign_in_apple(client, app, device_a["api_token"], sub="apple-billing-3")

    device_b = _register(client)
    _sign_in_apple(client, app, device_b["api_token"], sub="apple-billing-3")  # same identity -> same account

    import backend.payments as payments_mod

    fake_event = {
        "id": "evt_fake_1",
        "type": "checkout.session.completed",
        "data": {
            "object": {
                "client_reference_id": device_a["device_id"],
                "customer": "cus_webhook_1",
                "subscription": "sub_webhook_1",
                "metadata": {"tono_device_id": device_a["device_id"], "tono_account_id": account_id},
            }
        },
    }

    monkeypatch.setattr(
        payments_mod.stripe.Webhook, "construct_event", lambda *a, **k: fake_event
    )
    monkeypatch.setattr(
        payments_mod.stripe.Subscription,
        "retrieve",
        lambda _id: {"status": "active", "current_period_end": 4102444800},  # 2100-01-01
    )

    r = client.post(
        "/v1/stripe/webhook",
        content=b"{}",
        headers={"stripe-signature": "sig_fake", "Content-Type": "application/json"},
    )
    assert r.status_code == 200, r.text

    store = get_store()
    account = store.get_account(account_id)
    assert account.is_pro is True

    # Neither device's OWN plan column changed — both read Pro purely
    # through the linked account.
    for device in (device_a, device_b):
        device_row = store.get_by_device(device["device_id"])
        assert device_row.plan == "free"
        me = client.get("/v1/me", headers=_auth(device["api_token"])).json()
        assert me["is_pro"] is True
        assert "daily_limit" not in me
        assert "used_today" not in me
