package app.strongroom.android.core

/*
 * Rotation reminders (OQ-M9), a port of
 * apps/macos/Sources/StrongroomKit/RotationPolicy.swift. Android shows the
 * reminder as a banner after unlock; there is no scheduled notification.
 */

/** How often a password should be changed. [days] 0 means never. */
enum class RotationInterval(val days: Int) {
    DAYS_30(30), DAYS_60(60), DAYS_90(90), DAYS_180(180), DAYS_365(365), NEVER(0);

    val label: String
        get() = when (this) {
            NEVER -> "Never"
            DAYS_365 -> "Every year"
            else -> "Every $days days"
        }

    companion object {
        fun fromDays(days: Int): RotationInterval? = entries.firstOrNull { it.days == days }
    }
}

/** Rotation reminder settings. Not secret; stored in SharedPreferences. */
data class RotationSettings(
    val critical: RotationInterval = RotationInterval.DAYS_90,
    val other: RotationInterval = RotationInterval.DAYS_365,
    /** The banner is quiet until then (Unix seconds). */
    val snoozedUntil: Long? = null,
) {
    fun interval(importance: Importance): RotationInterval =
        if (importance == Importance.CRITICAL) critical else other

    fun isSnoozed(now: Long): Boolean = (snoozedUntil ?: 0) > now

    /** Values to store; keys are [KEY_CRITICAL] etc. */
    fun toMap(): Map<String, Long?> = mapOf(
        KEY_CRITICAL to critical.days.toLong(),
        KEY_OTHER to other.days.toLong(),
        KEY_SNOOZED_UNTIL to snoozedUntil,
    )

    companion object {
        const val KEY_CRITICAL = "rotation.criticalDays"
        const val KEY_OTHER = "rotation.otherDays"
        const val KEY_SNOOZED_UNTIL = "rotation.snoozedUntil"
        const val SNOOZE_SECONDS: Long = 7 * 86_400

        /** Reads stored values; unknown or missing values fall back to the defaults. */
        fun fromMap(m: Map<String, *>): RotationSettings {
            val d = RotationSettings()
            fun days(key: String) = (m[key] as? Number)?.toInt()?.let { RotationInterval.fromDays(it) }
            return RotationSettings(
                critical = days(KEY_CRITICAL) ?: d.critical,
                other = days(KEY_OTHER) ?: d.other,
                snoozedUntil = (m[KEY_SNOOZED_UNTIL] as? Number)?.toLong(),
            )
        }
    }
}

enum class DueReason(val label: String) {
    OLD("older than the rotation policy"),
    REUSED("used on another account"),
    WEAK("weak"),
}

/**
 * "Due for change": age since the password changed reaches the policy, OR
 * the password is reused, OR it is weak (strength score <= 1).
 */
object RotationPolicy {
    const val WEAK_SCORE = 1

    fun dueReasons(x: RiskInputs, policy: RotationSettings): List<DueReason> {
        val r = ArrayList<DueReason>()
        val days = policy.interval(x.importance).days
        if (days > 0 && x.ageDays >= days) r.add(DueReason.OLD)
        if (x.reusedWith > 0) r.add(DueReason.REUSED)
        if (x.strength <= WEAK_SCORE) r.add(DueReason.WEAK)
        return r
    }

    fun isDue(x: RiskInputs, policy: RotationSettings): Boolean = dueReasons(x, policy).isNotEmpty()
}

/**
 * Text of the unlock banner. It takes only the count, by design: no titles,
 * usernames, folders or domains.
 */
object RotationReminder {
    fun bannerText(count: Int): String =
        if (count == 1) "1 password should be changed" else "$count passwords should be changed"
}
