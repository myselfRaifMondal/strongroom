import StrongroomKit
import SwiftUI

/// Item ids on the drag pasteboard carry a prefix so drops from other apps
/// (plain text) are ignored. Ids are not secret.
enum DragPayload {
    static let prefix = "strongroom-item:"
    static func make(_ id: String) -> String { prefix + id }
    static func itemID(_ s: String) -> String? {
        guard s.hasPrefix(prefix) else { return nil }
        let id = String(s.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
}

struct VaultView: View {
    @EnvironmentObject var model: AppModel
    @State private var showGenerator = false

    var body: some View {
        VStack(spacing: 0) {
            if model.showRotationBanner && model.ranking.dueCount > 0 {
                RotationBanner()
                Divider()
            }
            splitView
        }
        .onChange(of: model.sheet == nil && model.transfer == nil && model.editor == nil) { _, idle in
            // An import's "Organize the N imported items?" waits for its sheet to close.
            if idle { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.presentPendingOrganizeIfIdle() } }
        }
        .onChange(of: model.pendingOrganize) { _, _ in model.presentPendingOrganizeIfIdle() }
    }

    private var splitView: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: DS.Column.sidebarMin, ideal: DS.Column.sidebarIdeal, max: DS.Column.sidebarMax)
        } content: {
            ContentColumn()
                .navigationSplitViewColumnWidth(min: DS.Column.listMin, ideal: DS.Column.listIdeal, max: DS.Column.listMax)
        } detail: {
            DetailColumn()
                .navigationSplitViewColumnWidth(min: DS.Column.detailMin, ideal: 640)
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search all items")
        .toolbar {
            // Vault-wide actions, in the same place on every screen. Actions on
            // one item are in the item's header.
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button { model.requestNewItem() } label: { Label("Choose a Template…", systemImage: "square.grid.2x2") }
                    Divider()
                    ForEach(ItemKind.allCases) { kind in
                        Button { model.requestNewItem(kind: kind) } label: {
                            Label("Blank \(kind.displayName)", systemImage: kind.symbolName)
                        }
                    }
                } label: {
                    Label("New Item", systemImage: "plus")
                } primaryAction: {
                    model.requestNewItem()
                }
                .help("New item (⌘N). Click and hold for a blank item of a given kind.")
                Button { showGenerator = true } label: { Label("Password Generator", systemImage: "wand.and.stars") }
                    .help("Generate a password or passphrase")
                Menu {
                    Button("Organize by Service…") { model.requestOrganize() }
                    Button("Undo Organize") { model.undoOrganize() }.disabled(!model.canUndoOrganize)
                } label: {
                    Label("Organize", systemImage: "folder.badge.gearshape")
                } primaryAction: {
                    model.requestOrganize()
                }
                .help("Organize by service: suggest folders from each login's website")
                Menu {
                    Button("Import VTF…") { model.beginImport() }
                    Button("Import with This Mac's Key…") { Task { await model.importWithThisMacsKey() } }
                    Button("Import from Another Password Manager (CSV)…") { model.sheet = .csvImport }
                    Divider()
                    Button("Export VTF…") { model.beginExport() }
                    Button("Back Up Vault…") { Task { await model.backup() } }
                    Divider()
                    Button("Devices and Pairing…") { model.sheet = .devices }
                } label: {
                    Label("Import and Export", systemImage: "arrow.up.arrow.down.square")
                }
                .help("Import, export, back up, pair devices")
                Button { model.requestLock() } label: { Label("Lock", systemImage: "lock.fill") }
                    .help("Lock Strongroom now (⇧⌘L)")
            }
        }
        .sheet(item: $model.editor) { req in
            ItemEditorView(itemId: req.itemId, draft: req.draft, changePassword: req.changePassword)
        }
        .sheet(item: $model.transfer) { req in
            TransferSheet(request: req)
        }
        .sheet(item: $model.templatePicker) { req in
            TemplatePickerView(folder: req.folder)
        }
        .sheet(item: $model.sheet) { req in
            switch req {
            case let .history(id): HistorySheet(itemId: id)
            case .csvImport: CSVImportSheet()
            case .devices: DevicesSheet()
            case let .folderName(mode): FolderNameSheet(mode: mode)
            case let .moveItems(ids): MoveItemsSheet(itemIds: ids)
            case let .moveFolder(path): MoveFolderSheet(path: path)
            case let .organize(r): OrganizeSheet(request: r)
            }
        }
        .sheet(isPresented: $showGenerator) {
            GeneratorSheet()
        }
        .safeAreaInset(edge: .bottom) {
            if let info = model.infoMessage {
                Label(info, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .symbolRenderingMode(.multicolor)
                    .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    .padding(DS.Space.s)
                    .task(id: info) {
                        try? await Task.sleep(for: .seconds(4))
                        if model.infoMessage == info { model.infoMessage = nil }
                    }
            }
        }
    }
}

