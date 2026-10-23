package app.strongroom.android

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import app.strongroom.android.core.Session
import app.strongroom.android.security.SecureClipboard

class StrongroomApp : Application() {

    lateinit var clipboard: SecureClipboard
        private set

    private val handler = Handler(Looper.getMainLooper())
    private var startedActivities = 0
    private val autoLock = Runnable { Session.lock() }

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
                    handler.postDelayed(autoLock, AUTO_LOCK_MS)
                }
            }

            override fun onActivityResumed(activity: Activity) = Unit
            override fun onActivityPaused(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        })
    }

    companion object {
        const val AUTO_LOCK_MS = 3 * 60 * 1000L
        lateinit var instance: StrongroomApp
            private set
    }
}
