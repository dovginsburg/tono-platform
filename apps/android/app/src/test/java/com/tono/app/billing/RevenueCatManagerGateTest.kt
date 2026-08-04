package com.tono.app.billing

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Build 123 — the RevenueCat canary gate, pinned as a native unit test.
 *
 * RevenueCat is Tono's first unified-subscription canary. It costs real money and
 * real trust when it regresses, so the invariants below are pinned the same way
 * [PlayBillingManagerGateTest] pins the Play gate: by reading the shipped source,
 * because the rules are about what the code does with the RevenueCat SDK and no
 * JVM unit test can drive a real purchase or a real logout.
 *
 * The five invariants (contract §5/§6):
 *   1. A purchase is impossible without the canonical account UUID (no anonymous
 *      durable paid access, no double-billing after reinstall).
 *   2. The App User ID is that canonical UUID — never the device id, email, or an
 *      anonymous RevenueCat id.
 *   3. The kill switch is dormant by default (empty publishable key ⇒ no SDK).
 *   4. Sign-out / account-switch releases the RevenueCat identity, so the next
 *      person on a shared device never inherits the previous account's customer.
 *   5. CustomerInfo is OBSERVATION only; the backend `/v1/me` projection stays the
 *      sole Pro authority, and the keyboard (:ime) never sees RevenueCat at all.
 */
class RevenueCatManagerGateTest {

    private val manager = "app/src/main/java/com/tono/app/billing/RevenueCatManager.kt"
    private val accountSheet = "app/src/main/java/com/tono/app/ui/AccountSheet.kt"
    private val gradle = "app/build.gradle.kts"

    // ── 1. Signed-out purchase is impossible ───────────────────────────────

    @Test
    fun purchaseIsImpossibleWithoutTheCanonicalAccount() {
        val code = stripComments(source(manager))
        assertTrue(
            "purchase() must refuse to buy without the canonical account UUID",
            code.contains("canonicalAccountId() == null"),
        )
        // The refusal must precede any attempt to fetch offerings / buy.
        assertTrue(
            "the account gate must precede the purchase call",
            code.indexOf("canonicalAccountId() == null") < code.indexOf("purchaseWith("),
        )
    }

    // ── 2. App User ID is the canonical account UUID, never the device ─────

    @Test
    fun appUserIdIsTheCanonicalAccountUuidNeverTheDevice() {
        val src = source(manager)
        assertTrue(
            "the RevenueCat App User ID must be the canonical account UUID",
            src.contains("SharedKeys.ACCOUNT_ID"),
        )
        assertFalse(
            "the App User ID must never be the device id",
            stripComments(src).contains("DEVICE_ID"),
        )
    }

    // ── 3. Kill switch: dormant by default ─────────────────────────────────

    @Test
    fun killSwitchIsDormantByDefault() {
        // Build 126: the publishable key is INJECTED from a Gradle property / env
        // var and defaults fail-closed to empty (no key ⇒ no SDK). Same seam the
        // cross-client pytest contract pins.
        val g = source(gradle)
        assertTrue(
            "the publishable key must be injected with a fail-closed empty default",
            g.contains("revenueCatInjected(\"revenueCatPublicSdkKey\", \"REVENUECAT_PUBLIC_SDK_KEY\", \"\")"),
        )
        // And the manager must treat empty / placeholder as "not configured".
        val code = stripComments(source(manager))
        assertTrue(
            "an empty key must leave RevenueCat dormant",
            code.contains("key.isEmpty()"),
        )
        assertTrue(
            "a placeholder key must leave RevenueCat dormant",
            code.contains("REPLACE_ME"),
        )
    }

    @Test
    fun noPublishableKeyLiteralIsCommitted() {
        assertFalse(
            "no publishable goog_ key may be committed in the manager",
            Regex("""goog_[A-Za-z0-9]{8,}""").containsMatchIn(source(manager)),
        )
        assertFalse(
            "no publishable goog_ key may be committed in the build config",
            Regex("""goog_[A-Za-z0-9]{8,}""").containsMatchIn(source(gradle)),
        )
    }

    // ── 4. Logout / account-switch releases the identity ───────────────────

    @Test
    fun signOutReleasesTheRevenueCatIdentityOnLogout() {
        // The manager must expose the release itself…
        val code = stripComments(source(manager))
        assertTrue(
            "signOut() must clear local observation state",
            code.contains("_customerInfoIsPro.value = false"),
        )
        assertTrue(
            "signOut() must call RevenueCat logOut when configured",
            code.contains("Purchases.sharedInstance.logOut()"),
        )
        // …and the account surface must actually call it on sign-out, after the
        // backend sign-out that clears the canonical ACCOUNT_ID. A manager nobody
        // calls is a leak.
        val sheet = stripComments(source(accountSheet))
        assertTrue(
            "sign-out must call RevenueCatManager.signOut()",
            sheet.contains("RevenueCatManager.signOut()"),
        )
        assertTrue(
            "RevenueCat logout must follow the backend sign-out that clears ACCOUNT_ID",
            sheet.indexOf("signOutEmail()") < sheet.indexOf("RevenueCatManager.signOut()"),
        )
    }

