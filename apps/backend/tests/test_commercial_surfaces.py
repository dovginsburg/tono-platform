"""Cross-surface commercial configuration checks that do not need store credentials."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]



def test_web_rewrite_proxy_has_no_unauthenticated_fallback():
    source = (ROOT / "apps/web/src/app/api/analyze/route.ts").read_text()
    assert "'/v1/analyze'" not in source
    assert "paywall_required" in source
    assert "status: 402" in source


def test_web_customer_copy_has_no_discontinued_access_claims():
    app_root = ROOT / "apps/web/src/app"
    customer_copy = "\n".join(path.read_text() for path in app_root.rglob("*.tsx"))
    for forbidden in (
        r"\bfree\b",
        r"no[ -]sign[ -]in",
        r"no card",
        r"3 rewrites",
        r"\$0(?:\D|$)",
    ):
        assert not re.search(forbidden, customer_copy, re.IGNORECASE), forbidden

    landing = (app_root / "page.tsx").read_text()
    pricing = (app_root / "pricing/page.tsx").read_text()
    for source in (landing, pricing):
        assert "eligible new users" in source
        assert "7-day trial" in source
    assert "auto-renews at $3.99/month unless canceled" in pricing
    assert "auto-renews at $39.99/year unless canceled" in pricing


def test_web_offer_and_checkout_are_account_and_provider_backed():
    callback = (ROOT / "apps/web/src/app/auth/callback/route.ts").read_text()
    checkout = (ROOT / "apps/backend/payments.py").read_text()
    button = (ROOT / "apps/web/src/app/ProCheckoutButton.tsx").read_text()
    vercel = json.loads((ROOT / "apps/web/vercel.json").read_text())

    assert "/v1/auth/web" in callback
    assert "X-Web-Auth-Secret" in callback
    assert "_require_account(user)" in checkout
    assert "stripe.Subscription.list" in checkout
    assert "stripe.Price.retrieve" in checkout
    assert "trial_period_days" in checkout
    assert "Intl.NumberFormat" in button
    assert "localizedPrice" in button
    rewrites = {(item["source"], item["destination"]) for item in vercel["rewrites"]}
    assert ("/api/offer", "/app/api/offer") in rewrites



def test_external_store_configuration_gates_are_documented():
    text = (ROOT / "docs/trial-only-release-gates.md").read_text().lower()
    assert "app store connect" in text
    assert "google play" in text
    assert "stripe" in text
    assert "7-day" in text
    assert "3.99" in text and "39.99" in text
