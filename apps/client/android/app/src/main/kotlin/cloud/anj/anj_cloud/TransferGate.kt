package cloud.anj.anj_cloud

/// How transfer progress is shown (spec #28 A4): through the dataSync service when it can
/// run, otherwise as a directly posted notification. Pure state, unit-tested
/// (TransferGateTest); TransferService applies its actions.
///
/// The service is started with startService, never startForegroundService: a service
/// started that way may stop without calling startForeground (a refused start, the
/// Android 15 cap) on every API level, whereas one started with startForegroundService
/// that stops first is reported by the system as "did not then call startForeground" and
/// crashes the app (API 26+). A start the system refuses (app in the background) throws
/// at the call site, so nothing is left half-started.
class TransferGate {
    enum class Action { STOP, START_SERVICE, POST_DIRECT }

    var running = false
        private set

    /// The service was refused (started from the background, Android 12+) or ran out of
    /// its Android 15 dataSync budget: post directly until the app is in the foreground
    /// again, instead of being refused on every update.
    var capped = false
        private set
    var wanted = 0
        private set

    fun update(count: Int): Action {
        wanted = count
        return when {
            count <= 0 -> Action.STOP
            running -> Action.START_SERVICE // updates the running service's notification
            capped -> Action.POST_DIRECT
            else -> Action.START_SERVICE
        }
    }

    fun started() {
        running = true
    }

    fun refused() {
        running = false
        capped = true
    }

    fun stopped() {
        running = false
    }

    /// The user opened the app: a foreground start is allowed again (the Android 15 budget
    /// may still refuse it, which caps again).
    fun appForeground() {
        capped = false
    }
}
