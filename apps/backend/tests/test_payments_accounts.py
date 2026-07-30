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

from concurrent.futures import ThreadPoolExecutor
import threading
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


def test_checkout_requests_exactly_the_catalog_trial(client, monkeypatch):
    """Stripe Checkout requests EXACTLY the canonical 14-day trial via
    subscription_data.trial_period_days — the single, code-backed trial source.
    No double-trial ambiguity: trial_end is never also set, and the value comes
    from the commercial catalog (the one source of truth)."""
    import backend.catalog as catalog
    from backend.server import app  # noqa: F401 — ensures payments router is loaded

    _configure_stripe(monkeypatch)
    device = _register(client)

    import backend.payments as payments_mod

    captured = {}

    def fake_customer_create(metadata=None, **kwargs):
        return _FakeCustomer(id="cus_fake_trial")

    def fake_session_create(**kwargs):
        captured.update(kwargs)
        return {"url": "https://checkout.stripe.test/session", "id": "cs_fake_trial"}

    monkeypatch.setattr(payments_mod.stripe.Customer, "create", fake_customer_create)
    monkeypatch.setattr(payments_mod.stripe.checkout.Session, "create", fake_session_create)

    r = client.post(
        "/v1/checkout", json={"interval": "month"}, headers=_auth(device["api_token"])
    )
    assert r.status_code == 200, r.text

    sub_data = captured["subscription_data"]
    assert sub_data["trial_period_days"] == 14
    assert sub_data["trial_period_days"] == catalog.trial_days()
    # Single trial source — no stacked/ambiguous second trial on the request.
    assert "trial_end" not in sub_data
    assert "trial_end" not in captured


def test_repeat_checkout_and_cancel_resubscribe_never_repeat_trial(client, monkeypatch):
    from backend.store import get_store
    import backend.payments as payments_mod

    _configure_stripe(monkeypatch)
    device = _register(client)
    captured = []
    monkeypatch.setattr(
        payments_mod.stripe.Customer,
        "create",
        lambda **_kwargs: _FakeCustomer(id="cus_repeat"),
    )
    monkeypatch.setattr(
        payments_mod.stripe.checkout.Session,
        "create",
        lambda **kwargs: captured.append(kwargs)
        or {"url": "https://checkout.stripe.test/session", "id": f"cs_{len(captured)}"},
    )

    for _ in range(2):
        r = client.post(
            "/v1/checkout", json={"interval": "month"}, headers=_auth(device["api_token"])
        )
        assert r.status_code == 200, r.text
    assert captured[0]["subscription_data"]["trial_period_days"] == 14
    assert "trial_period_days" not in captured[1]["subscription_data"]

    # Cancellation changes entitlement only; it must not touch trial history.
    get_store().update_subscription(
        device_id=device["device_id"],
        subscription_id="sub_old",
        status="canceled",
        renews_at=None,
    )
    r = client.post(
        "/v1/checkout", json={"interval": "month"}, headers=_auth(device["api_token"])
    )
    assert r.status_code == 200, r.text
    assert "trial_period_days" not in captured[2]["subscription_data"]


def test_simultaneous_checkout_only_one_gets_trial(client, monkeypatch):
    import backend.payments as payments_mod

    _configure_stripe(monkeypatch)
    device = _register(client)
    captured = []
    capture_lock = threading.Lock()
    monkeypatch.setattr(
        payments_mod.stripe.Customer,
        "create",
        lambda **_kwargs: _FakeCustomer(id="cus_concurrent"),
    )

    def fake_session_create(**kwargs):
        with capture_lock:
            captured.append(kwargs)
            number = len(captured)
        return {"url": "https://checkout.stripe.test/session", "id": f"cs_{number}"}

    monkeypatch.setattr(payments_mod.stripe.checkout.Session, "create", fake_session_create)

    def checkout(_):
        return client.post(
            "/v1/checkout", json={"interval": "month"}, headers=_auth(device["api_token"])
        )

    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(checkout, range(2)))
    assert [r.status_code for r in responses] == [200, 200]
    assert sum(
        kwargs["subscription_data"].get("trial_period_days") == 14 for kwargs in captured
    ) == 1


def test_customer_creation_race_uses_single_reachable_binding(client, monkeypatch):
    from backend.store import get_store
    import backend.payments as payments_mod
    _configure_stripe(monkeypatch)
    device = _register(client)
    created = []
    captured = []
    lock = threading.Lock()

    def create_customer(**_kwargs):
        with lock:
            customer_id = f"cus_race_{len(created) + 1}"
            created.append(customer_id)
        return _FakeCustomer(id=customer_id)

    monkeypatch.setattr(payments_mod.stripe.Customer, "create", create_customer)
    monkeypatch.setattr(
        payments_mod.stripe.checkout.Session, "create",
        lambda **kwargs: captured.append(kwargs)
        or {"url": "https://checkout.stripe.test/s", "id": f"cs_race_{len(captured)}"},
    )
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(
            lambda _: client.post("/v1/checkout", json={},
                                  headers=_auth(device["api_token"])), range(2)
        ))
    assert [r.status_code for r in responses] == [200, 200]
    account_id = get_store().get_by_device(device["device_id"]).account_id
    winner = get_store().get_stripe_customer_binding(account_id)
    assert winner in created
    assert {request["customer"] for request in captured} == {winner}
    assert sum("trial_period_days" in request["subscription_data"]
               for request in captured) == 1


