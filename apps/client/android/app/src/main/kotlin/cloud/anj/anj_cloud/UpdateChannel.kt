package cloud.anj.anj_cloud

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.content.pm.SigningInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.lang.ref.WeakReference
import java.util.concurrent.Executors

/// The in-app updater's Android half (spec #28 A7, decision #108 Q6). The Dart updater
/// downloads the package over the device's mTLS connection and checks its SHA-256 and size;
/// this channel reports what the installed app and the downloaded archive are (package,
/// versionCode, signing certificates) so the Dart side can refuse a mismatch before Android
/// is asked anything, and installs through a PackageInstaller session.
///
/// Every session requires the user's confirmation (USER_ACTION_REQUIRED): once AnJ Cloud is
/// the installer of record, Android 12+ would otherwise let it update itself silently. The
/// bytes written into the session are hashed as they are written and must equal the
/// manifest's SHA-256 and size, so what Android installs is exactly what was verified.
object UpdateChannel {
    const val NAME = "cloud.anj.anj_cloud/updater"
    const val ACTION_STATUS = "cloud.anj.anj_cloud.UPDATE_STATUS"
    /// One logcat line per session event (never a path or package bytes), so an install
    /// attempt is visible in evidence.
    const val TAG = "AnjUpdater"
    private val pending = ConcurrentHashMap<Int, MethodChannel.Result>()
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /// The resumed MainActivity, if any. Android's confirmation is started from it, so it sits
    /// in AnJ Cloud's own task: leaving and reopening the app brings it back instead of
    /// leaving it behind in a task of its own.
    private var activity: WeakReference<Activity>? = null

    /// A confirmation that arrived while no activity was resumed; shown on the next resume.
    private var waitingConfirmation: Intent? = null

    fun resumed(host: Activity) {
        activity = WeakReference(host)
        val confirm = waitingConfirmation ?: return
        waitingConfirmation = null
        runCatching { host.startActivity(confirm) }
            .onFailure { Log.i(TAG, "install confirmation could not open: ${it.javaClass.simpleName}") }
    }

    fun paused(host: Activity) {
        if (activity?.get() === host) activity = null
    }

    /// From the session status receiver: show Android's confirmation in the app's task.
    fun confirm(context: Context, session: Int, intent: Intent) {
        val host = activity?.get()
        if (host != null && !host.isFinishing) {
            runCatching { host.startActivity(intent) }.onSuccess { return }
        }
        Log.i(TAG, "install session $session: confirmation waits for the app")
        waitingConfirmation = intent
    }

