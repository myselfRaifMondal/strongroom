package app.strongroom.android.security

import android.content.Context
import android.os.SystemClock
import android.provider.Settings

/**
 * Platform signals the core's UnlockGate needs but cannot read itself:
 * "rebooted since the last password unlock" and "biometric enrollment
 * changed". Non-secret; stored in app-private preferences.
 */
class UnlockSignals(private val context: Context, private val vaultName: String) {
    private val prefs = context.getSharedPreferences("unlock_signals", Context.MODE_PRIVATE)

    fun currentBootId(): String = BootIdentity.of(
        bootCount = runCatching {
            Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1)
        }.getOrDefault(-1),
        wallClockMs = System.currentTimeMillis(),
        elapsedRealtimeMs = SystemClock.elapsedRealtime(),
    )

    fun rebootedSinceLastPassword(): Boolean =
        BootIdentity.rebooted(prefs.getString("$vaultName.boot", null), currentBootId())

    fun enrollmentChanged(): Boolean = prefs.getBoolean("$vaultName.enrollmentChanged", false)

    fun markEnrollmentChanged() {
        prefs.edit().putBoolean("$vaultName.enrollmentChanged", true).apply()
    }

    /** Called after a successful password unlock. */
    fun recordPasswordUnlock() {
        prefs.edit()
            .putString("$vaultName.boot", currentBootId())
            .putBoolean("$vaultName.enrollmentChanged", false)
            .apply()
    }
}

/** Pure boot-identity logic (unit-tested). */
object BootIdentity {
    /** Boot time is quantised to minutes so clock jitter does not look like a reboot. */
    fun of(bootCount: Int, wallClockMs: Long, elapsedRealtimeMs: Long): String =
        if (bootCount >= 0) "count:$bootCount"
        else "boot:${(wallClockMs - elapsedRealtimeMs) / 60_000L}"

    /** No record (never unlocked with password on this boot) counts as rebooted. */
    fun rebooted(recorded: String?, current: String): Boolean = recorded == null || recorded != current
}