/// The toolbar's password generator.
struct GeneratorSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: "Password Generator", subtitle: "Copied values clear from the clipboard after \(Int(SecureClipboard.defaultClearAfter)) seconds.",
                      symbol: "wand.and.stars", size: DS.Sheet.small) {
            GeneratorView(onUse: nil)
        } footer: {
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: middle column

struct ContentColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.sidebar {
        case .health: HealthView()
        case .ranking: RankingView()
        case .trash: TrashView()
        default: ItemListView()
        }
    }
}

struct ItemListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(model.items, id: \.id, selection: $model.selection) { item in
            ItemRow(item: item, weak: model.weakIDs.contains(item.id), reused: model.reusedIDs.contains(item.id),
                    showFolder: showFolder(item))
                .tag(item.id)
                .draggable(DragPayload.make(item.id))
                .contextMenu { ItemContextMenu(itemId: item.id) }
        }
        .overlay {
            if model.items.isEmpty {
                if model.query.isEmpty {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: emptySymbol)
                    } description: {
                        Text(emptyHint)
                    } actions: {
                        if model.sidebar != .favourites {
                            Button("Add an Item") { model.requestNewItem() }
                        }
                    }
                } else {
                    ContentUnavailableView.search(text: model.query)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                ScopeHeader()
                Divider()
            }
            .background(.bar)
        }
        .navigationTitle(scopeTitle)
    }

    /// Items in sub-folders show where they live.
    private func showFolder(_ item: ItemSummary) -> Bool {
        guard let path = model.sidebar.folderPath else { return model.sidebar != .all || !model.query.isEmpty }
        return !FolderPath.isDirectlyIn(item.folder, path)
    }

    private var emptyTitle: String {
        switch model.sidebar {
        case .favourites: return "No favourites yet"
        case .folder: return "This folder is empty"
        case .tag: return "No items with this tag"
        default: return "No items yet"
        }
    }

    private var emptySymbol: String {
        switch model.sidebar {
        case .favourites: return "star"
        case .folder: return "folder"
        case .tag: return "tag"
        default: return "tray"
        }
    }

    private var emptyHint: String {
        switch model.sidebar {
        case .favourites: return "Star an item to keep it here."
        case .folder: return "Add an item here, or drag items onto this folder in the sidebar."
        case .tag: return "Tags are set in an item's editor."
        default: return "Add a login, card or note, or import from another password manager."
        }
    }

    private var scopeTitle: String {
        switch model.sidebar {
        case .all: return "All Items"
        case .favourites: return "Favourites"
        case let .folder(id): return FolderPath.components(id).last ?? "Folder"
        case let .tag(t): return "#\(t)"
        case .health: return "Password Health"
        case .ranking: return "Security Ranking"
        case .trash: return "Trash"
        }
    }
}

/// Breadcrumb and count above the item list.
struct ScopeHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: DS.Space.s) {
            switch model.sidebar {
            case .folder:
                Breadcrumb(path: model.currentFolder)
            case .favourites:
                Label("Favourites", systemImage: "star.fill").font(.callout.weight(.medium))
            case let .tag(t):
                Label("#\(t)", systemImage: "tag").font(.callout.weight(.medium))
            default:
                Breadcrumb(path: [])
            }
            Spacer(minLength: DS.Space.xs)
            Text(model.query.isEmpty ? "\(model.items.count)" : "\(model.items.count) found")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .accessibilityLabel("\(model.items.count) items")
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
    }
}

