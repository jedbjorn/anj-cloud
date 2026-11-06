package cloud.anj.anj_cloud

import android.app.Application

/// Starts the process's one engine (SyncHost) with the process, so every component that
/// later wakes the app finds the same engine and sync worker. Background sync (spec #28
/// A4): the notification channels, the default-network monitor for "Wi-Fi only", and the
/// periodic WorkManager work when the Background-sync switch is on.
class AnjApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Notifications.createChannels(this)
        SyncHost.engine(this)
        NetworkMonitor.start(this)
        BackgroundSync.ensure(this)
    }
}
