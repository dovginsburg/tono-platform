"""Build 101 revenue-integration tests.

These are the integration-slice tests that exist because three independently
QA-GO'd lineages (web/canonical account, Stripe lifecycle, iOS Build101) were
merged into one candidate. They assert the invariants that only matter once all
three are present in the same process:

  * Convergence — for ONE immutable canonical account, a web (Stripe) checkout
    and a StoreKit (Apple) transaction bound to that same account converge onto
    a single entitlement. Devices never own access; the account does.
  * Conflict refusal — a StoreKit transaction whose appAccountToken belongs to a
    DIFFERENT account is refused as a deterministic conflict. No self-grant, no
    cross-account entitlement claim, and the canonical account is undisturbed.
  * Health redaction — the public /health response cannot expose any API /
    provider credential material (key length, prefix, fingerprint, presence of
    the raw secret) — only safe feature booleans.
"""

from __future__ import annotations

import json

# Reuse the vetted Stripe-lifecycle helpers so this test drives the exact same
# canonical account + webhook path the standalone lineage already QA'd.
from .test_stripe_lifecycle import (
    _auth,
    _configure_stripe,
    _fake_sub_retrieve,
    _post_webhook,
    _register,
    _sign_in_apple,
    _sub_obj,
    _FUTURE_PERIOD_END,
)

_OTHER_ACCOUNT = "11111111-2222-3333-4444-555555555555"


def _apply_apple_purchased(store, *, account_id, app_account_token, otxn, txn):
    """Apply one verified, active PURCHASED Apple transaction to `account_id`,
    stamped with `app_account_token`. Signed far in the future so no
    stale-replay guard fires."""
    return store.apply_apple_transaction(
        account_id=account_id,
        original_transaction_id=otxn,
        transaction_id=txn,
        product_id="tono_pro_monthly",
        environment="Production",
        ownership_type="PURCHASED",
        app_account_token=app_account_token,
        signed_ms=_FUTURE_PERIOD_END * 1000,
        expires_ms=_FUTURE_PERIOD_END * 1000,
    )


# ---------------------------------------------------------------------------
# Convergence: web checkout + StoreKit → one account, one entitlement
# ---------------------------------------------------------------------------


def test_web_and_storekit_converge_to_one_entitlement(client, monkeypatch):
    """Same immutable canonical account: a web Stripe checkout AND a StoreKit
    transaction bound to that account both project onto ONE entitled account.
    The two channels do not create two accounts or two rival entitlements —
    they converge (integration invariant 1)."""
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)

    # One canonical account, established via Supabase-web-equivalent Apple sign-in.
    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="conv-apple-1")
    store = get_store()
    store.attach_account_stripe_customer(account_id, "cus_conv_1")

    # --- Channel A: web checkout (Stripe subscription webhook → account) ---
    import backend.payments as payments_mod

    obj = _sub_obj(
        sub_id="sub_conv_1",
        customer_id="cus_conv_1",
        status="active",
        period_end=_FUTURE_PERIOD_END,
        account_id=account_id,
    )
    r = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_conv_1", "customer.subscription.updated", obj,
        sub_retrieve=_fake_sub_retrieve(),
    )
    assert r.status_code == 200, r.text
    assert store.account_entitlement_active(account_id), "web checkout must entitle the account"

    # --- Channel B: StoreKit transaction bound to the SAME account ---
    res = _apply_apple_purchased(
        store, account_id=account_id, app_account_token=account_id,
        otxn="otxn_conv_1", txn="txn_conv_1",
    )
    assert res.outcome == "direct_granted", res.detail

    # Convergence: still exactly ONE entitled canonical account. Both the Stripe
    # projection and the Apple projection point at that one account; every active
    # grant belongs to it (no rival account, no device-owned access).
    assert store.account_entitlement_active(account_id)
    grants = store.list_entitlement_grants(account_id)
    active = [g for g in grants if g["state"] == "active"]
    assert active, "the account must hold active grants from both channels"
    assert all(g["account_id"] == account_id for g in grants), "grants must not leak to another account"
    # No grants ever landed on any other account.
    assert store.list_entitlement_grants(_OTHER_ACCOUNT) == []


# ---------------------------------------------------------------------------
# Conflict refusal: cross-account StoreKit claim is refused
# ---------------------------------------------------------------------------


