import CryptoKit
import Foundation

/// Signs and verifies the UnlockGate state (threat model residual risk 3).
/// The key must not need user presence: the gate is read before any prompt.
public protocol GateSealKey: Sendable {
    /// `nil` when no signature can be made (no Secure Enclave, key error).
    func sign(_ message: Data) -> Data?
    func isValid(_ signature: Data, for message: Data) -> Bool
}

/// Secure Enclave P-256 signing key without any access-control flag, so no
/// prompt. Stored as its SE-encrypted blob; only this Mac's SE can use it,
/// so an attacker who can only write files cannot forge a seal.
public struct SecureEnclaveGateSealKey: GateSealKey {
    public let blobPath: URL

    public init(blobPath: URL) {
        self.blobPath = blobPath
    }

    private func load() -> SecureEnclave.P256.Signing.PrivateKey? {
        guard SecureEnclave.isAvailable, let blob = SecureFile.read(blobPath) else { return nil }
        return try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
    }

    public func sign(_ message: Data) -> Data? {
        guard SecureEnclave.isAvailable else { return nil }
        var key = load()
        if key == nil {
            guard let fresh = try? SecureEnclave.P256.Signing.PrivateKey(),
                  (try? SecureFile.write(fresh.dataRepresentation, to: blobPath)) != nil else { return nil }
            key = fresh
        }
        return (try? key?.signature(for: message))?.rawRepresentation
    }

    public func isValid(_ signature: Data, for message: Data) -> Bool {
        guard let key = load(),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.publicKey.isValidSignature(sig, for: message)
    }
}

/// `UnlockGate` plus an integrity seal over its state file, kept in a
/// sibling file. The core file format and the FFI are unchanged.
///
/// Before the gate reads its state, the seal is checked. A state file with a
/// missing or invalid seal is treated as tampered and deleted; the core reads
/// a missing file as "never unlocked with the password", so the next unlock
/// asks for the master password (fail closed). After every write the state is
/// sealed again; if that fails the seal is removed, which also fails closed.
///
/// Not covered: replaying an older state file together with its seal.
public final class SealedUnlockGate: @unchecked Sendable {
    private static let domain = Data("strongroom-gate-seal-v1\0".utf8)

    private let gate: UnlockGate
    public let statePath: URL
    public let sealPath: URL
    private let key: GateSealKey
    private let lock = NSLock()

    public init(statePath: URL, sealPath: URL, key: GateSealKey) throws {
        self.gate = try UnlockGate(statePath: statePath.path)
        self.statePath = statePath
        self.sealPath = sealPath
        self.key = key
    }

    /// Domain tag, then the state file's name (a seal cannot be moved to
    /// another state file), then its exact bytes.
    private func message(_ state: Data) -> Data {
        var m = Self.domain
        m.append(Data(statePath.lastPathComponent.utf8))
        m.append(0)
        m.append(state)
        return m
    }

    /// True when the state file is absent or carries a valid seal.
    public func stateIsIntact() -> Bool {
        guard let state = SecureFile.read(statePath) else {
            return !SecureFile.exists(statePath)
        }
        guard let seal = SecureFile.read(sealPath) else { return false }
        return key.isValid(seal, for: message(state))
    }

    private func dropTamperedState() {
        if !stateIsIntact() {
            SecureFile.remove(statePath)
            SecureFile.remove(sealPath)
        }
    }

    private func reseal() {
        guard let state = SecureFile.read(statePath),
              let seal = key.sign(message(state)),
              (try? SecureFile.write(seal, to: sealPath)) != nil
        else {
            SecureFile.remove(sealPath)
            return
        }
    }

    public func check(now: Int64, rebootedSinceLastPassword: Bool, enrollmentChanged: Bool,
                      hasDeviceKey: Bool) -> PasswordRequiredReason {
        lock.lock()
        defer { lock.unlock() }
        dropTamperedState()
        return gate.check(now: now, rebootedSinceLastPassword: rebootedSinceLastPassword,
                          enrollmentChanged: enrollmentChanged, hasDeviceKey: hasDeviceKey)
    }

    public func recordPasswordUnlock(now: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        try gate.recordPasswordUnlock(now: now)
        reseal()
    }

    public func recordBiometricFailure() throws {
        lock.lock()
        defer { lock.unlock() }
        dropTamperedState()
        try gate.recordBiometricFailure()
        reseal()
    }

    public func recordBiometricSuccess() throws {
        lock.lock()
        defer { lock.unlock() }
        dropTamperedState()
        try gate.recordBiometricSuccess()
        reseal()
    }
}
