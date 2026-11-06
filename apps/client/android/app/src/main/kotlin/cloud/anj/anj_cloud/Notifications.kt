package cloud.anj.anj_cloud

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.ForegroundInfo

/// Transfer-progress and attention notifications (decision #108 Q14). Both need the user's
/// POST_NOTIFICATIONS grant; without it nothing is posted (the dataSync service still runs,
/// its notification hidden by the OS) and the app's own status stays the truthful record.
object Notifications {
    const val TRANSFERS = "transfers"
    const val ATTENTION = "attention"
    const val PROGRESS_ID = 1001

    fun createChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(TRANSFERS, "File transfers", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown only while files upload or download."
                setShowBadge(false)
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(ATTENTION, "Needs attention", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Conflicts and uploads the server refused."
            },
        )
    }

    /// The user allows notifications, and, with [channel], has not turned that channel off.
    fun allowed(context: Context, channel: String? = null): Boolean {
        val manager = NotificationManagerCompat.from(context)
        if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED ||
            !manager.areNotificationsEnabled()
        ) {
            return false
        }
        if (channel == null) return true
        val found = manager.getNotificationChannel(channel) ?: return true
        return found.importance != NotificationManager.IMPORTANCE_NONE
    }

    private fun attentionId(path: String) = ("attention:$path").hashCode() and 0x7fffffff

    fun cancelAttention(context: Context, path: String) =
        NotificationManagerCompat.from(context).cancel(attentionId(path))

    private fun openApp(context: Context, request: Int): PendingIntent = PendingIntent.getActivity(
        context,
        request,
        Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    fun progress(context: Context, count: Int): Notification =
        NotificationCompat.Builder(context, TRANSFERS)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("AnJ Cloud is syncing")
            .setContentText(
                if (count <= 0) "Transferring files" else if (count == 1) "1 file" else "$count files",
            )
            .setProgress(0, 0, true)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(openApp(context, 0))
            .build()

    fun foregroundInfo(context: Context, count: Int) =
        ForegroundInfo(PROGRESS_ID, progress(context, count), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)

    /// The progress notification posted directly, for when the dataSync service cannot run
    /// (started from the background, or the Android 15 daily cap is used up).
    fun postProgress(context: Context, count: Int) {
        if (!allowed(context, TRANSFERS)) return
        try {
            NotificationManagerCompat.from(context).notify(PROGRESS_ID, progress(context, count))
        } catch (_: SecurityException) {
            // Permission withdrawn between the check and the post.
        }
    }

    fun cancelProgress(context: Context) =
        NotificationManagerCompat.from(context).cancel(PROGRESS_ID)

    /// One conflict or refused upload, keyed by path so a newer problem with the same file
    /// replaces the older notification.
    fun attention(context: Context, item: Map<String, String>) {
        if (!allowed(context, ATTENTION)) return
        val path = item["path"] ?: return
        val id = attentionId(path)
        val notification = NotificationCompat.Builder(context, ATTENTION)
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setContentTitle(item["title"] ?: "AnJ Cloud needs attention")
            .setContentText(item["text"] ?: path)
            .setStyle(NotificationCompat.BigTextStyle().bigText("${item["text"] ?: ""}\n$path"))
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_ERROR)
            .setContentIntent(openApp(context, id))
            .build()
        try {
            NotificationManagerCompat.from(context).notify(id, notification)
        } catch (_: SecurityException) {
        }
    }
}