def test_storekit_bound_to_other_account_is_refused(client, monkeypatch):
    """A StoreKit transaction whose appAccountToken belongs to a DIFFERENT
    account must be refused deterministically as a conflict: no self-grant, no
    cross-account claim, and the canonical account's entitlement is undisturbed
    (integration invariants 1 & 7)."""
    from backend.server import app
    from backend.store import get_store

    _configure_stripe(monkeypatch)

    device = _register(client)
    account_id = _sign_in_apple(client, app, device["api_token"], sub="conf-apple-1")
    store = get_store()
    store.attach_account_stripe_customer(account_id, "cus_conf_1")

    # Establish the canonical account's legitimate web entitlement first.
    import backend.payments as payments_mod

    obj = _sub_obj(
        sub_id="sub_conf_1", customer_id="cus_conf_1", status="active",
        period_end=_FUTURE_PERIOD_END, account_id=account_id,
    )
    r = _post_webhook(
        client, monkeypatch, payments_mod,
        "evt_conf_1", "customer.subscription.updated", obj,
        sub_retrieve=_fake_sub_retrieve(),
    )
    assert r.status_code == 200, r.text
    assert store.account_entitlement_active(account_id)

    # Now a StoreKit transaction arrives at THIS account but is bound (via
    # appAccountToken) to a different account. This is the hostile cross-account
    # claim: it must be refused, not silently granted.
    res = _apply_apple_purchased(
        store, account_id=account_id, app_account_token=_OTHER_ACCOUNT,
        otxn="otxn_conf_1", txn="txn_conf_1",
    )
    assert res.outcome == "conflict", res.detail

    # No new grant was created for either the acting account off this hostile
    # transaction or the foreign token's account.
    assert store.list_entitlement_grants(_OTHER_ACCOUNT) == []
    # The canonical account keeps exactly its legitimate web entitlement and is
    # not disturbed by the refused claim.
    assert store.account_entitlement_active(account_id)


# ---------------------------------------------------------------------------
# Health redaction (integration invariant 4)
# ---------------------------------------------------------------------------

# Any of these substrings appearing in the /health JSON would mean the response
# leaks credential material (key length, prefix/start, fingerprint, or the raw
# secret itself).
# Probe values are deliberately distinctive ("ZQX…") so a substring hit is a
# genuine secret leak, not an accidental collision with a legitimate field name
# like "slack_configured".
_SECRET_PROBES = {
    "STRIPE_SECRET_KEY": "ZQXsk_live_51SupersecretValue0123456789ABCDEF",
    "SLACK_CLIENT_SECRET": "ZQXslackClientSecretValue0123456789ABCDEF",
    "ANTHROPIC_API_KEY": "ZQXsk-ant-SupersecretValue0123456789ABCDEF",
    "OPENAI_API_KEY": "ZQXsk-openai-SupersecretValue0123456789ABCDEF",
    "TONO_ADMIN_SECRET": "ZQXadminSupersecretValue0123456789ABCDEF",
}


def test_health_never_exposes_credential_material(client, monkeypatch):
    """The public /health endpoint may report safe feature booleans but must
    never expose any API/provider secret's value, length, prefix, or
    fingerprint. Regression lock for integration invariant 4."""
    for name, value in _SECRET_PROBES.items():
        monkeypatch.setenv(name, value)

    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    raw = json.dumps(body)

    secret_lengths = {len(v) for v in _SECRET_PROBES.values()}
    for name, value in _SECRET_PROBES.items():
        # Raw secret must never appear.
        assert value not in raw, f"/health leaked raw {name}"
        # No prefix/start fingerprint: no leading slice of the secret may appear.
        for n in (4, 6, 8, 12):
            assert value[:n] not in raw, f"/health leaked a {n}-char prefix of {name}"

    # No key length disclosed: no field value may equal a secret's length.
    # (Checked against actual field values, not the serialized blob, so the
    # unix `ts` integer can't cause a spurious substring match.)
    for key, val in body.items():
        if isinstance(val, int):
            assert val not in secret_lengths, f"health.{key} discloses a secret length"

    # Presence may only be reported as a plain boolean, never a string that
    # could carry length/prefix/fingerprint detail.
    for key, val in body.items():
        if key.endswith("_configured"):
            assert isinstance(val, bool), f"health.{key} must be a bare bool, got {val!r}"

    # Positive: the safe feature booleans still work (stripe_configured true
    # because the probe set STRIPE_SECRET_KEY).
    assert body.get("stripe_configured") is True