/// "All Items › Social › Instagram"; every segment is a link.
struct Breadcrumb: View {
    @EnvironmentObject var model: AppModel
    let path: [String]
    var font: Font = .callout

    var body: some View {
        ViewThatFits(in: .horizontal) {
            segments(path.indices.map { $0 })
            // Not enough room: root, …, last two.
            segments(path.count > 2 ? [path.count - 2, path.count - 1] : path.indices.map { $0 }, elided: path.count > 2)
            // Still not enough: the last folder only.
            segments(path.isEmpty ? [] : [path.count - 1], elided: path.count > 1, showRoot: path.isEmpty)
        }
        .font(font)
    }

    private func segments(_ indices: [Int], elided: Bool = false, showRoot: Bool = true) -> some View {
        HStack(spacing: 3) {
            if showRoot {
                Button("All Items") { model.selectFolder([]) }
                    .buttonStyle(.link)
                    .foregroundStyle(path.isEmpty ? Color.primary : Color.secondary)
            }
            if elided {
                if showRoot { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                Text("…").foregroundStyle(.secondary)
            }
            ForEach(indices, id: \.self) { i in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                Button(path[i]) { model.selectFolder(Array(path.prefix(i + 1))) }
                    .buttonStyle(.link)
                    .foregroundStyle(i == path.count - 1 ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct ItemRow: View {
    let item: ItemSummary
    var weak = false
    var reused = false
    var showFolder = false

    var body: some View {
        HStack(spacing: DS.Space.s + 2) {
            Image(systemName: ItemPresentation.symbol(kind: item.kind, tags: item.tags))
                .frame(width: 22)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.xs) {
                    Text(item.title).lineLimit(1)
                    if ReservedTags.isFavourite(item.tags) {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                            .accessibilityLabel("Favourite")
                    }
                }
                let sub = [item.subtitle, showFolder ? FolderPath.components(item.folder).joined(separator: " › ") : nil]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: DS.Space.xs)
            if weak || reused {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help(reused ? "Password reused elsewhere" : "Weak password")
                    .accessibilityLabel(reused ? "Password reused elsewhere" : "Weak password")
            }
            if item.hasTotp {
                Image(systemName: "clock.badge.checkmark").foregroundStyle(.secondary)
                    .help("Has a one-time code")
                    .accessibilityLabel("Has a one-time code")
            }
        }
        .padding(.vertical, DS.Space.xxs)
    }
}

struct ItemContextMenu: View {
    @EnvironmentObject var model: AppModel
    let itemId: String

    var body: some View {
        if let s = model.summary(itemId) {
            Button(model.isFavourite(itemId) ? "Remove from Favourites" : "Add to Favourites") { model.toggleFavourite(itemId) }
            Button("Edit…") { model.requestEdit(itemId) }
            if ItemPresentation.isAccount(kind: s.kind, tags: s.tags) {
                Button("Add Another Account for \(ItemPresentation.serviceName(folder: s.folder, urls: s.urls, title: s.title))…") {
                    model.requestSibling(of: itemId)
                }
            }
            Button("Move to Folder…") { model.sheet = .moveItems([itemId]) }
            Button("History…") { model.sheet = .history(itemId) }
            Divider()
            Button("Move to Trash", role: .destructive) { model.trash(itemId) }
        }
    }
}

// MARK: detail column

struct DetailColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let id = model.selection, model.summary(id) != nil {
            ItemDetailView(itemId: id)
                .id("\(id)-\(model.revision)")
        } else {
            switch model.sidebar {
            case .all:
                FolderOverviewView(path: [])
            case let .folder(id):
                FolderOverviewView(path: FolderPath.components(id))
            case .health:
                HealthOverview()
            case .ranking:
                RankingOverview()
            case .trash:
                ContentUnavailableView {
                    Label("Trashed items stay for 180 days", systemImage: "trash")
                } description: {
                    Text("Restore them from the list, or let them expire.")
                }
            default:
                ContentUnavailableView {
                    Label("Select an item", systemImage: "key.horizontal")
                } description: {
                    Text("Choose an item in the list to see its details, copy a password or edit it.")
                } actions: {
                    Button("New Item") { model.requestNewItem() }
                }
            }
        }
    }
}
