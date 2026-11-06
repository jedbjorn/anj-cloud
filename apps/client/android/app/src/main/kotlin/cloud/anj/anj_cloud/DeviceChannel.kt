package cloud.anj.anj_cloud

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import java.io.File
import java.security.KeyStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/// `cloud.anj/device`: facts the shared Dart code cannot read on Android (spec #28 A3).
/// `label` is the enrolment label (spec #28 Pairing step 4): the user's device name
/// (Settings.Global.DEVICE_NAME, no permission needed), else the model. Dart clips it to
/// 80 characters. Platform.localHostname is "localhost" on Android and is not used.
/// `resetSecrets` (PR #60 review F5) wipes flutter_secure_storage without the plugin, for the
/// case where the plugin itself cannot start and every call through it fails: its
/// SharedPreferences files (FlutterSecure*) and its AndroidKeyStore entries (aliases under
/// <package>.FlutterSecureStorage). It touches nothing else; the profile, manifest and files
/// stay. The app then restarts, because the plugin keeps its failed state for the process.
object DeviceChannel {
    private const val PREFIX = "FlutterSecure"

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, "cloud.anj/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "label" -> {
                    val name = Settings.Global.getString(app.contentResolver, Settings.Global.DEVICE_NAME)
                    result.success(if (name.isNullOrBlank()) Build.MODEL else name)
                }
                "resetSecrets" -> {
                    try {
                        resetSecrets(app)
                    } catch (e: Exception) {
                        result.error("reset-failed", e.javaClass.simpleName, null)
                        return@setMethodCallHandler
                    }
                    result.success(null)
                    // Restart after the reply reaches Dart, in a fresh process.
                    Handler(Looper.getMainLooper()).postDelayed({ restart(app) }, 300)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun resetSecrets(context: Context) {
        val prefs = File(context.applicationInfo.dataDir, "shared_prefs")
        prefs.listFiles()?.filter { it.name.startsWith(PREFIX) && it.name.endsWith(".xml") }?.forEach {
            context.deleteSharedPreferences(it.name.removeSuffix(".xml"))
        }
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = context.packageName + ".FlutterSecureStorage"
        keys.aliases().toList().filter { it.startsWith(alias) }.forEach { keys.deleteEntry(it) }
    }

    private fun restart(context: Context) {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        context.startActivity(Intent.makeRestartActivityTask(launch.component))
        Runtime.getRuntime().exit(0)
    }
}
