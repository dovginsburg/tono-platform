"""Source-level regressions for the active iOS billing and Settings copy."""

from pathlib import Path


IOS = Path(__file__).resolve().parents[2] / "ios"


def _source(relative: str) -> str:
    return (IOS / relative).read_text(encoding="utf-8")


def test_active_ios_surfaces_do_not_expose_retired_free_plan_copy():
    sources = "\n".join(
        _source(path)
        for path in (
            "App/SettingsView.swift",
            "App/HomeView.swift",
            "App/CoachView.swift",
            "KeyboardExtension/TonoCoachClient.swift",
            "Shared/TonoBackend.swift",
        )
    )

    for retired_copy in (
        'Text(u.isPro ? "Pro" : "Free")',
        '"Pro ✓" : "Free"',
        "Free ·",
        "Free: 3",
        "Unlimited rewrites (Free is 3/day)",
        "no card required",
        "No credit card, no trial",
        "Daily free limit",
    ):
        assert retired_copy not in sources


def test_paywall_never_renders_introductory_zero_price_as_the_plan_price():
    settings = _source("App/SettingsView.swift")

    assert "intro.displayPrice" not in settings
    assert "product.displayPrice" in settings
    assert "intro.paymentMode == .freeTrial" in settings
    assert "then auto-renews at \\(product.displayPrice) unless canceled" in settings


def test_settings_visible_labels_use_tone_without_renaming_storage_symbols():
    settings = _source("App/SettingsView.swift")

    assert 'Section("Tone")' in settings
    assert 'TextField("Preferred tone (e.g. direct, warm, concise)"' in settings
    assert 'Section("Tone hint (optional)")' in settings
    assert "tone hint is sent with a coaching request" in settings
    assert "preferredVoice" in settings
    assert "voiceHint" in settings
    assert 'Section("Voice")' not in settings
    assert 'TextField("Preferred voice' not in settings
    assert 'Section("Voice hint (optional)")' not in settings


def test_storekit_purchase_outcomes_are_explicit_and_server_authoritative():
    manager = _source("Shared/StoreKitManager.swift")
    app = _source("App/TonoApp.swift")

    assert "syncAppStoreSubscription" in manager
    assert "applyBackendState(" in manager
    assert "inTrial: transaction.offer?.paymentMode == .freeTrial" in manager
    assert "subscription.isEligibleForIntroOffer" in manager
    assert 'purchaseError = "Purchase canceled."' in manager
    assert 'purchaseError = "Purchase is pending approval."' in manager
    assert "guard updatesTask == nil else { return }" in manager
    assert "StoreKitManager.shared.start()" in app