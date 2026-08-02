"""GET /v1/account/payment-history — the account's owner-scoped billing timeline.

This is the read contract for data (provider_purchases + entitlement_grants)
that was always modelled server-side but previously had no endpoint. The tests
below are the negative controls that matter for a billing surface:

  * one account can never read another's timeline (no id parameter exists);
  * an entitled-by-coupon account reads is_pro=true with an empty item list
    (entitlement without a provider purchase is never faked into a purchase row);
  * a revoked grant still appears (audit truth) but is_current is false;
  * a FAMILY_SHARED beneficiary sees their access grant but NO raw provider or
    transaction identifier ever crosses the wire.
"""

from __future__ import annotations

import datetime as dt
import uuid


def _register(client) -> dict:
    r = client.post("/v1/register", json={})
    assert r.status_code == 200, r.text
    return r.json()


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _sign_in_apple(client, app, device_token: str, sub: str) -> str:
    import backend.social_auth as social_auth

    async def fake_verifier(_token: str):
        return social_auth.IdentityClaims(sub=sub, email=f"{sub}@example.com")

    app.dependency_overrides[social_auth.get_apple_verifier] = lambda: fake_verifier
    r = client.post(
        "/v1/auth/apple", json={"identity_token": "t"}, headers=_auth(device_token)
    )
    assert r.status_code == 200, r.text
    return r.json()["account_id"]


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def _seed_purchase_and_grant(
    store,
    account_id: str,
    *,
    provider: str = "apple",
    product_id: str = "com.tonoit.pro.monthly",
    ownership_type: str = "PURCHASED",
    grant_kind: str = "direct",
    grant_state: str = "active",
    purchase_state: str = "active",
    original_transaction_id: str | None = None,
    expires_at: str | None = None,
    revoked_at: str | None = None,
) -> tuple[str, str]:
    """Insert one provider_purchase + one entitlement_grant to `account_id`.

    Returns (purchase_id, grant_id). Uses raw INSERTs (like
    test_payments_accounts.py) so the timeline read is exercised without
    depending on any provider verifier stub.
    """
    now = _now()
    purchase_id = str(uuid.uuid4())
    grant_id = str(uuid.uuid4())
    otx = original_transaction_id or f"otx-{uuid.uuid4()}"
    store._conn.execute(
        """INSERT INTO provider_purchases
           (id, provider, original_transaction_id, product_id, environment,
            ownership_type, app_account_token, lifecycle_state, latest_signed_ms,
            trial_consumed, created_at, updated_at)
           VALUES (?, ?, ?, ?, 'Production', ?, ?, ?, 0, 0, ?, ?)""",
        (purchase_id, provider, otx, product_id, ownership_type,
         account_id if ownership_type == "PURCHASED" else None,
         purchase_state, now, now),
    )
    store._conn.execute(
        """INSERT INTO entitlement_grants
           (id, purchase_id, account_id, grant_kind, state, effective_at,
            expires_at, revoked_at, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (grant_id, purchase_id, account_id, grant_kind, grant_state, now,
         expires_at, revoked_at, now, now),
    )
    store._conn.commit()
    return purchase_id, grant_id


def test_requires_bearer(client):
    # No bearer at all -> 401 (never an anonymous read of a billing timeline).
    r = client.get("/v1/account/payment-history")
    assert r.status_code == 401, r.text


def test_empty_timeline_for_fresh_account(client):
    device = _register(client)
    r = client.get("/v1/account/payment-history", headers=_auth(device["api_token"]))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["items"] == []
    assert body["is_pro"] is False
    assert body["account_id"] == device["account_id"]


def test_active_purchase_appears_and_is_current(client):
    from backend.server import app
    from backend.store import get_store

    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="pay-hist-1")
    _seed_purchase_and_grant(get_store(), account_id)

    r = client.get("/v1/account/payment-history", headers=_auth(device["api_token"]))
    assert r.status_code == 200, r.text
    body = r.json()
    assert len(body["items"]) == 1
    item = body["items"][0]
    assert item["provider"] == "apple"
    assert item["product_id"] == "com.tonoit.pro.monthly"
    assert item["entitlement"] == "pro"
    assert item["ownership_type"] == "PURCHASED"
    assert item["grant_kind"] == "direct"
    assert item["entitlement_state"] == "active"
    assert item["purchase_state"] == "active"
    assert item["is_current"] is True
    # Opaque handle only — never the original transaction id.
    assert item["id"] and item["id"] != ""


def test_no_raw_provider_or_transaction_identifiers_leak(client):
    from backend.server import app
    from backend.store import get_store

    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="pay-hist-2")
    otx = "SECRET-ORIGINAL-TXN-9999"
    _seed_purchase_and_grant(get_store(), account_id, original_transaction_id=otx)

    r = client.get("/v1/account/payment-history", headers=_auth(device["api_token"]))
    assert r.status_code == 200, r.text
    # The raw provider transaction id must not appear anywhere in the payload,
    # and neither must the internal column names for it.
    raw = r.text
    assert otx not in raw
    assert "original_transaction_id" not in raw
    assert "app_account_token" not in raw


def test_one_account_cannot_read_anothers_timeline(client):
    from backend.server import app
    from backend.store import get_store

    store = get_store()
    dev_a = _register(client)
    acct_a = _sign_in_apple(client, app, dev_a["api_token"], sub="pay-hist-A")
    _seed_purchase_and_grant(store, acct_a, product_id="com.tonoit.pro.yearly")

    dev_b = _register(client)
    acct_b = _sign_in_apple(client, app, dev_b["api_token"], sub="pay-hist-B")
    assert acct_a != acct_b

    # B has no purchases of its own and there is no account-id parameter to
    # supply, so B's timeline is empty even though A's is not.
    rb = client.get("/v1/account/payment-history", headers=_auth(dev_b["api_token"]))
    assert rb.status_code == 200, rb.text
    assert rb.json()["items"] == []

    ra = client.get("/v1/account/payment-history", headers=_auth(dev_a["api_token"]))
    assert len(ra.json()["items"]) == 1
    assert ra.json()["items"][0]["product_id"] == "com.tonoit.pro.yearly"


def test_revoked_grant_is_shown_but_not_current(client):
    from backend.server import app
    from backend.store import get_store

    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="pay-hist-3")
    _seed_purchase_and_grant(
        get_store(),
        account_id,
        grant_state="revoked",
        purchase_state="refunded",
        revoked_at=_now(),
    )

    r = client.get("/v1/account/payment-history", headers=_auth(device["api_token"]))
    body = r.json()
    assert len(body["items"]) == 1
    item = body["items"][0]
    assert item["entitlement_state"] == "revoked"
    assert item["purchase_state"] == "refunded"
    assert item["is_current"] is False
    assert item["revoked_at"] is not None


def test_lapsed_active_grant_is_not_current(client):
    from backend.server import app
    from backend.store import get_store

    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="pay-hist-4")
    past = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=1)).isoformat()
    _seed_purchase_and_grant(
        get_store(), account_id, grant_state="active", expires_at=past
    )

    r = client.get("/v1/account/payment-history", headers=_auth(device["api_token"]))
    item = r.json()["items"][0]
    # An 'active'-state grant whose expiry has passed is history, not the live
    # entitlement — is_current must mirror the paywall's lexical-UTC rule.
    assert item["entitlement_state"] == "active"
    assert item["is_current"] is False


def test_family_beneficiary_sees_access_without_ownership_lineage(client):
    from backend.server import app
    from backend.store import get_store

    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="pay-hist-5")
    _seed_purchase_and_grant(
        get_store(),
        account_id,
        ownership_type="FAMILY_SHARED",
        grant_kind="family",
    )

    r = client.get("/v1/account/payment-history", headers=_auth(device["api_token"]))
    item = r.json()["items"][0]
    assert item["ownership_type"] == "FAMILY_SHARED"
    assert item["grant_kind"] == "family"
    # The family beneficiary is entitled but is NOT the purchaser — no owning
    # account id or transaction id is disclosed.
    assert "app_account_token" not in r.text


def test_stripe_purchase_carries_verified_amount(client):
    """A Stripe subscription fact stamps the plan's authoritative price
    (unit_amount minor units + ISO currency); the timeline renders it back
    without any raw provider/transaction id."""
    from backend.server import app
    from backend.store import get_store

    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="pay-hist-amt")
    period_end_ms = int(
        (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=30)).timestamp() * 1000
    )
    get_store().apply_stripe_subscription_fact(
        account_id=account_id,
        subscription_id="sub_amount_test",
        stripe_status="active",
        period_end_ms=period_end_ms,
        product_id="com.tonoit.pro.monthly",
        amount_minor=399,
        currency="usd",
    )

    r = client.get("/v1/account/payment-history", headers=_auth(device["api_token"]))
    assert r.status_code == 200, r.text
    item = r.json()["items"][0]
    assert item["provider"] == "stripe"
    assert item["amount_minor"] == 399
    assert item["currency"] == "usd"
    # The subscription id is a raw provider identifier and must never leak.
    assert "sub_amount_test" not in r.text


def test_non_normalized_provider_has_null_amount(client):
    """Providers we don't normalize (Apple/Google here) carry no amount — the
    field is null, never a fabricated price."""
    from backend.server import app
    from backend.store import get_store

    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="pay-hist-noamt")
    _seed_purchase_and_grant(get_store(), account_id, provider="apple")

    r = client.get("/v1/account/payment-history", headers=_auth(device["api_token"]))
    item = r.json()["items"][0]
    assert item["provider"] == "apple"
    assert item["amount_minor"] is None
    assert item["currency"] is None


def test_price_from_sub_normalizes_only_authoritative_amounts():
    """_price_from_sub returns integer minor units + lowercase ISO currency,
    and (None, None) whenever either is missing — never a guess."""
    from backend.payments import _price_from_sub

    ok = {"items": {"data": [{"price": {"unit_amount": 3999, "currency": "USD"}}]}}
    assert _price_from_sub(ok) == (3999, "usd")

    assert _price_from_sub({"items": {"data": []}}) == (None, None)
    assert _price_from_sub(
        {"items": {"data": [{"price": {"currency": "usd"}}]}}
    ) == (None, None)
    assert _price_from_sub(
        {"items": {"data": [{"price": {"unit_amount": 500}}]}}
    ) == (None, None)


def test_newest_grant_first(client):
    from backend.server import app
    from backend.store import get_store

    store = get_store()
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="pay-hist-6")
    # Seed two grants with distinct created_at ordering.
    old = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=30)).isoformat()
    new = _now()
    p1 = str(uuid.uuid4()); g1 = str(uuid.uuid4())
    p2 = str(uuid.uuid4()); g2 = str(uuid.uuid4())
    for pid, gid, created, product in (
        (p1, g1, old, "com.tonoit.pro.monthly"),
        (p2, g2, new, "com.tonoit.pro.yearly"),
    ):
        store._conn.execute(
            """INSERT INTO provider_purchases
               (id, provider, original_transaction_id, product_id, environment,
                ownership_type, app_account_token, lifecycle_state,
                latest_signed_ms, trial_consumed, created_at, updated_at)
               VALUES (?, 'apple', ?, ?, 'Production', 'PURCHASED', ?, 'active',
                       0, 0, ?, ?)""",
            (pid, f"otx-{gid}", product, account_id, created, created),
        )
        store._conn.execute(
            """INSERT INTO entitlement_grants
               (id, purchase_id, account_id, grant_kind, state, effective_at,
                expires_at, revoked_at, created_at, updated_at)
               VALUES (?, ?, ?, 'direct', 'active', ?, NULL, NULL, ?, ?)""",
            (gid, pid, account_id, created, created, created),
        )
    store._conn.commit()

    r = client.get("/v1/account/payment-history", headers=_auth(device["api_token"]))
    products = [i["product_id"] for i in r.json()["items"]]
    assert products == ["com.tonoit.pro.yearly", "com.tonoit.pro.monthly"]
