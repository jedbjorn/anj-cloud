package cloud.anj.anj_cloud

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.lang.ref.WeakReference
import java.util.concurrent.Executors

/// Add files, Add folder and "Save to AnJ Cloud" (spec #43), the runner's half.
///
/// The system picker (ACTION_OPEN_DOCUMENT, any type, several files; ACTION_OPEN_DOCUMENT_TREE
/// for a folder) and the Share sheet give MainActivity a one-time read grant; no storage
/// permission and no persistable grant is taken. Each source is read through that grant into a
/// private copy under the app's cache (outside the synced root), stopping once it passes the
/// upload limit; the Dart side hands the copy's path to the sync worker, which alone writes into
/// the root. Copies an earlier process left behind are removed when the engine starts.
object AddFilesChannel {
    const val NAME = "cloud.anj.anj_cloud/add"
    const val PICK_FILES = 4301
    const val PICK_FOLDER = 4302
    private const val TAG = "AnjAddFiles"
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var channel: MethodChannel? = null
    private var activity: WeakReference<Activity>? = null
    private var pick: MethodChannel.Result? = null
    private var tree: Uri? = null
    @Volatile private var cancelListing = false
    @Volatile private var cancelOpen = false
    /// The last share received and not yet taken by Dart.
    private var share: List<Map<String, Any?>>? = null

    private class Stop(val code: String) : Exception(code)

    private fun temp(context: Context) = File(context.cacheDir, "anj-add")

