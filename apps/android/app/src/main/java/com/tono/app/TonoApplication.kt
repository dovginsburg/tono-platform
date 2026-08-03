package com.tono.app

import android.app.Application
import com.tono.app.billing.PlayBillingManager
import com.tono.app.billing.RevenueCatManager
import com.tono.app.notifications.DigestScheduler
import com.tono.shared.analytics.CrashReporter
import com.tono.shared.flags.FeatureFlag
import com.tono.shared.flags.FeatureFlags
import com.tono.shared.storage.SecureStore
import com.tono.shared.storage.SharedKeys
import com.tono.shared.storage.SharedStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class TonoApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        SharedStore.init(this)   // must be first
        SecureStore.init(this)   // EncryptedSharedPreferences
        // Build 114 — publish the shipped build number so registration events
        // carry the release they came from. Written once, from BuildConfig, so
        // there is exactly one source for it and no client can invent one.
        SharedStore.putString(SharedKeys.APP_BUILD, BuildConfig.VERSION_CODE.toString())
        CrashReporter.configure(this)  // A1: no-op until Firebase added
        PlayBillingManager.start(this)
        // Build 123 — RevenueCat canary. A no-op unless REVENUECAT_PUBLIC_SDK_KEY
        // is set (kill switch). Backend stays the sole entitlement authority; this
        // only wires RevenueCat's identity/observation layer with the canonical
        // account UUID. The existing Play billing path above is unchanged.
        RevenueCatManager.configureIfEnabled(this)

        DigestScheduler.createChannel(this)

        // Schedule or cancel the weekly digest depending on the user's preference.
        // KEEP policy means this is a no-op if already scheduled — safe to call every launch.
        if (FeatureFlags.isEnabled(FeatureFlag.WEEKLY_DIGEST)) {
            DigestScheduler.schedule(this)
        } else {
            DigestScheduler.cancel(this)
        }

        // Register then fetch remote feature flags on every launch (both are idempotent)
        CoroutineScope(Dispatchers.IO).launch {
            val registration = runCatching {
                com.tono.shared.network.TonoBackend.registerIfNeeded(
                    appVersion = BuildConfig.VERSION_NAME,
                )
            }
            if (registration.isSuccess) {
                withContext(Dispatchers.Main) {
                    PlayBillingManager.refresh()
                    // Re-assert the RevenueCat identity now the canonical account
                    // UUID exists (minted at registration). No-op when disabled.
                    RevenueCatManager.identifyFromStore()
                }
            }
            // Pull server-side feature flags and merge into local prefs.
            // This runs even if registerIfNeeded fails (device may already be registered).
            runCatching {
                val flags = com.tono.shared.network.TonoBackend.fetchFeatures()
                FeatureFlags.update(flags)
                // Re-evaluate digest scheduling now that flags are fresh
                if (FeatureFlags.isEnabled(FeatureFlag.WEEKLY_DIGEST)) {
                    DigestScheduler.schedule(applicationContext)
                } else {
                    DigestScheduler.cancel(applicationContext)
                }
            }
        }
    }
}
