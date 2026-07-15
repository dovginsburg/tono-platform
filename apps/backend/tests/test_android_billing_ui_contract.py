"""Source-level regressions for provider-bound Google Play checkout."""

from pathlib import Path


ANDROID_APP = Path(__file__).resolve().parents[2] / "android" / "app"


def _source(relative: str) -> str:
    return (ANDROID_APP / relative).read_text(encoding="utf-8")


def test_shipping_google_play_checkout_binds_purchase_to_registered_device():
    manager = _source("src/main/java/com/tono/app/billing/PlayBillingManager.kt")
    contract = _source("src/main/java/com/tono/app/billing/BillingContract.kt")

    assert "SecureStore.get(KeychainKeys.DEVICE_ID)" in manager
    assert ".setObfuscatedAccountId(BillingOwnership.obfuscatedAccountId(deviceId))" in manager
    assert 'MessageDigest.getInstance("SHA-256")' in contract
    assert 'digest("tono:$deviceId"' in contract


def test_active_android_ui_uses_trial_and_tone_copy_without_zero_price():
    home = _source("src/main/java/com/tono/app/ui/HomeScreen.kt")
    settings = _source("src/main/java/com/tono/app/ui/SettingsScreen.kt")
    recipients = _source("src/main/java/com/tono/app/ui/RecipientsScreen.kt")
    manager = _source("src/main/java/com/tono/app/billing/PlayBillingManager.kt")

    active_ui = "\n".join((home, settings, recipients))
    assert "$0.00" not in active_ui
    assert '"Free' not in active_ui
    assert 'title = "Voice"' not in active_ui
    assert 'Text("Preferred voice")' not in active_ui
    assert 'Text("Voice hint (optional)")' not in active_ui
    assert "TrialOfferContract.isRealSevenDayTrial" in manager
    assert "regularPhase.formattedPrice" in manager
