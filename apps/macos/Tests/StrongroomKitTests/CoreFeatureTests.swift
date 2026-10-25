import CryptoKit
import Foundation
@testable import StrongroomKit
import Testing

/// End-to-end checks of the new macOS features against the real core (each
/// test stops early if the core reports Unsupported, like CoreBindingTests).
@Suite(.serialized) struct CoreFeatureTests {
    private func withTempDir<T>(_ body: (URL) async throws -> T) async throws -> T {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("strongroom-feat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        return try await body(base)
    }

    private func socialAccount(_ title: String, folder: String, codes: [String]) throws -> ItemInput {
        var d = ItemDraft(template: try #require(ItemTemplate.named("social")))
        d.title = title
        d.username = title.replacingOccurrences(of: "@", with: "")
        d.password = "pw-\(title)-Xq9!vL2#"
        d.folder = folder
        d.urls = ["https://instagram.com"]
        d.addRecoveryCodes(codes)
        d.fields[d.fields.firstIndex { $0.name == "Security question 1" }!].value = "First pet?"
        d.fields[d.fields.firstIndex { $0.name == "Security answer 1" }!].value = "Rex"
        d.fields.append(.init(name: SensitiveField.twoFactorNoteName, value: "Authenticator on old phone", concealed: true))
        d.favourite = true
        return d.toInput()
    }

    /// Nested folder paths, template tags, favourites and recovery-code fields
    /// (including a used one) survive export_vtf -> import_vtf unchanged.
    @Test func hierarchyAndRecoveryCodesSurviveVtfRoundTrip() async throws {
        let sk = generateSecretKey()
        guard !sk.isEmpty else { return }
        try await withTempDir { base in
            try await CoreThread.run {
                let now = Clock.now()
                let a = try Vault.create(path: base.appendingPathComponent("a.srdb").path, password: "test-password-1", secretKey: sk, now: now)
                var personal = try socialAccount("@personal", folder: "Social/Instagram", codes: ["1111-2222", "3333-4444", "5555-6666"])
                personal.fields = RecoveryCodes.setUsed(personal.fields, index: personal.fields.firstIndex { $0.value == "3333-4444" }!, used: true)
                let work = try socialAccount("@work", folder: "Social / Instagram", codes: ["aaaa"])
                let deep = ItemInput(kind: .secureNote, title: "Deep", username: nil, password: nil, urls: [], notes: "n", totp: nil,
                                     folder: "Work/Servers/Prod/EU", tags: ["template:secure-note", "ops"], fields: [], travelSafe: true)
                let originals = [personal, work, deep]
                for input in originals { _ = try a.addItem(input: input, now: now) }
                let vtf = try a.exportVtf(password: "test-password-1", secretKey: sk, deviceRecipients: [], now: now)
                a.lock()

                let b = try Vault.create(path: base.appendingPathComponent("b.srdb").path, password: "test-password-2", secretKey: generateSecretKey(), now: now)
                defer { b.lock() }
                let s = try b.importVtf(file: vtf, password: "test-password-1", secretKey: sk, now: now + 1)
                #expect(s.added == 3)
                let summaries = try b.search(query: "", folder: nil, tag: nil)
                for original in originals {
                    let sum = try #require(summaries.first { $0.title == original.title })
                    let got = try b.getItem(id: sum.id).data
                    #expect(got == original, "\(original.title) changed in transit")
                }
                let tree = FolderTree.build(folders: summaries.map(\.folder))
                #expect(FolderTree.find(["Social", "Instagram"], in: tree)?.totalCount == 2)
                #expect(FolderTree.find(["Work", "Servers", "Prod", "EU"], in: tree)?.totalCount == 1)
                let p = try b.getItem(id: summaries.first { $0.title == "@personal" }!.id).data
                #expect(RecoveryCodes.unusedCount(p.fields) == 2)
                #expect(p.fields.contains(CustomField(name: "[used] Recovery code 2", value: "3333-4444", concealed: true)))
                #expect(ReservedTags.isFavourite(p.tags))
                #expect(ReservedTags.templateID(in: p.tags) == "social")
                // `search` matches an exact folder only; prefix filtering is client-side.
                let exact = try b.search(query: "", folder: "Social", tag: nil)
                #expect(exact.isEmpty)
                #expect(summaries.filter { FolderPath.isInSubtree($0.folder, of: ["Social"]) }.count == 2)
                #expect(try b.search(query: "", folder: nil, tag: "favourite").count == 2)
            }
        }
    }

    /// Folder rename = update_item on every item in the subtree; history keeps
    /// the old folder; mark-used through update_item; restore from trash.
    @Test func renameHistoryTrashAndHealth() async throws {
        let sk = generateSecretKey()
        guard !sk.isEmpty else { return }
        try await withTempDir { base in
            try await CoreThread.run {
                let now = Clock.now()
                let v = try Vault.create(path: base.appendingPathComponent("v.srdb").path, password: "test-password-1", secretKey: sk, now: now)
                defer { v.lock() }
                let id1 = try v.addItem(input: try socialAccount("@one", folder: "Social/Insta", codes: ["c1", "c2"]), now: now)
                var reused = try socialAccount("@two", folder: "Social/Insta/Old", codes: [])
                reused.password = "pw-@one-Xq9!vL2#"
                let id2 = try v.addItem(input: reused, now: now)
                var weak = ItemDraft(kind: .login)
                weak.title = "Weak"
                weak.password = "abc"
                weak.folder = "Other"
                let id3 = try v.addItem(input: weak.toInput(), now: now)

                let all = try v.search(query: "", folder: nil, tag: nil)
                let plan = FolderOps.plan(items: all.map { ($0.id, $0.folder) }, from: ["Social", "Insta"], to: ["Social", "Instagram"])
                #expect(plan.count == 2)
                for change in plan {
                    var input = try v.getItem(id: change.id).data
                    input.folder = change.folder
                    try v.updateItem(id: change.id, input: input, now: now + 10)
                }
                #expect(try v.getItem(id: id1).data.folder == "Social/Instagram")
                #expect(try v.getItem(id: id2).data.folder == "Social/Instagram/Old")
                #expect(try v.getItem(id: id3).data.folder == "Other")

                var item = try v.getItem(id: id1).data
                let codeIndex = try #require(RecoveryCodes.entries(item.fields.map(\.name)).first?.index)
                item.fields = RecoveryCodes.setUsed(item.fields, index: codeIndex, used: true)
                try v.updateItem(id: id1, input: item, now: now + 20)
                #expect(RecoveryCodes.unusedCount(try v.getItem(id: id1).data.fields) == 1)

                let history = try v.itemHistory(id: id1)
                #expect(history.count == 2)
                #expect(history.first?.data.folder == "Social/Insta")
                #expect(RecoveryCodes.unusedCount(history.last!.data.fields) == 2)

                let health = try v.passwordHealth(now: now)
                #expect(health.securityScore <= 100)
                #expect(Set(health.reusedItemIds) == [id1, id2])
                #expect(health.weakItemIds.contains(id3))

                try v.trashItem(id: id3, now: now + 30)
                let trash = try v.listTrash()
                #expect(trash.map(\.item.id) == [id3])
                #expect(trash[0].purgeAt - trash[0].deletedAt == 180 * 86_400)
                #expect(try v.purgeExpiredTrash(now: now + 31) == 0)
                try v.restoreItem(id: id3, now: now + 40)
                #expect(try v.listTrash().isEmpty)
            }
        }
    }

    /// Decoy: one call with both paths; either password opens its own vault,
    /// a wrong password fails the same way, and a missing second file is fine.
    @Test func decoyUnlockAndVaultIdentity() async throws {
        let sk = generateSecretKey()
        guard !sk.isEmpty else { return }
        try await withTempDir { base in
            let dir = try DataDirectory(prepared: base.appendingPathComponent("data"))
            let paths = dir.unlockCandidatePaths.map(\.path)
            try await CoreThread.run {
                let now = Clock.now()
                let main = try Vault.create(path: dir.vaultPath.path, password: "main-password-1", secretKey: sk, now: now)
                var d = ItemDraft(kind: .secureNote); d.title = "Real"
                _ = try main.addItem(input: d.toInput(), now: now)
                main.lock()

                // Second vault missing: the main password still opens the main vault.
                let m0 = try Vault.unlockFirstMatching(paths: paths, password: "main-password-1", secretKey: sk, now: now)
                #expect(try m0.search(query: "", folder: nil, tag: nil).map(\.title) == ["Real"])
                #expect(VaultIdentity.isVault(m0, storedAt: dir.vaultPath))
                #expect(!VaultIdentity.isVault(m0, storedAt: dir.secondVaultPath))
                m0.lock()

                let decoy = try Vault.create(path: dir.secondVaultPath.path, password: "other-password-2", secretKey: sk, now: now)
                d.title = "Plausible"
                _ = try decoy.addItem(input: d.toInput(), now: now)
                decoy.lock()

                let m = try Vault.unlockFirstMatching(paths: paths, password: "main-password-1", secretKey: sk, now: now)
                #expect(try m.search(query: "", folder: nil, tag: nil).map(\.title) == ["Real"])
                #expect(!VaultIdentity.isVault(m, storedAt: dir.secondVaultPath))
                m.lock()
                let o = try Vault.unlockFirstMatching(paths: paths, password: "other-password-2", secretKey: sk, now: now)
                #expect(try o.search(query: "", folder: nil, tag: nil).map(\.title) == ["Plausible"])
                #expect(VaultIdentity.isVault(o, storedAt: dir.secondVaultPath))
                #expect(!VaultIdentity.isVault(o, storedAt: dir.vaultPath))
                o.lock()
                #expect(throws: StrongroomError.UnlockFailed) {
                    _ = try Vault.unlockFirstMatching(paths: paths, password: "wrong-password-3", secretKey: sk, now: now)
                }
            }
        }
    }

    /// Backup to a chosen path, replacing an older backup, opens with the same
    /// credentials; CSV import; travel mode removes non-travel-safe items.
    @Test func backupCsvAndTravelMode() async throws {
        let sk = generateSecretKey()
        guard !sk.isEmpty else { return }
        try await withTempDir { base in
            try await CoreThread.run {
                let now = Clock.now()
                let v = try Vault.create(path: base.appendingPathComponent("v.srdb").path, password: "test-password-1", secretKey: sk, now: now)
                defer { v.lock() }
                let csv = "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n" +
                    "Social,,login,Example,,,0,https://example.com,alice,hunter2-longer,\n"
                let summary = try v.importCsv(source: .bitwarden, csv: csv, now: now)
                #expect(summary.added == 1)

                var safe = ItemDraft(kind: .secureNote); safe.title = "Safe"; safe.travelSafe = true
                _ = try v.addItem(input: safe.toInput(), now: now)

                let dest = base.appendingPathComponent("backup.srdb")
                try VaultBackup.write(v, to: dest)
                try VaultBackup.write(v, to: dest) // replaces the older backup
                #expect(SecureFile.mode(dest) == 0o600)
                #expect(SecureFile.exists(URL(fileURLWithPath: dest.path + ".hdr")))
                let leftovers = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasSuffix(".tmp") || $0.contains(".tmp.") }
                #expect(leftovers.isEmpty)
                let restored = try Vault.unlockWithPassword(path: dest.path, password: "test-password-1", secretKey: sk, now: now)
                #expect(try restored.search(query: "", folder: nil, tag: nil).count == 2)
                restored.lock()

                #expect(try !v.travelMode())
                try v.setTravelMode(enabled: true, now: now + 5)
                #expect(try v.travelMode())
                #expect(try v.search(query: "", folder: nil, tag: nil).map(\.title) == ["Safe"])
            }
        }
    }

