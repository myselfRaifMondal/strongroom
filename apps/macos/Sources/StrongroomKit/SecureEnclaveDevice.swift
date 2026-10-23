import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// What this Mac offers for hardware-backed unlock.
public enum DeviceCapabilities {
    public static var secureEnclaveAvailable: Bool { SecureEnclave.isAvailable }

    /// Touch ID present, enrolled and usable right now.
    public static func biometryAvailable() -> (available: Bool, detail: String?) {
        let ctx = LAContext()
        var err: NSError?
        let ok = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        return (ok, err?.localizedDescription)
    }

    /// Both needed for Touch ID unlock. Without them the feature is disabled
    /// and password unlock is the only path.
    public static var deviceUnlockSupported: Bool {
        secureEnclaveAvailable && biometryAvailable().available
    }

    /// Opaque hash of the current biometric enrollment set. Changes whenever a
    /// finger is added or removed.
    public static func biometryStateHash() -> Data? {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else { return nil }
        if #available(macOS 15.0, *) {
            return ctx.domainState.biometry.stateHash
        }
        return ctx.evaluatedPolicyDomainState
    }
}

/// Why the last hardware key agreement failed. The core only ever sees
/// `UnlockFailed`; the app uses this to feed `UnlockGate`.
public enum DeviceKeyFailure: Equatable, Sendable {
    case cancelled
    case biometryFailed
    case lockout
    /// Touch ID succeeded but the SE refused the key: with `.biometryCurrentSet`
    /// this means the enrollment set changed since the key was created.
    case keyInvalidated
    case other(String)
}

/// `DeviceKeyAgreement` over a Secure Enclave P-256 key that requires the
/// current Touch ID enrollment set for every use. No keychain is involved:
/// the key is persisted as its `dataRepresentation`, an SE-encrypted blob
/// that only this Mac's Secure Enclave can use.
public final class SecureEnclaveDeviceKey: DeviceKeyAgreement, @unchecked Sendable {
    private let blob: Data
    private let publicKeyX963: Data
    private let reason: String
    private let lock = NSLock()
    private var _lastFailure: DeviceKeyFailure?

    public var lastFailure: DeviceKeyFailure? {
        lock.lock()
        defer { lock.unlock() }
        return _lastFailure
    }

    /// Creates a new SE key bound to the current biometric enrollment.
    /// Returns its blob and 65-byte uncompressed public key.
    public static func create() throws -> (blob: Data, publicKey: Data) {
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
            compactRepresentable: false, accessControl: try accessControl(biometry: true))
        return (key.dataRepresentation, key.publicKey.x963Representation)
    }

    static func accessControl(biometry: Bool) throws -> SecAccessControl {
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        if biometry { flags.insert(.biometryCurrentSet) }
        var error: Unmanaged<CFError>?
        guard let ac = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error)
        else {
            throw error!.takeRetainedValue() as Error
        }
        return ac
    }

    public init(blob: Data, reason: String) throws {
        // Loading the blob and reading the public key does not prompt.
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
        self.blob = blob
        self.publicKeyX963 = key.publicKey.x963Representation
        self.reason = reason
    }

    public func publicKey() -> Data { publicKeyX963 }

    /// One Touch ID prompt per call, then one ECDH inside the Secure Enclave.
    /// Returns the raw 32-byte shared secret (x-coordinate).
    public func agree(peerPublicKey: Data) throws -> Data {
        setFailure(nil)
        let peer: P256.KeyAgreement.PublicKey
        do {
            peer = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey)
        } catch {
            setFailure(.other("bad peer key"))
            throw StrongroomError.UnlockFailed
        }

        let ctx = LAContext()
        ctx.localizedReason = reason
        ctx.touchIDAuthenticationAllowableReuseDuration = 0
        if let failure = Self.evaluate(ctx, reason: reason) {
            setFailure(failure)
            throw StrongroomError.UnlockFailed
        }
        do {
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                dataRepresentation: blob, authenticationContext: ctx)
            let secret = try key.sharedSecretFromKeyAgreement(with: peer)
            return secret.withUnsafeBytes { Data($0) }
        } catch {
            setFailure(.keyInvalidated)
            throw StrongroomError.UnlockFailed
        }
    }

    private func setFailure(_ f: DeviceKeyFailure?) {
        lock.lock()
        _lastFailure = f
        lock.unlock()
    }

    /// Blocking Touch ID evaluation. Never call on the main thread.
    private static func evaluate(_ ctx: LAContext, reason: String) -> DeviceKeyFailure? {
        let done = DispatchSemaphore(value: 0)
        var outcome: DeviceKeyFailure?
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, error in
            if !ok {
                switch (error as? LAError)?.code {
                case .userCancel?, .appCancel?, .systemCancel?, .userFallback?: outcome = .cancelled
                case .biometryLockout?: outcome = .lockout
                case .authenticationFailed?: outcome = .biometryFailed
                case .biometryNotEnrolled?, .biometryNotAvailable?: outcome = .keyInvalidated
                default: outcome = .other(error?.localizedDescription ?? "unknown")
                }
            }
            done.signal()
        }
        done.wait()
        return outcome
    }
}

/// Non-interactive Secure Enclave self-test for the CLI `probe` and the report:
/// creates a throwaway SE key *without* the biometry flag (so no prompt), runs
/// one ECDH against a software key and checks both sides agree.
public enum SecureEnclaveProbe {
    public struct Result: Sendable {
        public var available: Bool
        public var keyCreated: Bool
        public var publicKeyLength: Int
        public var ecdhMatchesSoftware: Bool
        public var biometryKeyCreated: Bool
        public var detail: String
    }

    public static func run() -> Result {
        var r = Result(available: SecureEnclave.isAvailable, keyCreated: false, publicKeyLength: 0,
                       ecdhMatchesSoftware: false, biometryKeyCreated: false, detail: "")
        guard r.available else {
            r.detail = "SecureEnclave.isAvailable == false"
            return r
        }
        do {
            let se = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                compactRepresentable: false,
                accessControl: try SecureEnclaveDeviceKey.accessControl(biometry: false))
            r.keyCreated = true
            r.publicKeyLength = se.publicKey.x963Representation.count
            let sw = P256.KeyAgreement.PrivateKey()
            let a = try se.sharedSecretFromKeyAgreement(with: sw.publicKey).withUnsafeBytes { Data($0) }
            let b = try sw.sharedSecretFromKeyAgreement(with: se.publicKey).withUnsafeBytes { Data($0) }
            r.ecdhMatchesSoftware = a == b && a.count == 32
        } catch {
            r.detail = "SE key (no biometry): \(error)"
            return r
        }
        do {
            // Creating a biometry-bound key does not prompt; it fails when
            // no finger is enrolled.
            _ = try SecureEnclaveDeviceKey.create()
            r.biometryKeyCreated = true
        } catch {
            r.detail = "SE key with .biometryCurrentSet: \(error)"
        }
        return r
    }
}
