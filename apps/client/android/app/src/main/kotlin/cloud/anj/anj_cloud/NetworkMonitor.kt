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
    @Volatile private var last: Pair<Boolean, Boolean>? = null

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

    fun state(context: Context): Pair<Boolean, Boolean> {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val caps = manager.getNetworkCapabilities(manager.activeNetwork)
        return wifi(caps) to (caps != null && online(caps))
    }

    fun onWifi(context: Context): Boolean = state(context).first

    /// Registered once per process (AnjApplication); callbacks arrive on the main thread.
    fun start(context: Context) {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        manager.registerDefaultNetworkCallback(
            object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
                    report(wifi(caps), online(caps))

                override fun onLost(network: Network) = report(wifi = false, online = false)
            },
            Handler(Looper.getMainLooper()),
        )
    }

    fun online(caps: NetworkCapabilities): Boolean =
        caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)

    private fun report(wifi: Boolean, online: Boolean) {
        val state = wifi to online
        if (last == state) return
        last = state
        BackgroundChannel.push("network", mapOf("wifi" to wifi, "online" to online))
    }
}
