package cloud.anj.grantee

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.MediaStore
import android.util.Log
import android.widget.TextView
import java.io.File
import java.io.FileInputStream

/**
 * Stands in for "another app" against the AnJ Cloud provider (spec #28 A5, seat E). Adapted from
 * the A1 probe grantee. Commands: `am start -n <pkg>/cloud.anj.grantee.GranteeActivity --es cmd C`:
 *   pick --es slot S          ACTION_OPEN_DOCUMENT_TREE (uiautomator picks), takes the persistable
 *                             grant, remembers it as S -> out/pick-S.json
 *   access --es slot S --es out O [--ez write true] [--ez create true]
 *                             list S's tree, read a file, optionally append to it and create /
 *                             rename / delete a file -> out/O.json (each step ok or its exception)
 *   hold --es slot S --es out O
 *                             open a file, report out/O-held.json, wait for files/release, then read
 *                             through the same descriptor -> out/O.json
 *   seed --es slot S --es out O
 *                             create Album/track.txt and loose.txt in S's tree (approved read-write)
 *   persisted --es out O      this app's persisted grants
 *   write --es slot S --es name N --es text T --es out O
 *                             create N in S's tree, write T and close it (row 10, review M1)
 *   pickfile --es slot S [--es initial URI]
 *                             ACTION_OPEN_DOCUMENT (one file, uiautomator picks), opening at URI
 *                             when given; takes the persistable grant (R1, review M2)
 *                             -> out/pickfile-S.json
 *   readfile --es slot S --es out O
 *                             read the single file S through its own grant -> out/O.json
 *   share --esa names N1,N2 --esa texts T1,T2 [--ei repeat R] --es target PKG --es out O
 *                             save each Ni (Ti repeated R times) as this app's own download in
 *                             MediaStore, then send them to PKG with ACTION_SEND_MULTIPLE and a
 *                             read grant, as Gallery or Files would (spec #43 AC7) -> out/O.json
 */
