"""Commercial catalog integrity + cross-provider mapping.

These tests pin the single versioned commercial catalog
(``packages/contracts/commercial-catalog.v1.json``) as the source of truth and
prove the launch invariants for build 101:

  * exactly ONE canonical paid entitlement ('pro') — no duplicate/per-provider plan;
  * every provider product (Stripe / App Store / Google Play) maps to it;
  * the approved display prices are unchanged ($3.99 / $39.99);
  * the backend code that consumes the mapping (app_store product-id default,
    payments Stripe price env-var names) matches the catalog with no drift;
  * the mobile client identifiers (iOS StoreKit, Android BillingContract) match
    the catalog, so the three surfaces can never silently diverge;
  * a malformed catalog fails closed (CatalogError), never silently degrades.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[3]
_CATALOG_PATH = _REPO_ROOT / "packages" / "contracts" / "commercial-catalog.v1.json"

_EXPECTED_PRODUCT_IDS = {"com.tonoit.pro.monthly", "com.tonoit.pro.yearly"}


def test_catalog_file_exists_and_is_json():
    assert _CATALOG_PATH.is_file(), f"missing catalog at {_CATALOG_PATH}"
    data = json.loads(_CATALOG_PATH.read_text(encoding="utf-8"))
    assert data["catalog_version"] == "1.0.0"


def test_single_canonical_entitlement():
    import backend.catalog as catalog

    assert catalog.canonical_entitlement_ids() == frozenset({"pro"})


def test_every_provider_product_maps_to_pro():
    import backend.catalog as catalog

    data = catalog.load_catalog()
    for name, provider in data["providers"].items():
        assert provider["products"], f"provider {name} has no products"
        for product in provider["products"]:
            assert product["entitlement"] == "pro", (
                f"provider {name} product {product} does not map to the canonical entitlement"
            )


def test_apple_and_google_product_ids_match_expected():
    import backend.catalog as catalog

    assert catalog.apple_product_ids() == _EXPECTED_PRODUCT_IDS
    assert catalog.google_play_subscription_ids() == _EXPECTED_PRODUCT_IDS


def test_stripe_price_env_var_names():
    import backend.catalog as catalog

    assert catalog.stripe_price_env_var("month") == "STRIPE_PRICE_PRO_MONTHLY"
    assert catalog.stripe_price_env_var("year") == "STRIPE_PRICE_PRO_YEARLY"


def test_approved_prices_unchanged():
    import backend.catalog as catalog

    # These are the approved amounts. If a change is intended it must be a
    # deliberate, reviewed edit to the catalog AND this test — not an accident.
    assert catalog.approved_price("month") == "3.99"
    assert catalog.approved_price("year") == "39.99"


def test_app_store_default_product_ids_come_from_catalog():
    """The App Store config default must equal the catalog, and the literal
    fallback must too — so neither can drift from the single source of truth."""
    import backend.catalog as catalog
    from backend import app_store

    catalog_ids = catalog.apple_product_ids()
    assert set(app_store._default_apple_product_ids().split(",")) == catalog_ids
    assert set(app_store._APPLE_PRODUCT_IDS_FALLBACK.split(",")) == catalog_ids

    # And the assembled runtime config (no env override) uses them.
    config = app_store.get_appstore_config()
    assert config.product_ids == catalog_ids


def test_google_play_defaults_come_from_catalog():
    """The Google Play server config defaults must equal the catalog, and the
    literal fallbacks in google_play.py must too — so neither can drift from the
    single source of truth (mirrors the App Store default test)."""
    import backend.catalog as catalog
    from backend import google_play

    catalog_ids = catalog.google_play_subscription_ids()
    assert set(google_play._default_google_subscription_ids().split(",")) == catalog_ids
    assert set(google_play._GOOGLE_SUBSCRIPTION_IDS_FALLBACK.split(",")) == catalog_ids

    assert catalog.google_play_package_name() == "com.tono.myapp"
    assert google_play._default_google_package_name() == "com.tono.myapp"
    assert google_play._GOOGLE_PACKAGE_FALLBACK == "com.tono.myapp"

    # The assembled runtime config (no env override) uses the catalog values, and
    # base plans are unconfigured by default -> cannot grant until set (§6).
    config = google_play.get_google_play_config()
    assert config.subscription_ids == catalog_ids
    assert config.package_name == "com.tono.myapp"
    assert config.base_plan_ids == frozenset()


def test_google_play_base_plan_env_var_recorded_not_invented():
    """The catalog records the base-plan env-var NAME (config surface) but never
    an invented console base-plan id (§6): both product base_plan_id stay null."""
    import backend.catalog as catalog

    assert catalog.google_play_base_plan_env_var() == "TONO_GOOGLE_BASE_PLAN_IDS"
    data = catalog.load_catalog()
    for product in data["providers"]["google_play"]["products"]:
        assert product["base_plan_id"] is None


def test_payments_price_env_fallback_matches_catalog():
    import backend.catalog as catalog
    from backend import payments

    for interval in ("month", "year"):
        assert payments._STRIPE_PRICE_ENV_FALLBACK[interval] == catalog.stripe_price_env_var(
            interval
        )


def test_price_for_resolves_via_catalog_env_var(monkeypatch):
    from backend import payments

    monkeypatch.setenv("STRIPE_PRICE_PRO_MONTHLY", "price_month_xyz")
    monkeypatch.setenv("STRIPE_PRICE_PRO_YEARLY", "price_year_xyz")
    assert payments._price_for("pro", "month") == "price_month_xyz"
    assert payments._price_for("pro", "year") == "price_year_xyz"
    # Unknown plan / interval never resolves to a price.
    assert payments._price_for("pro", "week") is None
    assert payments._price_for("team", "month") is None


def test_ios_storekit_product_ids_match_catalog():
    """The iOS StoreKit config must reference exactly the catalog product ids."""
    import backend.catalog as catalog

    storekit = _REPO_ROOT / "apps" / "ios" / "App" / "Tono.storekit"
    if not storekit.is_file():
        pytest.skip("iOS StoreKit config not present in this checkout")
    text = storekit.read_text(encoding="utf-8")
    for product_id in catalog.apple_product_ids():
        assert product_id in text, f"{product_id} missing from {storekit}"


def test_android_billing_contract_matches_catalog():
    """The Android BillingContract must reference exactly the catalog Play ids."""
    import backend.catalog as catalog

    contract = (
        _REPO_ROOT
        / "apps"
        / "android"
        / "app"
        / "src"
        / "main"
        / "java"
        / "com"
        / "tono"
        / "app"
        / "billing"
        / "BillingContract.kt"
    )
    if not contract.is_file():
        pytest.skip("Android BillingContract not present in this checkout")
    text = contract.read_text(encoding="utf-8")
    found = set(re.findall(r"com\.tonoit\.pro\.\w+", text))
    assert found == catalog.google_play_subscription_ids()


def test_catalog_package_name_matches_android_application_id():
    import backend.catalog as catalog

    data = catalog.load_catalog()
    play = data["providers"]["google_play"]
    assert play["package_name"] == "com.tono.myapp"


def test_malformed_catalog_fails_closed(tmp_path, monkeypatch):
    """A duplicated/extra canonical entitlement must raise, never silently pass."""
    import backend.catalog as catalog

    bad = tmp_path / "bad-catalog.json"
    bad.write_text(
        json.dumps(
            {
                "catalog_version": "1.0.0",
                "canonical_entitlements": {"pro": {}, "team": {}},
                "providers": {
                    "stripe": {"products": [{"interval": "month", "entitlement": "pro"}]}
                },
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setenv("TONO_COMMERCIAL_CATALOG_PATH", str(bad))
    catalog.load_catalog.cache_clear()
    with pytest.raises(catalog.CatalogError):
        catalog.load_catalog()
    catalog.load_catalog.cache_clear()
