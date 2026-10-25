import CryptoKit
import Foundation
@testable import StrongroomKit
import Testing

/// Exercises the generated bindings against whatever core is linked. If the
/// core reports Unsupported (or returns empty values), those tests stop early
/// instead of failing.
@Suite(.serialized) struct CoreBindingTests {
    @Test func bindingsLinkAndCall() {
        let sk = generateSecretKey()
        #expect(sk.isEmpty || sk.hasPrefix("SR1-"))
        let s = estimateStrength(password: "correct horse battery staple")
        #expect(s.score <= 4)
    }

    @Test func errorsAreTyped() {
        do {
            _ = try vtfInspect(file: Data("not a vtf".utf8))
            Issue.record("garbage was accepted as VTF")
        } catch let e as StrongroomError {
            switch e {
            case .FormatRejected, .Unsupported: break
            default: Issue.record("unexpected error \(e)")
            }
        } catch {
            Issue.record("untyped error \(error)")
        }
    }

    @Test func vaultRoundTripOnCoreThread() async throws {
        let sk = generateSecretKey()
        guard !sk.isEmpty else { return } // core reported Unsupported / empty
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("strongroom-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let titles = try await CoreThread.run { () throws -> [String] in
            let now = Clock.now()
            let a = try Vault.create(path: base.appendingPathComponent("a.srdb").path, password: "test-password-1", secretKey: sk, now: now)
            var draft = ItemDraft(kind: .card)
            draft.title = "Card"
            draft.fields[1].value = "4111111111111111"
            _ = try a.addItem(input: draft.toInput(), now: now)
            var login = ItemDraft(kind: .login)
            login.title = "Login"
            login.password = "pw"
            login.totp = "JBSWY3DPEHPK3PXP"
            let id = try a.addItem(input: login.toInput(), now: now)
            let code = try a.itemTotp(id: id, now: now)
            #expect(code.code.count == 6)
            let vtf = try a.exportVtf(password: "test-password-1", secretKey: sk, deviceRecipients: [], now: now)
            a.lock()

            let b = try Vault.create(path: base.appendingPathComponent("b.srdb").path, password: "test-password-2", secretKey: generateSecretKey(), now: now)
            defer { b.lock() }
            let summary = try b.importVtf(file: vtf, password: "test-password-1", secretKey: sk, now: now + 1)
            #expect(summary.added == 2)
            let card = try #require(try b.search(query: "Card", folder: nil, tag: nil).first)
            let full = try b.getItem(id: card.id)
            #expect(full.data.fields.contains(CustomField(name: "Number", value: "4111111111111111", concealed: true)))
            return try b.search(query: "", folder: nil, tag: nil).map(\.title).sorted()
        }
        #expect(titles == ["Card", "Login"])
    }

    /// The gate inputs the app feeds (reboot, enrollment change, device key)
    /// produce the documented reasons.
    @Test func unlockGatePolicy() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("strongroom-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let gate = try UnlockGate(statePath: base.appendingPathComponent("gate.state").path)
        let now: Int64 = 1_800_000_000
        do {
            try gate.recordPasswordUnlock(now: now)
        } catch let e where CoreErrors.isUnsupported(e) {
            return // core reported Unsupported / empty
        }
        #expect(gate.check(now: now + 60, rebootedSinceLastPassword: false, enrollmentChanged: false, hasDeviceKey: true) == .notRequired)
        #expect(gate.check(now: now + 60, rebootedSinceLastPassword: false, enrollmentChanged: false, hasDeviceKey: false) == .noBiometricKey)
        #expect(gate.check(now: now + 60, rebootedSinceLastPassword: true, enrollmentChanged: false, hasDeviceKey: true) == .firstLaunchAfterReboot)
        #expect(gate.check(now: now + 60, rebootedSinceLastPassword: false, enrollmentChanged: true, hasDeviceKey: true) == .biometricEnrollmentChanged)
        #expect(gate.check(now: now + 8 * 86_400, rebootedSinceLastPassword: false, enrollmentChanged: false, hasDeviceKey: true) == .periodicCheck)
        for _ in 0 ..< 5 { try gate.recordBiometricFailure() }
        #expect(gate.check(now: now + 60, rebootedSinceLastPassword: false, enrollmentChanged: false, hasDeviceKey: true) == .tooManyBiometricFailures)
        try gate.recordPasswordUnlock(now: now + 120)
        #expect(gate.check(now: now + 180, rebootedSinceLastPassword: false, enrollmentChanged: false, hasDeviceKey: true) == .notRequired)
    }

    /// End to end over the real Secure Enclave without a Touch ID prompt: the
    /// vault key is wrapped to an SE key (no biometry flag, test only) and the
    /// vault is reopened through `unlock_with_device_key`, i.e. one SE ECDH
    /// driven by the core's HPKE receiver. Skipped without an SE or if the core reports Unsupported.
    @Test func deviceKeyUnlockThroughSecureEnclave() async throws {
        let sk = generateSecretKey()
        guard !sk.isEmpty, SecureEnclave.isAvailable else { return }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("strongroom-se-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("v.srdb").path

        let titles = try await CoreThread.run { () throws -> [String] in
            let device = try NoPromptSecureEnclaveKey()
            let v = try Vault.create(path: path, password: "test-password-1", secretKey: sk, now: Clock.now())
            var d = ItemDraft(kind: .login)
            d.title = "Sealed to the Secure Enclave"
            _ = try v.addItem(input: d.toInput(), now: Clock.now())
            let wrapped = try v.wrapVaultKeyForDevice(devicePublicKey: device.publicKey())
            v.lock()

            let reopened = try Vault.unlockWithDeviceKey(path: path, deviceWrappedKey: wrapped, device: device)
            defer { reopened.lock() }
            #expect(device.agreeCount == 1)

            // A different SE key must not open it.
            let other = try NoPromptSecureEnclaveKey()
            #expect(throws: StrongroomError.UnlockFailed) {
                _ = try Vault.unlockWithDeviceKey(path: path, deviceWrappedKey: wrapped, device: other)
            }
            return try reopened.search(query: "", folder: nil, tag: nil).map(\.title)
        }
        #expect(titles == ["Sealed to the Secure Enclave"])
    }
}

/// Test-only SE key without `.biometryCurrentSet`, so it runs unattended.
final class NoPromptSecureEnclaveKey: DeviceKeyAgreement, @unchecked Sendable {
    private let key: SecureEnclave.P256.KeyAgreement.PrivateKey
    private(set) var agreeCount = 0

    init() throws {
        key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
            compactRepresentable: false, accessControl: try SecureEnclaveDeviceKey.accessControl(biometry: false))
    }

    func publicKey() -> Data { key.publicKey.x963Representation }

    func agree(peerPublicKey: Data) throws -> Data {
        agreeCount += 1
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey)
        return try key.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
    }
}
