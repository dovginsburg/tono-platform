package com.tono.app.billing

import com.tono.shared.storage.AccountIdentity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Build 114 — the Android purchase gate and the consumer copy around it.
 *
 * Two things are pinned here, both of which cost real money when they regress:
 *
 *   1. A purchase may only START on a device holding a RECOVERABLE canonical
 *      account (a confirmed address plus the account UUID). Binding Play's
 *      `obfuscatedAccountId` to an anonymous device-only account means the
 *      purchase cannot be restored after a reinstall, and the person pays twice.
 *   2. Being eligible to buy is not being Pro. Only the server's verdict grants
 *      entitlement — a confirmed address never does.
 *
 * The source-reading tests below mirror the iOS `Build101RevenueTests` approach:
 * they read the shipped file, because the invariant is about what the code does
 * with Play's builder, and no unit test can drive a real billing flow.
 */
class PlayBillingManagerGateTest {

    // ── The gate rule ──────────────────────────────────────────────────────

    @Test
    fun purchaseRequiresBothAConfirmedAddressAndACanonicalAccount() {
        val account = "11111111-2222-3333-4444-555555555555"
        assertTrue(AccountIdentity.isIdentified("person@example.com", account))
        assertFalse("an anonymous device may not buy", AccountIdentity.isIdentified(null, account))
        assertFalse("an address with no account has nothing to bind", AccountIdentity.isIdentified("person@example.com", null))
        assertFalse(AccountIdentity.isIdentified(null, null))
        assertFalse("blank is not a value", AccountIdentity.isIdentified("", account))
        assertFalse(AccountIdentity.isIdentified("person@example.com", "   "))
    }

    // ── A confirmed address is never an entitlement ─────────────────────────

    @Test
    fun entitlementIgnoresIdentityEntirelyAndReadsOnlyTheServerVerdict() {
        // Every combination of local identity state must leave the entitlement
        // answer exactly equal to what the server said.
        for (backendIsPro in listOf(true, false)) {
            for (hasPlayPurchase in listOf(true, false)) {
                assertEquals(
                    "entitlement must equal the server's verdict alone",
                    backendIsPro,
                    EntitlementDecision.isPro(hasPlayPurchase, backendIsPro),
                )
            }
        }
    }

    @Test
    fun aFullyIdentifiedDeviceIsStillNotProWithoutTheServerSayingSo() {
        assertTrue(
            AccountIdentity.isIdentified(
                "person@example.com", "11111111-2222-3333-4444-555555555555"
            )
        )
        assertFalse(
            "confirming an address must never grant paid access",
            EntitlementDecision.isPro(hasActivePlayPurchase = true, backendIsPro = false),
        )
    }

    // ── The shipped source honours the gate ────────────────────────────────

    @Test
    fun theShippedPurchasePathGatesOnIdentityBeforeBindingTheOwnershipId() {
        val source = source("app/src/main/java/com/tono/app/billing/PlayBillingManager.kt")
        assertTrue(
            "purchase must gate on the identity rule",
            source.contains("SecureStore.isIdentifiedAccount(accountId)"),
        )
        assertTrue(
            "the canonical account UUID must be bound as Play's ownership id",
            source.contains("setObfuscatedAccountId(accountId)"),
        )
        // The gate has to come BEFORE the binding, or it gates nothing.
        assertTrue(
            "the identity gate must precede the ownership binding",
            source.indexOf("isIdentifiedAccount(accountId)") <
                source.indexOf("setObfuscatedAccountId(accountId)"),
        )
        // Never the device id: a device id is not a person, and it does not
        // survive a reinstall.
        assertFalse(
            "the ownership id must never be sourced from the device id",
            source.lines().any {
                it.contains("setObfuscatedAccountId") && it.contains("DEVICE_ID")
            },
        )
    }

