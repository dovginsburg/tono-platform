package com.tono.ime.keyboard

import android.text.InputType
import android.view.inputmethod.EditorInfo

/**
 * Pure decisions about how to behave for a given host editor, derived only from
 * the `EditorInfo` bit fields the framework hands the IME. No `InputConnection`,
 * no text, no state — just integer masking — so the service stays thin and each
 * rule is JVM-unit-testable. The Android `InputType`/`EditorInfo` values are
 * compile-time constants and inline into the caller, so tests need no device.
 */
object EditorPolicies {

    /**
     * True when the field masks input (passwords, PINs). Tono still *types* in
     * these fields — it's a full keyboard — but the analysis features that read
     * the field (Coach / Read) must fail closed here, mirroring iOS
     * `LiveToneEligibility` secure-field gating.
     */
    fun isSecureField(inputType: Int): Boolean {
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        return when (inputType and InputType.TYPE_MASK_CLASS) {
            InputType.TYPE_CLASS_TEXT ->
                variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
            InputType.TYPE_CLASS_NUMBER ->
                variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> false
        }
    }

    /**
     * Whether sentence auto-capitalization should run for this field. Enabled
     * for ordinary text fields, disabled for email / URI / password fields
     * where an unexpected capital is wrong. HOW to capitalize lives in
     * [KeyboardTypingState.applyAutoCapitalization]; this only decides WHETHER.
     */
    fun autoCapEnabled(inputType: Int): Boolean {
        if ((inputType and InputType.TYPE_MASK_CLASS) != InputType.TYPE_CLASS_TEXT) return false
        if (isSecureField(inputType)) return false
        return when (inputType and InputType.TYPE_MASK_VARIATION) {
            InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
            InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS,
            InputType.TYPE_TEXT_VARIATION_URI,
            InputType.TYPE_TEXT_VARIATION_FILTER -> false
            else -> true
        }
    }

    /**
     * The editor action the return key should perform, or `null` when it should
     * insert a newline instead. Honors `IME_FLAG_NO_ENTER_ACTION` and treats
     * NONE / UNSPECIFIED as "just a newline". Matches iOS `returnKeySpec`, which
     * adapts the return key to the host's `returnKeyType`.
     */
    fun returnAction(imeOptions: Int): Int? {
        if ((imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION) != 0) return null
        val action = imeOptions and EditorInfo.IME_MASK_ACTION
        return when (action) {
            EditorInfo.IME_ACTION_NONE,
            EditorInfo.IME_ACTION_UNSPECIFIED -> null
            else -> action
        }
    }

    /** Human label for the return key given the resolved action. */
    fun returnLabel(imeOptions: Int): String = when (returnAction(imeOptions)) {
        EditorInfo.IME_ACTION_GO       -> "Go"
        EditorInfo.IME_ACTION_SEARCH   -> "Search"
        EditorInfo.IME_ACTION_SEND     -> "Send"
        EditorInfo.IME_ACTION_NEXT     -> "Next"
        EditorInfo.IME_ACTION_DONE     -> "Done"
        EditorInfo.IME_ACTION_PREVIOUS -> "Previous"
        else                           -> "return"
    }
}
