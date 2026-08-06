package com.tono.app.ime

import com.tono.ime.keyboard.KeyLayer
import com.tono.ime.keyboard.KeyboardLayout
import com.tono.ime.keyboard.KeyboardTypingState
import com.tono.ime.keyboard.ShiftState
import com.tono.ime.keyboard.displayLabel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.max
import kotlin.math.min

/**
 * Ari's blank-letters blocker: "keyboard letters not showing up."
 *
 * The report is ambiguous between two failures, so this guards BOTH:
 *
 *   (A) VISUAL — alphabet keys render with a blank/invisible legend. Covered by
 *       label-completeness over every layer/shift state plus a real contrast
 *       computation on the shipped key text/fill colors.
 *   (B) DISPATCH — tapping a letter commits nothing into the host field. Covered
 *       by the pure typing state (what each tap yields) plus structural checks
 *       that the Compose key passes the RAW key (not the display label) and that
 *       the service actually commits it through the InputConnection.
 *
 * Pure JVM + source scanning, matching this module's existing test convention
 * (no Robolectric on the classpath). Nothing here types, logs, or retains user
 * text: the only strings involved are the static key legends.
 */
class KeyboardLetterVisibilityTest {

    // ── (A) Every key has a visible legend ────────────────────────────────

    @Test
    fun everyLetterKeyHasANonBlankLabelInEveryShiftState() {
        for (shift in ShiftState.values()) {
            for (row in KeyboardLayout.letterRows) {
                for (key in row) {
                    val label = displayLabel(key, KeyLayer.LETTERS, shift)
                    assertTrue(
                        "letter key '$key' rendered a blank label in shift=$shift — " +
                            "this is the blank-keyboard defect",
                        label.isNotBlank(),
                    )
                }
            }
        }
    }

    @Test
    fun everySymbolKeyHasANonBlankLabel() {
        for (row in KeyboardLayout.symbolRows) {
            for (key in row) {
                val label = displayLabel(key, KeyLayer.SYMBOLS, ShiftState.NONE)
                assertTrue("symbol key '$key' rendered a blank label", label.isNotBlank())
            }
        }
    }

    @Test
    fun theLetterLayerCoversTheWholeAlphabetExactlyOnce() {
        // "Letters not showing up" also covers a partially-populated layout, so
        // pin the full a–z set with no duplicates and the QWERTY row shape.
        val letters = KeyboardLayout.letterRows.flatten()
        assertEquals("the letter layer must expose 26 keys", 26, letters.size)
        assertEquals("no letter may be duplicated", 26, letters.toSet().size)
        assertEquals(
            "the alphabet must be complete",
            ('a'..'z').toSet(),
            letters.map { it.single() }.toSet(),
        )
        assertEquals(
            "QWERTY row lengths must stay 10/9/7",
            listOf(10, 9, 7),
            KeyboardLayout.letterRows.map { it.size },
        )
    }

    @Test
    fun shiftUppercasesTheVisibleLegendSoTheKeyIsNeverEmpty() {
        val q = displayLabel("q", KeyLayer.LETTERS, ShiftState.SHIFT_ONCE)
        assertEquals("Q", q)
        val caps = displayLabel("q", KeyLayer.LETTERS, ShiftState.CAPS_LOCK)
        assertEquals("Q", caps)
        assertEquals("q", displayLabel("q", KeyLayer.LETTERS, ShiftState.NONE))
    }

    // ── (A) The legend is actually readable against the key ───────────────

    @Test
    fun keyLabelContrastAgainstTheKeyFillIsReadable() {
        // A legend drawn in the key's own fill colour is invisible even though
        // the string is non-blank — the other way this defect presents. Parse
        // the shipped colours out of the Compose source and compute the real
        // WCAG contrast ratio rather than trusting the constants by eye.
        val screen = imeSource("ui/KeyboardScreen.kt")

        val keyFill = hexColor(screen, "KeyFill")
        assertNotNull("KeyboardScreen must define a KeyFill colour", keyFill)

        // CharKey draws its label with Color.White.
        val charKey = screen.substringAfter("private fun CharKey(")
            .substringBefore("private fun SpecialKey(")
        assertTrue(
            "CharKey must draw its label in an explicit opaque colour",
            Regex("""Text\(\s*label\s*,\s*color\s*=\s*Color\.White""").containsMatchIn(charKey),
        )
        assertTrue(
            "CharKey's label must not be alpha-faded into invisibility",
            !Regex("""Text\(\s*label\s*,\s*color\s*=\s*Color\.White\.copy""").containsMatchIn(charKey),
        )

        val ratio = contrastRatio(0xFFFFFF, keyFill!!)
        assertTrue(
            "key legend contrast ${"%.2f".format(ratio)}:1 is below the 4.5:1 readable floor",
            ratio >= 4.5,
        )
    }

