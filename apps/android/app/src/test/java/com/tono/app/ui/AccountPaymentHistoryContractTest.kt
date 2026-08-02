package com.tono.app.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Source-contract tests for the account / payment-history / password work on
 * Android. They read the shipped source (the same approach as
 * PlayBillingManagerGateTest) because these invariants are about what the UI
 * and storage code do, and no JVM unit test can drive Compose or the Android
 * SharedPreferences these touch.
 */
class AccountPaymentHistoryContractTest {

    @Test
    fun passwordFieldHasAnAccessibleShowHideToggle() {
        val sheet = source("app/src/main/java/com/tono/app/ui/AccountSheet.kt")
        // A real reveal control: a state flag flips the masking, and the icon
        // button carries a TalkBack contentDescription for both states.
        assertTrue("password visibility state", sheet.contains("passwordVisible"))
        assertTrue(
            "reveal flips the visual transformation",
            sheet.contains("if (passwordVisible)") && sheet.contains("VisualTransformation.None"),
        )
        assertTrue("show label", sheet.contains("\"Show password\""))
        assertTrue("hide label", sheet.contains("\"Hide password\""))
    }

    @Test
    fun signOutClearsDeviceLocalPersonalCachesForAccountIsolation() {
        val backend = source("shared/src/main/java/com/tono/shared/network/TonoBackend.kt")
        assertTrue(
            "sign-out purges personal caches",
            backend.contains("SharedStore.clearPersonalData()"),
        )
        val store = source("shared/src/main/java/com/tono/shared/storage/SharedStore.kt")
        assertTrue("clearPersonalData exists", store.contains("fun clearPersonalData()"))
        // It must remove the personal content keys...
        for (key in listOf("DRAFT_HISTORY", "RECENT_SESSIONS", "MEMORY_FACTS", "RECIPIENTS", "AXIS_WEIGHTS")) {
            assertTrue("clears $key", store.contains("SharedKeys.$key"))
        }
        // ...but NOT device identity/session or app settings.
        val body = store.substringAfter("fun clearPersonalData()")
            .substringBefore("\n    }")
        assertFalse("must not clear identity", body.contains("ACCOUNT_ID"))
        assertFalse("must not clear backend url", body.contains("BACKEND_URL"))
        assertFalse("must not clear onboarding", body.contains("ONBOARDING_DONE"))
    }

    @Test
    fun paymentHistoryReadsOwnerScopedEndpointWithNoRawIdentifiers() {
        val backend = source("shared/src/main/java/com/tono/shared/network/TonoBackend.kt")
        assertTrue(
            "owner-scoped endpoint, no account-id parameter",
            backend.contains("get(\"/v1/account/payment-history\")"),
        )
        val section = source("app/src/main/java/com/tono/app/ui/PaymentHistorySection.kt")
        // The wire model + UI must not surface raw provider/transaction ids.
        assertFalse(section.contains("original_transaction_id"))
        assertFalse(section.contains("app_account_token"))
        // And it renders a human status, not the internal ownership token alone.
        assertTrue(section.contains("statusLabel"))
    }

    @Test
    fun paymentHistorySectionIsMountedInSettings() {
        val settings = source("app/src/main/java/com/tono/app/ui/SettingsScreen.kt")
        assertTrue(settings.contains("PaymentHistorySection()"))
    }

    @Test
    fun paymentHistoryRendersVerifiedAmountOnlyWhenNormalized() {
        val model = source("shared/src/main/java/com/tono/shared/network/TonoBackend.kt")
        // The wire model carries the normalized amount, defaulted null.
        assertTrue(model.contains("amount_minor"))
        val section = source("app/src/main/java/com/tono/app/ui/PaymentHistorySection.kt")
        // The price is gated on BOTH minor units and currency being present —
        // never fabricated for a provider we didn't normalize.
        assertTrue("guards on amountMinor", section.contains("item.amountMinor ?: return null"))
        assertTrue("guards on currency", section.contains("item.currency ?: return null"))
        assertTrue("renders a plan price line", section.contains("plan price"))
    }

    @Test
    fun imeIsNowARealTypingKeyboardWithExplicitTapCoach() {
        val screen = source("ime/src/main/java/com/tono/ime/ui/KeyboardScreen.kt")
        // The IME now types — it renders a real QWERTY from the shared layout —
        // so the earlier "rewrite companion, not a full keyboard" copy is gone.
        assertTrue("renders real key rows", screen.contains("KeyboardLayout.rows(layer)"))
        assertTrue("has a character key that commits", screen.contains("onKey(raw)"))
        assertFalse(
            "the temporary 'not a full keyboard' copy is removed now that it types",
            screen.contains("not a full keyboard"),
        )
        assertFalse(
            "the temporary 'rewrite companion' copy is removed",
            screen.contains("rewrite companion"),
        )
        // Coach/Read remain explicit, tap-only actions layered on top.
        assertTrue("Coach stays explicit-tap", screen.contains("viewModel.runCoach()"))
        assertTrue("Read stays explicit-tap", screen.contains("viewModel.runRead()"))
    }

    private fun repoRoot(): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".")
        while (dir != null && !File(dir, "apps/android/settings.gradle.kts").exists()) {
            dir = dir.parentFile
        }
        return requireNotNull(dir) { "could not locate the repository root" }
    }

    private fun source(relativeToAndroidRoot: String): String =
        File(repoRoot(), "apps/android/$relativeToAndroidRoot").readText()
}