    @Test
    fun noBillingFailureRendersAProviderDiagnostic() {
        // Comments are dropped first, so prose explaining why `debugMessage` is
        // banned cannot itself fail the ban.
        val code = stripComments(source("app/src/main/java/com/tono/app/billing/PlayBillingManager.kt"))
        // `debugMessage` is Google's developer-facing string: response codes,
        // internal reasons, sometimes identifiers. It must not reach a screen.
        assertFalse(
            "Play's debugMessage must not be rendered to a person",
            code.contains("debugMessage"),
        )
        // Nor may a caught failure's own text be interpolated into copy.
        for (leak in listOf(
            "error.message", "\${error.message}", "it.message", "throwable.message",
            "e.message", "backend unavailable", "localizedMessage", "stackTraceToString",
        )) {
            assertFalse(
                "consumer copy must not interpolate a raw failure ($leak)",
                code.contains(leak),
            )
        }
    }

    @Test
    fun billingCopyNamesNoImplementationDetail() {
        val forbidden = listOf(
            "backend", "endpoint", "api key", "bearer", "supabase", "http", "://",
            "non-2xx", "transport", "proxy", "token",
        )
        // Judged on what a person READS — the sentences assigned to the UI
        // state's `message` and `error` — not on every literal in the file. The
        // Play manage-subscriptions address is a destination the app navigates
        // to, which is the request it builds rather than copy anyone reads.
        val rendered = renderedBillingCopy(
            source("app/src/main/java/com/tono/app/billing/PlayBillingManager.kt")
        )
        assertTrue("the billing copy surface must not be empty", rendered.size >= 8)
        for (sentence in rendered) {
            val haystack = sentence.lowercase()
            for (term in forbidden) {
                assertFalse(
                    "billing copy names “$term”: $sentence",
                    haystack.contains(term),
                )
            }
        }
    }

    @Test
    fun theRefusalTellsThePersonWhatToDoAndDoesNotReadAsAPaywall() {
        val source = source("app/src/main/java/com/tono/app/billing/PlayBillingManager.kt")
        val refusal =
            "Sign in with your email first so your subscription follows you if you reinstall."
        assertTrue(
            "the gate's refusal must name the next step",
            source.contains(refusal),
        )
        // It mentions a subscription because it is ABOUT the subscription
        // following them — but it must not imply a payment is required to sign in.
        assertFalse(refusal.lowercase().contains("purchase required"))
        assertFalse(refusal.lowercase().contains("upgrade"))
    }

    // ── Release identity ───────────────────────────────────────────────────

