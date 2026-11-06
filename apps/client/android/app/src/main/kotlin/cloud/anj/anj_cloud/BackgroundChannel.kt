package cloud.anj.anj_cloud

import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/// The `cloud.anj/background` channel between the runner and the Dart engine (spec #28 A4;
/// lib/platform/android/background.dart). Installed on SyncHost's one engine before its
/// Dart entry point runs. Every call happens on the main thread.
object BackgroundChannel {
    const val NAME = "cloud.anj/background"
    private const val TAG = "AnjBackground"
    private var channel: MethodChannel? = null
    private lateinit var app: Context

    /// Completes when the Dart side has installed its handler (its `attach` call).
    var attached = CompletableDeferred<Unit>()
        private set

    fun install(context: Context, engine: FlutterEngine) {
        app = context.applicationContext
        attached = CompletableDeferred()
        val created = MethodChannel(engine.dartExecutor.binaryMessenger, NAME)
        created.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "attach" -> {
                        attached.complete(Unit)
                        result.success(
                            mapOf(
                                "notifications" to Notifications.allowed(app),
                                "wifi" to NetworkMonitor.onWifi(app),
                            ),
                        )
                    }
                    "transfers" -> {
                        val count = call.argument<Int>("count") ?: 0
                        val waiting = call.argument<Int>("waiting") ?: 0
                        TransferService.update(app, count)
                        if (waiting > 0) BackgroundSync.requestWifiRun(app)
                        result.success(null)
                    }
                    "attention" -> {
                        @Suppress("UNCHECKED_CAST")
                        val items = call.argument<List<Map<String, String>>>("items") ?: emptyList()
                        // Withdraw resolved items first: a path with a new problem is posted
                        // again under the same id.
                        for (path in call.argument<List<String>>("resolved") ?: emptyList()) {
                            Notifications.cancelAttention(app, path)
                        }
                        for (item in items) Notifications.attention(app, item)
                        result.success(null)
                    }
                    "prompt" -> {
                        BackgroundSync.requestPrompt(app)
                        result.success(null)
                    }
                    "openNotificationSettings" -> {
                        app.startActivity(
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, app.packageName)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                        result.success(null)
                    }
                    "backgroundSync.get" -> result.success(switchState())
                    "backgroundSync.set" -> {
                        BackgroundSync.setEnabled(app, call.argument<Boolean>("enabled") == true)
                        result.success(switchState())
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                Log.w(TAG, "${call.method} failed", error)
                result.error("background", error.message, null)
            }
        }
        channel = created
    }

    private fun switchState() = mapOf(
        "enabled" to BackgroundSync.enabled(app),
        "source" to BackgroundSync.source(app),
    )

    /// Pushes to Dart; dropped before the Dart side has attached (its attach reads the
    /// current state instead).
    fun push(method: String, arguments: Any?) {
        if (!attached.isCompleted) return
        channel?.invokeMethod(method, arguments)
    }

    /// One background run: a complete pass, answered when it ends. Null when the Dart
    /// side did not answer (not attached, or it failed).
    suspend fun backgroundRun(): Map<*, *>? {
        val target = channel ?: return null
        return suspendCancellableCoroutine { continuation ->
            target.invokeMethod(
                "backgroundRun",
                null,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (continuation.isActive) continuation.resume(result as? Map<*, *>)
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        Log.w(TAG, "backgroundRun: $code $message")
                        if (continuation.isActive) continuation.resume(null)
                    }

                    override fun notImplemented() {
                        if (continuation.isActive) continuation.resume(null)
                    }
                },
            )
        }
    }
}
