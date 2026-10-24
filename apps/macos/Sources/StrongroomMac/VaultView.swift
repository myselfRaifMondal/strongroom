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
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } content: {
            ContentColumn()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            DetailColumn()
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItemGroup {
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
                .help("New item (choose a template)")
                Button { showGenerator = true } label: { Label("Generator", systemImage: "wand.and.stars") }
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
                    Label("Transfer", systemImage: "arrow.up.arrow.down.square")
                }
                Button { model.lock() } label: { Label("Lock", systemImage: "lock.fill") }
            }
        }
        .sheet(item: $model.editor) { req in
            ItemEditorView(itemId: req.itemId, draft: req.draft)
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
            }
        }
        .sheet(isPresented: $showGenerator) {
            VStack(alignment: .leading) {
                GeneratorView(onUse: nil)
                HStack { Spacer(); Button("Done") { showGenerator = false }.keyboardShortcut(.defaultAction) }
            }
            .padding(20)
            .frame(width: 460)
        }
        .safeAreaInset(edge: .bottom) {
            if let info = model.infoMessage {
                Text(info)
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(8)
                    .task(id: info) {
                        try? await Task.sleep(for: .seconds(4))
                        if model.infoMessage == info { model.infoMessage = nil }
                    }
            }
        }
    }
}

// MARK: middle column

struct ContentColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.sidebar {
        case .health: HealthView()
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
                        Label(emptyTitle, systemImage: "tray")
                    } actions: {
                        Button("Add an Item") { model.requestNewItem() }
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

    private var scopeTitle: String {
        switch model.sidebar {
        case .all: return "All Items"
        case .favourites: return "Favourites"
        case let .folder(id): return FolderPath.components(id).last ?? "Folder"
        case let .tag(t): return "#\(t)"
        case .health: return "Password Health"
        case .trash: return "Trash"
        }
    }
}

/// Breadcrumb and count above the item list.
struct ScopeHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
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
            Spacer(minLength: 4)
            Text("\(model.items.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
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
        }
        .font(font)
    }

    private func segments(_ indices: [Int], elided: Bool = false) -> some View {
        HStack(spacing: 3) {
            Button("All Items") { model.selectFolder([]) }
                .buttonStyle(.link)
                .foregroundStyle(path.isEmpty ? Color.primary : Color.secondary)
            if elided {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Text("…").foregroundStyle(.secondary)
            }
            ForEach(indices, id: \.self) { i in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
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
        HStack(spacing: 10) {
            Image(systemName: ItemPresentation.symbol(kind: item.kind, tags: item.tags))
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
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
            Spacer()
            if weak || reused {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help(reused ? "Password reused elsewhere" : "Weak password")
            }
            if item.hasTotp {
                Image(systemName: "clock.badge.checkmark").foregroundStyle(.secondary).help("Has a one-time code")
            }
        }
        .padding(.vertical, 2)
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
                ContentUnavailableView("Select an item to review it", systemImage: "checkmark.shield")
            case .trash:
                ContentUnavailableView("Trashed items stay for 180 days", systemImage: "trash",
                                       description: Text("Restore them from the list, or let them expire."))
            default:
                ContentUnavailableView("Select an item", systemImage: "key.horizontal")
            }
        }
    }
}
