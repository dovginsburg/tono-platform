"""RevenueCat canary — cross-client source contract (runnable in CI).

The native clients (iOS Swift, Android Kotlin) cannot run their full suites in
every environment, so this pytest READS the shipped client source (no mutation,
like test_revenue_catalog_parity.py) and fails closed if any RevenueCat canary
invariant drifts on a client:

  * App User ID is the canonical account UUID — never device/email/anonymous.
  * The backend stays the sole entitlement authority (CustomerInfo is observation).
  * A kill switch (publishable key present) gates configuration; dormant by default.
  * No secret / publishable key literal is committed in source.
  * The integration is additive (existing StoreKit / Play billing path preserved).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

# tests/ -> apps/backend -> apps -> <repo root>
_REPO_ROOT = Path(__file__).resolve().parents[3]

_IOS_MANAGER = _REPO_ROOT / "apps/ios/App/RevenueCatManager.swift"
_IOS_APP = _REPO_ROOT / "apps/ios/App/TonoApp.swift"
_IOS_INFO = _REPO_ROOT / "apps/ios/App/Info.plist"
_ANDROID_MANAGER = (
    _REPO_ROOT / "apps/android/app/src/main/java/com/tono/app/billing/RevenueCatManager.kt"
)
_ANDROID_GRADLE = _REPO_ROOT / "apps/android/app/build.gradle.kts"
_ANDROID_APP = _REPO_ROOT / "apps/android/app/src/main/java/com/tono/app/TonoApplication.kt"
_WEB_CONFIG = _REPO_ROOT / "apps/web/src/lib/revenuecat-config.ts"


def _read(path: Path) -> str:
    assert path.exists(), f"expected RevenueCat client source missing: {path}"
    return path.read_text(encoding="utf-8")


def _code_only(text: str) -> str:
    """Strip // line comments and /* */ block comments (Swift + Kotlin) so an
    assertion about CODE isn't tripped by a doc comment that names the boundary
    it deliberately does not cross."""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    text = re.sub(r"//[^\n]*", " ", text)
    return text


# ---------------------------------------------------------------------------
# iOS
# ---------------------------------------------------------------------------


def test_ios_uses_canonical_account_uuid_as_app_user_id():
    src = _read(_IOS_MANAGER)
    assert "KeychainKeys.accountID" in src, "iOS App User ID must be the canonical account UUID"
    # Never the device id as the RevenueCat identity.
    assert "deviceID" not in src and "device_id" not in src


def test_ios_is_kill_switched_and_sdk_optional():
    src = _read(_IOS_MANAGER)
    assert "#if canImport(RevenueCat)" in src, "must compile with or without the SPM package"
    assert "REVENUECAT_PUBLIC_SDK_KEY" in src, "must read the publishable key from Info.plist"
    # Dormant by default: the key is treated as unset when it is the $()-placeholder.
    assert "$(" in src or "placeholder" in src.lower()


def test_ios_backend_stays_entitlement_authority():
    src = _read(_IOS_MANAGER)
    assert "observation" in src.lower(), "CustomerInfo must be documented as observation-only"
    # The manager must not flip the app's authoritative Pro gate (check CODE, not
    # the doc comment that names the boundary it does not cross).
    code = _code_only(src)
    assert "isProAuthoritative" not in code
    assert "recordEntitlement" not in code


def test_ios_wired_but_additive():
    app = _read(_IOS_APP)
    assert "RevenueCatManager.shared.configureIfEnabled()" in app
    # StoreKit path preserved (not removed).
    assert "StoreKitManager.shared.start()" in app
    info = _read(_IOS_INFO)
    assert "REVENUECAT_PUBLIC_SDK_KEY" in info


def test_ios_no_committed_key_literal():
    src = _read(_IOS_MANAGER)
    assert not re.search(r"appl_[A-Za-z0-9]{8,}", src), "no publishable appl_ key may be committed"


# ---------------------------------------------------------------------------
# Android
# ---------------------------------------------------------------------------


def test_android_uses_canonical_account_uuid_as_app_user_id():
    src = _read(_ANDROID_MANAGER)
    assert "SharedKeys.ACCOUNT_ID" in src, "Android App User ID must be the canonical account UUID"
    assert "DEVICE_ID" not in src


def test_android_is_kill_switched():
    src = _read(_ANDROID_MANAGER)
    assert "BuildConfig.REVENUECAT_PUBLIC_SDK_KEY" in src
    gradle = _read(_ANDROID_GRADLE)
    assert 'buildConfigField("String", "REVENUECAT_PUBLIC_SDK_KEY"' in gradle
    # Empty default => dormant by default (kill switch off).
    assert 'REVENUECAT_PUBLIC_SDK_KEY", "\\"\\""' in gradle


def test_android_backend_stays_entitlement_authority():
    src = _read(_ANDROID_MANAGER)
    assert "OBSERVATION" in src or "observation" in src
    # The manager must not write the pro mirror (check CODE, not the doc comment
    # that explains the keyboard reads PRO_UNLOCKED).
    assert "PRO_UNLOCKED" not in _code_only(src)


def test_android_lives_in_app_module_not_ime():
    src = _read(_ANDROID_MANAGER)
    assert src.startswith("package com.tono.app.billing"), "RevenueCat must live in :app, never :ime"


def test_android_wired_but_additive():
    app = _read(_ANDROID_APP)
    assert "RevenueCatManager.configureIfEnabled(this)" in app
    assert "PlayBillingManager.start(this)" in app  # existing path preserved


def test_android_billing7_not_pinned_to_avoid_billing_bump():
    """RevenueCat 7.x keeps Play Billing 6.x; an 8.x bump would risk the existing
    PlayBillingManager. Pin the major to 7 so this stays intentional."""
    gradle = _read(_ANDROID_GRADLE)
    m = re.search(r'com\.revenuecat\.purchases:purchases:(\d+)\.', gradle)
    assert m, "RevenueCat purchases dependency must be declared"
    assert m.group(1) == "7", f"expected RevenueCat 7.x (Billing 6.x); found major {m.group(1)}"


def test_android_no_committed_key_literal():
    src = _read(_ANDROID_MANAGER)
    assert not re.search(r"goog_[A-Za-z0-9]{8,}", src), "no publishable goog_ key may be committed"
    assert not re.search(r"goog_[A-Za-z0-9]{8,}", _read(_ANDROID_GRADLE))


# ---------------------------------------------------------------------------
# Web
# ---------------------------------------------------------------------------


def test_web_config_is_failclosed_and_preserves_stripe():
    src = _read(_WEB_CONFIG)
    assert "Stripe-hosted" in src
    assert "RevenueCat Billing" in src  # explicitly documents NOT introducing it
    assert "client_reference_id" in src  # account UUID binding preserved
    assert not re.search(r"rcb_[A-Za-z0-9]{8,}", src), "no publishable web key may be committed"


# ---------------------------------------------------------------------------
# Catalog cross-check
# ---------------------------------------------------------------------------


def test_catalog_declares_revenuecat_provider_mapping_pro():
    from backend import catalog

    data = catalog.load_catalog()
    rc = data["providers"].get("revenuecat")
    assert rc, "catalog must declare a revenuecat provider block"
    assert catalog.revenuecat_default_entitlement_id() == "pro"
    for product in rc["products"]:
        assert product["entitlement"] == "pro"
        assert product["interval"] in ("month", "year")