    @Test
    fun androidShipsBuild120() {
        val gradle = source("app/build.gradle.kts")
        assertTrue(
            "Android must declare versionCode 120 for account coupon redemption",
            Regex("""versionCode\s*=\s*120""").containsMatchIn(gradle),
        )
        assertTrue(
            "the marketing version must stay 1.1",
            Regex("""versionName\s*=\s*"1\.1"""").containsMatchIn(gradle),
        )
    }

    @Test
    fun android120PreservesItsCodeWhileIosAdvancesToReviewedBuild121() {
        // Google Play Build 120 remains immutable. The reviewed convergence
        // changes shipping iOS auth and StoreKit behavior, so iOS advances to
        // the next cross-platform release identifier without changing Android.
        val bumpScript = File(repoRoot(), "apps/ios/Scripts/bump-build.sh")
        if (!bumpScript.exists()) return  // Android may be built without the iOS tree present.
        val expected = bumpScript.readLines()
            .firstOrNull { it.trimStart().startsWith("EXPECTED_BUILD=") }
            ?.substringAfter('=')
            ?.trim('"', '\'', ' ')
        assertEquals(
            "iOS convergence must use the next valid Build 121 authority",
            "121",
            expected,
        )
    }

    // ── The account surface exists and is reachable ────────────────────────

    @Test
    fun settingsOffersTheWholeAccountLifecycle() {
        val settings = source("app/src/main/java/com/tono/app/ui/SettingsScreen.kt")
        assertTrue("Settings must present the account sheet", settings.contains("EmailAccountSheet"))
        assertTrue("Settings must show the account rows", settings.contains("EmailAccountRows"))
        assertTrue(
            "a sign-in must refresh the entitlement this device already owns",
            settings.contains("PlayBillingManager.refresh()"),
        )

        val sheet = source("app/src/main/java/com/tono/app/ui/AccountSheet.kt")
        for (capability in listOf(
            "registerWithEmail",       // sign up
            "signInWithEmail",         // log in
            "resendVerification",      // resend the confirmation
            "requestPasswordReset",    // reset / recovery
            "signOutEmail",            // sign out
        )) {
            assertTrue(
                "the account surface must offer $capability",
                sheet.contains(capability),
            )
        }
        // Confirmation is a real destination, not a toast: a person leaves for an
        // inbox and may come back after closing the app.
        assertTrue(sheet.contains("Step.ConfirmSent"))
    }

    @Test
    fun theAccountSurfaceRendersOnlyMappedCopy() {
        val sheet = source("app/src/main/java/com/tono/app/ui/AccountSheet.kt")
        assertTrue(
            "every sentence must come from the one mapper",
            sheet.contains("EmailAccountCopy.message("),
        )
        for (leak in listOf(
            ".message}", "failure.message", "error.message", "it.localizedMessage",
            "stackTraceToString", "printStackTrace",
        )) {
            assertFalse(
                "the account surface must not render a raw failure ($leak)",
                sheet.contains(leak),
            )
        }
    }

    @Test
    fun noSecretIsEverPersisted() {
        val secureStore = source("shared/src/main/java/com/tono/shared/storage/SecureStore.kt")
        // There must be no key for a password or an auth-provider token: a
        // password is typed, sent once, and forgotten; links live in the inbox.
        for (forbiddenKey in listOf(
            "PASSWORD", "PASSWD", "ACCESS_TOKEN", "REFRESH_TOKEN",
            "VERIFICATION_TOKEN", "RESET_TOKEN",
        )) {
            assertFalse(
                "SecureStore must never define a $forbiddenKey key",
                Regex("""const\s+val\s+$forbiddenKey\s*=""").containsMatchIn(secureStore),
            )
        }
        val sheet = source("app/src/main/java/com/tono/app/ui/AccountSheet.kt")
        assertFalse(
            "the account surface must never write the typed password anywhere",
            sheet.contains("SecureStore.set") || sheet.contains("SharedStore.putString"),
        )
    }

    @Test
    fun theKeyboardReceivesOnlyMinimalSharedState() {
        // The IME is a separate surface with its own trust boundary. It may learn
        // whether Pro is active; it must never learn the person's address, and it
        // must not be able to start an account operation.
        val ime = File(repoRoot(), "apps/android/ime/src/main/java/com/tono/ime")
            .walkTopDown()
            .filter { it.extension == "kt" }
            .joinToString("\n") { it.readText() }
        for (forbidden in listOf(
            "SIGNED_IN_EMAIL", "signedInEmail", "registerWithEmail", "signInWithEmail",
            "requestPasswordReset", "resendVerification", "EmailAccountSheet",
        )) {
            assertFalse(
                "the keyboard must not reach account state or actions ($forbidden)",
                ime.contains(forbidden),
            )
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    /** `user.dir` for a Gradle unit test is the module directory (`app/`). */
    private fun repoRoot(): File {
        var dir: File? = File(System.getProperty("user.dir")!!)
        while (dir != null && !File(dir, "apps/android/settings.gradle.kts").exists()) {
            dir = dir.parentFile
        }
        return requireNotNull(dir) { "could not locate the repository root" }
    }

    private fun source(relativeToAndroidRoot: String): String =
        File(repoRoot(), "apps/android/$relativeToAndroidRoot").readText()

    /** Double-quoted literals, so a comment about a backend is not mistaken for copy. */
    private fun stringLiterals(source: String): List<String> =
        Regex("\"([^\"\\\\\\n]*(?:\\\\.[^\"\\\\\\n]*)*)\"")
            .findAll(stripComments(source))
            .map { it.groupValues[1] }
            .toList()

    /**
     * The sentences that actually reach a person: literals on a line assigning
     * the billing UI state's `message` or `error`, plus the `showBillingError`
     * prefixes, which become the `error` verbatim.
     */
    private fun renderedBillingCopy(source: String): List<String> =
        stripComments(source)
            .lines()
            .filter {
                val line = it.trim()
                line.startsWith("message =") || line.startsWith("error =") ||
                    line.contains("showBillingError(result,")
            }
            .flatMap { stringLiterals(it) }
            .filter { it.isNotBlank() }

    private fun stripComments(source: String): String =
        source.lines()
            .filterNot { it.trimStart().startsWith("//") || it.trimStart().startsWith("*") }
            .joinToString("\n")
            .replace(Regex("""/\*[\s\S]*?\*/"""), "")
}
