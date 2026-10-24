package app.strongroom.android.core

import uniffi.strongroom.CsvSource

/** Pure UI rules (unit-tested). */
object MasterPasswordRules {
    /** Same minimum as the macOS app. */
    const val MIN_LENGTH = 10

    /** Why [password]/[confirm] cannot be used yet, or null when they can. */
    fun problem(password: String, confirm: String): String? = when {
        password.isEmpty() -> "Enter a master password."
        password.length < MIN_LENGTH -> "Use at least $MIN_LENGTH characters."
        password.isBlank() -> "The master password cannot be only spaces."
        confirm.isNotEmpty() && password != confirm -> "Passwords do not match."
        confirm.isEmpty() -> "Confirm the master password."
        else -> null
    }
}

/** Auto-lock delay after the app leaves the screen. */
object AutoLock {
    val CHOICES_MINUTES = listOf(1, 3, 5, 15, 60)
    const val DEFAULT_MINUTES = 3

    fun sanitize(minutes: Int): Int = if (minutes in CHOICES_MINUTES) minutes else DEFAULT_MINUTES
    fun label(minutes: Int): String = if (minutes == 60) "1 hour" else "$minutes min"
}

/** CSV sources offered in the importer, with the exporter's own names. */
object CsvSources {
    val ALL: List<Pair<CsvSource, String>> = listOf(
        CsvSource.CHROME to "Chrome / Edge / Android Google Password Manager",
        CsvSource.BITWARDEN to "Bitwarden",
        CsvSource.LAST_PASS to "LastPass",
        CsvSource.ONE_PASSWORD to "1Password / Apple Passwords",
    )

    fun label(source: CsvSource): String = ALL.first { it.first == source }.second

    /** Guesses the exporter from the header line; null when unknown. */
    fun guess(csv: String): CsvSource? {
        val header = csv.removePrefix("﻿").lineSequence().firstOrNull()?.lowercase() ?: return null
        val cols = header.split(',').map { it.trim().trim('"') }.toSet()
        return when {
            "login_uri" in cols || "login_username" in cols -> CsvSource.BITWARDEN
            "grouping" in cols || "extra" in cols -> CsvSource.LAST_PASS
            "title" in cols && ("otpauth" in cols || "url" in cols) -> CsvSource.ONE_PASSWORD
            "name" in cols && "url" in cols && "username" in cols -> CsvSource.CHROME
            else -> null
        }
    }
}
