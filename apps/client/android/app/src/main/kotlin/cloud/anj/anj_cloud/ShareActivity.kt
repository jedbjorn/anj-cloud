package cloud.anj.anj_cloud

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/// The Share sheet's target (spec #43). The process has one engine, attached to one activity:
/// this trampoline forwards the share to MainActivity in AnJ Cloud's own task (onNewIntent when
/// it is already open, so the library keeps its place) and passes the read grant on with it.
/// It shows nothing and finishes at once.
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val share = intent
        if (share != null && savedInstanceState == null) {
            val forward = Intent(share).setClass(this, MainActivity::class.java)
            forward.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            runCatching { startActivity(forward) }
        }
        finish()
    }
}
