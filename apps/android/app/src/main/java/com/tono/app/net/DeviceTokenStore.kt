package com.tono.app.net

import android.content.Context

private const val PREFS_NAME = "tono_device"
private const val KEY_API_TOKEN = "api_token"

/**
 * Persists the bearer token returned by POST /v1/register — the Android
 * equivalent of apps/web's lib/device.ts (localStorage) and the browser
 * extension's chrome.storage.local.
 */
class DeviceTokenStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    var apiToken: String?
        get() = prefs.getString(KEY_API_TOKEN, null)
        set(value) = prefs.edit().putString(KEY_API_TOKEN, value).apply()
}
