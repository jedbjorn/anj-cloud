package cloud.anj.anj_cloud

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.database.MatrixCursor
import android.os.Binder
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.os.Process
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import java.io.File
import java.io.FileNotFoundException

/**
 * The "AnJ Cloud" documents provider (spec #28 A5, decision #127) over the engine's app-private
 * root. Protected by MANAGE_DOCUMENTS, so only the system Files app and picker query it directly;
 * other apps hold platform URI grants. On top of those grants the provider enforces our own
 * allowlist on every call: it identifies the caller here (this app, the system document UI, an
 * app with a per-document grant for exactly this document, or any other app by
 * [getCallingPackage]) and the shared Dart DocumentsService decides. An app the user has not
 * approved for a folder is refused even if it picked that folder in the system picker.
 *
 * Document ids are "root", "n:<id>" (a stable id that follows rename and move) and "w:<name>"
 * (an editor working copy, reached only through a per-document grant). Descriptors are opened by
 * the sync worker through the descriptor-relative boundary; this class reopens the worker's
 * read-only descriptor through /proc/self/fd with the app's mode (the same inode) and reports
 * the app's close back, so the registry and the release guard see every open descriptor.
 */
class AnjDocumentsProvider : DocumentsProvider() {
    private val authority by lazy { DocumentsBridge.authority(context!!) }
    private val closeHandler by lazy {
        Handler(HandlerThread("anj-documents-close").apply { start() }.looper)
    }

