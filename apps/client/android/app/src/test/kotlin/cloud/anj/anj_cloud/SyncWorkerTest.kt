package cloud.anj.anj_cloud

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncWorkerTest {
    @Test
    fun theWifiFollowUpSkipsOffWifiOnly() {
        assertTrue(SyncWorker.skipOffWifi(setOf(BackgroundSync.WIFI), onWifi = false))
        assertFalse(SyncWorker.skipOffWifi(setOf(BackgroundSync.WIFI), onWifi = true))
        // Periodic and prompt runs list on any network (R3).
        assertFalse(SyncWorker.skipOffWifi(setOf(BackgroundSync.PERIODIC), onWifi = false))
        assertFalse(SyncWorker.skipOffWifi(setOf(BackgroundSync.PROMPT), onWifi = false))
    }
}
