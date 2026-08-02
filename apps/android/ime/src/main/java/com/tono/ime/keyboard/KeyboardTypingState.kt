package com.tono.ime.keyboard

/** Which key layer is on screen. Mirrors iOS `KeyboardLayoutMode`. */
enum class KeyLayer { LETTERS, SYMBOLS }

/** Shift machine state. Mirrors iOS `ShiftState` (none / shiftOnce / capsLock). */
enum class ShiftState { NONE, SHIFT_ONCE, CAPS_LOCK }

/**
 * Pure, framework-free typing state for the Tono Android keyboard.
 *
 * Mirrors the iOS `KeyboardModel` layout/shift machine in
 * `ios/KeyboardExtension/KeyboardRootView.swift` (and the live
 * `KeyboardViewController` shift machine) so both platforms shift, caps-lock,
 * auto-capitalize and switch layers identically. Those iOS comments even name a
 * `TonoInputMethodService.onShiftTapped` parity that Android never actually
 * shipped — this closes that gap.
 *
 * There are deliberately no Android imports here: the class is a plain
 * state machine that the IME service turns into `InputConnection` calls, which
 * makes every transition JVM-unit-testable without a device or Robolectric.
 * It never reads, stores, or emits the characters that flow through it — the
 * only text it touches is the single key label handed to [commitFor], returned
 * straight back for the service to commit locally.
 */
class KeyboardTypingState {

    var layer: KeyLayer = KeyLayer.LETTERS
        private set

    /** A fresh field starts capitalized, exactly like iOS auto-cap at field start. */
    var shift: ShiftState = ShiftState.SHIFT_ONCE
        private set

    private var lastShiftTapAtMs: Long = Long.MIN_VALUE

    /**
     * The exact text to commit for a tapped key, honoring shift + layer.
     *
     * Only real letters in the LETTERS layer are cased; digits, symbols,
     * whitespace and multi-char labels commit verbatim. A one-shot shift is
     * consumed only when an actual letter is produced (parity with iOS
     * `insertCharacter`), so pressing shift then space keeps the pending capital.
     */
    fun commitFor(key: String): String {
        if (isCasableLetter(key)) {
            val out = if (shift != ShiftState.NONE) key.uppercase() else key.lowercase()
            if (shift == ShiftState.SHIFT_ONCE) shift = ShiftState.NONE
            return out
        }
        return key
    }

    /**
     * Shift-key tap. A single tap arms one-shot shift; a second tap within
     * [DOUBLE_TAP_WINDOW_MS] promotes it to caps-lock; a tap from caps-lock
     * releases it. Mirrors iOS `onShiftTapped`. [nowMs] is injected so the
     * double-tap window is deterministic in tests.
     */
    fun onShiftTapped(nowMs: Long) {
        // Guard the sentinel: without a prior tap there is no double-tap, and
        // subtracting Long.MIN_VALUE would overflow into a spurious "double".
        val isDoubleTap = lastShiftTapAtMs != Long.MIN_VALUE &&
            nowMs - lastShiftTapAtMs < DOUBLE_TAP_WINDOW_MS
        lastShiftTapAtMs = nowMs
        shift = when {
            shift == ShiftState.SHIFT_ONCE && isDoubleTap -> ShiftState.CAPS_LOCK
            shift == ShiftState.CAPS_LOCK                 -> ShiftState.NONE
            shift == ShiftState.NONE                      -> ShiftState.SHIFT_ONCE
            else                                          -> ShiftState.NONE
        }
    }

    /**
     * Flip letters ↔ symbols. Does NOT touch shift — returning to letters from
     * the symbol layer must preserve the user's caps-lock intent, matching iOS
     * `toggleLayoutMode`.
     */
    fun toggleLayer() {
        layer = if (layer == KeyLayer.LETTERS) KeyLayer.SYMBOLS else KeyLayer.LETTERS
    }

    /**
     * Re-arm one-shot shift at sentence / field starts, given the text
     * immediately before the cursor. Skipped while caps-lock is engaged so an
     * explicit lock is never silently released. Mirrors iOS
     * `applyAutoCapitalizationIfNeeded`.
     *
     * The service passes at most the two characters before the cursor; nothing
     * is retained here.
     */
    fun applyAutoCapitalization(textBeforeCursor: String) {
        if (shift == ShiftState.CAPS_LOCK) return
        val lastTwo = textBeforeCursor.takeLast(2)
        val shouldCapitalize = lastTwo.isEmpty() ||
            lastTwo.endsWith("\n") ||
            SENTENCE_END.containsMatchIn(lastTwo)
        shift = if (shouldCapitalize) ShiftState.SHIFT_ONCE else ShiftState.NONE
    }

    /**
     * Reset for a newly focused field: letters layer, and shift armed only when
     * the field wants sentence capitalization. Clears the double-tap timer so a
     * stale shift tap from a previous field can't promote to caps-lock.
     */
    fun resetForNewField(autoCapitalize: Boolean) {
        layer = KeyLayer.LETTERS
        shift = if (autoCapitalize) ShiftState.SHIFT_ONCE else ShiftState.NONE
        lastShiftTapAtMs = Long.MIN_VALUE
    }

    private fun isCasableLetter(key: String): Boolean =
        layer == KeyLayer.LETTERS && key.length == 1 && key[0].isLetter()

    companion object {
        /** iOS uses 0.4s for the caps-lock double-tap window; keep them equal. */
        const val DOUBLE_TAP_WINDOW_MS = 400L
        private val SENTENCE_END = Regex("[.!?]\\s$")
    }
}
