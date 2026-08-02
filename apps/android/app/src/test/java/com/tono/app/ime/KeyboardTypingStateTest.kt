package com.tono.app.ime

import com.tono.ime.keyboard.KeyLayer
import com.tono.ime.keyboard.KeyboardLayout
import com.tono.ime.keyboard.KeyboardTypingState
import com.tono.ime.keyboard.ShiftState
import com.tono.ime.keyboard.displayLabel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Deterministic transitions for the pure typing state machine that backs the
 * Android keyboard. These run in the fast JVM unit lane (the class has no
 * Android imports) and pin the shift/caps/layer/auto-cap behavior the IME
 * service turns into InputConnection commits.
 */
class KeyboardTypingStateTest {

    // ─── Casing ───────────────────────────────────────────────────────────

    @Test
    fun `fresh field starts armed for one capital`() {
        val s = KeyboardTypingState()
        assertEquals(ShiftState.SHIFT_ONCE, s.shift)
        assertEquals("A", s.commitFor("a"))
        // one-shot shift is consumed after the letter
        assertEquals(ShiftState.NONE, s.shift)
        assertEquals("b", s.commitFor("b"))
    }

    @Test
    fun `no shift yields lowercase letters`() {
        val s = KeyboardTypingState()
        s.commitFor("a") // consume initial shift
        assertEquals("h", s.commitFor("h"))
        assertEquals("i", s.commitFor("i"))
    }

    @Test
    fun `caps lock keeps every letter uppercase`() {
        val s = KeyboardTypingState()
        s.commitFor("x") // consume initial shift → NONE
        s.onShiftTapped(1000)          // NONE → SHIFT_ONCE
        s.onShiftTapped(1200)          // within 400ms → CAPS_LOCK
        assertEquals(ShiftState.CAPS_LOCK, s.shift)
        assertEquals("A", s.commitFor("a"))
        assertEquals("B", s.commitFor("b"))
        assertEquals(ShiftState.CAPS_LOCK, s.shift) // not consumed
    }

    @Test
    fun `single shift tap outside the window does not lock`() {
        val s = KeyboardTypingState()
        s.commitFor("x")
        s.onShiftTapped(1000)          // NONE → SHIFT_ONCE
        s.onShiftTapped(2000)          // 1s later, SHIFT_ONCE (not double) → NONE
        assertEquals(ShiftState.NONE, s.shift)
    }

    @Test
    fun `shift tap from caps lock releases it`() {
        val s = KeyboardTypingState()
        s.resetForNewField(autoCapitalize = false) // normalize to NONE
        s.onShiftTapped(1000) // NONE → SHIFT_ONCE
        s.onShiftTapped(1100) // double → CAPS_LOCK
        assertEquals(ShiftState.CAPS_LOCK, s.shift)
        s.onShiftTapped(5000) // release
        assertEquals(ShiftState.NONE, s.shift)
    }

    @Test
    fun `one-shot shift is only consumed by a letter, not by space or symbols`() {
        val s = KeyboardTypingState()
        assertEquals(ShiftState.SHIFT_ONCE, s.shift)
        assertEquals(" ", s.commitFor(" "))
        assertEquals("Still armed after space", ShiftState.SHIFT_ONCE, s.shift)
    }

    // ─── Layer switching ──────────────────────────────────────────────────

    @Test
    fun `symbols layer commits verbatim and ignores shift`() {
        val s = KeyboardTypingState()
        s.toggleLayer()
        assertEquals(KeyLayer.SYMBOLS, s.layer)
        assertEquals("1", s.commitFor("1"))
        assertEquals("@", s.commitFor("@"))
    }

    @Test
    fun `layer toggle preserves caps lock intent`() {
        val s = KeyboardTypingState()
        s.resetForNewField(autoCapitalize = false)
        s.onShiftTapped(1000) // NONE → SHIFT_ONCE
        s.onShiftTapped(1100) // double → CAPS_LOCK
        s.toggleLayer()       // → symbols
        s.toggleLayer()       // → letters
        assertEquals("Caps lock survives the round trip", ShiftState.CAPS_LOCK, s.shift)
        assertEquals("Z", s.commitFor("z"))
    }