    // ── 5. Observation only; the keyboard never sees RevenueCat ────────────

    @Test
    fun customerInfoIsObservationOnlyNeverTheProGate() {
        val code = stripComments(source(manager))
        // The manager must never write the Pro mirror the keyboard reads.
        assertFalse(
            "RevenueCat must never write the PRO_UNLOCKED mirror",
            code.contains("PRO_UNLOCKED"),
        )
    }

    @Test
    fun theKeyboardNeverSeesRevenueCat() {
        // The IME is a separate trust boundary (KeyboardPrivacyContract). It reads
        // only the PRO_UNLOCKED mirror and must never link or name RevenueCat.
        val ime = File(repoRoot(), "apps/android/ime/src/main/java/com/tono/ime")
            .walkTopDown()
            .filter { it.extension == "kt" }
            .joinToString("\n") { it.readText() }
        for (forbidden in listOf("RevenueCat", "revenuecat", "com.revenuecat", "Purchases.")) {
            assertFalse(
                "the keyboard must never reference RevenueCat ($forbidden)",
                ime.contains(forbidden),
            )
        }
    }

    // ── Product isolation ──────────────────────────────────────────────────

    @Test
    fun theCanaryNamesNoOtherProduct() {
        val text = source(manager).lowercase()
        for (foreign in listOf("tandempaws", "tandemskills", "tandem_paws", "tandem_skills")) {
            assertFalse(
                "the RevenueCat manager must not name another product ($foreign)",
                text.contains(foreign),
            )
        }
    }

    // ── Build 126 — routing wiring ─────────────────────────────────────────

    @Test
    fun theReleaseInjectsKeyAndModeFailClosed() {
        val gradleText = stripComments(source(gradle))
        assertTrue(
            "build.gradle.kts must declare the REVENUECAT_MODE buildConfig field",
            gradleText.contains("REVENUECAT_MODE"),
        )
        // The routing mode is injected from an explicit Gradle property or env var
        // and defaults fail-closed to off — never a committed authoritative value.
        assertTrue(
            "the RevenueCat mode must be injected with a fail-closed off default",
            gradleText.contains(
                "revenueCatInjected(\"revenueCatMode\", \"REVENUECAT_MODE\", \"off\")",
            ),
        )
        // The publishable key is injected and defaults fail-closed to empty (dormant).
        assertTrue(
            "the RevenueCat publishable key must be injected with a fail-closed empty default",
            gradleText.contains(
                "revenueCatInjected(\"revenueCatPublicSdkKey\", \"REVENUECAT_PUBLIC_SDK_KEY\", \"\")",
            ),
        )
        // No publishable goog_ key literal is ever committed to the build script.
        assertFalse(
            "a RevenueCat publishable key must never be committed",
            Regex("goog_[A-Za-z0-9]{6,}").containsMatchIn(gradleText),
        )
    }

    @Test
    fun thePaywallRoutesPurchaseAndRestoreThroughTheCanaryRouter() {
        val settings = stripComments(
            source("app/src/main/java/com/tono/app/ui/SettingsScreen.kt"),
        )
        assertTrue(
            "the paywall purchase must dispatch through RevenueCatPurchaseRouter.route",
            settings.contains("RevenueCatPurchaseRouter.route("),
        )
        assertTrue(
            "the paywall restore must dispatch through RevenueCatPurchaseRouter.restoreRoute",
            settings.contains("RevenueCatPurchaseRouter.restoreRoute("),
        )
        // The authoritative branch must reconcile Pro from the backend authority —
        // RevenueCat conducts the charge, the server still projects the grant.
        assertTrue(
            "the RevenueCat route must reconcile entitlement from the backend (/v1/me)",
            settings.contains("reconcileEntitlementAfterExternalPurchase"),
        )
    }

    // ── Helpers (module-local; a unit test's user.dir is the module dir) ────

    private fun repoRoot(): File {
        var dir: File? = File(System.getProperty("user.dir")!!)
        while (dir != null && !File(dir, "apps/android/settings.gradle.kts").exists()) {
            dir = dir.parentFile
        }
        return requireNotNull(dir) { "could not locate the repository root" }
    }

    private fun source(relativeToAndroidRoot: String): String =
        File(repoRoot(), "apps/android/$relativeToAndroidRoot").readText()

    // Remove block comments FIRST (so a single- or two-line KDoc's closing
    // delimiter is never orphaned and made to swallow the code that follows),
    // then strip line comments. Good enough for these source-contract checks;
    // the manager has no line-comment marker inside a string literal.
    private fun stripComments(source: String): String =
        source
            .replace(Regex("""/\*[\s\S]*?\*/"""), " ")
            .lines()
            .joinToString("\n") { line ->
                val idx = line.indexOf("//")
                if (idx >= 0) line.take(idx) else line
            }
}
