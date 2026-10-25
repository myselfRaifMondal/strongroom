import StrongroomKit
import SwiftUI

/// Overview of a folder (or of the whole vault for []): a card per sub-folder
/// and per item directly in it, with icons by template/kind, item counts,
/// password-health badges and recovery codes left.
struct FolderOverviewView: View {
    @EnvironmentObject var model: AppModel
    let path: [String]
    @State private var codes: [String: (unused: Int, total: Int)] = [:]

    private var node: FolderNode? { path.isEmpty ? nil : FolderTree.find(path, in: model.tree) }
    private var subfolders: [FolderNode] { path.isEmpty ? model.tree : (node?.children ?? []) }
    private var subtreeItems: [ItemSummary] { model.allItems.filter { FolderPath.isInSubtree($0.folder, of: path) } }
    private var directItems: [ItemSummary] { model.allItems.filter { FolderPath.isDirectlyIn($0.folder, path) } }

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: DS.Space.m, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                header
                if !subfolders.isEmpty {
                    section("Folders") {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.m) {
                            ForEach(subfolders) { sub in
                                Button { model.selectFolder(sub.path) } label: { FolderCard(node: sub, stats: stats(for: sub.path)) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Folder \(sub.name), \(sub.totalCount) items")
                                    .dropDestination(for: String.self) { strings, _ in
                                        let ids = strings.compactMap(DragPayload.itemID)
                                        guard !ids.isEmpty else { return false }
                                        model.moveItems(ids, to: sub.path)
                                        return true
                                    }
                            }
                        }
                    }
                }
                if !directItems.isEmpty {
                    section(path.isEmpty ? "Not in a folder" : "Items") {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.m) {
                            ForEach(directItems, id: \.id) { item in
                                Button { model.selection = item.id } label: {
                                    ItemCard(item: item, weak: model.weakIDs.contains(item.id),
                                             reused: model.reusedIDs.contains(item.id), codes: codes[item.id])
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(item.title)
                                .draggable(DragPayload.make(item.id))
                                .contextMenu { ItemContextMenu(itemId: item.id) }
                            }
                        }
                    }
                }
                if subfolders.isEmpty && directItems.isEmpty {
                    ContentUnavailableView {
                        Label(path.isEmpty ? "Your vault is empty" : "This folder is empty", systemImage: "folder")
                    } description: {
                        Text(path.isEmpty ? "Add your first login, card or note, or import from another password manager (File › Import)."
                                          : "Add an item here, or drag items onto a folder in the sidebar.")
                    } actions: {
                        Button("Add an Item") { model.templatePicker = .init(folder: path) }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .readableWidth(DS.Width.grid)
            .panePadding()
        }
        .task(id: "\(FolderPath.id(path))-\(model.revision)") {
            codes = model.recoveryCounts(subtreeItems.map(\.id))
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(title).font(.sectionTitle).foregroundStyle(.secondary)
            content()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if !path.isEmpty { Breadcrumb(path: path, font: .caption) }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: DS.Space.m) {
                    title
                    Spacer(minLength: DS.Space.m)
                    addButton
                }
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    title
                    addButton
                }
            }
            let s = stats(for: path)
            FlowRow {
                Text("\(subtreeItems.count) item\(subtreeItems.count == 1 ? "" : "s")").foregroundStyle(.secondary).font(.callout)
                HealthBadges(stats: s)
                if path.isEmpty, let score = model.health?.securityScore {
                    Badge(text: "Security score \(score)", symbol: "checkmark.shield", tint: HealthView.color(for: score))
                }
            }
        }
    }

    private var title: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: path.isEmpty ? "tray.full" : "folder").font(.title2).foregroundStyle(.tint).accessibilityHidden(true)
            Text(path.last ?? "All Items").font(.paneTitle).lineLimit(1)
        }
    }

    private var addButton: some View {
        Button { model.templatePicker = .init(folder: path) } label: {
            Label(path.isEmpty ? "Add Item" : "Add Item Here", systemImage: "plus")
        }
        .help(path.isEmpty ? "New item" : "New item in \(path.joined(separator: " › "))")
    }

    private func stats(for p: [String]) -> FolderStats {
        let ids = model.allItems.filter { FolderPath.isInSubtree($0.folder, of: p) }.map(\.id)
        var s = FolderStats()
        let weak = model.weakIDs, reused = model.reusedIDs
        for id in ids {
            if weak.contains(id) { s.weak += 1 }
            if reused.contains(id) { s.reused += 1 }
            if let c = codes[id] { s.codesUnused += c.unused; s.codesTotal += c.total }
        }
        return s
    }
}

/// Lays children out left to right and wraps to the next line (badges).
struct FlowRow: Layout {
    var spacing: CGFloat = DS.Space.s
    var lineSpacing: CGFloat = DS.Space.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += line + lineSpacing
                x = bounds.minX
                line = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

struct FolderStats {
    var weak = 0
    var reused = 0
    var codesUnused = 0
    var codesTotal = 0
}

struct HealthBadges: View {
    let stats: FolderStats

    var body: some View {
        if stats.reused > 0 { Badge(text: "\(stats.reused) reused", symbol: "arrow.triangle.2.circlepath", tint: .orange) }
        if stats.weak > 0 { Badge(text: "\(stats.weak) weak", symbol: "exclamationmark.triangle", tint: .orange) }
        if stats.codesTotal > 0 {
            Badge(text: "\(stats.codesUnused)/\(stats.codesTotal) codes", symbol: "lifepreserver",
                  tint: stats.codesUnused <= 2 ? .orange : .secondary)
        }
    }
}

struct FolderCard: View {
    let node: FolderNode
    let stats: FolderStats

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Image(systemName: "folder.fill").font(.title2).foregroundStyle(.tint).accessibilityHidden(true)
                Spacer()
                Text("\(node.totalCount)").font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(node.name).font(.headline).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            FlowRow(spacing: DS.Space.xs) { HealthBadges(stats: stats) }
        }
        .card(minHeight: 112)
    }

    private var subtitle: String {
        let subs = node.children?.count ?? 0
        let items = "\(node.totalCount) item\(node.totalCount == 1 ? "" : "s")"
        return subs == 0 ? items : "\(subs) folder\(subs == 1 ? "" : "s") · \(items)"
    }
}

struct ItemCard: View {
    let item: ItemSummary
    let weak: Bool
    let reused: Bool
    let codes: (unused: Int, total: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Image(systemName: ItemPresentation.symbol(kind: item.kind, tags: item.tags))
                    .font(.title2).foregroundStyle(.tint).frame(width: 30, alignment: .leading)
                    .accessibilityHidden(true)
                Spacer()
                if ReservedTags.isFavourite(item.tags) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Favourite")
                }
            }
            Text(item.title).font(.headline).lineLimit(1)
            Text(item.subtitle ?? ItemPresentation.typeName(kind: item.kind, tags: item.tags))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            FlowRow(spacing: DS.Space.xs) {
                if reused { Badge(text: "Reused", symbol: "arrow.triangle.2.circlepath", tint: .orange) }
                if weak { Badge(text: "Weak", symbol: "exclamationmark.triangle", tint: .orange) }
                if let codes {
                    Badge(text: "\(codes.unused)/\(codes.total) codes", symbol: "lifepreserver",
                          tint: codes.unused <= 2 ? .orange : .secondary)
                }
                if item.hasTotp { Badge(text: "2FA", symbol: "clock.badge.checkmark") }
            }
        }
        .card(minHeight: 112)
    }
}
