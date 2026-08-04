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
_ANDROID_ACCOUNT_SHEET = (
    _REPO_ROOT / "apps/android/app/src/main/java/com/tono/app/ui/AccountSheet.kt"
)
_IOS_SETTINGS = _REPO_ROOT / "apps/ios/App/SettingsView.swift"
_WEB_CONFIG = _REPO_ROOT / "apps/web/src/lib/revenuecat-config.ts"
_BACKEND_PAYMENTS = _REPO_ROOT / "apps/backend/payments.py"

# The RevenueCat integration is Tono-only. These CODE files must never name or
# embed another product's identity (isolated per-product project — contract §1/§6).
_RC_CODE_FILES = (
    _REPO_ROOT / "apps/ios/App/RevenueCatManager.swift",
    _REPO_ROOT / "apps/android/app/src/main/java/com/tono/app/billing/RevenueCatManager.kt",
    _REPO_ROOT / "apps/web/src/lib/revenuecat-config.ts",
    _REPO_ROOT / "apps/backend/revenuecat.py",
)
# Other Tono-sibling products that share NOTHING with this canary.
_FOREIGN_PRODUCT_TOKENS = ("tandempaws", "tandemskills", "tandem_paws", "tandem_skills")


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
    # Build 126: the publishable goog_ key is INJECTED from a Gradle property / env
    # var and defaults fail-closed to empty (no key => dormant, kill switch off).
    assert (
        'revenueCatInjected("revenueCatPublicSdkKey", "REVENUECAT_PUBLIC_SDK_KEY", "")'
        in gradle
    )


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


# ---------------------------------------------------------------------------
# Lifecycle: logout / account-switch releases the RevenueCat identity
#
# The manager exposes signOut() (RevenueCat logOut + local state reset), but a
# manager nobody calls is a leak: without a logout call, the SDK keeps the
# signed-out account's customer logged in and the next person on a shared device
# inherits it, and an anonymous->identified->identified switch can alias two
# accounts. These lock the wiring so it cannot silently regress.
# ---------------------------------------------------------------------------


def test_ios_logout_and_delete_release_revenuecat_identity():
    code = _code_only(_read(_IOS_SETTINGS))
    # Both the sign-out path and the account-deletion path must release RC.
    assert (
        code.count("RevenueCatManager.shared.signOut()") >= 2
    ), "iOS sign-out AND account deletion must call RevenueCatManager.shared.signOut()"
    # It must sit alongside the existing local-credential teardown, not replace it.
    assert "TonoBackend.shared.signOut()" in code
    assert "TonoBackend.shared.deleteAccount()" in code


def test_android_logout_releases_revenuecat_identity():
    code = _code_only(_read(_ANDROID_ACCOUNT_SHEET))
    assert "RevenueCatManager.signOut()" in code, (
        "Android sign-out must call RevenueCatManager.signOut()"
    )
    # Called after the backend sign-out that clears the canonical ACCOUNT_ID.
    assert "TonoBackend.signOutEmail()" in code
    # Imported from :app billing (never :ime — the keyboard must not see identity).
    assert "import com.tono.app.billing.RevenueCatManager" in _read(_ANDROID_ACCOUNT_SHEET)


# ---------------------------------------------------------------------------
# Signed-out purchase is impossible (no anonymous durable paid access)
# ---------------------------------------------------------------------------


def test_ios_purchase_refuses_without_canonical_account():
    code = _code_only(_read(_IOS_MANAGER))
    assert "Self.canonicalAccountID != nil" in code, (
        "iOS purchase() must refuse to buy without the canonical account UUID"
    )


def test_android_purchase_refuses_without_canonical_account():
    code = _code_only(_read(_ANDROID_MANAGER))
    assert "canonicalAccountId() == null" in code, (
        "Android purchase() must refuse to buy without the canonical account UUID"
    )


# ---------------------------------------------------------------------------
# Product isolation: this canary is Tono-only
# ---------------------------------------------------------------------------


def test_no_foreign_product_identifiers_in_revenuecat_source():
    for path in _RC_CODE_FILES:
        text = _read(path).lower()
        for token in _FOREIGN_PRODUCT_TOKENS:
            assert token not in text, (
                f"{path.name} must not reference another product ({token!r}); "
                "the RevenueCat project is isolated per product"
            )


# ---------------------------------------------------------------------------
# Web account binding: the canonical UUID reaches Stripe as tono_account_id
# metadata (what RevenueCat's Stripe integration maps to its App User ID).
# ---------------------------------------------------------------------------


def test_web_documents_stripe_metadata_account_binding():
    cfg = _read(_WEB_CONFIG)
    assert "tono_account_id" in cfg, (
        "web config must name the Stripe metadata field RevenueCat maps to the App User ID"
    )


def test_backend_checkout_stamps_account_uuid_on_stripe():
    """The web->RevenueCat attribution the web config documents must be real: the
    Stripe checkout stamps tono_account_id on both the Customer and the
    subscription so RevenueCat's Stripe integration can bind the canonical UUID."""
    pay = _read(_BACKEND_PAYMENTS)
    assert '"tono_account_id": account_id' in pay, (
        "checkout must stamp the canonical account UUID as Stripe tono_account_id metadata"
    )
    assert "subscription_data" in pay and "metadata" in pay