    // ─── Auto-capitalization ──────────────────────────────────────────────

    @Test
    fun `auto-cap arms at field start`() {
        val s = KeyboardTypingState()
        s.commitFor("x") // → NONE
        s.applyAutoCapitalization("")
        assertEquals(ShiftState.SHIFT_ONCE, s.shift)
    }

    @Test
    fun `auto-cap arms after sentence end plus space`() {
        val s = KeyboardTypingState()
        s.commitFor("x")
        s.applyAutoCapitalization("done. ")
        assertEquals(ShiftState.SHIFT_ONCE, s.shift)
        s.applyAutoCapitalization("wait? ")
        assertEquals(ShiftState.SHIFT_ONCE, s.shift)
    }

    @Test
    fun `auto-cap disarms mid-word`() {
        val s = KeyboardTypingState()
        s.applyAutoCapitalization("hello")
        assertEquals(ShiftState.NONE, s.shift)
    }

    @Test
    fun `auto-cap never releases an explicit caps lock`() {
        val s = KeyboardTypingState()
        s.resetForNewField(autoCapitalize = false)
        s.onShiftTapped(1000) // NONE → SHIFT_ONCE
        s.onShiftTapped(1100) // double → CAPS_LOCK
        s.applyAutoCapitalization("hello") // would otherwise disarm
        assertEquals(ShiftState.CAPS_LOCK, s.shift)
    }

    @Test
    fun `reset for new field honors the auto-cap flag`() {
        val s = KeyboardTypingState()
        s.toggleLayer()
        s.resetForNewField(autoCapitalize = false)
        assertEquals(KeyLayer.LETTERS, s.layer)
        assertEquals(ShiftState.NONE, s.shift)

        s.resetForNewField(autoCapitalize = true)
        assertEquals(ShiftState.SHIFT_ONCE, s.shift)
    }

    @Test
    fun `a shift tap right after a new field cannot false-trigger caps lock`() {
        val s = KeyboardTypingState()
        s.onShiftTapped(1000)              // arm from a previous field
        s.resetForNewField(autoCapitalize = true)
        s.onShiftTapped(1050)              // 50ms later, but timer was cleared
        assertEquals(ShiftState.NONE, s.shift) // SHIFT_ONCE → NONE, not CAPS_LOCK
    }

    // ─── Display labels ───────────────────────────────────────────────────

    @Test
    fun `display label uppercases letters only when shifted`() {
        assertEquals("q", displayLabel("q", KeyLayer.LETTERS, ShiftState.NONE))
        assertEquals("Q", displayLabel("q", KeyLayer.LETTERS, ShiftState.SHIFT_ONCE))
        assertEquals("Q", displayLabel("q", KeyLayer.LETTERS, ShiftState.CAPS_LOCK))
        // Symbols never change with shift.
        assertEquals("1", displayLabel("1", KeyLayer.SYMBOLS, ShiftState.CAPS_LOCK))
    }

    @Test
    fun `layout rows are a full qwerty and match across platforms`() {
        val letters = KeyboardLayout.rows(KeyLayer.LETTERS)
        assertEquals(listOf("q", "w", "e", "r", "t", "y", "u", "i", "o", "p"), letters[0])
        assertEquals(listOf("a", "s", "d", "f", "g", "h", "j", "k", "l"), letters[1])
        assertEquals(listOf("z", "x", "c", "v", "b", "n", "m"), letters[2])
        val all = letters.flatten()
        for (c in 'a'..'z') assertTrue("letter $c present", all.contains(c.toString()))

        val symbols = KeyboardLayout.rows(KeyLayer.SYMBOLS)
        assertEquals(listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "0"), symbols[0])
        assertFalse("symbols layer is distinct from letters", symbols == letters)
    }
}
