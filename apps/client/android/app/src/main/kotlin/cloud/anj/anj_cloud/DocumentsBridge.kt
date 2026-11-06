package cloud.anj.anj_cloud

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.OperationCanceledException
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * The runner's two channels to the shared Dart code (spec #28 A5):
 *
 * - `cloud.anj/documents`: the DocumentsProvider forwards each call to Dart (DocumentsService)
 *   and waits for the answer on its binder thread; Dart sends `changed` back so open listings
 *   refresh. The provider never reads the manifest or touches the root itself.
 * - `cloud.anj/apps`: "Apps with access" lists and opens apps, lists and withdraws platform
 *   tree grants and persisted single-document grants, and opens documents in other apps with a
 *   per-document grant (R1).
 */
object DocumentsBridge {
    class Failure(val code: String, message: String?) : Exception(message)

    private val main = Handler(Looper.getMainLooper())
    private val background = Executors.newSingleThreadExecutor()
    @Volatile private var channel: MethodChannel? = null

    fun authority(context: Context) = context.packageName + ".documents"

    fun attach(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        val documents = MethodChannel(engine.dartExecutor.binaryMessenger, "cloud.anj/documents")
        documents.setMethodCallHandler { call, result ->
            if (call.method == "changed") {
                val auth = authority(app)
                @Suppress("UNCHECKED_CAST")
                for (id in call.arguments as List<String>) {
                    app.contentResolver.notifyChange(DocumentsContract.buildChildDocumentsUri(auth, id), null)
                    app.contentResolver.notifyChange(DocumentsContract.buildDocumentUri(auth, id), null)
                }
                app.contentResolver.notifyChange(DocumentsContract.buildRootsUri(auth), null)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
        channel = documents
        MethodChannel(engine.dartExecutor.binaryMessenger, "cloud.anj/apps")
            .setMethodCallHandler { call, result -> apps(app, call, result) }
    }

    /**
     * Calls Dart from a binder thread and waits at most [timeoutMs]. Never on the main thread:
     * the answer arrives there. A Dart side that is not listening yet answers `loading`. When
     * the caller cancels or the deadline passes first, an answer that still arrives goes to
     * [onAbandoned] (an open closes its descriptor), never to nobody (review F1).
     */
    fun call(
        context: Context,
        method: String,
        args: Map<String, Any?>,
        timeoutMs: Long,
        signal: CancellationSignal? = null,
        onAbandoned: (Any?) -> Unit = {},
    ): Any? {
        check(Looper.myLooper() != Looper.getMainLooper()) { "documents call on the main thread" }
        if (channel == null) {
            val ready = CountDownLatch(1)
            main.post { SyncHost.engine(context); ready.countDown() }
            ready.await(30, TimeUnit.SECONDS)
        }
        val target = channel ?: throw Failure("loading", "AnJ Cloud is starting.")
        val pending = PendingCall<Any?>(onAbandoned)
        main.post {
            target.invokeMethod(method, args, object : MethodChannel.Result {
                override fun success(result: Any?) = pending.succeed(result)
                override fun error(code: String, message: String?, details: Any?) =
                    pending.fail(Failure(code, message))
                override fun notImplemented() = pending.fail(Failure("loading", "AnJ Cloud is starting."))
            })
        }
        return pending.await(timeoutMs, { signal?.isCanceled == true }, { OperationCanceledException() },
            { Failure("unavailable", "AnJ Cloud did not answer in time.") })
    }

    /** Fire and forget (descriptor closed). */
    fun post(method: String, args: Map<String, Any?>) {
        main.post { channel?.invokeMethod(method, args) }
    }

    fun mimeOf(name: String, directory: Boolean): String {
        if (directory) return DocumentsContract.Document.MIME_TYPE_DIR
        val ext = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: when (ext) {
            "opus" -> "audio/ogg"
            "mkv" -> "video/x-matroska"
            "flac" -> "audio/flac"
            "md" -> "text/markdown"
            else -> "application/octet-stream"
        }
    }

    private fun icon(drawable: Drawable): ByteArray {
        val size = 96
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        bitmap.recycle()
        return out.toByteArray()
    }

    private fun describe(pm: PackageManager, pkg: String): Map<String, Any?>? = try {
        val info = pm.getApplicationInfo(pkg, 0)
        mapOf("package" to pkg, "label" to pm.getApplicationLabel(info).toString(),
            "icon" to icon(pm.getApplicationIcon(info)))
    } catch (e: PackageManager.NameNotFoundException) {
        null
    }

    /** Runs [work] off the main thread and answers on it. */
    private fun async(result: MethodChannel.Result, work: () -> Any?) {
        background.execute {
            val outcome = runCatching(work)
            main.post {
                outcome.fold({ result.success(it) }, { result.error("failed", it.message, null) })
            }
        }
    }

    private fun apps(context: Context, call: MethodCall, result: MethodChannel.Result) {
        val pm = context.packageManager
        val auth = authority(context)
        when (call.method) {
            // Package visibility: the manifest's <queries> for launcher activities (decision #127).
            "installedApps" -> async(result) {
                val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                pm.queryIntentActivities(launcher, 0)
                    .map { it.activityInfo.packageName }
                    .filter { it != context.packageName }
                    .distinct()
                    .mapNotNull { describe(pm, it) }
                    .sortedBy { (it["label"] as String).lowercase() }
            }
            "describe" -> async(result) {
                @Suppress("UNCHECKED_CAST")
                (call.arguments as List<String>).mapNotNull { describe(pm, it) }
            }
            "openApp" -> {
                val launch = pm.getLaunchIntentForPackage(call.arguments as String)
                if (launch == null) result.success(false) else {
                    launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    result.success(runCatching { context.startActivity(launch) }.isSuccess)
                }
            }
            "persistedTrees" -> result.success(
                context.contentResolver.outgoingPersistedUriPermissions
                    .map { it.uri }
                    .filter { it.authority == auth && DocumentsContract.isTreeUri(it) }
                    .map { DocumentsContract.getTreeDocumentId(it) }
                    .distinct())
            // R1: single files an app picked and kept (ACTION_OPEN_DOCUMENT + takePersistable…);
            // one entry per app's grant. The platform does not say which app holds it.
            "persistedDocuments" -> result.success(
                context.contentResolver.outgoingPersistedUriPermissions
                    .filter { it.uri.authority == auth && !DocumentsContract.isTreeUri(it.uri) }
                    .mapNotNull { grant ->
                        runCatching { DocumentsContract.getDocumentId(grant.uri) }.getOrNull()?.let {
                            mapOf("id" to it, "read" to grant.isReadPermission,
                                "write" to grant.isWritePermission)
                        }
                    })
            // Every app's grant on that one document, persisted or not (the provider owns the
            // URI, so the platform withdraws them all, whoever holds them).
            "revokeDocument" -> {
                val uri = DocumentsContract.buildDocumentUri(auth, call.argument<String>("id")!!)
                context.revokeUriPermission(uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                result.success(null)
            }
            "revokeTree" -> {
                val pkg = call.argument<String>("package")!!
                val uri = DocumentsContract.buildTreeDocumentUri(auth, call.argument<String>("id")!!)
                context.revokeUriPermission(pkg, uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                result.success(null)
            }
            // R1: a single document, opened in an app the user picks, with a per-document grant.
            "openDocument" -> {
                val uri = DocumentsContract.buildDocumentUri(auth, call.argument<String>("id")!!)
                val view = Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, mimeOf(call.argument<String>("name")!!, false))
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_ACTIVITY_NEW_TASK)
                result.success(start(context, Intent.createChooser(view, null)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)))
            }
            // Show in folder: the system Files app at that folder of the AnJ Cloud root.
            "showFolder" -> {
                val uri = DocumentsContract.buildDocumentUri(auth, call.argument<String>("id")!!)
                val browse = Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                result.success(start(context, browse))
            }
            else -> result.notImplemented()
        }
    }

    private fun start(context: Context, intent: Intent): Boolean = try {
        context.startActivity(intent); true
    } catch (e: ActivityNotFoundException) {
        false
    } catch (e: SecurityException) {
        false
    }
}
