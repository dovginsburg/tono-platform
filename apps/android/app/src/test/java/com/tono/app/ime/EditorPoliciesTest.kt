package com.tono.app.ime

import android.text.InputType
import android.view.inputmethod.EditorInfo
import com.tono.ime.keyboard.EditorPolicies
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure InputConnection-adjacent decisions: secure-field detection, auto-cap
 * gating, and return-key action resolution. The Android bit-field constants are
 * compile-time values, so this exercises the real masking logic without a
 * device.
 */
class EditorPoliciesTest {

    // ─── Secure fields ────────────────────────────────────────────────────

    @Test
    fun `text and number password fields are secure`() {
        assertTrue(
            EditorPolicies.isSecureField(
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
            ),
        )
        assertTrue(
            EditorPolicies.isSecureField(
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            ),
        )
        assertTrue(
            EditorPolicies.isSecureField(
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
            ),
        )
        assertTrue(
            EditorPolicies.isSecureField(
                InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD,
            ),
        )
    }

    @Test
    fun `ordinary text and email fields are not secure`() {
        assertFalse(EditorPolicies.isSecureField(InputType.TYPE_CLASS_TEXT))
        assertFalse(
            EditorPolicies.isSecureField(
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
            ),
        )
    }

    // ─── Auto-cap gating ──────────────────────────────────────────────────

    @Test
    fun `auto-cap on for plain text, off for email uri password and non-text`() {
        assertTrue(EditorPolicies.autoCapEnabled(InputType.TYPE_CLASS_TEXT))
        assertTrue(
            EditorPolicies.autoCapEnabled(
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_LONG_MESSAGE,
            ),
        )
        assertFalse(
            EditorPolicies.autoCapEnabled(
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
            ),
        )
        assertFalse(
            EditorPolicies.autoCapEnabled(
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI,
            ),
        )
        assertFalse(
            EditorPolicies.autoCapEnabled(
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
            ),
        )
        assertFalse(EditorPolicies.autoCapEnabled(InputType.TYPE_CLASS_NUMBER))
    }

    // ─── Return key ───────────────────────────────────────────────────────

    @Test
    fun `return performs the host action when one is requested`() {
        assertEquals(EditorInfo.IME_ACTION_SEND, EditorPolicies.returnAction(EditorInfo.IME_ACTION_SEND))
        assertEquals(EditorInfo.IME_ACTION_SEARCH, EditorPolicies.returnAction(EditorInfo.IME_ACTION_SEARCH))
        assertEquals("Send", EditorPolicies.returnLabel(EditorInfo.IME_ACTION_SEND))
        assertEquals("Search", EditorPolicies.returnLabel(EditorInfo.IME_ACTION_SEARCH))
        assertEquals("Go", EditorPolicies.returnLabel(EditorInfo.IME_ACTION_GO))
        assertEquals("Next", EditorPolicies.returnLabel(EditorInfo.IME_ACTION_NEXT))
        assertEquals("Done", EditorPolicies.returnLabel(EditorInfo.IME_ACTION_DONE))
    }

    @Test
    fun `return inserts a newline when there is no action`() {
        assertNull(EditorPolicies.returnAction(EditorInfo.IME_ACTION_NONE))
        assertNull(EditorPolicies.returnAction(EditorInfo.IME_ACTION_UNSPECIFIED))
        assertEquals("return", EditorPolicies.returnLabel(EditorInfo.IME_ACTION_NONE))
    }

    @Test
    fun `the no-enter-action flag forces a newline even with an action set`() {
        val opts = EditorInfo.IME_ACTION_SEND or EditorInfo.IME_FLAG_NO_ENTER_ACTION
        assertNull(EditorPolicies.returnAction(opts))
        assertEquals("return", EditorPolicies.returnLabel(opts))
    }
}