def test_anonymous_history_merges_to_account_and_survives_new_device(
    client, monkeypatch
):
    from backend.server import app
    import backend.payments as payments_mod

    _configure_stripe(monkeypatch)
    first_device = _register(client)
    captured = []
    monkeypatch.setattr(
        payments_mod.stripe.Customer,
        "create",
        lambda **_kwargs: _FakeCustomer(id=f"cus_{len(captured)}"),
    )
    monkeypatch.setattr(
        payments_mod.stripe.checkout.Session,
        "create",
        lambda **kwargs: captured.append(kwargs)
        or {"url": "https://checkout.stripe.test/session", "id": f"cs_{len(captured)}"},
    )

    assert client.post(
        "/v1/checkout",
        json={"interval": "month"},
        headers=_auth(first_device["api_token"]),
    ).status_code == 200
    account_id = _sign_in_apple(
        client, app, first_device["api_token"], sub="apple-trial-merge"
    )

    # Simulate reinstall/new hardware: a fresh anonymous device signs into the
    # same account, whose canonical reservation must win.
    second_device = _register(client)
    assert (
        _sign_in_apple(
            client, app, second_device["api_token"], sub="apple-trial-merge"
        )
        == account_id
    )
    r = client.post(
        "/v1/checkout",
        json={"interval": "month"},
        headers=_auth(second_device["api_token"]),
    )
    assert r.status_code == 200, r.text
    assert captured[0]["subscription_data"]["trial_period_days"] == 14
    assert "trial_period_days" not in captured[1]["subscription_data"]


def test_stripe_creation_failure_retains_trial_reservation(client, monkeypatch):
    import backend.payments as payments_mod

    _configure_stripe(monkeypatch)
    device = _register(client)
    monkeypatch.setattr(
        payments_mod.stripe.Customer,
        "create",
        lambda **_kwargs: _FakeCustomer(id="cus_failure"),
    )

    def fail_session(**_kwargs):
        raise RuntimeError("ambiguous Stripe timeout")

    monkeypatch.setattr(payments_mod.stripe.checkout.Session, "create", fail_session)
    with pytest.raises(RuntimeError, match="ambiguous Stripe timeout"):
        client.post(
            "/v1/checkout", json={"interval": "month"}, headers=_auth(device["api_token"])
        )

    captured = {}
    monkeypatch.setattr(
        payments_mod.stripe.checkout.Session,
        "create",
        lambda **kwargs: captured.update(kwargs)
        or {"url": "https://checkout.stripe.test/session", "id": "cs_after_failure"},
    )
    r = client.post(
        "/v1/checkout", json={"interval": "month"}, headers=_auth(device["api_token"])
    )
    assert r.status_code == 200, r.text
    assert "trial_period_days" not in captured["subscription_data"]


def test_checkout_bills_canonical_account_when_anonymous(client, monkeypatch):
    """Anonymous installs still use their canonical account trial scope."""
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
    assert captured["metadata"]["tono_account_id"]

    store = get_store()
    device_row = store.get_by_device(device["device_id"])
    assert device_row.stripe_customer_id is None
    assert device_row.account.stripe_customer_id == "cus_anon_1"


@pytest.mark.parametrize("hostile", [
    "http://tonoit.com/pwn", "https://evil.example/pwn",
    "https://tonoit.com.evil.example/pwn", "javascript:alert(1)",
    "//evil.example/pwn",
])
def test_checkout_rejects_hostile_return_urls(client, monkeypatch, hostile):
    import backend.payments as payments_mod
    _configure_stripe(monkeypatch)
    monkeypatch.delenv("PUBLIC_BASE_URL", raising=False)
    device = _register(client)
    captured = {}
    monkeypatch.setattr(payments_mod.stripe.Customer, "create",
                        lambda **_k: _FakeCustomer(id="cus_redirect"))
    monkeypatch.setattr(
        payments_mod.stripe.checkout.Session, "create",
        lambda **kwargs: captured.update(kwargs)
        or {"url": "https://checkout.stripe.test/s", "id": "cs_redirect"},
    )
    response = client.post(
        "/v1/checkout", json={"success_url": hostile, "cancel_url": hostile},
        headers={**_auth(device["api_token"]), "host": "attacker.example"},
    )
    assert response.status_code == 200
    assert captured["success_url"] == "https://tonoit.com/welcome-pro?s=1"
    assert captured["cancel_url"] == "https://tonoit.com/pricing"


