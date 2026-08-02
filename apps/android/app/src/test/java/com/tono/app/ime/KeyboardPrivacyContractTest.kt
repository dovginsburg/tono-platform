package com.tono.app.ime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Regression contracts for the two properties the typing keyboard must never
 * lose: typing stays local (never logged, retained, or sent), and Coach/Read
 * stay explicit-tap only. Source-level, matching the other IME contracts —
 * these invariants are about which calls appear on the typing path, which no
 * JVM behavioural test can assert without a device.
 */
class KeyboardPrivacyContractTest {

    // ─── Typing is local ──────────────────────────────────────────────────

    @Test
    fun typingStateMachineHasNoNetworkOrAnalyticsDependencies() {
        val src = ime("keyboard/KeyboardTypingState.kt")
        // A pure state machine: it must not import the backend, analytics, or
        // storage layers, so a keystroke physically cannot be logged or sent.
        assertFalse("no shared-layer imports", src.contains("import com.tono.shared"))
        assertFalse(src.contains("TonoAnalytics"))
        assertFalse(src.contains("TonoBackend"))
        assertFalse(src.contains("CrashReporter"))
    }

    @Test
    fun theInputConnectionTypingPathNeverLogsOrTransmits() {
        val src = ime("TonoImeService.kt")
        // Isolate the typing section (character/backspace/return/auto-cap).
        val typingBlock = src.substringAfter("Typing (InputConnection)")
            .substringBefore("Private helpers")
        assertTrue("typing section present", typingBlock.isNotBlank())
        for (forbidden in listOf("TonoAnalytics", "track(", "TonoBackend", "logAxisWin", "analyze(")) {
            assertFalse(
                "the typing path must not call $forbidden — keystrokes stay on device",
                typingBlock.contains(forbidden),
            )
        }
        // The character handler commits locally and reads at most 2 chars for
        // auto-cap; it must never read the whole field for typing.
        assertTrue("commits locally", typingBlock.contains("ic.commitText(viewModel.onCharacterKey(key)"))
        assertTrue("auto-cap reads a bounded window", src.contains("getTextBeforeCursor(2, 0)"))
    }

    @Test
    fun viewModelTypingHelpersDoNotEmitAnalytics() {
        val src = ime("CoachViewModel.kt")
        val typingBlock = src.substringAfter("Typing surface state")
            .substringBefore("C4: detect edit-after-insert")
        assertTrue(typingBlock.isNotBlank())
        assertFalse(
            "shift/layer/character helpers must not track anything",
            typingBlock.contains("TonoAnalytics") || typingBlock.contains("track("),
        )
    }

    // ─── Coach / Read stay explicit-tap ───────────────────────────────────

    @Test
    fun coachAndReadFireOnlyFromExplicitButtons() {
        val src = ime("ui/KeyboardScreen.kt")
        // The only call sites are the Coach/Read buttons in the Coach strip.
        assertTrue("Coach button runs runCoach", src.contains("onCoach           = { viewModel.runCoach() }"))
        assertTrue("Read button runs runRead", src.contains("onRead            = { viewModel.runRead() }"))
        // A character-key press must never be wired to analysis.
        assertFalse("onKey never coaches", charKeyCoaches(src))
    }

    @Test
    fun secureFieldsHideCoachAndReadButStillType() {
        val screen = ime("ui/KeyboardScreen.kt")
        assertTrue("branches on secureField", screen.contains("if (secureField)"))
        // In the secure branch the CoachStrip is not rendered; instead an
        // honest note is shown, and the character rows still render below.
        assertTrue(
            "secure note explains typing stays local",
            screen.contains("Tono types on your device"),
        )
        // The service keeps typing in secure fields — it does not bail out of
        // onStartInput for password fields, it only flags them.
        val service = ime("TonoImeService.kt")
        assertTrue("secure is a flag, not a hard block", service.contains("secure      = secure"))
        assertFalse(
            "typing must not be disabled in secure fields",
            service.contains("if (isSecure) return") || service.contains("if (secure) return"),
        )
    }

    // ─── Honest positioning ───────────────────────────────────────────────

    @Test
    fun theKeyboardTypesAndNoLongerClaimsToBeARewriteCompanion() {
        val screen = ime("ui/KeyboardScreen.kt")
        // It renders a real QWERTY from the shared layout.
        assertTrue("renders real key rows", screen.contains("KeyboardLayout.rows(layer)"))
        assertTrue("has a character key that commits", screen.contains("onKey(raw)"))
        // The temporary honest-companion copy is gone now that it types.
        assertFalse("no 'not a full keyboard' copy", screen.contains("not a full keyboard"))
        assertFalse("no 'rewrite companion' copy", screen.contains("rewrite companion"))
        assertFalse(
            "no 'rewrites what's already in the field' copy",
            screen.contains("rewrites what's already in the field"),
        )
    }

    // A guard for the negative assertion above: true only if a character-key
    // press is wired to coach, which must never happen.
    private fun charKeyCoaches(src: String): Boolean =
        Regex("""onKey\s*=\s*\{[^}]*runCoach""").containsMatchIn(src)

    private fun repoRoot(): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".")
        while (dir != null && !File(dir, "apps/android/settings.gradle.kts").exists()) {
            dir = dir.parentFile
        }
        return requireNotNull(dir) { "could not locate the repository root" }
    }

    private fun ime(relative: String): String =
        File(repoRoot(), "apps/android/ime/src/main/java/com/tono/ime/$relative").readText()
}