    fun register(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "installed" -> result.success(facts(installedInfo(app)))
                "inspect" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("inspect", "No package path.", null)
                    } else {
                        io.execute {
                            val facts = runCatching { archiveInfo(app, path)?.let(::facts) }.getOrNull()
                            main.post { result.success(facts) }
                        }
                    }
                }
                "canRequestInstalls" -> result.success(app.packageManager.canRequestPackageInstalls())
                "freeBytes" -> {
                    val path = call.argument<String>("path")
                    result.success(path?.let { runCatching { StatFs(it).availableBytes }.getOrNull() })
                }
                "cancelInstall" -> {
                    // The user left the confirmation or it never opened: abandon every session
                    // still waiting and answer its pending install as declined.
                    waitingConfirmation = null
                    val ids = pending.keys.toList()
                    io.execute {
                        for (id in ids) {
                            runCatching { app.packageManager.packageInstaller.abandonSession(id) }
                            Log.i(TAG, "install session $id abandoned: cancelled")
                            finish(id, "declined", "cancelled")
                        }
                        main.post { result.success(ids.size) }
                    }
                }
                "discardSessions" -> {
                    // Sessions this app created and never finished (a process killed mid-install).
                    io.execute {
                        val installer = app.packageManager.packageInstaller
                        var count = 0
                        for (info in installer.mySessions) {
                            if (pending.containsKey(info.sessionId)) continue
                            if (runCatching { installer.abandonSession(info.sessionId) }.isSuccess) count++
                        }
                        if (count > 0) Log.i(TAG, "abandoned $count earlier install sessions")
                        main.post { result.success(count) }
                    }
                }
                "openInstallPermission" -> {
                    app.startActivity(
                        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${app.packageName}"))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(null)
                }
                "install" -> {
                    val path = call.argument<String>("path")
                    val sha = call.argument<String>("sha256")
                    val size = call.argument<Number>("size")?.toLong()
                    if (path == null || sha == null || size == null || size <= 0) {
                        result.error("install", "Incomplete install request.", null)
                    } else {
                        io.execute { install(app, path, sha, size, result) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION") // the PackageInfoFlags overloads need API 33; minSdk is 31
    private fun installedInfo(app: Context): PackageInfo =
        app.packageManager.getPackageInfo(app.packageName, PackageManager.GET_SIGNING_CERTIFICATES)

    @Suppress("DEPRECATION")
    private fun archiveInfo(app: Context, path: String): PackageInfo? =
        app.packageManager.getPackageArchiveInfo(path, PackageManager.GET_SIGNING_CERTIFICATES)

    private fun facts(info: PackageInfo): Map<String, Any?> = mapOf(
        "package" to info.packageName,
        "versionCode" to info.longVersionCode,
        "versionName" to (info.versionName ?: ""),
        "signers" to signers(info.signingInfo),
    )

    /// The certificates that signed the APK's contents now (not past rotated ones).
    private fun signers(info: SigningInfo?): List<String> =
        info?.apkContentsSigners?.map { hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray())) }
            ?: emptyList()

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    private class Mismatch(message: String) : Exception(message)

    private fun install(app: Context, path: String, sha: String, size: Long, result: MethodChannel.Result) {
        val installer = app.packageManager.packageInstaller
        var sessionId = -1
        try {
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                setAppPackageName(app.packageName)
                setSize(size)
                setInstallReason(PackageManager.INSTALL_REASON_USER)
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
            }
            sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                val digest = MessageDigest.getInstance("SHA-256")
                var written = 0L
                FileInputStream(File(path)).use { input ->
                    session.openWrite("base.apk", 0, size).use { out ->
                        val buffer = ByteArray(256 * 1024)
                        while (true) {
                            val n = input.read(buffer)
                            if (n < 0) break
                            written += n
                            if (written > size) break
                            digest.update(buffer, 0, n)
                            out.write(buffer, 0, n)
                        }
                        session.fsync(out)
                    }
                }
                if (written != size || hex(digest.digest()) != sha) {
                    throw Mismatch("The update file changed after it was checked, so it was discarded.")
                }
                pending[sessionId] = result
                val status = Intent(app, UpdateStatusReceiver::class.java).setAction(ACTION_STATUS)
                // Mutable: the installer adds the status extras to this explicit, unexported intent.
                val sender = PendingIntent.getBroadcast(
                    app, sessionId, status, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                )
                session.commit(sender.intentSender)
                Log.i(TAG, "install session $sessionId committed ($size bytes, verified)")
            }
        } catch (error: Exception) {
            if (sessionId >= 0) {
                pending.remove(sessionId)
                runCatching { installer.abandonSession(sessionId) }
                Log.i(TAG, "install session $sessionId abandoned: ${error.javaClass.simpleName}")
            }
            val message = (error as? Mismatch)?.message ?: "Android could not start the install."
            main.post { result.success(mapOf("outcome" to "failed", "message" to message)) }
        }
    }

    fun finish(sessionId: Int, outcome: String, message: String?) {
        Log.i(TAG, "install session $sessionId: $outcome")
        val result = pending.remove(sessionId) ?: return
        main.post { result.success(mapOf("outcome" to outcome, "message" to message)) }
    }
}

/// The install session's status (unexported: only the PendingIntent the system holds reaches
/// it). Android's confirmation is started from here; the user's answer comes back as
/// STATUS_SUCCESS (normally after this process was replaced) or STATUS_FAILURE_ABORTED.
class UpdateStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != UpdateChannel.ACTION_STATUS) return
        val session = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                if (confirm == null) {
                    UpdateChannel.finish(session, "failed", "Android did not show its install confirmation.")
                } else {
                    UpdateChannel.confirm(context, session, confirm)
                }
            }
            PackageInstaller.STATUS_SUCCESS -> UpdateChannel.finish(session, "installed", null)
            PackageInstaller.STATUS_FAILURE_ABORTED -> UpdateChannel.finish(session, "declined", null)
            else -> UpdateChannel.finish(session, "failed", failure(status))
        }
    }

    private fun failure(status: Int): String = when (status) {
        PackageInstaller.STATUS_FAILURE_STORAGE -> "Not enough storage on this phone to install the update."
        PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "The update is not compatible with this phone."
        PackageInstaller.STATUS_FAILURE_CONFLICT -> "Android refused the update because it conflicts with the installed app."
        PackageInstaller.STATUS_FAILURE_INVALID -> "Android found the update package invalid."
        PackageInstaller.STATUS_FAILURE_BLOCKED -> "Android blocked the update."
        else -> "Android did not install the update."
    }
}
