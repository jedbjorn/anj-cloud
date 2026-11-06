package cloud.anj.anj_cloud

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Log
import androidx.core.app.ServiceCompat

/// The dataSync foreground service while files transfer (spec #28 Background Sync): it
/// keeps the process running when the user leaves the app mid-transfer, shows the progress
/// notification, and stops when the queue drains. There is no permanent notification
/// (#108 Q3). It does no work itself: the engine in SyncHost transfers.
///
/// Android limits it; every limit falls back to posting the same progress notification
/// directly (TransferGate), with the transfer continuing for as long as the process runs
/// (a background run's job window, or until the OS reclaims the process; durable intents
/// resume on the next run):
/// - Android 12+: no foreground service may start while the app is in the background, so a
///   WorkManager run never gets one (startService throws at the call site).
/// - Android 15+: dataSync services share a 6-hour budget per 24 hours. At the cap the
///   system calls [onTimeout], which stops the service at once; a later startForeground is
///   refused until the budget recovers.
class TransferService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val count = intent?.getIntExtra(EXTRA_COUNT, 0) ?: 0
        if (gate.wanted <= 0) {
            stop(this)
            return START_NOT_STICKY
        }
        try {
            ServiceCompat.startForeground(
                this,
                Notifications.PROGRESS_ID,
                Notifications.progress(this, count),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
            gate.started()
        } catch (error: Exception) {
            // Refused (the Android 15 cap, or the app left the foreground meanwhile).
            // Started with startService, so stopping without startForeground is safe.
            Log.i(TAG, "foreground refused: $error")
            gate.refused()
            Notifications.postProgress(this, count)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    /// Android 15+ dataSync budget used up: stop now, keep the notification truthful.
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.i(TAG, "dataSync time limit reached; continuing without the service")
        gate.refused()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        Notifications.postProgress(this, gate.wanted)
        stopSelf()
    }

    override fun onDestroy() {
        gate.stopped()
        super.onDestroy()
    }

    companion object {
        const val TAG = "AnjTransfers"
        private const val EXTRA_COUNT = "count"
        val gate = TransferGate()

        /// Called on the main thread with the number of files transferring now; 0 stops
        /// the service and removes the notification.
        fun update(context: Context, count: Int) {
            when (gate.update(count)) {
                TransferGate.Action.STOP -> stop(context)
                TransferGate.Action.POST_DIRECT -> Notifications.postProgress(context, count)
                TransferGate.Action.START_SERVICE -> try {
                    context.startService(
                        Intent(context, TransferService::class.java).putExtra(EXTRA_COUNT, count),
                    )
                } catch (error: IllegalStateException) {
                    // Background start not allowed (Android 12+).
                    Log.i(TAG, "start refused: $error")
                    gate.refused()
                    Notifications.postProgress(context, count)
                }
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, TransferService::class.java))
            gate.stopped()
            Notifications.cancelProgress(context)
        }

        /// The app is in the foreground: the service may start again.
        fun appForeground() = gate.appForeground()
    }
}
