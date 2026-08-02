package com.tono.shared.flags

import com.tono.shared.storage.SharedKeys
import com.tono.shared.storage.SharedStore
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

// Mirrors ios/Shared/FeatureFlags.swift

enum class FeatureFlag(val key: String) {
    // Default ON
    ONBOARDING_CALIBRATION("onboarding_calibration"),
    THREAD_CONTEXT("thread_context"),
    RISK_DELTA("risk_delta"),
    MEMORY_INFERENCE("memory_inference"),
    MEMORY_CONTEXT_HINTS("memory_context_hints"),

    // Default ON, Pro-gated
    WEEKLY_DIGEST("weekly_digest"),

    // Default OFF (staged)
    CUSTOM_AXES("custom_axes"),
    RECIPIENT_MEMORY("recipient_memory"),
    WIDGET_ENABLED("widget_enabled"),

    // Default OFF (B2B only)
    SLACK_ENABLED("slack_enabled"),

    // Default OFF (staged, dark-launch). The remote/user kill switch for the
    // Gemini Nano on-device "Funnier" gesture. Off by default because the path
    // is not device-verified: it lights up only when this flag is on AND the
    // device actually reports the on-device model available (fail-closed). It
    // never bypasses billing (Pro-gated) or the backend Safer route.
    GEMINI_NANO_REWRITE("gemini_nano_rewrite"),

    // Collective improvement signal (default ON, user-controllable opt-out)
    IMPROVE_TONO("improve_tono");

    val defaultValue: Boolean get() = when (this) {
        CUSTOM_AXES, RECIPIENT_MEMORY, WIDGET_ENABLED, SLACK_ENABLED, GEMINI_NANO_REWRITE -> false
        else -> true
    }

    val requiresPro: Boolean get() = when (this) {
        MEMORY_INFERENCE, MEMORY_CONTEXT_HINTS, WEEKLY_DIGEST, CUSTOM_AXES, RECIPIENT_MEMORY,
        GEMINI_NANO_REWRITE -> true
        else -> false
    }

    val isUserControllable: Boolean get() = when (this) {
        THREAD_CONTEXT, WEEKLY_DIGEST, RISK_DELTA, MEMORY_INFERENCE, MEMORY_CONTEXT_HINTS,
        IMPROVE_TONO, GEMINI_NANO_REWRITE -> true
        else -> false
    }

    val displayName: String get() = when (this) {
        ONBOARDING_CALIBRATION -> "First-run calibration"
        THREAD_CONTEXT         -> "Thread context"
        WEEKLY_DIGEST          -> "Weekly tone report"
        CUSTOM_AXES            -> "Custom rewrite axes"
        RISK_DELTA             -> "Risk change indicator"
        MEMORY_INFERENCE       -> "Learn from my sessions"
        MEMORY_CONTEXT_HINTS   -> "Use memory in rewrites"
        RECIPIENT_MEMORY       -> "Per-recipient style memory"
        WIDGET_ENABLED         -> "Home screen widget"
        SLACK_ENABLED          -> "Slack integration"
        GEMINI_NANO_REWRITE    -> "On-device Funnier (Gemini Nano)"
        IMPROVE_TONO           -> "Help improve Tono"
    }
}

object FeatureFlags {

    private val json = Json { ignoreUnknownKeys = true }

    fun isEnabled(flag: FeatureFlag): Boolean {
        if (flag.requiresPro && !SharedStore.getBoolean(SharedKeys.PRO_UNLOCKED)) return false
        return cached()[flag.key] ?: flag.defaultValue
    }

    fun update(from: Map<String, Boolean>) {
        SharedStore.putString(SharedKeys.FEATURE_FLAGS, json.encodeToString(from))
    }

    fun setUserPreference(flag: FeatureFlag, enabled: Boolean) {
        val dict = cached().toMutableMap()
        dict[flag.key] = enabled
        SharedStore.putString(SharedKeys.FEATURE_FLAGS, json.encodeToString(dict))
    }

    private fun cached(): Map<String, Boolean> {
        val raw = SharedStore.getString(SharedKeys.FEATURE_FLAGS) ?: return emptyMap()
        return runCatching { json.decodeFromString<Map<String, Boolean>>(raw) }.getOrDefault(emptyMap())
    }
}
