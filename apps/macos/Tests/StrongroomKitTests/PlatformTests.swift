import AppKit
import CryptoKit
import Foundation
@testable import StrongroomKit
import Testing

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("strongroom-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct SecureFileTests {
    @Test func writesWith0600AndDirectoryIs0700() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = try DataDirectory(prepared: base.appendingPathComponent("Strongroom"))
        #expect(SecureFile.mode(dir.url) == 0o700)

        try SecureFile.write(Data([1, 2, 3]), to: dir.deviceKeyBlobPath)
        #expect(SecureFile.mode(dir.deviceKeyBlobPath) == 0o600)
        #expect(SecureFile.read(dir.deviceKeyBlobPath) == Data([1, 2, 3]))

        // Overwrite keeps 0600 and replaces atomically.
        try SecureFile.write(Data([9]), to: dir.deviceKeyBlobPath)
        #expect(SecureFile.mode(dir.deviceKeyBlobPath) == 0o600)
        #expect(SecureFile.read(dir.deviceKeyBlobPath) == Data([9]))

        // No temp files left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.url.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }
}

@Suite struct BootTimeTests {
    @Test func currentBootTimeIsPlausible() throws {
        let boot = try #require(BootTime.current())
        #expect(boot > 1_500_000_000)
        #expect(boot <= Clock.now())
    }

    @Test func rebootDetection() {
        #expect(BootTime.rebootedSince(recorded: nil, current: 100))
        #expect(BootTime.rebootedSince(recorded: 100, current: nil))
        #expect(!BootTime.rebootedSince(recorded: 1000, current: 1000))
        #expect(!BootTime.rebootedSince(recorded: 1000, current: 1000 + BootTime.tolerance))
        #expect(BootTime.rebootedSince(recorded: 1000, current: 1000 + BootTime.tolerance + 1))
    }

    @Test func recordAndCompare() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = try DataDirectory(prepared: base)
        #expect(BootTime.rebootedSinceLastPassword(dir), "no record must count as rebooted")
        try BootTime.recordCurrent(dir)
        #expect(SecureFile.mode(dir.bootTimePath) == 0o600)
        #expect(!BootTime.rebootedSinceLastPassword(dir))
    }
}

@Suite(.serialized) struct SecureClipboardTests {
    @Test func marksConcealedAndTransientAndClears() async throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("strongroom-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let clip = SecureClipboard(pasteboard: pb)
        clip.copy("s3cret", clearAfter: 0.2)
        let types = pb.types ?? []
        #expect(types.contains(.string))
        #expect(types.contains(SecureClipboard.concealedType))
        #expect(types.contains(SecureClipboard.transientType))
        #expect(pb.string(forType: .string) == "s3cret")
        #expect(SecureClipboard.concealedType.rawValue == "org.nspasteboard.ConcealedType")
        #expect(SecureClipboard.transientType.rawValue == "org.nspasteboard.TransientType")

        try await Task.sleep(for: .milliseconds(600))
        #expect(pb.string(forType: .string) == nil)
    }

    @Test func doesNotClearSomeoneElsesCopy() async throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("strongroom-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let clip = SecureClipboard(pasteboard: pb)
        clip.copy("s3cret", clearAfter: 0.2)
        pb.clearContents()
        pb.setString("user copied this", forType: .string)
        try await Task.sleep(for: .milliseconds(600))
        #expect(pb.string(forType: .string) == "user copied this")
    }

    @Test func defaultTimeoutInRequiredWindow() {
        #expect((20 ... 30).contains(SecureClipboard.defaultClearAfter))
    }
}

/// Software P-256 stand-in for the Secure Enclave key: checks the
/// DeviceKeyAgreement contract shape (65-byte SEC1 public key, 32-byte raw
/// shared secret equal to the peer's view).
final class SoftwareDeviceKey: DeviceKeyAgreement, @unchecked Sendable {
    let key = P256.KeyAgreement.PrivateKey()
    func publicKey() -> Data { key.publicKey.x963Representation }
    func agree(peerPublicKey: Data) throws -> Data {
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey)
        return try key.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
    }
}

@Suite struct DeviceKeyContractTests {
    @Test func softwareKeyMatchesContract() throws {
        let device = SoftwareDeviceKey()
        let pub = device.publicKey()
        #expect(pub.count == 65)
        #expect(pub.first == 0x04)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let secret = try device.agree(peerPublicKey: ephemeral.publicKey.x963Representation)
        #expect(secret.count == 32)
        let other = try ephemeral.sharedSecretFromKeyAgreement(with: device.key.publicKey).withUnsafeBytes { Data($0) }
        #expect(secret == other)
    }

    /// On Macs with a Secure Enclave: SE ECDH matches software ECDH. Uses a
    /// key without the biometry flag, so no Touch ID prompt. CI VMs have no SE.
    @Test func secureEnclaveProbe() {
        let r = SecureEnclaveProbe.run()
        if r.available {
            #expect(r.keyCreated)
            #expect(r.publicKeyLength == 65)
            #expect(r.ecdhMatchesSoftware)
        } else {
            #expect(!r.keyCreated)
        }
    }

    @Test func notEnrolledMeansNoDeviceKey() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = try DataDirectory(prepared: base)
        // UnlockGate's constructor may be a stub (main) or real (core-vault).
        guard let du = try? DeviceUnlock(dir: dir) else { return }
        #expect(!du.isEnrolled)
        #expect(!du.enrollmentChanged())
        #expect(du.passwordRequired() != .notRequired)
    }
}

@Suite struct ItemDraftTests {
    @Test func roundTripsAllKinds() {
        for kind in ItemKind.allCases {
            var d = ItemDraft(kind: kind)
            d.title = "  \(kind.displayName) item "
            d.username = "alice"
            d.password = "pw"
            d.urls = ["https://example.com", "  ", ""]
            d.tags = "work, , personal ,"
            d.folder = " Banking "
            d.fields.append(.init(name: " PIN ", value: "1234", concealed: true))
            let input = d.toInput()
            #expect(input.kind == kind)
            #expect(input.title == "\(kind.displayName) item")
            #expect(input.urls == ["https://example.com"])
            #expect(input.tags == ["work", "personal"])
            #expect(input.folder == "Banking")
            #expect(input.fields.contains(CustomField(name: "PIN", value: "1234", concealed: true)))
            #expect(input.fields.count == kind.templateFields.count + 1)
            let back = ItemDraft(input).toInput()
            #expect(back == input)
        }
    }

    @Test func emptyOptionalsBecomeNil() {
        var d = ItemDraft(kind: .secureNote)
        d.title = "Note"
        let input = d.toInput()
        #expect(input.username == nil)
        #expect(input.password == nil)
        #expect(input.totp == nil)
        #expect(input.notes == nil)
        #expect(input.urls.isEmpty)
        #expect(d.isValid)
    }

    @Test func kindChangeKeepsData() {
        var d = ItemDraft(kind: .card)
        d.fields[1].value = "4111111111111111"
        d.changeKind(to: .identity)
        #expect(d.fields.contains { $0.value == "4111111111111111" })
        #expect(d.fields.contains { $0.name == "Email" })
        #expect(d.kind == .identity)
    }

    @Test func templatesConcealSecrets() {
        #expect(ItemKind.card.templateFields.first { $0.name == "Number" }?.concealed == true)
        #expect(ItemKind.sshKey.templateFields.first { $0.name == "Private key" }?.concealed == true)
    }
}