def test_checkout_expired_releases_only_unconsumed_reservation(client, monkeypatch):
    from backend.store import get_store
    import backend.payments as payments_mod
    _configure_stripe(monkeypatch)
    device = _register(client)
    monkeypatch.setattr(payments_mod.stripe.Customer, "create",
                        lambda **_k: _FakeCustomer(id="cus_expiry"))
    monkeypatch.setattr(
        payments_mod.stripe.checkout.Session, "create",
        lambda **_k: {"url": "https://checkout.stripe.test/s", "id": "cs_expiry"},
    )
    assert client.post("/v1/checkout", json={},
                       headers=_auth(device["api_token"])).status_code == 200
    store = get_store()
    payments_mod._handle_all_stripe_events(store, {
        "id": "evt_expiry", "type": "checkout.session.expired",
        "data": {"object": {"id": "cs_expiry"}},
    })
    rows = store._conn.execute(
        "SELECT state FROM stripe_trial_ledger WHERE session_id='cs_expiry'"
    ).fetchall()
    assert {row["state"] for row in rows} == {"released"}
    assert store.release_trial_session("cs_expiry") == 0


def test_checkout_completed_without_subscription_never_grants_pro(client, monkeypatch):
    from backend.store import get_store
    import backend.payments as payments_mod
    _configure_stripe(monkeypatch)
    device = _register(client)
    account_id = get_store().get_by_device(device["device_id"]).account_id
    event = {"id": "evt_no_sub", "type": "checkout.session.completed",
             "data": {"object": {"id": "cs_no_sub", "customer": "cus_no_sub",
             "client_reference_id": device["device_id"],
             "metadata": {"tono_account_id": account_id}}}}
    monkeypatch.setattr(payments_mod.stripe.Webhook, "construct_event",
                        lambda *_a, **_k: event)
    response = client.post("/v1/stripe/webhook", content=b"{}",
                           headers={"stripe-signature": "fake"})
    assert response.status_code == 200
    assert get_store().get_account(account_id).is_pro is False


def test_fingerprint_reuse_records_conflict_and_ends_duplicate_trial(client, monkeypatch):
    from backend.store import get_store
    import backend.payments as payments_mod
    _configure_stripe(monkeypatch)
    first, second = _register(client), _register(client)
    store = get_store()
    first_account = store.get_by_device(first["device_id"]).account_id
    second_account = store.get_by_device(second["device_id"]).account_id
    assert store.consume_stripe_trial(
        account_id=first_account, customer_id="cus_first",
        subscription_id="sub_first", fingerprint="fp_shared") is False
    modified = []
    monkeypatch.setattr(
        payments_mod.stripe.Subscription, "modify",
        lambda sub_id, **kwargs: modified.append((sub_id, kwargs)),
    )
    payments_mod._handle_subscription_event(
        store, "customer.subscription.created",
        {"id": "sub_second", "customer": "cus_second", "status": "trialing",
         "current_period_end": 4102444800, "trial_end": 4102444800,
         "default_payment_method": {"card": {"fingerprint": "fp_shared"}},
         "metadata": {"tono_account_id": second_account}},
    )
    assert modified == [("sub_second", {"trial_end": "now"})]
    row = store._conn.execute(
        "SELECT COUNT(*) c FROM stripe_trial_conflicts "
        "WHERE conflict_kind='trial_scope_reuse'").fetchone()
    assert row["c"] == 1


def test_backfill_is_idempotent_and_includes_tombstone_and_provider_purchase(
    client,
):
    from backend.store import get_store
    import datetime as dt
    import uuid

    store = get_store()
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    tombstone = str(uuid.uuid4())
    purchase_account = str(uuid.uuid4())
    store._conn.execute(
        """INSERT INTO accounts
           (id, plan, stripe_customer_id, subscription_status, deleted_at,
            created_at, updated_at)
           VALUES (?, 'free', 'cus_tombstone', 'canceled', ?, ?, ?)""",
        (tombstone, tombstone, now, now),
    )
    store._conn.execute(
        "INSERT INTO accounts (id, plan, created_at, updated_at) VALUES (?, 'free', ?, ?)",
        (purchase_account, now, now),
    )
    store._conn.execute(
        """INSERT INTO provider_purchases
           (id, provider, original_transaction_id, product_id, environment,
            ownership_type, app_account_token, lifecycle_state, created_at, updated_at)
           VALUES (?, 'stripe', 'cus_purchase', 'stripe_pro', 'production',
                   'PURCHASED', ?, 'expired', ?, ?)""",
        (str(uuid.uuid4()), purchase_account, now, now),
    )
    store.backfill_stripe_trial_ledger()
    before = store._conn.execute(
        "SELECT scope, scope_id, state FROM stripe_trial_ledger ORDER BY scope, scope_id"
    ).fetchall()
    store.backfill_stripe_trial_ledger()
    after = store._conn.execute(
        "SELECT scope, scope_id, state FROM stripe_trial_ledger ORDER BY scope, scope_id"
    ).fetchall()
    assert [tuple(row) for row in before] == [tuple(row) for row in after]
    assert ("account", tombstone, "consumed") in [tuple(row) for row in after]
    assert ("account", purchase_account, "consumed") in [tuple(row) for row in after]
    assert ("customer", "cus_tombstone", "consumed") in [tuple(row) for row in after]


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
    other = _register(client)

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
    assert client.get("/v1/me", headers=_auth(other["api_token"])).json()["is_pro"] is False
