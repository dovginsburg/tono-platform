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
    monkeypatch.setenv("STRIPE_PRICE_PRO_YEARLY", "price_fake_year")


@pytest.mark.parametrize("interval", ["month", "year"])
def test_checkout_requires_explicit_authorization_for_a_seven_day_trial(client, monkeypatch, interval):
    """Both exact-price products start the real trial inside Stripe Checkout."""
    from backend.server import app  # noqa: F401
    import backend.payments as payments_mod

    _configure_stripe(monkeypatch)
    user = _register(client)
    _sign_in_apple(client, app, user["api_token"], sub=f"apple-trial-{interval}")
    captured = {}

    monkeypatch.setattr(
        payments_mod.stripe.Customer,
        "create",
        lambda **kwargs: {"id": "cus_trial"},
    )

    monkeypatch.setattr(
        payments_mod.stripe.checkout.Session,
        "create",
        lambda **kwargs: captured.update(kwargs) or {"url": "https://checkout.stripe.test/trial", "id": "cs_trial"},
    )

    response = client.post("/v1/checkout", headers=_auth(user["api_token"]), json={"interval": interval})
    assert response.status_code == 200, response.text
    assert captured["mode"] == "subscription"
    assert captured["subscription_data"]["trial_period_days"] == 7
    assert captured["subscription_data"]["metadata"]["tono_source"] == "web"
    assert captured["customer"] == "cus_trial"
    assert captured["client_reference_id"] == user["device_id"]


@pytest.mark.parametrize(
    ("stripe_status", "expected_access"),
    [
        ("trialing", True),
        ("active", True),  # day-8 conversion
        ("past_due", False),
        ("canceled", False),
        ("incomplete", False),
        ("unknown_future_status", False),
    ],
)
def test_webhook_subscription_statuses_fail_closed(client, monkeypatch, stripe_status, expected_access):
    from backend.server import app  # noqa: F401
    from backend.store import get_store
    import backend.payments as payments_mod

    device = _register(client)
    payments_mod._handle_subscription_event(
        get_store(),
        "customer.subscription.updated",
        {
            "id": "sub_lifecycle",
            "customer": "cus_lifecycle",
            "status": stripe_status,
            "current_period_end": 1_800_000_000,
            "metadata": {"tono_device_id": device["device_id"]},
        },
    )

    me = client.get("/v1/me", headers=_auth(device["api_token"]))
    assert me.status_code == 200, me.text
    assert me.json()["subscription_status"] == stripe_status
    assert me.json()["is_pro"] is expected_access


def test_invoice_payment_failure_durably_sets_past_due(client):
    from backend.server import app  # noqa: F401
    from backend.store import get_store
    import backend.payments as payments_mod

    device = _register(client)
    payments_mod._handle_subscription_event(
        get_store(),
        "invoice.payment_failed",
        {
            "id": "in_failed",
            "customer": "cus_failed",
            "subscription": "sub_failed",
            "metadata": {"tono_device_id": device["device_id"]},
        },
    )
    me = client.get("/v1/me", headers=_auth(device["api_token"])).json()
    assert me["subscription_status"] == "past_due"
    assert me["is_pro"] is False


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


def test_checkout_rejects_unauthenticated_caller(client, monkeypatch):
    _configure_stripe(monkeypatch)
    response = client.post("/v1/checkout", json={"interval": "month"})
    assert response.status_code == 401


def test_checkout_rejects_authenticated_device_without_account(client, monkeypatch):
    _configure_stripe(monkeypatch)
    device = _register(client)
    response = client.post(
        "/v1/checkout", json={"interval": "month"}, headers=_auth(device["api_token"])
    )
    assert response.status_code == 403


def test_returning_stripe_customer_does_not_receive_a_second_trial(client, monkeypatch):
    from types import SimpleNamespace
    from backend.server import app
    from backend.store import get_store
    import backend.payments as payments_mod

    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="apple-returning")
    get_store().attach_account_stripe_customer(account_id, "cus_returning")
    monkeypatch.setattr(
        payments_mod.stripe.Subscription,
        "list",
        lambda **kwargs: SimpleNamespace(data=[{"id": "sub_previous"}]),
    )
    captured = {}
    monkeypatch.setattr(
        payments_mod.stripe.checkout.Session,
        "create",
        lambda **kwargs: captured.update(kwargs) or {"url": "https://checkout.stripe.test/returning", "id": "cs_returning"},
    )

    response = client.post(
        "/v1/checkout", json={"interval": "month"}, headers=_auth(device["api_token"])
    )
    assert response.status_code == 200, response.text
    assert response.json()["trial_eligible"] is False
    assert "trial_period_days" not in captured["subscription_data"]


def test_offer_uses_current_stripe_price_and_account_eligibility(client, monkeypatch):
    from types import SimpleNamespace
    from backend.server import app
    import backend.payments as payments_mod

    _configure_stripe(monkeypatch)
    device = _register(client)
    _sign_in_apple(client, app, device["api_token"], sub="apple-offer")
    monkeypatch.setattr(
        payments_mod.stripe.Price,
        "retrieve",
        lambda _id: SimpleNamespace(unit_amount=399, currency="usd"),
    )

    response = client.get("/v1/offer?interval=month", headers=_auth(device["api_token"]))
    assert response.status_code == 200, response.text
    assert response.json() == {
        "interval": "month",
        "currency": "usd",
        "unit_amount": 399,
        "trial_eligible": True,
        "trial_days": 7,
    }


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
        assert me["daily_limit"] == -1
