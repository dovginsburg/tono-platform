package com.tono.shared.storage

import android.content.Context
import android.content.SharedPreferences

// Mirrors ios/Shared/SharedUserDefaults.swift
// On Android the IME and host app share the same process + package,
// so a single named SharedPreferences file replaces iOS App Groups.

object SharedKeys {
    const val PROVIDER          = "tc.provider"
    const val PREFERRED_VOICE   = "tc.preferredVoice"
    const val AXES              = "tc.axes"
    const val FREE_TIER_USED    = "tc.freeTierUsed"
    const val FREE_TIER_DAY     = "tc.freeTierDay"
    const val PRO_UNLOCKED      = "tc.proUnlocked"
    const val LAST_REWRITE_VOICE = "tc.lastRewriteVoice"
    const val BACKEND_URL       = "tc.backendURL"
    const val REGISTERED_AT     = "tc.registeredAt"
    const val KEYBOARD_LOADED   = "tc.keyboardLoaded"
    const val COACH_USE_COUNT   = "tc.coachUseCount"
    const val DRAFT_HISTORY     = "tc.draftHistory"
    const val RECIPIENTS        = "tc.recipients"
    const val AXIS_WEIGHTS      = "tc.axisWeights"
    const val LAST_COACH_DATE   = "tc.lastCoachDate"
    const val MEMORY_FACTS      = "tc.memoryFacts"
    const val RECENT_SESSIONS   = "tc.recentSessions"
    const val LAST_PERCEPTION   = "tc.lastPerception"
    const val LAST_RISK_LEVEL   = "tc.lastRiskLevel"
    const val FEATURE_FLAGS     = "tc.featureFlags"
    const val ONBOARDING_DONE   = "tc.onboardingDone"
    const val LAST_WEEKLY_DIGEST = "tc.lastWeeklyDigest"
}

object SharedStore {
    private const val PREFS_NAME = "tono_shared_prefs"
    private lateinit var prefs: SharedPreferences

    fun init(context: Context) {
        prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    fun getString(key: String, default: String? = null): String? = prefs.getString(key, default)
    fun putString(key: String, value: String?) = prefs.edit().putString(key, value).apply()

    fun getBoolean(key: String, default: Boolean = false): Boolean = prefs.getBoolean(key, default)
    fun putBoolean(key: String, value: Boolean) = prefs.edit().putBoolean(key, value).apply()

    fun getInt(key: String, default: Int = 0): Int = prefs.getInt(key, default)
    fun putInt(key: String, value: Int) = prefs.edit().putInt(key, value).apply()

    fun remove(key: String) = prefs.edit().remove(key).apply()
}
