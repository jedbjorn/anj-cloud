package cloud.anj.anj_cloud

import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

/// Background sync through WorkManager (spec #28 Background Sync, decision #108 Q3).
///
/// - [PERIODIC]: unique periodic work at the 15-minute platform floor with a
///   network-connected constraint (listings run on any network, R3), Doze-deferred. It is
///   the Background-sync switch, Android's start at login (#40), on by default: turning it
///   off cancels exactly this work. WorkManager keeps it across reboots and runs it after
///   the first unlock, when credential-encrypted storage is available.
/// - [WIFI]: one-time work on an unmetered network, asked for when a run ends with files
///   waiting for Wi-Fi, so they transfer when Wi-Fi returns without waiting for the next
///   periodic run.
/// - [PROMPT]: expedited one-time work, so a local change made while the app is in the
///   background (the provider, A5; transfers still running as the app leaves) uploads
///   promptly instead of at the next periodic run.
object BackgroundSync {
    const val PERIODIC = "anj-sync"
    const val WIFI = "anj-sync-wifi"
    const val PROMPT = "anj-sync-prompt"
    private const val PREFS = "anj-background"
    private const val KEY_ENABLED = "enabled"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun enabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, true)

    /// 'default' until the user changes the switch, then 'user' (AutostartState.source).
    fun source(context: Context): String =
        if (prefs(context).contains(KEY_ENABLED)) "user" else "default"

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).commit()
        ensure(context)
    }

    /// Called at every process start: keeps the periodic work in place (KEEP leaves an
    /// existing schedule alone) or cancels it when the switch is off.
    fun ensure(context: Context) {
        val work = WorkManager.getInstance(context.applicationContext)
        if (!enabled(context)) {
            work.cancelUniqueWork(PERIODIC)
            work.cancelUniqueWork(WIFI)
            return
        }
        val request = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES)
            .setConstraints(Constraints(requiredNetworkType = NetworkType.CONNECTED))
            .addTag(PERIODIC)
            .build()
        work.enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    fun requestWifiRun(context: Context) {
        if (!enabled(context)) return
        val request = OneTimeWorkRequestBuilder<SyncWorker>()
            .setConstraints(Constraints(requiredNetworkType = NetworkType.UNMETERED))
            .addTag(WIFI)
            .build()
        WorkManager.getInstance(context.applicationContext)
            .enqueueUniqueWork(WIFI, ExistingWorkPolicy.KEEP, request)
    }

    /// Not gated by the switch: it finishes work the user just did.
    fun requestPrompt(context: Context) {
        val request = OneTimeWorkRequestBuilder<SyncWorker>()
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .setConstraints(Constraints(requiredNetworkType = NetworkType.CONNECTED))
            .addTag(PROMPT)
            .build()
        WorkManager.getInstance(context.applicationContext)
            .enqueueUniqueWork(PROMPT, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
    }
}
