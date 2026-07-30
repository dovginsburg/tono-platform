package com.tono.app.ui

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class PromoCodeSurfaceContractTest {
    private fun source(path: String): String = File(path).readText()

    @Test
    fun settingsShowsAReachablePromoInputAndApplyAction() {
        val account = source("app/src/main/java/com/tono/app/ui/AccountSheet.kt")
        val settings = source("app/src/main/java/com/tono/app/ui/SettingsScreen.kt")
        assertTrue(account.contains("""Text("Promo code")"""))
        assertTrue(account.contains("""Text(if (state.isApplying) "Applying…" else "Apply")"""))
        assertTrue(account.contains("enabled = isAuthorized && state.canApply"))
        assertTrue(settings.contains("PromoCodeRows("))
    }

    @Test
    fun successRefreshesVisibleAccountAndBillingState() {
        val settings = source("app/src/main/java/com/tono/app/ui/SettingsScreen.kt")
        val callback = settings.substringAfter("PromoCodeRows(").substringBefore("),")
        assertTrue(callback.contains("accountRevision++"))
        assertTrue(callback.contains("PlayBillingManager.refresh()"))
    }
}