class GranteeActivity : Activity() {
    private val prefs get() = getSharedPreferences("g", Context.MODE_PRIVATE)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(TextView(this).apply { text = packageName; setPadding(48, 96, 48, 48) })
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); handle(intent) }

    private fun q(s: String?): String =
        if (s == null) "null" else "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\""

    private fun out(name: String, json: String) {
        val d = File(filesDir, "out").apply { mkdirs() }
        File(d, "$name.json.tmp").apply { writeText(json); renameTo(File(d, "$name.json")) }
        Log.i("ANJGRANTEE", "$packageName $name $json")
    }

    private var pendingSlot: String? = null

    private fun handle(i: Intent) {
        val cmd = i.getStringExtra("cmd") ?: return
        val slot = i.getStringExtra("slot") ?: "default"
        val name = i.getStringExtra("out") ?: cmd
        if (cmd == "pickfile") {
            pendingSlot = slot
            File(filesDir, "out/pickfile-$slot.json").delete()
            @Suppress("DEPRECATION")
            val open = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
            i.getStringExtra("initial")?.let { open.putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(it)) }
            @Suppress("DEPRECATION")
            startActivityForResult(open, 2)
            return
        }
        if (cmd == "pick") {
            pendingSlot = slot
            File(filesDir, "out/pick-$slot.json").delete()
            @Suppress("DEPRECATION")
            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), 1)
            return
        }
        val write = i.getBooleanExtra("write", false)
        val create = i.getBooleanExtra("create", false)
        Thread {
            val json = try {
                when (cmd) {
                    "access" -> access(slot, write, create)
                    "hold" -> hold(slot, name)
                    "seed" -> seed(slot)
                    "persisted" -> persisted()
                    "readfile" -> readFile(slot)
                    "share" -> share(i.getStringArrayExtra("names") ?: emptyArray(),
                        i.getStringArrayExtra("texts") ?: emptyArray(), i.getIntExtra("repeat", 1),
                        i.getStringExtra("target") ?: error("no target"))
                    "write" -> write(slot, i.getStringExtra("name") ?: "written.txt",
                        i.getStringExtra("text") ?: "written\n")
                    else -> "{\"error\":\"unknown cmd\"}"
                }
            } catch (t: Throwable) {
                "{\"error\":${q(t.toString())}}"
            }
            out(name, json)
            runOnUiThread { finish() }
        }.start()
    }

    private fun share(names: Array<String>, texts: Array<String>, repeat: Int, target: String): String {
        val uris = ArrayList<Uri>()
        for ((index, name) in names.withIndex()) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.RELATIVE_PATH, "Download/anj-share")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: error("insert refused for $name")
            contentResolver.openOutputStream(uri)!!.use { out ->
                val bytes = texts.getOrElse(index) { name }.toByteArray()
                repeat(repeat) { out.write(bytes) }
            }
            contentResolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
            uris += uri
        }
        val send = Intent(Intent.ACTION_SEND_MULTIPLE).setType("*/*").setPackage(target)
            .putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        runOnUiThread { startActivity(send) }
        return "{\"ok\":true,\"uris\":[${uris.joinToString(",") { q(it.toString()) }}]}"
    }

    @Deprecated("platform API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        val slot = pendingSlot ?: "default"
        val uri = data?.data
        var taken: String? = null
        val kind = if (requestCode == 2) "file" else "tree"
        if (resultCode == RESULT_OK && uri != null) {
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            taken = runCatching { contentResolver.takePersistableUriPermission(uri, flags) }
                .exceptionOrNull()?.toString() ?: "ok"
            prefs.edit().putString("$kind-$slot", uri.toString()).commit()
        }
        out(if (requestCode == 2) "pickfile-$slot" else "pick-$slot", "{\"result\":$resultCode,\"uri\":${q(uri?.toString())},\"take_persistable\":${q(taken)}}")
        finish()
    }

    private fun attempt(block: () -> String): String = try {
        "{\"ok\":true,${block()}}"
    } catch (t: Throwable) {
        "{\"ok\":false,\"error\":${q(t.javaClass.simpleName)},\"message\":${q(t.message)}}"
    }

    private fun tree(slot: String): Uri =
        Uri.parse(prefs.getString("tree-$slot", null) ?: error("no grant taken for $slot"))

    private fun children(tree: Uri, doc: String): List<Triple<String, String, String>> =
        contentResolver.query(DocumentsContract.buildChildDocumentsUriUsingTree(tree, doc),
            arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_MIME_TYPE, Document.COLUMN_DISPLAY_NAME),
            null, null, null)!!.use { c ->
            buildList { while (c.moveToNext()) add(Triple(c.getString(0), c.getString(1), c.getString(2))) }
        }

    private fun firstFile(tree: Uri): String? {
        val top = children(tree, DocumentsContract.getTreeDocumentId(tree))
        top.firstOrNull { it.second != Document.MIME_TYPE_DIR }?.let { return it.first }
        for (d in top.filter { it.second == Document.MIME_TYPE_DIR }) {
            children(tree, d.first).firstOrNull { it.second != Document.MIME_TYPE_DIR }?.let { return it.first }
        }
        return null
    }

    private fun access(slot: String, write: Boolean, create: Boolean): String {
        val tree = tree(slot)
        val root = DocumentsContract.getTreeDocumentId(tree)
        var file: String? = null
        val list = attempt {
            val names = children(tree, root).map { it.third }
            file = firstFile(tree)
            "\"children\":[${names.joinToString(",") { q(it) }}]"
        }
        val read = attempt {
            val f = file ?: error("no file listed")
            val n = contentResolver.openInputStream(DocumentsContract.buildDocumentUriUsingTree(tree, f))!!
                .use { it.readBytes().size }
            "\"doc\":${q(f)},\"bytes\":$n"
        }
        val appended = if (!write) "null" else attempt {
            val f = file ?: error("no file listed")
            contentResolver.openOutputStream(DocumentsContract.buildDocumentUriUsingTree(tree, f), "wa")!!
                .use { it.write("+$packageName\n".toByteArray()) }
            "\"doc\":${q(f)}"
        }
        val changed = if (!create) "null" else attempt {
            val parent = DocumentsContract.buildDocumentUriUsingTree(tree, root)
            val made = DocumentsContract.createDocument(contentResolver, parent, "text/plain",
                "${packageName.substringAfterLast('.')}.txt") ?: error("create returned null")
            contentResolver.openOutputStream(made, "w")!!.use { it.write("made by $packageName\n".toByteArray()) }
            val createdId = DocumentsContract.getDocumentId(made)
            val renamed = DocumentsContract.renameDocument(contentResolver, made,
                "${packageName.substringAfterLast('.')}-renamed.txt") ?: made
            val renamedId = DocumentsContract.getDocumentId(renamed)
            val back = contentResolver.openInputStream(renamed)!!.use { String(it.readBytes()) }
            DocumentsContract.deleteDocument(contentResolver, renamed)
            "\"created\":${q(createdId)},\"renamed\":${q(renamedId)},\"same_id\":${createdId == renamedId}," +
                "\"read_back\":${q(back)}"
        }
        return "{\"tree\":${q(tree.toString())},\"list\":$list,\"read\":$read,\"append\":$appended,\"create_rename_delete\":$changed}"
    }

    private fun hold(slot: String, name: String): String {
        val tree = tree(slot)
        val f = firstFile(tree) ?: error("no file listed")
        val pfd = contentResolver.openFileDescriptor(DocumentsContract.buildDocumentUriUsingTree(tree, f), "r")!!
        out("$name-held", "{\"opened\":true,\"doc\":${q(f)}}")
        val release = File(filesDir, "release").apply { delete() }
        val deadline = System.currentTimeMillis() + 120_000
        while (!release.exists() && System.currentTimeMillis() < deadline) Thread.sleep(250)
        val afterRevoke = attempt {
            val n = FileInputStream(pfd.fileDescriptor).readBytes().size // pfd.close() closes it
            "\"bytes\":$n"
        }
        val reopen = attempt {
            val n = contentResolver.openInputStream(DocumentsContract.buildDocumentUriUsingTree(tree, f))!!
                .use { it.readBytes().size }
            "\"bytes\":$n"
        }
        pfd.close()
        return "{\"doc\":${q(f)},\"released_signal\":${release.exists()},\"read_held_descriptor\":$afterRevoke,\"reopen\":$reopen}"
    }

    private fun seed(slot: String): String = attempt {
        val tree = tree(slot)
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        fun file(parent: Uri, name: String, text: String): String {
            val made = DocumentsContract.createDocument(contentResolver, parent, "text/plain", name)
                ?: error("create $name returned null")
            contentResolver.openOutputStream(made, "w")!!.use { it.write(text.toByteArray()) }
            return DocumentsContract.getDocumentId(made)
        }
        val album = DocumentsContract.createDocument(contentResolver, root, Document.MIME_TYPE_DIR, "Album")
            ?: error("create Album returned null")
        val track = file(album, "track.txt", "track\n")
        val loose = file(root, "loose.txt", "loose\n")
        "\"album\":${q(DocumentsContract.getDocumentId(album))},\"track\":${q(track)},\"loose\":${q(loose)}"
    }

    private fun write(slot: String, name: String, text: String): String = attempt {
        val tree = tree(slot)
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val made = DocumentsContract.createDocument(contentResolver, root, "text/plain", name)
            ?: error("create $name returned null")
        contentResolver.openOutputStream(made, "w")!!.use { it.write(text.toByteArray()) }
        "\"doc\":${q(DocumentsContract.getDocumentId(made))}"
    }

    private fun readFile(slot: String): String {
        val uri = Uri.parse(prefs.getString("file-$slot", null) ?: error("no file grant taken for $slot"))
        val read = attempt {
            val n = contentResolver.openInputStream(uri)!!.use { it.readBytes().size }
            "\"bytes\":$n"
        }
        return "{\"uri\":${q(uri.toString())},\"read\":$read}"
    }

    private fun persisted(): String = "{\"persisted\":[${contentResolver.persistedUriPermissions.joinToString(",") {
        "{\"uri\":${q(it.uri.toString())},\"read\":${it.isReadPermission},\"write\":${it.isWritePermission}}"
    }}]}"
}
