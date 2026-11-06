package cloud.anj.anj_cloud

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/// The UI attaches to the process's one engine (SyncHost) and never starts or
/// destroys its own, so leaving the app does not stop sync (spec #28).
///
/// Notifications (decision #108 Q14): POST_NOTIFICATIONS is asked for once, the first time
/// the app is opened. Declining it leaves sync running; the menu then offers the system
/// setting, and every return to the app reports the current grant to the engine.
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine = SyncHost.engine(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onResume() {
        super.onResume()
        TransferService.appForeground()
        // The cap is cleared: have the engine report transfers again, so a transfer
        // already running gets the service now, not at its next count change.
        BackgroundChannel.push("foreground", null)
        val prefs = getSharedPreferences("anj-background", MODE_PRIVATE)
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            !prefs.getBoolean(ASKED, false)
        ) {
            prefs.edit().putBoolean(ASKED, true).apply()
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        }
        BackgroundChannel.push("notifications", mapOf("allowed" to Notifications.allowed(this)))
        // The updater shows Android's install confirmation from the resumed activity (spec #28 A7).
        UpdateChannel.resumed(this)
    }

    override fun onPause() {
        UpdateChannel.paused(this)
        super.onPause()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_NOTIFICATIONS) {
            BackgroundChannel.push("notifications", mapOf("allowed" to Notifications.allowed(this)))
        }
    }

    companion object {
        private const val ASKED = "notificationsAsked"
        private const val REQUEST_NOTIFICATIONS = 41
    }
}
