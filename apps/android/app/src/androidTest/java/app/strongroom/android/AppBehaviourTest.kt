package app.strongroom.android

import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.strongroom.android.autofill.AutofillUnlockActivity
import app.strongroom.android.security.SecureClipboard
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppBehaviourTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    /** Regression: rotation / dark mode recreated the activity and lost navigation and drafts. */
    @Test
    fun activitiesHandleConfigChangesInPlace() {
        val needed = ActivityInfo.CONFIG_ORIENTATION or ActivityInfo.CONFIG_SCREEN_SIZE or
            ActivityInfo.CONFIG_SMALLEST_SCREEN_SIZE or ActivityInfo.CONFIG_SCREEN_LAYOUT or
            ActivityInfo.CONFIG_UI_MODE or ActivityInfo.CONFIG_KEYBOARD_HIDDEN
        for (cls in listOf(MainActivity::class.java, AutofillUnlockActivity::class.java)) {
            val info = context.packageManager.getActivityInfo(ComponentName(context, cls), PackageManager.GET_META_DATA)
            assertEquals("${cls.simpleName} configChanges", needed, info.configChanges and needed)
        }
    }

    @Test
    fun noNetworkPermissionRequested() {
        val pkg = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        val perms = pkg.requestedPermissions.orEmpty().toList()
        assertFalse(perms.toString(), perms.any { it.contains("INTERNET") || it.contains("NETWORK_STATE") || it.contains("WIFI_STATE") })
    }

    /** Copy marks the clip sensitive and clears it after 25 s. Needs a focused activity to read the clipboard. */
    @Test
    fun clipboardIsSensitiveAndAutoCleared() {
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        try {
            instrumentation.waitForIdleSync()
            Thread.sleep(1000) // window focus
            val app = context.applicationContext as StrongroomApp
            val cm = context.getSystemService(ClipboardManager::class.java)
            instrumentation.runOnMainSync { app.clipboard.copy("Password", "clip-test-secret-123") }
            var text: String? = null
            var sensitive = false
            instrumentation.runOnMainSync {
                val clip = cm.primaryClip
                text = clip?.getItemAt(0)?.text?.toString()
                sensitive = clip?.description?.extras?.getBoolean(SecureClipboard.EXTRA_IS_SENSITIVE) == true
            }
            assertEquals("clip-test-secret-123", text)
            assertTrue("EXTRA_IS_SENSITIVE set", sensitive)

            Thread.sleep(SecureClipboard.CLEAR_AFTER_MS + 2_000)
            var after: String? = "unset"
            instrumentation.runOnMainSync {
                after = cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()
            }
            assertTrue("clipboard cleared, was '$after'", after.isNullOrEmpty())
        } finally {
            activity.finish()
        }
    }
}