    fun register(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        io.execute { temp(app).deleteRecursively() }
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, NAME).apply {
            setMethodCallHandler { call, result -> handle(app, call, result) }
        }
    }

    /// The activity the pickers start from and the share screen leaves.
    fun attach(host: Activity) {
        activity = WeakReference(host)
    }

    fun detach(host: Activity) {
        if (activity?.get() === host) activity = null
    }

    private fun handle(app: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFiles" -> startPick(result, PICK_FILES) {
                Intent(Intent.ACTION_OPEN_DOCUMENT)
                    .addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("*/*")
                    .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            }
            "pickFolder" -> startPick(result, PICK_FOLDER) { Intent(Intent.ACTION_OPEN_DOCUMENT_TREE) }
            "listFolder" -> {
                val picked = tree
                if (picked == null) {
                    result.success(null)
                    return
                }
                cancelListing = false
                io.execute {
                    val listed = runCatching { list(app, picked) }
                    tree = null
                    main.post {
                        listed.fold(
                            { result.success(it) },
                            { if (it is Stop) result.success(null) else result.error("unreadable", it.javaClass.simpleName, null) },
                        )
                    }
                }
            }
            "cancelListing" -> {
                cancelListing = true
                result.success(null)
            }
            "open" -> {
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                val limit = call.argument<Number>("limit")?.toLong() ?: 0L
                if (uri == null || limit <= 0) {
                    result.error("unreadable", "No source.", null)
                    return
                }
                cancelOpen = false
                io.execute {
                    val copied = runCatching { copy(app, uri, limit) }
                    main.post {
                        copied.fold(
                            { result.success(it) },
                            {
                                val code = (it as? Stop)?.code ?: "unreadable"
                                if (code == "unreadable") Log.i(TAG, "source unreadable: ${it.javaClass.simpleName}")
                                result.error(code, code, null)
                            },
                        )
                    }
                }
            }
            "cancelOpen" -> {
                cancelOpen = true
                result.success(null)
            }
            "release" -> {
                val path = call.argument<String>("path")
                val file = path?.let(::File)
                if (file != null && file.parentFile?.canonicalPath == temp(app).canonicalPath) file.delete()
                result.success(null)
            }
            "freeBytes" -> {
                val path = call.argument<String>("path")
                result.success(path?.let { runCatching { StatFs(it).availableBytes }.getOrNull() })
            }
            "takeShare" -> {
                val items = share
                share = null
                result.success(items?.let { mapOf("items" to it) })
            }
            "leaveShare" -> {
                activity?.get()?.moveTaskToBack(true)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun startPick(result: MethodChannel.Result, request: Int, intent: () -> Intent) {
        val host = activity?.get()
        if (host == null || pick != null) {
            result.error("busy", "The picker cannot open now.", null)
            return
        }
        pick = result
        try {
            host.startActivityForResult(intent(), request)
        } catch (error: Exception) {
            pick = null
            result.error("unavailable", "No picker on this phone.", null)
        }
    }

    /// From MainActivity.onActivityResult; true when the result was a picker's.
    fun onActivityResult(host: Activity, request: Int, code: Int, data: Intent?): Boolean {
        if (request != PICK_FILES && request != PICK_FOLDER) return false
        val result = pick ?: return true
        pick = null
        if (code != Activity.RESULT_OK || data == null) {
            result.success(null)
            return true
        }
        val app = host.applicationContext
        if (request == PICK_FOLDER) {
            val picked = data.data
            if (picked == null) {
                result.success(null)
                return true
            }
            tree = picked
            io.execute {
                val name = runCatching {
                    val id = DocumentsContract.getTreeDocumentId(picked)
                    describe(app, DocumentsContract.buildDocumentUriUsingTree(picked, id))["path"]
                }.getOrNull() ?: "Folder"
                main.post { result.success(name) }
            }
            return true
        }
        val uris = buildList {
            val clip = data.clipData
            if (clip != null) for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(::add)
            if (isEmpty()) data.data?.let(::add)
        }
        io.execute {
            val items = uris.map { describe(app, it) }
            main.post { result.success(items) }
        }
        return true
    }

    /// A share reached MainActivity (onCreate or onNewIntent); true when it was one.
    fun received(host: Activity, intent: Intent?): Boolean {
        if (intent == null || (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return false
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return false
        val uris = mutableListOf<Uri>()
        if (action == Intent.ACTION_SEND) {
            stream(intent)?.let(uris::add)
        } else {
            streams(intent)?.let(uris::addAll)
        }
        if (uris.isEmpty()) {
            val clip = intent.clipData
            if (clip != null) for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(uris::add)
        }
        val app = host.applicationContext
        io.execute {
            val items = uris.map { describe(app, it) }
            main.post {
                share = items
                channel?.invokeMethod("shareArrived", null)
            }
        }
        // Handled: a later recreation of the activity does not offer it again.
        host.intent = Intent(Intent.ACTION_MAIN)
        return true
    }

    @Suppress("DEPRECATION")
    private fun stream(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableExtra(Intent.EXTRA_STREAM)

    @Suppress("DEPRECATION")
    private fun streams(intent: Intent): List<Uri>? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)

    private fun Cursor.string(column: String): String? =
        getColumnIndex(column).takeIf { it >= 0 && !isNull(it) }?.let(::getString)

    private fun Cursor.long(column: String): Long? =
        getColumnIndex(column).takeIf { it >= 0 && !isNull(it) }?.let(::getLong)

    /// Name, size and whether it has a byte stream, as its provider reports them.
    private fun describe(app: Context, uri: Uri): Map<String, Any?> {
        var name: String? = null
        var size: Long? = null
        var virtual = false
        runCatching {
            app.contentResolver.query(uri, null, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    name = c.string(OpenableColumns.DISPLAY_NAME)
                    size = c.long(OpenableColumns.SIZE)
                    virtual = ((c.long(Document.COLUMN_FLAGS) ?: 0L) and Document.FLAG_VIRTUAL_DOCUMENT.toLong()) != 0L
                }
            }
        }
        return mapOf(
            "path" to (name ?: uri.lastPathSegment?.substringAfterLast('/')?.ifEmpty { null } ?: "file"),
            "size" to size,
            "virtual" to virtual,
            "uri" to uri.toString(),
        )
    }

    /// The picked tree, the folder itself first and every folder before its contents.
    private fun list(app: Context, picked: Uri): List<Map<String, Any?>> {
        val rootId = DocumentsContract.getTreeDocumentId(picked)
        val top = (describe(app, DocumentsContract.buildDocumentUriUsingTree(picked, rootId))["path"] as String)
        val out = mutableListOf<Map<String, Any?>>(mapOf("path" to top, "directory" to true))
        val columns = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
            Document.COLUMN_FLAGS,
        )
        fun walk(id: String, path: String) {
            if (cancelListing) throw Stop("cancelled")
            val children = mutableListOf<Map<String, Any?>>()
            app.contentResolver.query(
                DocumentsContract.buildChildDocumentsUriUsingTree(picked, id), columns, null, null, null,
            )?.use { c ->
                while (c.moveToNext()) {
                    if (cancelListing) throw Stop("cancelled")
                    val child = c.string(Document.COLUMN_DOCUMENT_ID) ?: continue
                    val name = c.string(Document.COLUMN_DISPLAY_NAME) ?: continue
                    val flags = c.long(Document.COLUMN_FLAGS) ?: 0L
                    children += mapOf(
                        "id" to child,
                        "path" to "$path/$name",
                        "directory" to (c.string(Document.COLUMN_MIME_TYPE) == Document.MIME_TYPE_DIR),
                        "size" to c.long(Document.COLUMN_SIZE),
                        "virtual" to ((flags and Document.FLAG_VIRTUAL_DOCUMENT.toLong()) != 0L),
                    )
                }
            }
            for (child in children.sortedBy { (it["path"] as String).lowercase() }) {
                val childId = child["id"] as String
                if (child["directory"] == true) {
                    out += mapOf("path" to child["path"], "directory" to true)
                    walk(childId, child["path"] as String)
                } else {
                    out += mapOf(
                        "path" to child["path"],
                        "size" to child["size"],
                        "virtual" to child["virtual"],
                        "uri" to DocumentsContract.buildDocumentUriUsingTree(picked, childId).toString(),
                    )
                }
            }
        }
        walk(rootId, top)
        return out
    }

    /// Reads [uri] through its grant into a private copy; stops past [limit] bytes or on cancel.
    private fun copy(app: Context, uri: Uri, limit: Long): String {
        val directory = temp(app).apply { mkdirs() }
        val file = File.createTempFile("add-", ".part", directory)
        try {
            val input = app.contentResolver.openInputStream(uri) ?: throw Stop("unreadable")
            input.use { source ->
                FileOutputStream(file).use { out ->
                    val buffer = ByteArray(256 * 1024)
                    var total = 0L
                    while (true) {
                        if (cancelOpen) throw Stop("cancelled")
                        val n = source.read(buffer)
                        if (n < 0) break
                        total += n
                        if (total > limit) throw Stop("overLimit")
                        out.write(buffer, 0, n)
                    }
                    out.fd.sync()
                }
            }
            if (cancelOpen) throw Stop("cancelled")
            return file.path
        } catch (error: Throwable) {
            file.delete()
            throw error
        }
    }
}
