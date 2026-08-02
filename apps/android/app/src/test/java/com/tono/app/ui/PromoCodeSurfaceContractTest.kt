package com.tono.app.ui

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class PromoCodeSurfaceContractTest {
    /** `user.dir` for a Gradle unit test is the module directory (`app/`), so a
     *  bare relative path doubles the `app/` segment. Resolve every source path
     *  from the repository root, mirroring PlayBillingManagerGateTest. */
    private fun repoRoot(): File {
        var dir: File? = File(System.getProperty("user.dir")!!)
        while (dir != null && !File(dir, "apps/android/settings.gradle.kts").exists()) {
            dir = dir.parentFile
        }
        return requireNotNull(dir) { "could not locate the repository root" }
    }

    private fun source(path: String): String = File(repoRoot(), "apps/android/$path").readText()

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
