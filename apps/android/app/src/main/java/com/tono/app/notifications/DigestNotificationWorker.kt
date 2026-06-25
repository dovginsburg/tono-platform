package com.tono.app.notifications

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.tono.app.MainActivity
import com.tono.shared.network.TonoBackend

// Runs once a week via WorkManager. Fetches the digest summary and posts
// a notification summarising the user's coaching activity.
// Mirrors the NotificationManager.shared.scheduleWeeklyDigest() flow on iOS.

class DigestNotificationWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val digest = runCatching { TonoBackend.weeklyDigest() }.getOrNull()
            ?: return Result.retry()  // network offline — WorkManager will retry

        val title = "Your week in Tono"
        val body = buildString {
            append("${digest.rewrites} rewrite${if (digest.rewrites == 1) "" else "s"}")
            if (digest.daysActive > 0) append(" · ${digest.daysActive} active day${if (digest.daysActive == 1) "" else "s"}")
            digest.topAxis?.let { append(" · go-to: ${it.replaceFirstChar { c -> c.uppercase() }}") }
        }

        postNotification(title, body)
        return Result.success()
    }

    private fun postNotification(title: String, body: String) {
        val nm = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val tapIntent = Intent(applicationContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("nav_to", "digest")
        }
        val pi = PendingIntent.getActivity(
            applicationContext, 0, tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(applicationContext, DigestScheduler.CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()

        nm.notify(DigestScheduler.NOTIFICATION_ID, notification)
    }
}