    // ── (B) A tapped letter produces the character ────────────────────────

    @Test
    fun tappingEveryLetterYieldsThatLetter() {
        val state = KeyboardTypingState()
        state.resetForNewField(autoCapitalize = false) // isolate casing from auto-cap
        for (key in KeyboardLayout.letterRows.flatten()) {
            assertEquals(
                "tapping '$key' must commit '$key'",
                key,
                state.commitFor(key),
            )
        }
    }

    @Test
    fun theComposeKeyCommitsTheRawKeyNotTheDisplayLabel() {
        // Passing the display label would double-apply shift (committing "Q"
        // through a state machine that uppercases again) and would break the
        // symbol layer. The raw key is the contract.
        val screen = imeSource("ui/KeyboardScreen.kt")
        val charKey = screen.substringAfter("private fun CharKey(")
            .substringBefore("private fun SpecialKey(")
        assertTrue(
            "CharKey must dispatch the raw key to onKey",
            Regex("""clickable\s*\{\s*onKey\(raw\)\s*\}""").containsMatchIn(charKey),
        )
        assertTrue(
            "the character rows must render a CharKey per key",
            Regex("""row\.forEach\s*\{\s*key\s*->""").containsMatchIn(screen),
        )
    }

    @Test
    fun theServiceCommitsTappedCharactersThroughTheInputConnection() {
        // The dispatch half of the blocker: a rendered key that never reaches
        // the host editor is still "letters not showing up" to a tester.
        val service = imeSource("TonoImeService.kt")
        val handler = service.substringAfter("private fun onCharacterKey(")
            .substringBefore("private fun onBackspace(")
        assertTrue(
            "onCharacterKey must resolve the current InputConnection",
            handler.contains("currentInputConnection"),
        )
        assertTrue(
            "onCharacterKey must commit the state machine's character",
            Regex("""commitText\(\s*viewModel\.onCharacterKey\(key\)\s*,\s*1\s*\)""")
                .containsMatchIn(handler),
        )
        assertTrue(
            "the Compose keyboard must be wired to the service's key handler",
            Regex("""onKey\s*=\s*::onCharacterKey""").containsMatchIn(service),
        )
    }

    @Test
    fun typingStaysEnabledInSecureFieldsWhileReadingIsRefused() {
        // Preserve the shipped privacy posture: secure fields must still TYPE
        // (letters visible + committed); only field READING is disabled.
        val service = imeSource("TonoImeService.kt")
        val sync = service.substringAfter("private fun syncDraftFromEditor()")
            .substringBefore("private fun insertFullText(")
        assertTrue(
            "the draft sync must bail out of secure fields",
            sync.contains("secureField.value") && sync.contains("return"),
        )
        val handler = service.substringAfter("private fun onCharacterKey(")
            .substringBefore("private fun onBackspace(")
        assertTrue(
            "onCharacterKey must NOT gate typing on the secure-field flag",
            !handler.contains("secureField"),
        )
    }

    // ── helpers ───────────────────────────────────────────────────────────

    private fun repoRoot(): File {
        var dir: File? = File(System.getProperty("user.dir")!!)
        while (dir != null && !File(dir, "apps/android/settings.gradle.kts").exists()) {
            dir = dir.parentFile
        }
        return requireNotNull(dir) { "could not locate the repository root" }
    }

    private fun imeSource(relative: String): String =
        File(repoRoot(), "apps/android/ime/src/main/java/com/tono/ime/$relative").readText()

    /** `private val Name = Color(0xFFRRGGBB)` → 0xRRGGBB. */
    private fun hexColor(source: String, name: String): Int? =
        Regex("""val\s+$name\s*=\s*Color\(0x[fF]{2}([0-9a-fA-F]{6})\)""")
            .find(source)?.groupValues?.get(1)?.toInt(16)

    private fun contrastRatio(rgb1: Int, rgb2: Int): Double {
        val l1 = relativeLuminance(rgb1)
        val l2 = relativeLuminance(rgb2)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private fun relativeLuminance(rgb: Int): Double {
        fun channel(c: Int): Double {
            val s = c / 255.0
            return if (s <= 0.03928) s / 12.92 else Math.pow((s + 0.055) / 1.055, 2.4)
        }
        val r = channel((rgb shr 16) and 0xFF)
        val g = channel((rgb shr 8) and 0xFF)
        val b = channel(rgb and 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
