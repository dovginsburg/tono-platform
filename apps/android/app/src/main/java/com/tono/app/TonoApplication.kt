package com.tono.app

import android.app.Application
import com.tono.app.notifications.DigestScheduler
import com.tono.shared.analytics.CrashReporter
import com.tono.shared.flags.FeatureFlag
import com.tono.shared.flags.FeatureFlags
import com.tono.shared.storage.SecureStore
import com.tono.shared.storage.SharedStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class TonoApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        SharedStore.init(this)   // must be first
        SecureStore.init(this)   // EncryptedSharedPreferences
        CrashReporter.configure(this)  // A1: no-op until Firebase added

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
            runCatching {
                com.tono.shared.network.TonoBackend.registerIfNeeded(
                    appVersion = BuildConfig.VERSION_NAME,
                )
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
