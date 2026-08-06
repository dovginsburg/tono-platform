"""Tono bills on its OWN dedicated Stripe account — and nothing else.

Owner directive (2026-08-05): three dedicated Stripe accounts were activated, one
per product. Activation removes only the KYC/activation blocker; it proves
nothing about catalog, keys, webhook, or purchase journeys. Each lane may operate
ONLY its own account: never a sibling product's (TandemSkills / TandemPaws) and
never the legacy personal account `Dov Ginsburg MD PLLC` — a different legal
entity whose key is the only Stripe credential present on this machine.

Before this guard, nothing checked WHICH account a configured `STRIPE_SECRET_KEY`
belonged to, so a pasted sibling/legacy key would have created customers and
charged real money on the wrong entity. `TONO_STRIPE_ACCOUNT_ID` declares the
allowed account; the live account behind the key is read back and compared, and
a mismatch (or an unverifiable identity) fails closed BEFORE any Stripe object is
created.
"""

from __future__ import annotations

import pytest


TONO_ACCOUNT = "acct_tono_dedicated"
LEGACY_ACCOUNT = "acct_1TRJaBQ93BpfjtrE"      # Dov Ginsburg MD PLLC — forbidden
SIBLING_ACCOUNT = "acct_tandempaws_dedicated"  # sibling product — forbidden


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _register(client) -> dict:
    r = client.post("/v1/register", json={})
    assert r.status_code == 200, r.text
    return r.json()


def _configure_stripe(monkeypatch, *, expected_account: str | None = TONO_ACCOUNT) -> None:
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_tono_fake")
    monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", "whsec_tono_fake")
    monkeypatch.setenv("STRIPE_PRICE_PRO_MONTHLY", "price_tono_month")
    monkeypatch.setenv("STRIPE_PRICE_PRO_YEARLY", "price_tono_year")
    if expected_account is None:
        monkeypatch.delenv("TONO_STRIPE_ACCOUNT_ID", raising=False)
    else:
        monkeypatch.setenv("TONO_STRIPE_ACCOUNT_ID", expected_account)


def _stub_live_account(monkeypatch, account_id: str | None, *, raises: bool = False):
    """Point the account read-back at a given account (or make it fail)."""
    import backend.payments as payments_mod

    payments_mod._ISOLATION_CACHE.clear()

    def _retrieve(*_a, **_k):
        if raises:
            raise RuntimeError("provider unreachable")
        return {"id": account_id}

    monkeypatch.setattr(payments_mod.stripe.Account, "retrieve", _retrieve)
    return payments_mod


@pytest.fixture(autouse=True)
def _clear_isolation_cache():
    import backend.payments as payments_mod
    payments_mod._ISOLATION_CACHE.clear()
    yield
    payments_mod._ISOLATION_CACHE.clear()


# ── Checkout refuses any account that is not Tono's ───────────────────────


@pytest.mark.parametrize("foreign", [LEGACY_ACCOUNT, SIBLING_ACCOUNT])
def test_checkout_refuses_a_foreign_stripe_account_before_creating_anything(
    client, monkeypatch, foreign
):
    """A key belonging to the legacy personal account or a sibling product must
    never bill Tono's users — and must be refused BEFORE any Stripe object or
    trial reservation is created."""
    _configure_stripe(monkeypatch)
    payments_mod = _stub_live_account(monkeypatch, foreign)

    created: list = []
    monkeypatch.setattr(
        payments_mod.stripe.checkout.Session, "create",
        lambda **k: created.append(k) or {"id": "cs", "url": "u"},
    )
    monkeypatch.setattr(
        payments_mod.stripe.Customer, "create",
        lambda **k: created.append(k) or {"id": "cus"},
    )

    device = _register(client)
    r = client.post("/v1/checkout", json={"interval": "month"},
                    headers=_auth(device["api_token"]))

    assert r.status_code == 503, r.text
    assert created == [], "a Stripe object was created against a foreign account"
    # The refusal must not disclose which foreign account the key points at.
    assert foreign not in r.text


