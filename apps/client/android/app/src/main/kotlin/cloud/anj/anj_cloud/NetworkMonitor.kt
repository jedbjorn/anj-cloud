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
/// Wi-Fi when it is unmetered, which it is over Wi-Fi.
object NetworkMonitor {
    @Volatile private var last: Boolean? = null

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

    fun onWifi(context: Context): Boolean {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        return wifi(manager.getNetworkCapabilities(manager.activeNetwork))
    }

    /// Registered once per process (AnjApplication); callbacks arrive on the main thread.
    fun start(context: Context) {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        manager.registerDefaultNetworkCallback(
            object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
                    report(wifi(caps))

                override fun onLost(network: Network) = report(false)
            },
            Handler(Looper.getMainLooper()),
        )
    }

    private fun report(wifi: Boolean) {
        if (last == wifi) return
        last = wifi
        BackgroundChannel.push("network", mapOf("wifi" to wifi))
    }
}
