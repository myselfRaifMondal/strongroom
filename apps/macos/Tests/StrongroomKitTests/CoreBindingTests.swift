import Foundation
@testable import StrongroomKit
import Testing

/// Exercises the generated bindings against whatever core is linked. On
/// main's stub core the calls report Unsupported (or return empty values);
/// those tests then stop early instead of failing, like the CLI round-trip.
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
        guard !sk.isEmpty else { return } // stub core
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
}
