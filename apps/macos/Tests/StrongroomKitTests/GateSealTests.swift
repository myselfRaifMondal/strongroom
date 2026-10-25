import CryptoKit
import Foundation
@testable import StrongroomKit
import Testing

/// Software stand-in for the Secure Enclave key (CI VMs have no SE).
private struct SoftwareSealKey: GateSealKey {
    let key = P256.Signing.PrivateKey()

    func sign(_ message: Data) -> Data? {
        (try? key.signature(for: message))?.rawRepresentation
    }

    func isValid(_ signature: Data, for message: Data) -> Bool {
        guard let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.publicKey.isValidSignature(sig, for: message)
    }
}

/// Threat model residual risk 3: a tampered gate state must force the
/// master password.
@Suite struct GateSealTests {
    private let now: Int64 = 1_750_000_000

    private func makeGate() throws -> (SealedUnlockGate, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("strongroom-seal-\(UUID().uuidString)")
        let dir = try DataDirectory(prepared: base)
        let gate = try SealedUnlockGate(
            statePath: dir.unlockGateStatePath, sealPath: dir.unlockGateSealPath, key: SoftwareSealKey())
        return (gate, base)
    }

    private func check(_ gate: SealedUnlockGate, at t: Int64) -> PasswordRequiredReason {
        gate.check(now: t, rebootedSinceLastPassword: false, enrollmentChanged: false, hasDeviceKey: true)
    }

    @Test func sealedStateAllowsBiometrics() throws {
        let (gate, base) = try makeGate()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(check(gate, at: now) == .periodicCheck)
        try gate.recordPasswordUnlock(now: now)
        #expect(gate.stateIsIntact())
        #expect(check(gate, at: now + 60) == .notRequired)
        try gate.recordBiometricFailure()
        try gate.recordBiometricSuccess()
        #expect(check(gate, at: now + 60) == .notRequired)
    }

    @Test func resetFailureCounterForcesPassword() throws {
        let (gate, base) = try makeGate()
        defer { try? FileManager.default.removeItem(at: base) }
        try gate.recordPasswordUnlock(now: now)
        for _ in 0 ..< 5 { try gate.recordBiometricFailure() }
        #expect(check(gate, at: now + 60) == .tooManyBiometricFailures)

        // Attacker rewrites the counter to 0 (valid core format, old seal).
        try SecureFile.write(Data("SRGATE1\n\(now)\n0\n".utf8), to: gate.statePath)
        #expect(!gate.stateIsIntact())
        #expect(check(gate, at: now + 60) == .periodicCheck)
        #expect(!SecureFile.exists(gate.statePath))

        // Recording a failure on tampered state does not restore biometrics.
        try gate.recordBiometricFailure()
        #expect(check(gate, at: now + 60) == .periodicCheck)

        // A password unlock clears it.
        try gate.recordPasswordUnlock(now: now + 120)
        #expect(check(gate, at: now + 180) == .notRequired)
    }

    @Test func movedTimerForcesPassword() throws {
        let (gate, base) = try makeGate()
        defer { try? FileManager.default.removeItem(at: base) }
        try gate.recordPasswordUnlock(now: now)
        let later = now + 8 * 86_400
        #expect(check(gate, at: later) == .periodicCheck)
        try SecureFile.write(Data("SRGATE1\n\(later)\n0\n".utf8), to: gate.statePath)
        #expect(check(gate, at: later + 60) == .periodicCheck)
    }

    @Test func missingOrForgedSealForcesPassword() throws {
        let (gate, base) = try makeGate()
        defer { try? FileManager.default.removeItem(at: base) }

        try gate.recordPasswordUnlock(now: now)
        SecureFile.remove(gate.sealPath)
        #expect(check(gate, at: now + 60) == .periodicCheck)

        try gate.recordPasswordUnlock(now: now)
        // A seal from a different key (attacker's own) is rejected.
        let forged = SoftwareSealKey().sign(Data("anything".utf8))!
        try SecureFile.write(forged, to: gate.sealPath)
        #expect(check(gate, at: now + 60) == .periodicCheck)

        try gate.recordPasswordUnlock(now: now)
        try SecureFile.write(Data([0, 1, 2]), to: gate.sealPath)
        #expect(check(gate, at: now + 60) == .periodicCheck)
    }

    @Test func sealIsBoundToItsStateFile() throws {
        let key = SoftwareSealKey()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("strongroom-seal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = try DataDirectory(prepared: base)
        let a = try SealedUnlockGate(statePath: dir.url.appendingPathComponent("a.state"),
                                     sealPath: dir.url.appendingPathComponent("a.seal"), key: key)
        let b = try SealedUnlockGate(statePath: dir.url.appendingPathComponent("b.state"),
                                     sealPath: dir.url.appendingPathComponent("b.seal"), key: key)
        try a.recordPasswordUnlock(now: now)
        try SecureFile.write(SecureFile.read(a.statePath)!, to: b.statePath)
        try SecureFile.write(SecureFile.read(a.sealPath)!, to: b.sealPath)
        #expect(check(a, at: now + 60) == .notRequired)
        #expect(check(b, at: now + 60) == .periodicCheck)
    }

    @Test func unsealedLegacyStateForcesPassword() throws {
        let (gate, base) = try makeGate()
        defer { try? FileManager.default.removeItem(at: base) }
        // A state file written before sealing existed.
        try SecureFile.write(Data("SRGATE1\n\(now)\n0\n".utf8), to: gate.statePath)
        #expect(check(gate, at: now + 60) == .periodicCheck)
    }

    @Test func noSigningKeyFailsClosed() throws {
        struct NoKey: GateSealKey {
            func sign(_ message: Data) -> Data? { nil }
            func isValid(_ signature: Data, for message: Data) -> Bool { false }
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("strongroom-seal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = try DataDirectory(prepared: base)
        let gate = try SealedUnlockGate(
            statePath: dir.unlockGateStatePath, sealPath: dir.unlockGateSealPath, key: NoKey())
        try gate.recordPasswordUnlock(now: now)
        #expect(!SecureFile.exists(gate.sealPath))
        #expect(check(gate, at: now + 60) == .periodicCheck)
    }

    /// Real Secure Enclave key, no prompt. Skipped where there is no SE (CI).
    @Test func secureEnclaveSealKey() throws {
        guard SecureEnclave.isAvailable else { return }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("strongroom-seal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = try DataDirectory(prepared: base)
        let key = SecureEnclaveGateSealKey(blobPath: dir.gateSealKeyBlobPath)
        let msg = Data("SRGATE1\n1\n0\n".utf8)
        let sig = try #require(key.sign(msg))
        #expect(key.isValid(sig, for: msg))
        #expect(!key.isValid(sig, for: Data("SRGATE1\n2\n0\n".utf8)))
        // A fresh key (blob replaced) does not accept the old seal.
        SecureFile.remove(dir.gateSealKeyBlobPath)
        _ = key.sign(msg)
        #expect(!key.isValid(sig, for: msg))
    }

    @Test func deviceUnlockUsesTheSeal() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("strongroom-seal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let du = try DeviceUnlock(dir: try DataDirectory(prepared: base), sealKey: SoftwareSealKey())
        #expect(du.gate.statePath == du.dir.unlockGateStatePath)
        #expect(du.gate.sealPath == du.dir.unlockGateSealPath)
    }
}
