package com.tono.shared.storage

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

// Mirrors ios/Shared/SharedKeychain.swift
// EncryptedSharedPreferences uses Android Keystore under the hood —
// equivalent security level to iOS Keychain with kSecAttrAccessibleAfterFirstUnlock.

object KeychainKeys {
    const val API_TOKEN = "apiToken"
    const val DEVICE_ID = "deviceID"
    const val API_KEY   = "apiKey"
}

object SecureStore {
    private const val PREFS_NAME = "tono_secure_prefs"
    private var prefs: android.content.SharedPreferences? = null

    fun init(context: Context) {
        val masterKey = MasterKey.Builder(context.applicationContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        prefs = EncryptedSharedPreferences.create(
            context.applicationContext,
            PREFS_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    fun get(key: String): String? = prefs?.getString(key, null)

    fun set(key: String, value: String) {
        prefs?.edit()?.putString(key, value)?.apply()
    }

    fun delete(key: String) {
        prefs?.edit()?.remove(key)?.apply()
    }

    fun isRegistered(): Boolean = get(KeychainKeys.API_TOKEN)?.isNotEmpty() == true
}
