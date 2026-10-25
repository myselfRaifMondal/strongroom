package app.strongroom.android

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import app.strongroom.android.core.AutoLock
import app.strongroom.android.core.RotationSettings
import app.strongroom.android.core.Session
import app.strongroom.android.security.SecureClipboard

class StrongroomApp : Application() {

    lateinit var clipboard: SecureClipboard
        private set

    private val handler = Handler(Looper.getMainLooper())
    private var startedActivities = 0
    private val autoLock = Runnable { Session.lock() }

    /** Auto-lock delay after the app leaves the screen (Settings). Non-secret. */
    var autoLockMinutes: Int
        get() = AutoLock.sanitize(
            getSharedPreferences(PREFS, MODE_PRIVATE).getInt(KEY_AUTO_LOCK, AutoLock.DEFAULT_MINUTES),
        )
        set(value) {
            getSharedPreferences(PREFS, MODE_PRIVATE).edit().putInt(KEY_AUTO_LOCK, AutoLock.sanitize(value)).apply()
        }

    /** Rotation reminder settings (Settings, banner snooze). Non-secret. */
    var rotationSettings: RotationSettings
        get() = RotationSettings.fromMap(getSharedPreferences(PREFS, MODE_PRIVATE).all)
        set(value) {
            val e = getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            value.toMap().forEach { (k, v) -> if (v == null) e.remove(k) else e.putLong(k, v) }
            e.apply()
        }

    override fun onCreate() {
        super.onCreate()
        instance = this
        clipboard = SecureClipboard(this)
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
                // No screenshots, screen recording or recents thumbnails of any
                // Strongroom window. Compose dialogs/popups inherit this flag.
                activity.window.setFlags(
                    WindowManager.LayoutParams.FLAG_SECURE,
                    WindowManager.LayoutParams.FLAG_SECURE,
                )
            }

            override fun onActivityStarted(activity: Activity) {
                startedActivities++
                handler.removeCallbacks(autoLock)
            }

            override fun onActivityStopped(activity: Activity) {
                startedActivities--
                if (startedActivities <= 0) {
                    // Leaving the app (incl. the SAF picker) keeps the vault
                    // open briefly; after that it is locked.
                    handler.postDelayed(autoLock, autoLockMinutes * 60_000L)
                }
            }

            override fun onActivityResumed(activity: Activity) = Unit
            override fun onActivityPaused(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        })
    }

    companion object {
        private const val PREFS = "settings"
        private const val KEY_AUTO_LOCK = "autoLockMinutes"
        lateinit var instance: StrongroomApp
            private set
    }
}
