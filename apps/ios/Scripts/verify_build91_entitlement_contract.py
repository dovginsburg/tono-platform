#!/usr/bin/env python3
"""Zero-install source gate for the build-91 entitlement compatibility slice."""

from pathlib import Path
import json
import plistlib
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build90_recovery_gate  # noqa: E402 — sibling module, same Scripts dir

ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    backend = read("Shared/TonoBackend.swift")
    storekit = read("Shared/StoreKitManager.swift")
    coach = read("App/CoachView.swift")
    home = read("App/HomeView.swift")
    settings = read("App/SettingsView.swift")
    keyboard = read("KeyboardExtension/KeyboardRootView.swift")
    keyboard_client = read("KeyboardExtension/TonoCoachClient.swift")

    retired_wire_fields = ("used_today", "daily_limit")
    for field in retired_wire_fields:
        require(field not in backend, f"TonoBackend still requires retired field {field}")

    retired_copy = (
        "Daily free limit reached",
        "Free is 3/day",
        "coaching sessions/day",
        "No credit card, no trial",
    )
    public_sources = {
        "TonoBackend": backend,
        "CoachView": coach,
        "HomeView": home,
        "SettingsView": settings,
        "KeyboardRootView": keyboard,
        "TonoCoachClient": keyboard_client,
    }
    for label, source in public_sources.items():
        for phrase in retired_copy:
            require(phrase not in source, f"{label} still contains retired copy: {phrase}")

    active_ui = "\n".join(
        path.read_text(encoding="utf-8")
        for directory in ("App", "KeyboardExtension", "ShareExtension", "TonoMessagesExtension")
        for path in (ROOT / directory).rglob("*.swift")
    )
    require(
        re.search(r"\$(?:3\.99|5\.99|39\.99)", active_ui) is None,
        "active iOS UI hard-codes canonical subscription pricing instead of StoreKit displayPrice",
    )
    require(
        "intro.paymentMode == .freeTrial,\n                           isEligibleForFreeTrial" in settings,
        "introductory display price is not gated on StoreKit eligibility",
    )

    require("Active trial or subscription required" in backend, "429 policy copy is missing")
    require("/v1/app-store/subscription" in backend, "server subscription sync endpoint is missing")
    require("signed_transaction_info" in backend, "signed StoreKit JWS is not sent to backend")
    require("Product.PurchaseOption.appAccountToken" in storekit, "purchase ownership token is missing")
    require("purchase(options:" in storekit, "purchase does not bind the account token")
    require("verification.jwsRepresentation" in storekit, "purchase JWS is not synced")
    require("result.jwsRepresentation" in storekit, "restore/update JWS is not synced")
    require("me.isPro" in storekit, "backend state is not authoritative for Pro")
    load_section = storekit.split("private func loadProductsAndEntitlements() async", 1)[1]
    load_section = load_section.split("private func updateProState() async", 1)[0]
    require(
        load_section.index("registerIfNeeded") < load_section.index("updateProState"),
        "startup entitlement reconciliation can run before backend registration",
    )

    storekit_config = read("App/Tono.storekit")
    require("com.tono.pro." not in storekit_config, "StoreKit config still uses retired product IDs")
    config = json.loads(storekit_config)
    subscriptions = {
        product["productID"]: product
        for group in config["subscriptionGroups"]
        for product in group["subscriptions"]
    }
    expected_prices = {
        "com.tonoit.pro.monthly": "3.99",
        "com.tonoit.pro.yearly": "39.99",
    }
    for product_id, expected_price in expected_prices.items():
        require(product_id in subscriptions, f"StoreKit config missing {product_id}")
        product = subscriptions[product_id]
        require(product["displayPrice"] == expected_price, f"{product_id} price is not {expected_price}")
        offer = product.get("introductoryOffer") or {}
        require(offer.get("paymentMode") == "FREE_TRIAL", f"{product_id} lacks a real free trial")
        require(offer.get("subscriptionPeriod") == "P1W", f"{product_id} trial is not 7 days")

    canonical_claims = {
        "CLAUDE.md": read("CLAUDE.md"),
        "AppStoreReviewNotes.md": read("AppStoreReviewNotes.md"),
        "AppStore description": read("AppStore/description.txt"),
        "AppStore review notes": read("AppStore/review_notes.txt"),
        "App Store listing": read("AppStoreMetadata/app-store-listing.md"),
        "fastlane description": read("fastlane/metadata/en-US/description.txt"),
    }
    for label, source in canonical_claims.items():
        require("$5.99" not in source, f"{label} still claims retired monthly pricing")
        require("$3.99" in source and "$39.99" in source, f"{label} lacks approved canonical USD pricing")
        require("rewrites per day" not in source, f"{label} still presents a daily product quota")

    plist_paths = (
        "App/Info.plist",
        "KeyboardExtension/Info.plist",
        "ShareExtension/Info.plist",
        "TonoMessagesExtension/Info.plist",
    )
    for relative in plist_paths:
        with (ROOT / relative).open("rb") as handle:
            plist = plistlib.load(handle)
        require(str(plist["CFBundleVersion"]) == "91", f"{relative} is not build 91")

    project = read("Tono.xcodeproj/project.pbxproj")
    for bundle in ("TonoKeyboard.appex", "TonoShare.appex", "TonoMessagesExtension.appex"):
        embed_marker = f"{bundle} in Embed Foundation Extensions"
        require(project.count(embed_marker) >= 2, f"host embed missing for {bundle}")

    # Canonical tri-state must be the SOLE Pro authority; a missing/unknown
    # build-91 state fails closed and never falls back to a cached Bool (§7).
    shared_defaults = read("Shared/SharedUserDefaults.swift")
    require(
        "case nil: return false" in shared_defaults,
        "isProAuthoritative must fail closed on a missing entitlement state (no proUnlocked fallback)",
    )
    require(
        "case nil: return proUnlocked" not in shared_defaults,
        "isProAuthoritative still trusts the cached proUnlocked Bool for missing state",
    )
    tri_state_consumers = {
        "FeatureFlags": read("Shared/FeatureFlags.swift"),
        "MemoryView": read("App/MemoryView.swift"),
        "DigestView": read("App/DigestView.swift"),
        "CrashReporter": read("Shared/CrashReporter.swift"),
    }
    for label, source in tri_state_consumers.items():
        require(
            "TonePreferences().proUnlocked" not in source,
            f"{label} still authorizes/presents Pro from the cached proUnlocked Bool",
        )
    widget = read("Widget/TonoWidget.swift")
    require(
        'd.bool(forKey: "tc.proUnlocked")' not in widget,
        "TonoWidget still reads the cached proUnlocked Bool instead of the tri-state",
    )
    require(
        'd.string(forKey: "tc.entitlementState") == "entitled"' in widget,
        "TonoWidget must gate Pro on the canonical entitlement tri-state",
    )
    keyboard_source = read("KeyboardExtension/KeyboardRootView.swift")
    require(
        "SharedStore.defaults.set(usage.isPro, forKey: SharedKeys.proUnlocked)" not in keyboard_source,
        "keyboard still writes the proUnlocked mirror directly instead of recordEntitlement",
    )
    require(
        "TonePreferences.recordEntitlement(" in keyboard_source,
        "keyboard must record the backend verdict as canonical tri-state",
    )

    # Build-90 charged-before-upgrade external prerequisite (contract §5 /
    # hostile 20). This is the release gate the prior candidate lacked: it FAILS
    # CLOSED until checkout-disabled evidence or an owner-approved bounded
    # recovery policy is supplied. We do not fabricate that evidence, so this is
    # expected to block release until the owner provides it.
    readiness = build90_recovery_gate.evaluate(
        build90_recovery_gate.load_artifact(), __import__("os").environ
    )
    require(
        readiness.ready,
        "build-90 charged-before-upgrade prerequisite is unresolved: "
        + "; ".join(readiness.reasons),
    )

    print("build91-entitlement-contract: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"build91-entitlement-contract: FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
