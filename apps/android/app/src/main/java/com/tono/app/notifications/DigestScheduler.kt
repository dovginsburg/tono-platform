package com.tono.app.notifications

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.work.*
import java.util.concurrent.TimeUnit

// Schedules / cancels the weekly digest WorkManager task and owns the
// notification channel. Call createChannel() once from Application.onCreate().
// Mirrors NotificationManager.shared on iOS.

object DigestScheduler {

    const val CHANNEL_ID      = "tono_weekly_digest"
    const val NOTIFICATION_ID = 1001
    private const val WORK_TAG = "tono_weekly_digest_work"

    fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Weekly Tone Report",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "Your weekly coaching summary from Tono."
        }
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(channel)
    }

    fun schedule(context: Context) {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()

        val request = PeriodicWorkRequestBuilder<DigestNotificationWorker>(7, TimeUnit.DAYS)
            .setConstraints(constraints)
            // Back-off: retry after 30 min if network was unavailable, up to WorkManager's cap.
            .setBackoffCriteria(BackoffPolicy.LINEAR, 30, TimeUnit.MINUTES)
            .addTag(WORK_TAG)
            .build()

        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            WORK_TAG,
            ExistingPeriodicWorkPolicy.KEEP,  // don't reset the weekly clock if already scheduled
            request,
        )
    }

    fun cancel(context: Context) {
        WorkManager.getInstance(context).cancelAllWorkByTag(WORK_TAG)
    }
}