    private val rootColumns = arrayOf(Root.COLUMN_ROOT_ID, Root.COLUMN_FLAGS, Root.COLUMN_TITLE,
        Root.COLUMN_DOCUMENT_ID, Root.COLUMN_ICON, Root.COLUMN_SUMMARY)
    private val documentColumns = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
        Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED,
        Document.COLUMN_FLAGS, Document.COLUMN_SUMMARY)

    override fun onCreate(): Boolean = true

    private fun title(): String = context!!.applicationInfo.loadLabel(context!!.packageManager).toString()

    /** Who is calling, as the platform established it, for document [id] when one is named. */
    private fun caller(id: String?): Map<String, Any?> {
        val ctx = context!!
        if (Binder.getCallingUid() == Process.myUid()) return mapOf("kind" to "own")
        if (ctx.checkCallingPermission(Manifest.permission.MANAGE_DOCUMENTS) ==
            PackageManager.PERMISSION_GRANTED) return mapOf("kind" to "system")
        val pkg = try { callingPackage } catch (e: SecurityException) { null }
        if (id != null) {
            // A per-document grant names this document's own URI; a tree grant never does.
            val uri = DocumentsContract.buildDocumentUri(authority, id)
            val read = ctx.checkCallingUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) ==
                PackageManager.PERMISSION_GRANTED
            val write = ctx.checkCallingUriPermission(uri, Intent.FLAG_GRANT_WRITE_URI_PERMISSION) ==
                PackageManager.PERMISSION_GRANTED
            if (read || write) {
                return mapOf("kind" to "document", "package" to pkg, "documentRead" to read,
                    "documentWrite" to write)
            }
        }
        return mapOf("kind" to "app", "package" to pkg)
    }

    private fun call(method: String, args: Map<String, Any?>, timeoutMs: Long = 30_000,
                     signal: CancellationSignal? = null, onAbandoned: (Any?) -> Unit = {}): Any? = try {
        DocumentsBridge.call(context!!, method, args, timeoutMs, signal, onAbandoned)
    } catch (e: DocumentsBridge.Failure) {
        throw when (e.code) {
            "denied" -> SecurityException(e.message)
            else -> FileNotFoundException(e.message)
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun map(value: Any?) = value as Map<String, Any?>

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val ready = try { map(call("roots", emptyMap(), 5_000))["ready"] == true } catch (e: Exception) { false }
        return MatrixCursor(projection ?: rootColumns).apply {
            newRow().apply {
                add(Root.COLUMN_ROOT_ID, "anj")
                add(Root.COLUMN_FLAGS, Root.FLAG_SUPPORTS_IS_CHILD or (if (ready) Root.FLAG_SUPPORTS_CREATE else 0))
                add(Root.COLUMN_TITLE, title())
                add(Root.COLUMN_DOCUMENT_ID, "root")
                add(Root.COLUMN_ICON, R.mipmap.ic_launcher)
                add(Root.COLUMN_SUMMARY, if (ready) null else "Starting…")
            }
            setNotificationUri(context!!.contentResolver, DocumentsContract.buildRootsUri(authority))
        }
    }

    private fun addRow(cursor: MatrixCursor, row: Map<String, Any?>) {
        val directory = row["kind"] == "directory"
        val name = row["name"] as String? ?: title()
        var flags = 0
        if (row["write"] == true) flags = flags or Document.FLAG_SUPPORTS_WRITE
        if (row["create"] == true) flags = flags or Document.FLAG_DIR_SUPPORTS_CREATE
        if (row["delete"] == true) flags = flags or Document.FLAG_SUPPORTS_DELETE
        if (row["rename"] == true) flags = flags or Document.FLAG_SUPPORTS_RENAME
        if (row["move"] == true) flags = flags or Document.FLAG_SUPPORTS_MOVE
        cursor.newRow().apply {
            add(Document.COLUMN_DOCUMENT_ID, row["id"])
            add(Document.COLUMN_DISPLAY_NAME, name)
            add(Document.COLUMN_MIME_TYPE, DocumentsBridge.mimeOf(name, directory))
            add(Document.COLUMN_SIZE, (row["size"] as Number?)?.toLong())
            add(Document.COLUMN_LAST_MODIFIED, (row["modified"] as Number?)?.toLong())
            add(Document.COLUMN_FLAGS, flags)
            add(Document.COLUMN_SUMMARY, if (row["cloudOnly"] == true) "In the cloud" else null)
        }
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val row = map(call("document", mapOf("id" to documentId, "caller" to caller(documentId))))
        return MatrixCursor(projection ?: documentColumns).also { addRow(it, row) }
    }

    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?,
                                     sortOrder: String?): Cursor {
        val result = map(call("children", mapOf("id" to parentDocumentId, "caller" to caller(null))))
        val cursor = MatrixCursor(projection ?: documentColumns)
        @Suppress("UNCHECKED_CAST")
        for (row in result["rows"] as List<Map<String, Any?>>) addRow(cursor, row)
        if (result["loading"] == true) {
            cursor.extras = Bundle().apply { putBoolean(DocumentsContract.EXTRA_LOADING, true) }
        }
        cursor.setNotificationUri(context!!.contentResolver,
            DocumentsContract.buildChildDocumentsUri(authority, parentDocumentId))
        return cursor
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean = try {
        call("isChild", mapOf("parent" to parentDocumentId, "id" to documentId)) == true
    } catch (e: Exception) {
        false
    }

    override fun findDocumentPath(parentDocumentId: String?, childDocumentId: String): DocumentsContract.Path {
        @Suppress("UNCHECKED_CAST")
        val ids = call("findPath", mapOf("parent" to parentDocumentId, "id" to childDocumentId,
            "caller" to caller(null))) as List<String>
        // A provider root id identifies the sidebar root; "root" is its document id.
        return DocumentsContract.Path(if (parentDocumentId == null) "anj" else null, ids)
    }

    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        val bits = ParcelFileDescriptor.parseMode(mode)
        // An open may download a Cloud-only file into a working copy first. Dart gives up at 600 s
        // (and closes a descriptor the worker returns later); this deadline is longer, so Dart's
        // answer always arrives first. A cancelled open closes what it still receives (review F1).
        val result = map(call("open", mapOf("id" to documentId, "mode" to mode, "caller" to caller(documentId)),
            OPEN_TIMEOUT_MS, signal, ::closeAbandoned))
        val fd = (result["fd"] as Number).toInt()
        val token = result["token"] as String
        val closed = { DocumentsBridge.post("closed", mapOf("token" to token)) }
        try {
            return ParcelFileDescriptor.open(File("/proc/self/fd/$fd"), bits, closeHandler) { closed() }
        } catch (e: Exception) {
            closed()
            throw FileNotFoundException("AnJ Cloud could not open this file: ${e.message}")
        } finally {
            ParcelFileDescriptor.adoptFd(fd).close()
        }
    }

    companion object {
        const val OPEN_TIMEOUT_MS = 660_000L

        /** An open answered after its caller gave up: close the descriptor, report it closed. */
        fun closeAbandoned(result: Any?) {
            val answer = result as? Map<*, *> ?: return
            (answer["fd"] as? Number)?.let { runCatching { ParcelFileDescriptor.adoptFd(it.toInt()).close() } }
            (answer["token"] as? String)?.let { DocumentsBridge.post("closed", mapOf("token" to it)) }
        }
    }

    override fun createDocument(parentDocumentId: String, mimeType: String, displayName: String): String =
        call("create", mapOf("parent" to parentDocumentId, "name" to displayName,
            "directory" to (mimeType == Document.MIME_TYPE_DIR), "caller" to caller(null)), 60_000) as String

    override fun renameDocument(documentId: String, displayName: String): String? {
        val id = call("rename", mapOf("id" to documentId, "name" to displayName, "caller" to caller(null)),
            60_000) as String
        return if (id == documentId) null else id
    }

    override fun moveDocument(sourceDocumentId: String, sourceParentDocumentId: String,
                              targetParentDocumentId: String): String =
        call("move", mapOf("id" to sourceDocumentId, "target" to targetParentDocumentId,
            "caller" to caller(null)), 60_000) as String

    override fun deleteDocument(documentId: String) {
        call("delete", mapOf("id" to documentId, "caller" to caller(null)), 60_000)
    }
}