    /// Paired-device file (0600, dedup by fingerprint) and a VTF sealed to a
    /// device recipient opened with `import_vtf_with_device_key` through the
    /// Secure Enclave (no-prompt test key; skipped without an SE).
    @Test func pairingAndDeviceKeyImport() async throws {
        let sk = generateSecretKey()
        guard !sk.isEmpty else { return }
        try await withTempDir { base in
            let dir = try DataDirectory(prepared: base.appendingPathComponent("data"))
            let store = PairedDeviceStore(dir: dir)
            let other = SoftwareDeviceKey()
            let payload = pairingPayload(devicePublicKey: other.publicKey())
            #expect(payload.hasPrefix("SR1PAIR:"))
            let rec = try store.add(name: " Phone ", payload: payload + "\n", now: 1)
            #expect(rec.name == "Phone")
            #expect(try rec.publicKey() == other.publicKey())
            try store.add(name: "Renamed", payload: payload, now: 2)
            #expect(store.load().map(\.name) == ["Renamed"])
            #expect(SecureFile.mode(dir.pairedDevicesPath) == 0o600)
            #expect(throws: StrongroomError.self) { try store.add(name: "x", payload: "SR1PAIR:garbage", now: 3) }
            try store.remove(fingerprint: rec.fingerprint)
            #expect(store.load().isEmpty)

            guard SecureEnclave.isAvailable else { return }
            try await CoreThread.run {
                let now = Clock.now()
                let device = try NoPromptSecureEnclaveKey()
                let a = try Vault.create(path: base.appendingPathComponent("a.srdb").path, password: "test-password-1", secretKey: sk, now: now)
                _ = try a.addItem(input: try socialAccount("@sealed", folder: "Social/Instagram", codes: ["z1"]), now: now)
                let vtf = try a.exportVtf(password: "test-password-1", secretKey: sk,
                                          deviceRecipients: [device.publicKey(), other.publicKey()], now: now)
                a.lock()
                #expect(try vtfInspect(file: vtf).deviceSlots == 2)
                let b = try Vault.create(path: base.appendingPathComponent("b.srdb").path, password: "test-password-2", secretKey: generateSecretKey(), now: now)
                defer { b.lock() }
                let s = try b.importVtfWithDeviceKey(file: vtf, device: device, now: now + 1)
                #expect(s.added == 1)
                let got = try b.search(query: "", folder: nil, tag: nil)
                #expect(got.map(\.folder) == ["Social/Instagram"])
            }
        }
    }
}
