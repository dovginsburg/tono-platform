package com.tono.ime.keyboard

/**
 * Static key rows and label helpers for the Tono keyboard. Kept
 * framework-free and identical to the iOS arrays in
 * `KeyboardViewController.swift` / `KeyboardRootView.swift` so the two
 * keyboards render the same characters in the same order.
 */
object KeyboardLayout {

    val letterRows: List<List<String>> = listOf(
        listOf("q", "w", "e", "r", "t", "y", "u", "i", "o", "p"),
        listOf("a", "s", "d", "f", "g", "h", "j", "k", "l"),
        listOf("z", "x", "c", "v", "b", "n", "m"),
    )

    val symbolRows: List<List<String>> = listOf(
        listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "0"),
        listOf("-", "/", ":", ";", "(", ")", "$", "&", "@", "\""),
        listOf(".", ",", "?", "!", "'"),
    )

    fun rows(layer: KeyLayer): List<List<String>> =
        if (layer == KeyLayer.LETTERS) letterRows else symbolRows
}

/** Glyph shown on the shift key for each state. */
fun shiftGlyph(shift: ShiftState): String = when (shift) {
    ShiftState.NONE       -> "⇧"
    ShiftState.SHIFT_ONCE -> "⬆"
    ShiftState.CAPS_LOCK  -> "⇪"
}

/** TalkBack label for the shift key for each state. */
fun shiftAccessibilityLabel(shift: ShiftState): String = when (shift) {
    ShiftState.NONE       -> "Shift"
    ShiftState.SHIFT_ONCE -> "Shift on, one capital letter"
    ShiftState.CAPS_LOCK  -> "Caps lock on, tap to release"
}

/**
 * The label a key shows in the current state: letters uppercase when shift is
 * engaged, everything else verbatim. Pure so the Compose layer can derive it
 * from observed [KeyLayer]/[ShiftState] without touching typing state.
 */
fun displayLabel(key: String, layer: KeyLayer, shift: ShiftState): String =
    if (layer == KeyLayer.LETTERS && key.length == 1 && key[0].isLetter() && shift != ShiftState.NONE)
        key.uppercase()
    else
        key
