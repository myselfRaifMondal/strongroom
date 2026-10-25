import AppKit
import StrongroomKit
import SwiftUI
import UniformTypeIdentifiers

/// What the sidebar has selected.
enum SidebarSelection: Hashable {
    case all
    case favourites
    /// `FolderPath.id` of the folder ("Social/Instagram").
    case folder(String)
    case tag(String)
    case health
    case ranking
    case trash

    var folderPath: [String]? {
        if case let .folder(id) = self { return FolderPath.components(id) }
        return nil
    }

    /// Selections that show an item list in the middle column.
    var isItemScope: Bool {
        switch self {
        case .all, .favourites, .folder, .tag: return true
        case .health, .ranking, .trash: return false
        }
    }
}

/// App state. All core calls that can be slow (Argon2id, Touch ID, export,
/// import, backup) run on `CoreThread`; quick store reads run inline.
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
    /// Every live item (unfiltered); the source of the tree and counts.
    @Published private(set) var allItems: [ItemSummary] = []
    /// Items for the current sidebar selection and search.
    @Published private(set) var items: [ItemSummary] = []
    @Published private(set) var tree: [FolderNode] = []
    @Published private(set) var userTags: [String] = []
    @Published private(set) var trash: [TrashEntry] = []
    @Published private(set) var health: HealthReport?
    @Published private(set) var travelModeOn = false
    @Published private(set) var pairedDevices: [PairedDeviceRecord] = []
    /// Folders created in this session that have no items yet. A folder only
    /// exists in the vault through its items, so these vanish on lock unless
    /// something was put in them.
    @Published private(set) var sessionFolders: [[String]] = []

    @Published var query = "" { didSet { applyFilter() } }
    @Published var sidebar: SidebarSelection = .all { didSet { if sidebar != oldValue { applyFilter() } } }
    @Published var selection: String?
    @Published var busy = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published private(set) var gateReason: PasswordRequiredReason = .noBiometricKey
    @Published private(set) var touchIDEnrolled = false
    @Published var editor: EditorRequest?
    @Published var transfer: TransferRequest?
    @Published var sheet: SheetRequest?
    @Published var templatePicker: TemplatePickerRequest?
    @Published var hotKeyRegistered = false
    /// Set by an automatic lock (sleep, screen lock, idle…): the unlock window
    /// then waits for the user instead of prompting for Touch ID by itself.
    @Published var lockedAutomatically = false
    /// Settings › Locking (UserDefaults; saved and applied by the delegate).
    @Published var lockSettings = LockSettings.load()
    /// Bumped to ask a visible unlock screen to offer Touch ID now.
    @Published var touchIDPromptRequest = 0
    /// Routes "Lock" buttons through the lock coordinator (overlay, sheets,
    /// clipboard). Set by the app delegate.
    var lockRequestHandler: (() -> Void)?
    /// Called after every successful unlock (idle timer restart, menu icon).
    var didUnlockHandler: (() -> Void)?
    /// Security Ranking, computed in memory while unlocked; cleared on lock.
    @Published private(set) var ranking: RankingResult = .empty
    /// Rotation and organize settings (UserDefaults, not secret).
    @Published private(set) var rotation = RotationSettings.load()
    /// "N passwords should be changed" banner after unlock.
    @Published var showRotationBanner = false
    /// Previous folder/title of items organized this session (memory only).
    @Published private(set) var organizeUndo = OrganizeUndo()
    /// Organize preview waiting for the current sheet to close (after import).
    @Published var pendingOrganize: OrganizeRequest?
    let reminders = ReminderScheduler()
    private var strengthCache = VaultAnalysis.StrengthCache()
    /// Bumped on every change so detail views reload.
    @Published private(set) var revision = 0

    struct EditorRequest: Identifiable {
        let id = UUID()
        let itemId: String?
        let draft: ItemDraft
        /// "Change password…": open with the generator showing (nothing is
        /// replaced until the user picks a value and saves).
        var changePassword = false
    }

    /// The Organize preview. `ids` limits it to those items (imports).
    struct OrganizeRequest: Identifiable, Equatable {
        let id = UUID()
        let ids: Set<String>?
        let headline: String
    }

    struct TemplatePickerRequest: Identifiable {
        let id = UUID()
        let folder: [String]
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

    enum FolderNameMode: Equatable {
        case create(parent: [String])
        case rename([String])
    }

    enum SheetRequest: Identifiable {
        case history(String)
        case csvImport
        case devices
        case folderName(FolderNameMode)
        case moveItems([String])
        case moveFolder([String])
        case organize(OrganizeRequest)

        var id: String {
            switch self {
            case let .history(id): return "history:\(id)"
            case .csvImport: return "csv"
            case .devices: return "devices"
            case let .folderName(mode): return "folder:\(mode)"
            case let .moveItems(ids): return "move:\(ids.joined(separator: ","))"
            case let .moveFolder(path): return "movefolder:\(FolderPath.id(path))"
            case let .organize(r): return "organize:\(r.id)"
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
            pairedDevices = PairedDeviceStore(dir: dir).load()
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
            errorMessage = "The core returned an empty Secret Key, so the vault was not created."
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
        reload()
        refreshGate()
    }

    /// Always one `unlock_first_matching` over every candidate path (main
    /// vault and the optional second vault, present or not), so timing and
    /// errors are the same whichever password was typed.
    @discardableResult
    func unlock(password: String, secretKey: String, inline: Bool = false) async -> String? {
        guard let dir, !busy else { return nil }
        busy = true
        defer { busy = false }
        let paths = dir.unlockCandidatePaths.map(\.path)
        let sk = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let epoch = lockEpoch
        do {
            let v = try await CoreThread.run {
                try Vault.unlockFirstMatching(paths: paths, password: password, secretKey: sk, now: Clock.now())
            }
            if let du = deviceUnlock {
                let vaultRef = v
                try? await CoreThread.run { try du.recordPasswordUnlock(vault: vaultRef) }
            }
            // A lock event (sleep, screen lock…) arrived while Argon2id ran:
            // stay locked.
            guard epoch == lockEpoch else { v.lock(); return nil }
            vault = v
            didUnlock()
            return nil
        } catch {
            let message = CoreErrors.describe(error)
            if !inline { errorMessage = message }
            return message
        }
    }

    /// Touch ID through the Secure Enclave key, only when `UnlockGate` allows
    /// it. `inline`: return the error text instead of raising the main
    /// window's alert (the quick-access overlay shows it itself).
    @discardableResult
    func unlockWithTouchID(inline: Bool = false) async -> String? {
        guard dir != nil, let du = deviceUnlock, !busy else { return nil }
        refreshGate()
        guard gateReason == .notRequired else { return nil }
        busy = true
        defer { busy = false }
        let path = du.enrolledVaultPath
        let epoch = lockEpoch
        let outcome = try? await CoreThread.run { du.unlock(vaultPath: path, reason: "unlock your Strongroom vault") }
        var message: String?
        switch outcome {
        case let .unlocked(v)?:
            guard epoch == lockEpoch else { v.lock(); return nil }
            vault = v
            didUnlock()
        case let .failed(failure)?:
            switch failure {
            case .cancelled?: break
            case .keyInvalidated?:
                message = "Touch ID can no longer unlock this vault (the fingerprints on this Mac changed). Enter your master password; Touch ID will be set up again."
            case .lockout?:
                message = "Touch ID is locked out. Enter your master password."
            default:
                message = "Touch ID unlock failed."
            }
            refreshGate()
        case nil:
            message = "Touch ID unlock failed."
        }
        if let message, !inline { errorMessage = message }
        return message
    }

    private func didUnlock() {
        phase = .unlocked
        lockedAutomatically = false
        errorMessage = nil
        sidebar = .all
        // Items trashed more than 180 days ago are deleted for good.
        if let purged = try? vault?.purgeExpiredTrash(now: Clock.now()), purged > 0 {
            infoMessage = "\(purged) item\(purged == 1 ? "" : "s") older than 180 days removed from the trash."
        }
        reload()
        refreshGate()
        rotation = RotationSettings.load()
        showRotationBanner = ranking.dueCount > 0 && !rotation.isSnoozed(now: Clock.now())
        rescheduleReminder()
        didUnlockHandler?()
    }

    /// Bumped by every lock event, so an unlock that finishes after one
    /// (Argon2id or Touch ID still running when the Mac went to sleep) is
    /// thrown away.
    private var lockEpoch = 0

    /// "Lock" button / menu: the full lock path (overlay, sheets, clipboard).
    func requestLock() {
        if let lockRequestHandler { lockRequestHandler() } else { lock() }
    }

    /// Drops the vault and every secret derived from it (items, health and
    /// reuse map, ranking, strength cache, organize undo, open sheets).
    func lock() {
        guard vault != nil else { return }
        // The reminder carries only the count, computed now while unlocked.
        rescheduleReminder()
        vault?.lock()
        vault = nil
        allItems = []
        items = []
        tree = []
        userTags = []
        trash = []
        health = nil
        sessionFolders = []
        ranking = .empty
        strengthCache.clear()
        organizeUndo = OrganizeUndo()
        pendingOrganize = nil
        showRotationBanner = false
        selection = nil
        editor = nil
        transfer = nil
        sheet = nil
        templatePicker = nil
        errorMessage = nil
        infoMessage = nil
        query = ""
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

    // MARK: loading and filtering

    /// Reloads everything from the store after a change.
    func reload() {
        guard let vault else { items = []; allItems = []; return }
        do {
            allItems = try vault.search(query: "", folder: nil, tag: nil)
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            trash = (try? vault.listTrash())?.sorted { $0.deletedAt > $1.deletedAt } ?? []
            health = try? vault.passwordHealth(now: Clock.now())
            travelModeOn = (try? vault.travelMode()) ?? false
        } catch {
            errorMessage = CoreErrors.describe(error)
        }
        let existing = Set(allItems.compactMap { FolderPath.join(FolderPath.components($0.folder)) })
        sessionFolders.removeAll { existing.contains(FolderPath.id($0)) }
        tree = FolderTree.build(folders: allItems.map(\.folder), extraPaths: sessionFolders)
        var tags = Set<String>()
        for i in allItems { for t in ReservedTags.userTags(i.tags) { tags.insert(t) } }
        userTags = tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if case let .tag(t) = sidebar, !tags.contains(t) { sidebar = .all }
        if let p = sidebar.folderPath, FolderTree.find(p, in: tree) == nil { sidebar = .all }
        applyFilter()
        recomputeRanking()
        revision += 1
    }

    /// Kept for callers that only need a refresh.
    func refresh() { reload() }

    private func applyFilter() {
        guard let vault else { items = []; return }
        let base: [ItemSummary]
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            base = allItems
        } else {
            base = ((try? vault.search(query: q, folder: nil, tag: nil)) ?? [])
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        items = base.filter { inScope($0, sidebar) }
        if sidebar.isItemScope, let s = selection, !items.contains(where: { $0.id == s }) { selection = nil }
    }

    func inScope(_ item: ItemSummary, _ scope: SidebarSelection) -> Bool {
        switch scope {
        case .all, .health, .ranking, .trash: return true
        case .favourites: return ReservedTags.isFavourite(item.tags)
        case let .folder(id): return FolderPath.isInSubtree(item.folder, of: FolderPath.components(id))
        case let .tag(t): return item.tags.contains(t)
        }
    }

    var favouriteCount: Int { allItems.filter { ReservedTags.isFavourite($0.tags) }.count }

    func count(tag: String) -> Int { allItems.filter { $0.tags.contains(tag) }.count }

    /// The folder the user is "in": prefilled for new items.
    var currentFolder: [String] { sidebar.folderPath ?? [] }

    func summary(_ id: String) -> ItemSummary? { allItems.first { $0.id == id } }

    func search(_ q: String) -> [ItemSummary] {
        (try? vault?.search(query: q, folder: nil, tag: nil)) ?? []
    }

    func item(_ id: String) -> Item? {
        try? vault?.getItem(id: id)
    }

    func totp(_ id: String) -> TotpCode? {
        try? vault?.itemTotp(id: id, now: Clock.now())
    }

    var weakIDs: Set<String> { Set(health?.weakItemIds ?? []) }
    var reusedIDs: Set<String> { Set(health?.reusedItemIds ?? []) }
    var oldIDs: Set<String> { Set(health?.oldItemIds ?? []) }

    /// Unused / total recovery codes per item. Reads each item and keeps only
    /// the counts.
    func recoveryCounts(_ ids: [String]) -> [String: (unused: Int, total: Int)] {
        guard let vault else { return [:] }
        var out: [String: (Int, Int)] = [:]
        for id in ids {
            guard let fields = try? vault.getItem(id: id).data.fields else { continue }
            let total = RecoveryCodes.totalCount(fields)
            if total > 0 { out[id] = (RecoveryCodes.unusedCount(fields), total) }
        }
        return out
    }

    // MARK: item editing

    /// "New Item": the template picker, with the current folder prefilled.
    func requestNewItem() {
        guard isUnlocked else { return }
        templatePicker = TemplatePickerRequest(folder: currentFolder)
    }

    func requestNewItem(kind: ItemKind, folder: [String]? = nil) {
        guard isUnlocked else { return }
        var d = ItemDraft(kind: kind)
        d.folder = FolderPath.join(folder ?? currentFolder) ?? ""
        editor = EditorRequest(itemId: nil, draft: d)
    }

    func requestNewItem(template: ItemTemplate, folder: [String]? = nil) {
        guard isUnlocked else { return }
        var d = ItemDraft(template: template)
        d.folder = FolderPath.join(folder ?? currentFolder) ?? ""
        editor = EditorRequest(itemId: nil, draft: d)
    }

    /// "Add another account for <service>".
    func requestSibling(of id: String) {
        guard let item = item(id) else { return }
        editor = EditorRequest(itemId: nil, draft: ItemDraft.sibling(of: item.data))
    }

    func requestEdit(_ id: String, changePassword: Bool = false) {
        guard let item = item(id) else { return }
        var d = ItemDraft(item.data)
        d.ensureTemplateFields()
        editor = EditorRequest(itemId: id, draft: d, changePassword: changePassword)
    }

    /// "Change password…" from the ranking: the editor with the generator open.
    func requestChangePassword(_ id: String) { requestEdit(id, changePassword: true) }

    func save(_ draft: ItemDraft, id: String?) -> Bool {
        guard let vault else { return false }
        do {
            let saved: String
            if let id {
                try vault.updateItem(id: id, input: draft.toInput(), now: Clock.now())
                saved = id
            } else {
                saved = try vault.addItem(input: draft.toInput(), now: Clock.now())
            }
            reload()
            if !items.contains(where: { $0.id == saved }) {
                // Show the item even if it is now outside the current scope:
                // go to its folder (or All Items), and clear a search that hides it.
                query = ""
                let path = FolderPath.components(draft.toInput().folder)
                if !items.contains(where: { $0.id == saved }) { sidebar = path.isEmpty ? .all : .folder(FolderPath.id(path)) }
            }
            selection = saved
            return true
        } catch {
            errorMessage = CoreErrors.describe(error)
            return false
        }
    }

    /// Reads, changes and writes back one item.
    private func mutate(_ id: String, reloadAfter: Bool = true, _ change: (inout ItemInput) -> Void) -> Bool {
        guard let vault else { return false }
        do {
            var input = try vault.getItem(id: id).data
            let before = input
            change(&input)
            if input != before { try vault.updateItem(id: id, input: input, now: Clock.now()) }
            if reloadAfter { reload() }
            return true
        } catch {
            errorMessage = CoreErrors.describe(error)
            return false
        }
    }

    func isFavourite(_ id: String) -> Bool { summary(id).map { ReservedTags.isFavourite($0.tags) } ?? false }

    func toggleFavourite(_ id: String) {
        let on = !isFavourite(id)
        _ = mutate(id) { $0.tags = ReservedTags.settingFavourite($0.tags, on) }
    }

    func setRecoveryCodeUsed(_ id: String, fieldIndex: Int, used: Bool) {
        _ = mutate(id) { $0.fields = RecoveryCodes.setUsed($0.fields, index: fieldIndex, used: used) }
    }

    func trash(_ id: String) {
        do {
            try vault?.trashItem(id: id, now: Clock.now())
            if selection == id { selection = nil }
            reload()
        } catch {
            errorMessage = CoreErrors.describe(error)
        }
    }

    func restoreFromTrash(_ id: String) {
        do {
            try vault?.restoreItem(id: id, now: Clock.now())
            reload()
            infoMessage = "Restored from the trash."
        } catch {
            errorMessage = CoreErrors.describe(error)
        }
    }

    func purgeExpiredTrash() {
        do {
            let n = try vault?.purgeExpiredTrash(now: Clock.now()) ?? 0
            reload()
            infoMessage = n == 0 ? "Nothing in the trash is older than 180 days." : "\(n) expired item\(n == 1 ? "" : "s") deleted for good."
        } catch {
            errorMessage = CoreErrors.describe(error)
        }
    }

    func history(_ id: String) -> [ItemRevision] {
        ((try? vault?.itemHistory(id: id)) ?? []).sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Makes an old version current again (the current one goes to history).
    func restoreRevision(_ id: String, _ revision: ItemRevision) {
        if mutate(id, { $0 = revision.data }) {
            infoMessage = "Restored the version from \(Date(timeIntervalSince1970: TimeInterval(revision.modifiedAt)).formatted())."
        }
    }

    func copy(_ value: String?, label: String) {
        guard let value, !value.isEmpty else { return }
        SecureClipboard.shared.copy(value)
        infoMessage = "\(label) copied. The clipboard clears in \(Int(SecureClipboard.defaultClearAfter)) s."
    }

    // MARK: folders

    func selectFolder(_ path: [String]) {
        sidebar = path.isEmpty ? .all : .folder(FolderPath.id(path))
        selection = nil
    }

    /// A new folder is remembered for this session until an item is put in it.
    func createFolder(parent: [String], name: String) {
        guard let name = FolderPath.validName(name) else { return }
        let path = parent + [name]
        if FolderTree.find(path, in: tree) == nil { sessionFolders.append(path) }
        reload()
        selectFolder(path)
    }

    func renameFolder(_ path: [String], to name: String) {
        guard let new = FolderOps.renamed(path, to: name), new != path else { return }
        relocate(from: path, to: new)
    }

    func moveFolder(_ path: [String], toParent parent: [String]) {
        guard let new = FolderOps.moved(path, toParent: parent) else { return }
        relocate(from: path, to: new)
    }

    /// Rename/move: `update_item` on every item in the subtree.
    private func relocate(from: [String], to: [String]) {
        let plan = FolderOps.plan(items: allItems.map { ($0.id, $0.folder) }, from: from, to: to)
        var failed = 0
        for change in plan where !mutate(change.id, reloadAfter: false, { $0.folder = change.folder }) { failed += 1 }
        sessionFolders = FolderOps.relocatePaths(sessionFolders, from: from, to: to)
        reload()
        if case let .folder(id) = sidebar, FolderPath.isPrefix(from, of: FolderPath.components(id)) {
            sidebar = .folder(FolderPath.id(to + FolderPath.components(id).dropFirst(from.count)))
        }
        infoMessage = failed == 0
            ? "Updated \(plan.count) item\(plan.count == 1 ? "" : "s")."
            : "\(failed) of \(plan.count) items could not be updated."
    }

    /// Drag-and-drop and "Move to Folder…". `path` [] = no folder.
    func moveItems(_ ids: [String], to path: [String]) {
        let folder = FolderPath.join(path)
        var moved = 0
        for id in ids where mutate(id, reloadAfter: false, { $0.folder = folder }) { moved += 1 }
        reload()
        if moved > 0 {
            infoMessage = "Moved \(moved) item\(moved == 1 ? "" : "s") to \(path.isEmpty ? "no folder" : path.joined(separator: " › "))."
        }
    }

    // MARK: settings: travel mode, second vault, pairing

    func refreshTravelMode() {
        travelModeOn = (try? vault?.travelMode()) ?? false
    }

    /// Items that travel mode would remove from this Mac.
    var notTravelSafeCount: Int {
        guard let vault else { return 0 }
        return allItems.filter { (try? vault.getItem(id: $0.id).data.travelSafe) != true }.count
    }

    func setTravelMode(_ on: Bool) {
        guard let vault else { return }
        do {
            try vault.setTravelMode(enabled: on, now: Clock.now())
            reload()
            infoMessage = on ? "Travel mode is on. Items not marked travel safe were removed from this Mac." : "Travel mode is off."
        } catch {
            errorMessage = CoreErrors.describe(error)
        }
        refreshTravelMode()
    }

    var secondVaultExists: Bool { dir.map { SecureFile.exists($0.secondVaultPath) } ?? false }

    /// Creates the additional vault and locks it again at once.
    func createSecondVault(password: String, secretKey: String) async -> Bool {
        guard let dir, !secondVaultExists else { return false }
        busy = true
        defer { busy = false }
        let path = dir.secondVaultPath
        let sk = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await CoreThread.run {
                let v = try Vault.create(path: path.path, password: password, secretKey: sk, now: Clock.now())
                v.lock()
            }
            try? SecureFile.chmod(path, 0o600)
            try? SecureFile.chmod(URL(fileURLWithPath: path.path + ".hdr"), 0o600)
            return true
        } catch {
            errorMessage = CoreErrors.describe(error)
            return false
        }
    }

    struct PairingInfo {
        let payload: String
        let fingerprint: String
    }

    /// This Mac's pairing payload. Creates the transfer key on first use
    /// (no prompt).
    func thisMacPairing() -> Result<PairingInfo, Error> {
        guard let dir else { return .failure(StrongroomError.Internal) }
        return Result {
            let key = try TransferKey.loadOrCreate(dir)
            let payload = pairingPayload(devicePublicKey: key.publicKey())
            return PairingInfo(payload: payload, fingerprint: try parsePairingPayload(payload: payload).fingerprint)
        }
    }

    func addPairedDevice(name: String, payload: String) -> Bool {
        guard let dir else { return false }
        do {
            try PairedDeviceStore(dir: dir).add(name: name, payload: payload, now: Clock.now())
            pairedDevices = PairedDeviceStore(dir: dir).load()
            return true
        } catch {
            errorMessage = CoreErrors.describe(error)
            return false
        }
    }

    func removePairedDevice(_ fingerprint: String) {
        guard let dir else { return }
        try? PairedDeviceStore(dir: dir).remove(fingerprint: fingerprint)
        pairedDevices = PairedDeviceStore(dir: dir).load()
    }

    // MARK: VTF export / import

    func beginExport() {
        guard isUnlocked else { return }
        if let dir { pairedDevices = PairedDeviceStore(dir: dir).load() }
        transfer = .export
    }

    func beginImport() {
        guard isUnlocked, let url = chooseFile(title: "Import a VTF file", types: [UTType(filenameExtension: "vtf") ?? .data]) else { return }
        let info = (try? Data(contentsOf: url)).flatMap { try? vtfInspect(file: $0) }
        transfer = .importFile(url, info)
    }

    private func chooseFile(title: String, types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        WindowPrivacy.protect(panel)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Asks for a destination, then exports with the password slot plus one
    /// device slot per chosen recipient.
    func export(password: String, secretKey: String, recipients: [PairedDeviceRecord], includeThisMac: Bool) async -> Bool {
        guard let vault else { return false }
        var keys: [Data] = []
        do {
            keys = try recipients.map { try $0.publicKey() }
            if includeThisMac, let dir { keys.append(try TransferKey.loadOrCreate(dir).publicKey()) }
        } catch {
            errorMessage = CoreErrors.describe(error)
            return false
        }
        let panel = NSSavePanel()
        panel.title = "Export vault"
        panel.nameFieldStringValue = "Strongroom-\(Self.dateStamp()).vtf"
        panel.allowedContentTypes = [UTType(filenameExtension: "vtf") ?? .data]
        WindowPrivacy.protect(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        busy = true
        defer { busy = false }
        let sk = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipientKeys = keys
        do {
            let bytes = try await CoreThread.run {
                try vault.exportVtf(password: password, secretKey: sk, deviceRecipients: recipientKeys, now: Clock.now())
            }
            try SecureFile.write(bytes, to: url)
            let extra = recipientKeys.isEmpty ? "" : " Sealed to \(recipientKeys.count) device\(recipientKeys.count == 1 ? "" : "s") as well."
            infoMessage = "Exported \(bytes.count) bytes to \(url.lastPathComponent).\(extra)"
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
            let before = Set(allItems.map(\.id))
            let s = try await CoreThread.run {
                try vault.importVtf(file: data, password: password, secretKey: sk, now: Clock.now())
            }
            reload()
            offerOrganize(newSince: before)
            infoMessage = Self.describe(s, prefix: "Imported")
            return true
        } catch {
            errorMessage = CoreErrors.describe(error)
            return false
        }
    }

    /// "Import with This Mac's Key…": opens a VTF sealed to this Mac's
    /// transfer key (Secure Enclave; asks for Touch ID or the login password).
    func importWithThisMacsKey() async {
        guard isUnlocked, let vault, let dir,
              let url = chooseFile(title: "Import a file sealed to this Mac", types: [UTType(filenameExtension: "vtf") ?? .data])
        else { return }
        busy = true
        defer { busy = false }
        do {
            let data = try Data(contentsOf: url)
            let before = Set(allItems.map(\.id))
            let s = try await CoreThread.run { () throws -> ImportSummary in
                let key = try TransferKey.loadOrCreate(dir)
                return try vault.importVtfWithDeviceKey(file: data, device: key, now: Clock.now())
            }
            reload()
            offerOrganize(newSince: before)
            presentPendingOrganizeIfIdle()
            infoMessage = Self.describe(s, prefix: "Imported")
        } catch StrongroomError.UnlockFailed {
            errorMessage = "This file is not sealed to this Mac, or the check was cancelled."
        } catch {
            errorMessage = CoreErrors.describe(error)
        }
    }

    /// CSV import from another password manager. The CSV text is passed to
    /// the core and dropped; it is never logged.
    func importCSV(source: CsvSource, url: URL) async -> ImportSummary? {
        guard let vault else { return nil }
        busy = true
        defer { busy = false }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                errorMessage = "The file is not readable text."
                return nil
            }
            let before = Set(allItems.map(\.id))
            let s = try await CoreThread.run { try vault.importCsv(source: source, csv: text, now: Clock.now()) }
            reload()
            offerOrganize(newSince: before)
            return s
        } catch {
            errorMessage = CoreErrors.describe(error)
            return nil
        }
    }

    func chooseCSV() -> URL? {
        chooseFile(title: "Choose the exported CSV file", types: [.commaSeparatedText, .plainText])
    }

    /// "Back Up Vault…": an encrypted copy of the store (opens with the same
    /// master password and Secret Key).
    func backup() async {
        guard let vault else { return }
        let panel = NSSavePanel()
        panel.title = "Back up vault"
        panel.message = "The backup is encrypted. It opens with the same master password and Secret Key. A second file ending in .hdr is written next to it; keep both."
        panel.nameFieldStringValue = "Strongroom-backup-\(Self.dateStamp()).srdb"
        WindowPrivacy.protect(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        defer { busy = false }
        do {
            try await CoreThread.run { try VaultBackup.write(vault, to: url) }
            infoMessage = "Backed up to \(url.lastPathComponent) (+ .hdr)."
        } catch {
            errorMessage = CoreErrors.describe(error)
        }
    }

    static func describe(_ s: ImportSummary, prefix: String) -> String {
        "\(prefix): \(s.added) added, \(s.updated) updated, \(s.unchanged) unchanged, \(s.conflicts) conflicts."
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: organize by service

    /// Every item as the organizer sees it (no secrets).
    func organizeItems() -> [OrganizeItem] {
        guard let vault else { return [] }
        return (try? VaultAnalysis.organizeItems(vault)) ?? []
    }

    func requestOrganize() {
        guard isUnlocked else { return }
        sheet = .organize(OrganizeRequest(ids: nil, headline: "Organize by Service"))
    }

    /// Applies folder/title changes and remembers the previous values so
    /// "Undo Organize" can restore them until the vault locks.
    @discardableResult
    func applyOrganize(_ changes: [OrganizeChange], announce: Bool = true) -> Int {
        guard let vault, !changes.isEmpty else { return 0 }
        let (undo, failed) = Organizer.apply(changes, vault: vault, now: Clock.now())
        organizeUndo.merge(undo)
        reload()
        if announce {
            infoMessage = failed == 0
                ? "Organized \(undo.count) item\(undo.count == 1 ? "" : "s"). Undo Organize is in the Organize menu until you lock."
                : "Organized \(undo.count) items; \(failed) could not be updated."
        }
        return undo.count
    }

    var canUndoOrganize: Bool { !organizeUndo.isEmpty }

    func undoOrganize() {
        guard let vault, !organizeUndo.isEmpty else { return }
        let (restored, failed) = Organizer.undo(organizeUndo, vault: vault, now: Clock.now())
        organizeUndo = OrganizeUndo()
        reload()
        infoMessage = failed == 0
            ? "Restored the previous folder and title of \(restored) item\(restored == 1 ? "" : "s")."
            : "Restored \(restored) items; \(failed) could not be updated."
    }

    /// After an import: offer the Organize preview for the new logins that
    /// arrived without a folder.
    private func offerOrganize(newSince before: Set<String>) {
        guard rotation.suggestFolders else { return }
        let fresh = Set(allItems.filter { !before.contains($0.id) && FolderPath.components($0.folder).isEmpty && $0.kind == .login }.map(\.id))
        guard !fresh.isEmpty else { return }
        guard !Organizer.plan(items: organizeItems(), scope: .ids(fresh)).isEmpty else { return }
        pendingOrganize = OrganizeRequest(ids: fresh, headline: "Organize the \(fresh.count) imported item\(fresh.count == 1 ? "" : "s")?")
    }

    /// Shows a waiting Organize preview once no other sheet is open.
    func presentPendingOrganizeIfIdle() {
        guard let req = pendingOrganize, sheet == nil, transfer == nil, editor == nil, templatePicker == nil, isUnlocked else { return }
        pendingOrganize = nil
        sheet = .organize(req)
    }

    // MARK: security ranking and rotation

    /// Recomputes the ranking from the unlocked vault. Passwords are compared
    /// inside `VaultAnalysis` and dropped; only scores and id groups remain.
    func recomputeRanking() {
        guard let vault else { ranking = .empty; return }
        ranking = (try? VaultAnalysis.ranking(vault, policy: rotation, now: Clock.now(), cache: &strengthCache)) ?? .empty
        if ranking.dueCount == 0 { showRotationBanner = false }
    }

    func updateRotation(_ change: (inout RotationSettings) -> Void) {
        var r = rotation
        change(&r)
        guard r != rotation else { return }
        let turnedOn = r.weeklyReminder && !rotation.weeklyReminder
        r.save()
        rotation = r
        recomputeRanking()
        if !r.weeklyReminder {
            // Off: no pending reminder, even while locked.
            reminders.removeAll()
        } else if turnedOn {
            Task {
                _ = await reminders.requestAuthorization()
                rescheduleReminder()
            }
        } else {
            rescheduleReminder()
        }
    }

    func snoozeRotation() {
        updateRotation { $0.snoozedUntil = Clock.now() + RotationSettings.snoozeSeconds }
        showRotationBanner = false
    }

    func resumeRotation() { updateRotation { $0.snoozedUntil = nil } }

    /// One pending weekly notification carrying only the due count. Called
    /// on unlock, on lock and when the settings change.
    func rescheduleReminder() {
        guard vault != nil else { return }
        let count = ranking.dueCount
        let settings = rotation
        Task { await reminders.schedule(count: count, settings: settings) }
    }
}

extension AppModel: LockableSession {
    var isSessionUnlocked: Bool { vault != nil }

    func lockSession(reason: LockEvent) {
        lockEpoch += 1
        if reason != .manual { lockedAutomatically = true }
        lock()
    }
}