def test_checkout_proceeds_on_the_dedicated_tono_account(client, monkeypatch):
    """Positive control: the guard refuses foreign accounts without also
    refusing the legitimate Tono account."""
    _configure_stripe(monkeypatch)
    payments_mod = _stub_live_account(monkeypatch, TONO_ACCOUNT)

    monkeypatch.setattr(
        payments_mod.stripe.checkout.Session, "create",
        lambda **k: {"id": "cs_tono", "url": "https://checkout.stripe.com/c/tono"},
    )
    monkeypatch.setattr(
        payments_mod.stripe.Customer, "create", lambda **k: {"id": "cus_tono"},
    )

    device = _register(client)
    r = client.post("/v1/checkout", json={"interval": "month"},
                    headers=_auth(device["api_token"]))
    assert r.status_code == 200, r.text


def test_checkout_fails_closed_when_account_identity_cannot_be_verified(
    client, monkeypatch
):
    """An unverifiable identity is refused, not assumed correct."""
    _configure_stripe(monkeypatch)
    payments_mod = _stub_live_account(monkeypatch, None, raises=True)
    monkeypatch.setattr(
        payments_mod.stripe.checkout.Session, "create",
        lambda **k: pytest.fail("must not reach Stripe with an unverified account"),
    )

    device = _register(client)
    r = client.post("/v1/checkout", json={"interval": "month"},
                    headers=_auth(device["api_token"]))
    assert r.status_code == 503, r.text


def test_no_declared_account_preserves_previous_behaviour(client, monkeypatch):
    """The guard is additive: with no TONO_STRIPE_ACCOUNT_ID declared, checkout
    behaves exactly as before (so this cannot break an existing deployment)."""
    _configure_stripe(monkeypatch, expected_account=None)
    import backend.payments as payments_mod
    monkeypatch.setattr(
        payments_mod.stripe.checkout.Session, "create",
        lambda **k: {"id": "cs_legacy", "url": "https://checkout.stripe.com/c/x"},
    )
    monkeypatch.setattr(
        payments_mod.stripe.Customer, "create", lambda **k: {"id": "cus_legacy"},
    )

    device = _register(client)
    r = client.post("/v1/checkout", json={"interval": "month"},
                    headers=_auth(device["api_token"]))
    assert r.status_code == 200, r.text


# ── Readiness readback is non-secret and does not infer from activation ───


def test_readiness_reports_unconfigured_without_leaking_anything(client):
    """With nothing wired (the live state today), readiness must say so rather
    than imply the activated dashboard account is usable."""
    body = client.get("/v1/stripe/readiness").json()
    assert body["provider"] == "stripe"
    assert body["secret_key_configured"] is False
    assert body["webhook_secret_configured"] is False
    assert body["price_monthly_configured"] is False
    assert body["price_yearly_configured"] is False
    assert body["account_identity_verified"] is False
    assert body["account_id"] is None
    assert body["ready"] is False


def test_readiness_is_not_ready_until_identity_catalog_and_webhook_all_hold(
    client, monkeypatch
):
    _configure_stripe(monkeypatch)
    _stub_live_account(monkeypatch, TONO_ACCOUNT)
    body = client.get("/v1/stripe/readiness").json()
    assert body["account_identity_verified"] is True
    assert body["account_id"] == TONO_ACCOUNT
    assert body["ready"] is True

    # Drop one canonical price → not ready, even with a verified account.
    monkeypatch.delenv("STRIPE_PRICE_PRO_YEARLY", raising=False)
    body = client.get("/v1/stripe/readiness").json()
    assert body["price_yearly_configured"] is False
    assert body["ready"] is False


def test_readiness_never_names_a_foreign_account(client, monkeypatch):
    """A misconfiguration must not turn the probe into an oracle for which
    product/entity the key actually belongs to."""
    _configure_stripe(monkeypatch)
    _stub_live_account(monkeypatch, LEGACY_ACCOUNT)
    body = client.get("/v1/stripe/readiness").json()
    assert body["account_identity_verified"] is False
    assert body["account_id"] is None
    assert body["ready"] is False
    assert LEGACY_ACCOUNT not in str(body)


def test_readiness_exposes_no_secret_values(client, monkeypatch):
    _configure_stripe(monkeypatch)
    _stub_live_account(monkeypatch, TONO_ACCOUNT)
    blob = str(client.get("/v1/stripe/readiness").json())
    for secret in ("sk_test_tono_fake", "whsec_tono_fake",
                   "price_tono_month", "price_tono_year"):
        assert secret not in blob, f"{secret} leaked from the readiness probe"
