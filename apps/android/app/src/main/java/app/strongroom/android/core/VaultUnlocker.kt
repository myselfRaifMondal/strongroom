package app.strongroom.android.core

import android.content.Context
import android.util.Log
import app.strongroom.android.security.DeviceKey
import app.strongroom.android.security.DeviceKeySupport
import app.strongroom.android.security.KeyState
import app.strongroom.android.security.KeystoreDeviceKeyAgreement
import app.strongroom.android.security.UnlockSignals
import uniffi.strongroom.PasswordRequiredReason
import uniffi.strongroom.UnlockGate
import uniffi.strongroom.Vault

/**
 * Per-vault unlock policy: feeds platform signals into the core UnlockGate
 * and owns the device-bound (biometric) unlock material.
 */
class VaultUnlocker(context: Context, val name: String) {
    private val files = VaultFiles(context)
    private val signals = UnlockSignals(context, name)
    private val path = files.vaultPath(name)
    private val gate: UnlockGate? = runCatching { UnlockGate(files.gateStatePath(name)) }
        .onFailure { Log.w(TAG, "UnlockGate unavailable: ${it.userMessage()}") }
        .getOrNull()

    val deviceKey: DeviceKey? =
        if (DeviceKeySupport.supported) DeviceKey(context, VaultFiles.deviceKeyAlias(name)) else null

    private fun hasDeviceKey(): Boolean =
        deviceKey?.exists() == true && files.wrappedKeyFile(name).isFile

    /** Evaluates the password-required policy. Fails safe to "password required". */
    fun passwordRequiredReason(justAuthenticated: Boolean = false): PasswordRequiredReason {
        val key = deviceKey ?: return PasswordRequiredReason.NO_BIOMETRIC_KEY
        if (key.state(justAuthenticated) == KeyState.INVALIDATED) {
            // Enrollment changed: the hardware key is unusable forever.
            signals.markEnrollmentChanged()
            key.delete()
            files.wrappedKeyFile(name).delete()
        }
        val g = gate ?: return PasswordRequiredReason.NO_BIOMETRIC_KEY
        return runCatching {
            g.check(
                Clock.nowSeconds(),
                signals.rebootedSinceLastPassword(),
                signals.enrollmentChanged(),
                // A key destroyed by an enrollment change still counts, so the
                // gate reports BiometricEnrollmentChanged, not NoBiometricKey.
                hasDeviceKey() || signals.enrollmentChanged(),
            )
        }.getOrDefault(PasswordRequiredReason.NO_BIOMETRIC_KEY)
    }

    /** Blocking (Argon2id); call off the main thread. */
    fun unlockWithPassword(password: String, secretKey: String): Vault {
        val vault = Vault.unlockWithPassword(path, password, secretKey, Clock.nowSeconds())
        recordPasswordUnlock()
        return vault
    }

    fun recordPasswordUnlock() {
        runCatching { gate?.recordPasswordUnlock(Clock.nowSeconds()) }
            .onFailure { Log.w(TAG, "recordPasswordUnlock: ${it.userMessage()}") }
        signals.recordPasswordUnlock()
    }

    /** Seals the vault key to this device's hardware key (API 31+). */
    fun enableDeviceUnlock(vault: Vault) {
        val key = deviceKey ?: throw IllegalStateException(app.strongroom.android.security.DeviceKeySupport.UNSUPPORTED_MESSAGE)
        val pub = key.ensure()
        val wrapped = vault.wrapVaultKeyForDevice(pub)
        files.wrappedKeyFile(name).writeBytes(wrapped)
    }

    fun disableDeviceUnlock() {
        files.wrappedKeyFile(name).delete()
        deviceKey?.delete()
    }

    fun deviceUnlockEnabled(): Boolean = hasDeviceKey()

    /** Records a rejected biometric; returns true when the gate now demands the password. */
    fun biometricFailure(): Boolean {
        runCatching { gate?.recordBiometricFailure() }
        return passwordRequiredReason() == PasswordRequiredReason.TOO_MANY_BIOMETRIC_FAILURES
    }

    /**
     * The OS locked biometrics out. It does that on the attempt that would be
     * the 5th failure and reports it as an error, not as a failed attempt, so
     * the gate never saw that failure: record failures until the gate demands
     * the password (at most [MAX_FAILURES]).
     */
    fun biometricLockedOut() {
        repeat(MAX_FAILURES) { if (biometricFailure()) return }
    }

    /** Must run within DeviceKey.AUTH_VALIDITY_SECONDS of a successful BiometricPrompt. */
    fun unlockWithDevice(): Vault {
        val key = deviceKey ?: throw IllegalStateException(DeviceKeySupport.UNSUPPORTED_MESSAGE)
        val blob = files.wrappedKeyFile(name).readBytes()
        val vault = Vault.unlockWithDeviceKey(path, blob, KeystoreDeviceKeyAgreement(key))
        runCatching { gate?.recordBiometricSuccess() }
        return vault
    }

    companion object {
        private const val TAG = "StrongroomUnlock"
        const val MAX_FAILURES = 5
    }
}
