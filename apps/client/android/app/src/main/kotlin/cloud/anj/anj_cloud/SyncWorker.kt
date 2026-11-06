package cloud.anj.anj_cloud

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/// One background run (spec #28 Background Sync): attaches to the process's one engine
/// (SyncHost, which the Application already started) and asks it for a bounded complete
/// pass, which lists the cloud and verifies every local file (decision #130 (3)). The run
/// ends when that pass ends; while paused it ends at once, after any overdue certificate
/// pickup. A run that ends with files waiting for Wi-Fi asks for the unmetered follow-up.
/// The result is always success: the periodic work recurs, and a failed pass is retried by
/// the engine's own schedule, not by WorkManager backoff.
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val started = System.currentTimeMillis()
        // The Wi-Fi follow-up is scheduled on an unmetered network as a hint, but "Wi-Fi
        // only" means the transport (NetworkMonitor): on anything else the files would only
        // wait again, so this run does nothing. A later report of waiting files asks again.
        if (skipOffWifi(tags, NetworkMonitor.onWifi(applicationContext))) {
            Log.i(TAG, "run tags=[${BackgroundSync.WIFI}] skipped: not on Wi-Fi")
            return Result.success()
        }
        val reply = withContext(Dispatchers.Main) {
            SyncHost.engine(applicationContext)
            val attached = withTimeoutOrNull(ATTACH_TIMEOUT_MS) { BackgroundChannel.attached.await() }
            if (attached == null) {
                null
            } else {
                // WorkManager stops a run after 10 minutes; end before that.
                withTimeoutOrNull(RUN_TIMEOUT_MS) { BackgroundChannel.backgroundRun() }
            }
        }
        val waiting = (reply?.get("waiting") as? Number)?.toInt() ?: 0
        if (waiting > 0) BackgroundSync.requestWifiRun(applicationContext)
        Log.i(
            TAG,
            "run tags=${tags.filter { it.startsWith("anj-") }} ms=${System.currentTimeMillis() - started} reply=$reply",
        )
        return Result.success()
    }

    /// Only used where expedited work needs a foreground service (below API 31; minSdk is
    /// 31, so normally never).
    override suspend fun getForegroundInfo(): ForegroundInfo =
        Notifications.foregroundInfo(applicationContext, 0)

    companion object {
        /// The Wi-Fi follow-up does nothing off Wi-Fi; every other run proceeds.
        fun skipOffWifi(tags: Set<String>, onWifi: Boolean) = BackgroundSync.WIFI in tags && !onWifi

        const val TAG = "AnjSyncWorker"
        const val ATTACH_TIMEOUT_MS = 60_000L
        const val RUN_TIMEOUT_MS = 9 * 60_000L
    }
}
