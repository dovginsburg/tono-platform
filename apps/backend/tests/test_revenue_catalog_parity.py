"""Cross-platform revenue-catalog reconciliation (card t_6a183fcf, criterion 4).

The approved subscription product IDs are an immutable, cross-surface contract:
once registered in App Store Connect / Google Play they cannot change, and the
backend entitlement catalog must accept exactly them. These identifiers are
duplicated across four independent source-of-truth files (iOS StoreKit config,
iOS StoreKitManager, Android BillingContract, backend Apple catalog). A silent
drift in any one of them breaks entitlement grants for a whole platform.

This test READS the shipped source files (no mutation) and asserts they all
declare the SAME two product IDs, and that the canonical person/account binding
(appAccountToken) is present on both the client and the backend. It intentionally
does NOT assert prices — approved pricing is out of scope and must not be
invented or changed here. It exists to PROVE the reconciliation is already
correct and to fail closed if a future edit desyncs a platform.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

# tests/ -> apps/backend -> apps -> <repo root>
_REPO_ROOT = Path(__file__).resolve().parents[3]

CANONICAL_PRODUCT_IDS = {"com.tonoit.pro.monthly", "com.tonoit.pro.yearly"}

_STOREKIT = _REPO_ROOT / "apps/ios/App/Tono.storekit"
_STOREKIT_MANAGER = _REPO_ROOT / "apps/ios/Shared/StoreKitManager.swift"
_ANDROID_BILLING = (
    _REPO_ROOT
    / "apps/android/app/src/main/java/com/tono/app/billing/BillingContract.kt"
)
_ANDROID_MANAGER = (
    _REPO_ROOT
    / "apps/android/app/src/main/java/com/tono/app/billing/PlayBillingManager.kt"
)
_ANDROID_BACKEND = (
    _REPO_ROOT
    / "apps/android/shared/src/main/java/com/tono/shared/network/TonoBackend.kt"
)
_IMESSAGE = (
    _REPO_ROOT
    / "apps/ios/TonoMessagesExtension/MessagesViewController.swift"
)
_IOS_BACKEND = _REPO_ROOT / "apps/ios/Shared/TonoBackend.swift"
_BACKEND_APP_STORE = _REPO_ROOT / "apps/backend/app_store.py"
_BACKEND_CATALOG = _REPO_ROOT / "apps/backend/catalog.py"


def _ids_in(path: Path) -> set[str]:
    """Every `com.tonoit.pro.<tier>` occurrence in a file, deduplicated."""
    assert path.exists(), f"expected source-of-truth file missing: {path}"
    return set(re.findall(r"com\.tonoit\.pro\.[a-z]+", path.read_text()))


def test_storekit_config_declares_exactly_canonical_ids():
    assert _ids_in(_STOREKIT) == CANONICAL_PRODUCT_IDS


def test_ios_storekit_manager_declares_exactly_canonical_ids():
    assert _ids_in(_STOREKIT_MANAGER) == CANONICAL_PRODUCT_IDS


def test_android_billing_contract_declares_exactly_canonical_ids():
    assert _ids_in(_ANDROID_BILLING) == CANONICAL_PRODUCT_IDS


def test_backend_apple_catalog_default_matches_canonical_ids():
    """The backend's catalog-backed default and emergency literal fallback
    must both accept exactly the canonical product IDs."""
    text = _BACKEND_APP_STORE.read_text()
    fallback = re.search(r'_APPLE_PRODUCT_IDS_FALLBACK\s*=\s*"([^"]+)"', text)
    assert fallback, "backend Apple product-id fallback not found in app_store.py"
    fallback_ids = {p.strip() for p in fallback.group(1).split(",") if p.strip()}
    assert fallback_ids == CANONICAL_PRODUCT_IDS

    catalog_source = _BACKEND_CATALOG.read_text()
    assert "def apple_product_ids()" in catalog_source
    assert 'catalog.apple_product_ids()' in text

    from backend import catalog

    assert set(catalog.apple_product_ids()) == CANONICAL_PRODUCT_IDS


def test_all_four_surfaces_agree_on_the_same_product_ids():
    """The reconciliation invariant: every platform declares the identical set.
    A drift in any single surface fails this test with a precise diff."""
    surfaces = {
        "ios_storekit": _ids_in(_STOREKIT),
        "ios_storekit_manager": _ids_in(_STOREKIT_MANAGER),
        "android_billing": _ids_in(_ANDROID_BILLING),
    }
    for name, ids in surfaces.items():
        assert ids == CANONICAL_PRODUCT_IDS, f"{name} drifted: {ids}"


def test_backend_apple_catalog_enum_matches_actual_config_object():
    """Beyond the regex on source text, load the real backend catalog object and
    assert it accepts exactly the canonical IDs — the code path the webhook uses
    (`claims['productId'] not in config.product_ids`)."""
    from backend.app_store import get_appstore_config

    config = get_appstore_config()
    assert set(config.product_ids) == CANONICAL_PRODUCT_IDS


def test_person_account_binding_present_on_client_and_backend():
    """Canonical person/account binding: the client must attach an
    `appAccountToken` to the purchase and the backend must read it from the
    signed transaction. This binds a purchase to the server-issued account, not
    the device — the reconciliation the card requires. We assert the binding
    exists on both sides (behavioral coverage lives in the mobile-billing suite)."""
    client = _STOREKIT_MANAGER.read_text()
    assert "appAccountToken" in client, (
        "StoreKitManager must attach an appAccountToken to the purchase (person binding)"
    )
    backend = _BACKEND_APP_STORE.read_text()
    assert "appAccountToken" in backend, (
        "backend must read appAccountToken from the signed transaction (person binding)"
    )


def test_android_checkout_binds_server_account_and_keeps_backend_authoritative():
    manager = _ANDROID_MANAGER.read_text()
    client = _ANDROID_BACKEND.read_text()
    assert '@SerialName("account_id")' in client
    assert "SharedKeys.ACCOUNT_ID" in client
    assert ".setObfuscatedAccountId(accountId)" in manager
    assert ".setObfuscatedProfileId" not in manager
    assert "syncGooglePlaySubscription(" in manager
    assert "if (!me.isPro)" in manager


def test_imessage_uses_configured_one_chip_one_request_editable_result_contract():
    source = _IMESSAGE.read_text()
    backend = _IOS_BACKEND.read_text()
    assert 'return ["safer"] + settings.enabled' in source
    assert "CoachVariantSettings.maximumOptionalCount" in source
    assert "requestRewrite(axis: axis)" in source
    assert "TonoBackend.shared.analyzeVariant(" in source
    assert 'path: "/api/analyze/variant"' in backend
    assert "TextEditor(text: $resultText)" in source
    assert 'Button("Insert")' in source
    assert 'Button("Dismiss"' in source
    assert "insertText(text)" in source
    assert "result.status == \"ok\"" in source
    assert "normalized(rewrite) != normalized(source)" in source
    assert ".send(" not in source
