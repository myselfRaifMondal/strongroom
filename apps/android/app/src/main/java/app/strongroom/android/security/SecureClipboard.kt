package app.strongroom.android.security

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle

/**
 * Copies secrets marked sensitive (hidden from the clipboard preview and
 * keyboard suggestions) and clears them after [CLEAR_AFTER_MS].
 */
class SecureClipboard(context: Context) {
    private val clipboard = context.getSystemService(ClipboardManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private var pendingClear: Runnable? = null

    fun copy(label: String, value: String, sensitive: Boolean = true) {
        val clip = ClipData.newPlainText(LABEL_PREFIX + label, value)
        if (sensitive) {
            clip.description.extras = PersistableBundle().apply {
                putBoolean(EXTRA_IS_SENSITIVE, true)
            }
        }
        clipboard.setPrimaryClip(clip)
        pendingClear?.let { handler.removeCallbacks(it) }
        val clear = Runnable { clearIfOurs() }
        pendingClear = clear
        handler.postDelayed(clear, CLEAR_AFTER_MS)
    }

    private fun clearIfOurs() {
        pendingClear = null
        // Reading the clip label may be refused while in the background; in
        // that case clear anyway, since the last thing we put there is a secret.
        val label = runCatching { clipboard.primaryClipDescription?.label?.toString() }.getOrNull()
        if (label != null && !label.startsWith(LABEL_PREFIX)) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            clipboard.clearPrimaryClip()
        } else {
            clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
        }
    }

    companion object {
        const val CLEAR_AFTER_MS = 25_000L
        private const val LABEL_PREFIX = "Strongroom: "

        /** ClipDescription.EXTRA_IS_SENSITIVE (API 33); same key honoured by older OEM builds. */
        val EXTRA_IS_SENSITIVE: String =
            if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE
            else "android.content.extra.IS_SENSITIVE"
    }
}
