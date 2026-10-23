import Foundation

/// Touch ID unlock: Secure Enclave key + device-wrapped vault key on disk,
/// with `UnlockGate` deciding when the master password is required.
public final class DeviceUnlock: @unchecked Sendable {
    public let dir: DataDirectory
    public let gate: UnlockGate

    public init(dir: DataDirectory) throws {
        self.dir = dir
        self.gate = try UnlockGate(statePath: dir.unlockGateStatePath.path)
    }

    /// Both files present (the feature was turned on for this vault).
    public var isEnrolled: Bool {
        SecureFile.exists(dir.deviceKeyBlobPath) && SecureFile.exists(dir.deviceWrappedKeyPath)
    }

    /// The biometric set differs from the one the key was created under.
    /// Missing state or missing biometry counts as changed (fail safe).
    public func enrollmentChanged() -> Bool {
        guard isEnrolled else { return false }
        guard let stored = SecureFile.read(dir.biometryStatePath),
              let current = DeviceCapabilities.biometryStateHash() else { return true }
        return stored != current
    }

    /// Asks the gate whether the master password is required right now.
    public func passwordRequired(now: Int64 = Clock.now()) -> PasswordRequiredReason {
        gate.check(
            now: now,
            rebootedSinceLastPassword: BootTime.rebootedSinceLastPassword(dir),
            enrollmentChanged: enrollmentChanged(),
            hasDeviceKey: isEnrolled && DeviceCapabilities.deviceUnlockSupported)
    }

    /// Call after every successful password unlock: resets the gate's
    /// counters, records this boot, and re-keys Touch ID if the enrollment set
    /// changed (the old key is unusable by design).
    public func recordPasswordUnlock(vault: Vault, now: Int64 = Clock.now()) throws {
        try gate.recordPasswordUnlock(now: now)
        try BootTime.recordCurrent(dir)
        if isEnrolled && enrollmentChanged() {
            remove()
            if DeviceCapabilities.deviceUnlockSupported {
                try enroll(vault: vault)
            }
        }
    }

    /// Creates a fresh SE key and stores the vault key sealed to it.
    public func enroll(vault: Vault) throws {
        guard DeviceCapabilities.deviceUnlockSupported else {
            throw StrongroomError.Unsupported(reason: "Secure Enclave or Touch ID is not available on this Mac")
        }
        let (blob, publicKey) = try SecureEnclaveDeviceKey.create()
        let wrapped = try vault.wrapVaultKeyForDevice(devicePublicKey: publicKey)
        try SecureFile.write(blob, to: dir.deviceKeyBlobPath)
        try SecureFile.write(wrapped, to: dir.deviceWrappedKeyPath)
        if let state = DeviceCapabilities.biometryStateHash() {
            try SecureFile.write(state, to: dir.biometryStatePath)
        }
    }

    public func remove() {
        SecureFile.remove(dir.deviceKeyBlobPath)
        SecureFile.remove(dir.deviceWrappedKeyPath)
        SecureFile.remove(dir.biometryStatePath)
    }

    public enum Outcome {
        case unlocked(Vault)
        case failed(DeviceKeyFailure?)
    }

    /// One Touch ID prompt, one SE key agreement. Blocking: run on CoreThread.
    public func unlock(vaultPath: URL, reason: String) -> Outcome {
        guard let blob = SecureFile.read(dir.deviceKeyBlobPath),
              let wrapped = SecureFile.read(dir.deviceWrappedKeyPath),
              let device = try? SecureEnclaveDeviceKey(blob: blob, reason: reason)
        else {
            return .failed(.keyInvalidated)
        }
        do {
            let vault = try Vault.unlockWithDeviceKey(
                path: vaultPath.path, deviceWrappedKey: wrapped, device: device)
            try? gate.recordBiometricSuccess()
            return .unlocked(vault)
        } catch {
            let failure = device.lastFailure
            // A cancelled prompt is not a failed attempt.
            if failure != .cancelled {
                try? gate.recordBiometricFailure()
            }
            return .failed(failure)
        }
    }

    /// Text for the unlock screen.
    public static func explain(_ reason: PasswordRequiredReason) -> String {
        switch reason {
        case .notRequired: return "Touch ID is available."
        case .firstLaunchAfterReboot: return "Enter your master password: this Mac restarted since the last password unlock."
        case .tooManyBiometricFailures: return "Enter your master password: too many failed Touch ID attempts."
        case .periodicCheck: return "Enter your master password: it is required at least every 7 days."
        case .biometricEnrollmentChanged: return "Enter your master password: the Touch ID fingerprints on this Mac changed."
        case .noBiometricKey: return "Touch ID unlock is not set up."
        }
    }
}
