import AppKit
import StrongroomKit
import SwiftUI
import UniformTypeIdentifiers

/// App state. All core calls that can be slow (Argon2id, Touch ID, export,
/// import) run on `CoreThread`; quick store reads run inline.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case needsVault
        case showSecretKey(String)
        case locked
        case unlocked
        case fatal(String)
    }

    @Published private(set) var phase: Phase
    @Published private(set) var items: [ItemSummary] = []
    @Published var query = "" { didSet { refresh() } }
    @Published var selection: String?
    @Published var busy = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published private(set) var gateReason: PasswordRequiredReason = .noBiometricKey
    @Published private(set) var touchIDEnrolled = false
    @Published var editor: EditorRequest?
    @Published var transfer: TransferRequest?
    @Published var hotKeyRegistered = false
    /// Bumped on every change so detail views reload.
    @Published private(set) var revision = 0

    struct EditorRequest: Identifiable {
        let id = UUID()
        let itemId: String?
        let draft: ItemDraft
    }

    enum TransferRequest: Identifiable {
        case export
        case importFile(URL, VtfInfo?)
        var id: String {
            switch self {
            case .export: return "export"
            case let .importFile(url, _): return "import:\(url.path)"
            }
        }
    }

    let dir: DataDirectory?
    private var deviceUnlock: DeviceUnlock?
    private var vault: Vault?

    init() {
        do {
            let dir = try DataDirectory.standard()
            self.dir = dir
            self.deviceUnlock = try? DeviceUnlock(dir: dir)
            phase = SecureFile.exists(dir.vaultPath) ? .locked : .needsVault
        } catch {
            dir = nil
            phase = .fatal("Cannot open the data folder: \(error)")
        }
        refreshGate()
    }

    var isUnlocked: Bool { phase == .unlocked }
    var currentVault: Vault? { vault }
    var deviceUnlockSupported: Bool { DeviceCapabilities.deviceUnlockSupported }
    var touchIDAvailableNow: Bool { touchIDEnrolled && gateReason == .notRequired }

    func refreshGate() {
        touchIDEnrolled = deviceUnlock?.isEnrolled ?? false
        gateReason = deviceUnlock?.passwordRequired() ?? .noBiometricKey
    }

    // MARK: create / unlock / lock

    func createVault(password: String) async {
        guard let dir else { return }
        let secretKey = generateSecretKey()
        guard !secretKey.isEmpty else {
            errorMessage = "The core could not generate a Secret Key (core not implemented in this build)."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let path = dir.vaultPath
            let v = try await CoreThread.run {
                try Vault.create(path: path.path, password: password, secretKey: secretKey, now: Clock.now())
            }
            try? SecureFile.chmod(path, 0o600)
            vault = v
            try? deviceUnlock?.recordPasswordUnlock(vault: v)
            phase = .showSecretKey(secretKey)
        } catch {
            errorMessage = CoreErrors.describe(error)
        }
    }

    func acknowledgeSecretKey() {
        phase = .unlocked
        refresh()
        refreshGate()
    }

    func unlock(password: String, secretKey: String) async {
        guard let dir else { return }
        busy = true
        defer { busy = false }
        let path = dir.vaultPath.path
        let sk = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let v = try await CoreThread.run {
                try Vault.unlockWithPassword(path: path, password: password, secretKey: sk, now: Clock.now())
            }
            vault = v
            if let du = deviceUnlock {
                let vaultRef = v
                try? await CoreThread.run { try du.recordPasswordUnlock(vault: vaultRef) }
            }
            didUnlock()
        } catch {
            errorMessage = CoreErrors.describe(error)
        }
    }

    func unlockWithTouchID() async {
        guard let dir, let du = deviceUnlock else { return }
        refreshGate()
        guard gateReason == .notRequired else { return }
        busy = true
        defer { busy = false }
        let path = dir.vaultPath
        let outcome = try? await CoreThread.run { du.unlock(vaultPath: path, reason: "unlock your Strongroom vault") }
        switch outcome {
        case let .unlocked(v)?:
            vault = v
            didUnlock()
        case let .failed(failure)?:
            switch failure {
            case .cancelled?: break
            case .keyInvalidated?:
                errorMessage = "Touch ID can no longer unlock this vault (the fingerprints on this Mac changed). Enter your master password; Touch ID will be set up again."
            case .lockout?:
                errorMessage = "Touch ID is locked out. Enter your master password."
            default:
                errorMessage = "Touch ID unlock failed."
            }
            refreshGate()
        case nil:
            errorMessage = "Touch ID unlock failed."
        }
    }

    private func didUnlock() {
        phase = .unlocked
        errorMessage = nil
        refresh()
        refreshGate()
    }

    func lock() {
        guard vault != nil else { return }
        vault?.lock()
        vault = nil
        items = []
        selection = nil
        editor = nil
        transfer = nil
        SecureClipboard.shared.clearNow()
        if case .showSecretKey = phase {} else if phase == .unlocked { phase = .locked }
        refreshGate()
    }

    // MARK: Touch ID enrollment

    func setTouchID(enabled: Bool) async {
        guard let du = deviceUnlock else { return }
        if !enabled {
            du.remove()
            refreshGate()
            return
        }
        guard let v = vault else { return }
        busy = true
        defer { busy = false }
        do {
            try await CoreThread.run { try du.enroll(vault: v) }
            infoMessage = "Touch ID unlock is on for this Mac."
        } catch {
            errorMessage = "Could not turn on Touch ID: \(CoreErrors.describe(error))"
        }
        refreshGate()
    }

    // MARK: items

    func refresh() {
        guard let vault else { items = []; return }
        do {
            items = try vault.search(query: query, folder: nil, tag: nil)
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            if let s = selection, !items.contains(where: { $0.id == s }) { selection = nil }
        } catch {
            errorMessage = CoreErrors.describe(error)
        }
        revision += 1
    }

    func search(_ q: String) -> [ItemSummary] {
        (try? vault?.search(query: q, folder: nil, tag: nil)) ?? []
    }

    func item(_ id: String) -> Item? {
        try? vault?.getItem(id: id)
    }

    func totp(_ id: String) -> TotpCode? {
        try? vault?.itemTotp(id: id, now: Clock.now())
    }

    func requestNewItem(kind: ItemKind = .login) {
        guard isUnlocked else { return }
        editor = EditorRequest(itemId: nil, draft: ItemDraft(kind: kind))
    }

    func requestEdit(_ id: String) {
        guard let item = item(id) else { return }
        editor = EditorRequest(itemId: id, draft: ItemDraft(item.data))
    }

    func save(_ draft: ItemDraft, id: String?) -> Bool {
        guard let vault else { return false }
        do {
            if let id {
                try vault.updateItem(id: id, input: draft.toInput(), now: Clock.now())
                selection = id
            } else {
                selection = try vault.addItem(input: draft.toInput(), now: Clock.now())
            }
            refresh()
            return true
        } catch {
            errorMessage = CoreErrors.describe(error)
            return false
        }
    }

    func trash(_ id: String) {
        do {
            try vault?.trashItem(id: id, now: Clock.now())
            refresh()
        } catch {
            errorMessage = CoreErrors.describe(error)
        }
    }

    func copy(_ value: String?, label: String) {
        guard let value, !value.isEmpty else { return }
        SecureClipboard.shared.copy(value)
        infoMessage = "\(label) copied. The clipboard clears in \(Int(SecureClipboard.defaultClearAfter)) s."
    }

    // MARK: VTF export / import

    func beginExport() {
        guard isUnlocked else { return }
        transfer = .export
    }

    func beginImport() {
        guard isUnlocked else { return }
        let panel = NSOpenPanel()
        panel.title = "Import a VTF file"
        panel.allowedContentTypes = [UTType(filenameExtension: "vtf") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        WindowPrivacy.protect(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let info = (try? Data(contentsOf: url)).flatMap { try? vtfInspect(file: $0) }
        transfer = .importFile(url, info)
    }

    /// Asks for a destination, then exports with the password slot.
    func export(password: String, secretKey: String) async -> Bool {
        guard let vault else { return false }
        let panel = NSSavePanel()
        panel.title = "Export vault"
        panel.nameFieldStringValue = "Strongroom-\(Self.dateStamp()).vtf"
        panel.allowedContentTypes = [UTType(filenameExtension: "vtf") ?? .data]
        WindowPrivacy.protect(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        busy = true
        defer { busy = false }
        let sk = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let bytes = try await CoreThread.run {
                try vault.exportVtf(password: password, secretKey: sk, deviceRecipients: [], now: Clock.now())
            }
            try SecureFile.write(bytes, to: url)
            infoMessage = "Exported \(bytes.count) bytes to \(url.lastPathComponent)."
            return true
        } catch {
            errorMessage = CoreErrors.describe(error)
            return false
        }
    }

    func importFile(_ url: URL, password: String, secretKey: String) async -> Bool {
        guard let vault else { return false }
        busy = true
        defer { busy = false }
        let sk = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let data = try Data(contentsOf: url)
            let s = try await CoreThread.run {
                try vault.importVtf(file: data, password: password, secretKey: sk, now: Clock.now())
            }
            refresh()
            infoMessage = "Imported: \(s.added) added, \(s.updated) updated, \(s.unchanged) unchanged, \(s.conflicts) conflicts."
            return true
        } catch {
            errorMessage = CoreErrors.describe(error)
            return false
        }
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
