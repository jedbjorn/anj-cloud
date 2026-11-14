package cloud.anj.anj_cloud

import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/// `cloud.anj/phone_folders` (spec #52, decision #201): Music, Videos and Documents live in
/// the phone's own Music, Movies and Documents folders in shared storage, which needs All
/// files access (MANAGE_EXTERNAL_STORAGE). lib/platform/android/android_phone_folders.dart.
///
/// - `state`: whether All files access is granted (`Environment.isExternalStorageManager`)
///   and shared storage is mounted, the shared storage path and this app's own media folder,
///   where the phone folders' staging lives (removed with the app).
/// - `openSettings`: the system's All files access page for this app.
/// - `showFolder`: the Files app at a phone folder (`path` beneath shared storage).
/// - `scan`: asks the media library to index exactly these paths (AC0: writes by path are
///   not visible to other apps until scanned; a scan of a removed path drops its row).
object PhoneFoldersChannel {
    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, "cloud.anj/phone_folders").setMethodCallHandler { call, result ->
            when (call.method) {
                "state" -> {
                    val base = Environment.getExternalStorageDirectory().absolutePath
                    result.success(
                        mapOf(
                            "granted" to Environment.isExternalStorageManager(),
                            "mounted" to (Environment.getExternalStorageState() == Environment.MEDIA_MOUNTED),
                            "base" to base,
                            "media" to "$base/Android/media/${app.packageName}",
                        ),
                    )
                }
                "openSettings" -> {
                    val exact = Intent(
                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.parse("package:${app.packageName}"),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    try {
                        app.startActivity(exact)
                    } catch (e: Exception) {
                        // Some builds have only the list of apps.
                        app.startActivity(
                            Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                    }
                    result.success(null)
                }
                "scan" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    if (paths.isNotEmpty()) {
                        MediaScannerConnection.scanFile(app, paths.toTypedArray(), null, null)
                    }
                    result.success(null)
                }
                "showFolder" -> {
                    // Show in folder for a phone folder: the Files app at that folder of
                    // internal storage (the external storage provider, "primary:<path>").
                    val uri = DocumentsContract.buildDocumentUri(
                        "com.android.externalstorage.documents",
                        "primary:" + call.argument<String>("path")!!,
                    )
                    val browse = Intent(Intent.ACTION_VIEW)
                        .setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    result.success(
                        try {
                            app.startActivity(browse); true
                        } catch (e: Exception) {
                            false
                        },
                    )
                }
                else -> result.notImplemented()
            }
        }
    }
}
