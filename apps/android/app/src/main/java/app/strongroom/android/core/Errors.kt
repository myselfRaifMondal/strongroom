package app.strongroom.android.core

import uniffi.strongroom.PasswordRequiredReason
import uniffi.strongroom.StrongroomException

/** User-facing text for a failure. Never reveals which unlock factor failed. */
fun Throwable.userMessage(): String = when (this) {
    is StrongroomException.UnlockFailed ->
        "Unlock failed. The master password, Secret Key or device key is not correct."
    is StrongroomException.FormatRejected -> "The file was rejected (${this.check})."
    is StrongroomException.InvalidInput -> "Invalid input: ${this.reason}"
    is StrongroomException.NotFound -> "Not found."
    is StrongroomException.Locked -> "The vault is locked."
    is StrongroomException.Unsupported -> "Not available: ${this.reason}"
    is StrongroomException.Storage -> "Storage error: ${this.reason}"
    is StrongroomException.Internal -> "Internal error in the Strongroom core."
    is IllegalStateException -> this.message ?: "Invalid state."
    else -> "Unexpected error (${this::class.java.simpleName})."
}

fun PasswordRequiredReason.explanation(): String = when (this) {
    PasswordRequiredReason.NOT_REQUIRED -> "Biometric unlock is available."
    PasswordRequiredReason.FIRST_LAUNCH_AFTER_REBOOT ->
        "The device restarted. Enter your master password and Secret Key."
    PasswordRequiredReason.TOO_MANY_BIOMETRIC_FAILURES ->
        "Too many failed biometric attempts. Enter your master password and Secret Key."
    PasswordRequiredReason.PERIODIC_CHECK ->
        "It has been 7 days since you last used your master password. Enter it to continue."
    PasswordRequiredReason.BIOMETRIC_ENROLLMENT_CHANGED ->
        "The fingerprints or faces on this device changed. Biometric unlock was disabled; " +
            "enter your master password and Secret Key to turn it on again."
    PasswordRequiredReason.NO_BIOMETRIC_KEY -> "Biometric unlock is not set up for this vault."
}

object Clock {
    fun nowSeconds(): Long = System.currentTimeMillis() / 1000L
}
