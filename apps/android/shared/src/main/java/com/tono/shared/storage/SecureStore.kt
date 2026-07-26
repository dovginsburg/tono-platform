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
    const val DEVICE_CREDENTIAL = "deviceCredential"
    const val API_KEY   = "apiKey"

    /**
     * Build 114 — the address this device signed in with, mirroring
     * `ios/Shared/SharedKeychain.swift` `signedInEmail`.
     *
     * The ONLY writer is `TonoBackend.signInWithEmail`, and only after the
     * server confirmed the address is proven. Nothing else may write it: it is
     * what `PlayBillingManager` reads to decide whether this device holds a
     * RECOVERABLE canonical account, and a purchase bound to an unrecoverable
     * one is silent entitlement loss on the next reinstall.
     *
     * Note what is absent from this whole object: there is no password key and
     * no auth-provider-token key. Passwords are typed, sent once, and never
     * stored; verification and reset links live in the person's inbox.
     */
    const val SIGNED_IN_EMAIL = "signedInEmail"
}

/**
 * The purchase-eligibility decision, as a pure function.
 *
 * Split out of [SecureStore] deliberately: the rule is the load-bearing part
 * (bind a purchase only to an account the person can get back), and a rule that
 * needs an encrypted preferences file to evaluate is a rule no unit test can
 * pin. Keeping it here means `PlayBillingManagerGateTest` proves it directly.
 */
object AccountIdentity {

    /**
     * True only when BOTH facts hold: a confirmed address, and a canonical
     * account UUID for a purchase to bind to.
     *
     * Why both. The UUID alone is present on an anonymous device-only account,
     * but that UUID does not survive the app being removed — so a purchase bound
     * to it cannot be restored and the person pays twice. The confirmed address
     * is what makes the UUID recoverable. And the address alone is not enough
     * either: there is nothing to bind the purchase to.
     *
     * This function grants nothing. It answers "may this device START a
     * purchase", never "does this person have Pro" — that stays with the server.
     */
    fun isIdentified(signedInEmail: String?, accountId: String?): Boolean =
        !signedInEmail.isNullOrBlank() && !accountId.isNullOrBlank()
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

    /** The confirmed address this device is signed in with, or null. */
    fun signedInEmail(): String? = get(KeychainKeys.SIGNED_IN_EMAIL)?.takeIf { it.isNotBlank() }

    /**
     * True when this device holds a canonical account that survives a
     * reinstall — a confirmed address AND the account UUID a purchase binds to.
     *
     * Mirrors `StoreKitManager.isIdentifiedAccount` on iOS, and for the same
     * reason: an anonymous device-only account's UUID is lost when the app is
     * removed, so binding a purchase to it risks paying twice for one thing.
     * A confirmed address does NOT grant Pro — it only makes Pro recoverable.
     */
    fun isIdentifiedAccount(accountId: String?): Boolean =
        AccountIdentity.isIdentified(signedInEmail(), accountId)

    /**
     * Forget this device's session. Sign-out clears the credential that lets the
     * device re-register itself as the SAME device, because otherwise the next
     * registration would silently sign the person back into the account they
     * just left — the server-side sign-out drops that credential for the same
     * reason. The account, its history and its entitlement are untouched.
     */
    fun clearSession() {
        delete(KeychainKeys.API_TOKEN)
        delete(KeychainKeys.SIGNED_IN_EMAIL)
        delete(KeychainKeys.DEVICE_ID)
        delete(KeychainKeys.DEVICE_CREDENTIAL)
    }
}
