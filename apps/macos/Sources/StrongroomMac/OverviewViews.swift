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

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !subfolders.isEmpty {
                    Text("Folders").font(.headline).foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(subfolders) { sub in
                            Button { model.selectFolder(sub.path) } label: { FolderCard(node: sub, stats: stats(for: sub.path)) }
                                .buttonStyle(.plain)
                                .dropDestination(for: String.self) { strings, _ in
                                    let ids = strings.compactMap(DragPayload.itemID)
                                    guard !ids.isEmpty else { return false }
                                    model.moveItems(ids, to: sub.path)
                                    return true
                                }
                        }
                    }
                }
                if !directItems.isEmpty {
                    Text(path.isEmpty ? "Not in a folder" : "Items").font(.headline).foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(directItems, id: \.id) { item in
                            Button { model.selection = item.id } label: {
                                ItemCard(item: item, weak: model.weakIDs.contains(item.id),
                                         reused: model.reusedIDs.contains(item.id), codes: codes[item.id])
                            }
                            .buttonStyle(.plain)
                            .draggable(DragPayload.make(item.id))
                            .contextMenu { ItemContextMenu(itemId: item.id) }
                        }
                    }
                }
                if subfolders.isEmpty && directItems.isEmpty {
                    ContentUnavailableView {
                        Label(path.isEmpty ? "Your vault is empty" : "This folder is empty", systemImage: "folder")
                    } description: {
                        Text("Add an item here, or drag items onto a folder in the sidebar.")
                    } actions: {
                        Button("Add an Item") { model.templatePicker = .init(folder: path) }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
        .task(id: "\(FolderPath.id(path))-\(model.revision)") {
            codes = model.recoveryCounts(subtreeItems.map(\.id))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !path.isEmpty { Breadcrumb(path: path, font: .caption) }
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: path.isEmpty ? "tray.full" : "folder").font(.title2).foregroundStyle(.tint)
                Text(path.last ?? "All Items").font(.title.bold())
                Spacer()
                Button { model.templatePicker = .init(folder: path) } label: { Label("Add Item", systemImage: "plus") }
            }
            let s = stats(for: path)
            HStack(spacing: 8) {
                Text("\(subtreeItems.count) item\(subtreeItems.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                HealthBadges(stats: s)
                if path.isEmpty, let score = model.health?.securityScore {
                    Badge(text: "Security score \(score)", symbol: "checkmark.shield", tint: HealthView.color(for: score))
                }
            }
            .font(.callout)
        }
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

struct FolderStats {
    var weak = 0
    var reused = 0
    var codesUnused = 0
    var codesTotal = 0
}

struct HealthBadges: View {
    let stats: FolderStats

    var body: some View {
        HStack(spacing: 6) {
            if stats.reused > 0 { Badge(text: "\(stats.reused) reused", symbol: "arrow.triangle.2.circlepath", tint: .orange) }
            if stats.weak > 0 { Badge(text: "\(stats.weak) weak", symbol: "exclamationmark.triangle", tint: .orange) }
            if stats.codesTotal > 0 {
                Badge(text: "\(stats.codesUnused)/\(stats.codesTotal) codes", symbol: "lifepreserver",
                      tint: stats.codesUnused <= 2 ? .orange : .secondary)
            }
        }
    }
}

struct Badge: View {
    let text: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

struct FolderCard: View {
    let node: FolderNode
    let stats: FolderStats
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder.fill").font(.title2).foregroundStyle(.tint)
                Spacer()
                Text("\(node.totalCount)").font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(node.name).font(.headline).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HealthBadges(stats: stats)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hover ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.15)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hover = $0 }
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
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: ItemPresentation.symbol(kind: item.kind, tags: item.tags))
                    .font(.title2).foregroundStyle(.tint).frame(width: 30, alignment: .leading)
                Spacer()
                if ReservedTags.isFavourite(item.tags) { Image(systemName: "star.fill").foregroundStyle(.yellow) }
            }
            Text(item.title).font(.headline).lineLimit(1)
            Text(item.subtitle ?? ItemPresentation.typeName(kind: item.kind, tags: item.tags))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 6) {
                if reused { Badge(text: "Reused", symbol: "arrow.triangle.2.circlepath", tint: .orange) }
                if weak { Badge(text: "Weak", symbol: "exclamationmark.triangle", tint: .orange) }
                if let codes {
                    Badge(text: "\(codes.unused)/\(codes.total) codes", symbol: "lifepreserver",
                          tint: codes.unused <= 2 ? .orange : .secondary)
                }
                if item.hasTotp { Badge(text: "2FA", symbol: "clock.badge.checkmark") }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hover ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.15)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hover = $0 }
    }
}
