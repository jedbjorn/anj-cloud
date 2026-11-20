package cloud.anj.anj_cloud

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper

/// Reports whether the default network is Wi-Fi (or Ethernet) to the engine, for the
/// network setting (decision #108 Q4). "Wi-Fi only" holds file bytes otherwise; listings,
/// certificate pickup and update checks run on any network (spec #28 R3). A VPN counts as
/// Wi-Fi when it is unmetered, which it is over Wi-Fi. It also reports when the default network
/// is usable (validated internet), so a client that could not reach the server retries at once
/// instead of waiting out its backoff.
object NetworkMonitor {
    data class State(val wifi: Boolean, val online: Boolean, val route: Long?) {
        fun fields(): Map<String, Any?> = mapOf("wifi" to wifi, "online" to online, "route" to route)
    }

    @Volatile private var last: State? = null

    fun wifi(caps: NetworkCapabilities?): Boolean {
        if (caps == null) return false
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
        ) {
            return true
        }
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
            !caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }

    fun state(context: Context): State {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val network = manager.activeNetwork
        val caps = manager.getNetworkCapabilities(network)
        return State(wifi(caps), caps != null && online(caps), network?.networkHandle)
    }

    fun onWifi(context: Context): Boolean = state(context).wifi

    /// Registered once per process (AnjApplication); callbacks arrive on the main thread.
    fun start(context: Context) {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        manager.registerDefaultNetworkCallback(
            object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
                    report(State(wifi(caps), online(caps), network.networkHandle))

                override fun onLost(network: Network) {
                    if (last?.route == network.networkHandle) report(State(false, false, null))
                }
            },
            Handler(Looper.getMainLooper()),
        )
    }

    fun online(caps: NetworkCapabilities): Boolean =
        caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)

    private fun report(state: State) {
        if (last == state) return
        last = state
        BackgroundChannel.push("network", state.fields())
    }
}
