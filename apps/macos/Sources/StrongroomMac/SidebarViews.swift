import StrongroomKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var expanded: Set<String> = []

    private var selection: Binding<SidebarSelection?> {
        Binding(get: { model.sidebar }, set: { new in
            guard let new, new != model.sidebar else { return }
            model.sidebar = new
            model.selection = nil
        })
    }

    var body: some View {
        List(selection: selection) {
            Section {
                SidebarRow(title: "All Items", symbol: "tray.full", count: model.allItems.count)
                    .tag(SidebarSelection.all)
                    .dropDestination(for: String.self) { strings, _ in
                        drop(strings, to: [])
                    }
                    .help("Drop items here to take them out of their folder")
                SidebarRow(title: "Favourites", symbol: "star", count: model.favouriteCount)
                    .tag(SidebarSelection.favourites)
            }
            Section("Folders") {
                if model.tree.isEmpty {
                    Text("Add a folder, or give an item a folder like “Social/Instagram”.")
                        .font(.caption).foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(model.tree) { node in
                    FolderTreeRow(node: node, expanded: $expanded)
                }
            }
            if !model.userTags.isEmpty {
                Section("Tags") {
                    ForEach(model.userTags, id: \.self) { tag in
                        SidebarRow(title: tag, symbol: "tag", count: model.count(tag: tag))
                            .tag(SidebarSelection.tag(tag))
                    }
                }
            }
            Section("Tools") {
                HStack {
                    Label("Password Health", systemImage: "checkmark.shield")
                    Spacer()
                    if let score = model.health?.securityScore {
                        Text("\(score)").font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(HealthView.color(for: score))
                    }
                }
                .tag(SidebarSelection.health)
                HStack {
                    Label("Security Ranking", systemImage: "list.number")
                    Spacer()
                    if model.ranking.dueCount > 0 {
                        Text("\(model.ranking.dueCount)").font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.orange)
                            .help("\(model.ranking.dueCount) due for a change")
                    }
                }
                .tag(SidebarSelection.ranking)
                SidebarRow(title: "Trash", symbol: "trash", count: model.trash.count)
                    .tag(SidebarSelection.trash)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    model.sheet = .folderName(.create(parent: model.currentFolder))
                } label: {
                    Label(model.currentFolder.isEmpty ? "New Folder" : "New Subfolder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help(model.currentFolder.isEmpty ? "New top-level folder" : "New folder inside \(model.currentFolder.joined(separator: " › "))")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear { expanded.formUnion(model.tree.map(\.id)) }
        .onChange(of: model.sidebar, initial: true) { _, new in
            // Reveal the selected folder: expand its ancestors.
            guard let path = new.folderPath else { return }
            for i in 1 ..< max(path.count, 1) { expanded.insert(FolderPath.id(Array(path.prefix(i)))) }
        }
    }

    private func drop(_ strings: [String], to path: [String]) -> Bool {
        let ids = strings.compactMap(DragPayload.itemID)
        guard !ids.isEmpty else { return false }
        model.moveItems(ids, to: path)
        return true
    }
}

struct SidebarRow: View {
    let title: String
    let symbol: String
    let count: Int

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// One folder and (when expanded) its sub-folders. Items dropped on the row
/// move into that folder.
struct FolderTreeRow: View {
    @EnvironmentObject var model: AppModel
    let node: FolderNode
    @Binding var expanded: Set<String>
    @State private var targeted = false

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(node.id) },
                set: { if $0 { expanded.insert(node.id) } else { expanded.remove(node.id) } })
            ) {
                ForEach(children) { FolderTreeRow(node: $0, expanded: $expanded) }
            } label: {
                label
            }
            .tag(SidebarSelection.folder(node.id))
        } else {
            label.tag(SidebarSelection.folder(node.id))
        }
    }

    private var label: some View {
        HStack {
            Label(node.name, systemImage: targeted ? "folder.fill.badge.plus" : (node.totalCount == 0 ? "folder.badge.questionmark" : "folder"))
            Spacer()
            Text("\(node.totalCount)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { strings, _ in
            let ids = strings.compactMap(DragPayload.itemID)
            guard !ids.isEmpty else { return false }
            model.moveItems(ids, to: node.path)
            return true
        } isTargeted: { targeted = $0 }
        .help(node.totalCount == 0 ? "Empty folder: it is kept once an item is put in it" : "\(node.totalCount) item\(node.totalCount == 1 ? "" : "s")")
        .contextMenu {
            Button("New Item Here…") { model.templatePicker = .init(folder: node.path) }
            Button("New Subfolder…") { model.sheet = .folderName(.create(parent: node.path)) }
            Divider()
            Button("Rename…") { model.sheet = .folderName(.rename(node.path)) }
            Button("Move to…") { model.sheet = .moveFolder(node.path) }
        }
    }
}

// MARK: folder sheets

struct FolderNameSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let mode: AppModel.FolderNameMode
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.bold())
            Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Folder name", text: $name).textFieldStyle(.roundedBorder)
            if !name.isEmpty && FolderPath.validName(name) == nil {
                Text("A folder name cannot contain “/”.").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isRename ? "Rename" : "Create") {
                    switch mode {
                    case let .create(parent): model.createFolder(parent: parent, name: name)
                    case let .rename(path): model.renameFolder(path, to: name)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(FolderPath.validName(name) == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { if case let .rename(path) = mode { name = path.last ?? "" } }
    }

    private var isRename: Bool { if case .rename = mode { return true } else { return false } }

    private var title: String {
        switch mode {
        case let .create(parent): return parent.isEmpty ? "New Folder" : "New Folder in \(parent.last!)"
        case let .rename(path): return "Rename “\(path.last ?? "")”"
        }
    }

    private var explanation: String {
        switch mode {
        case .create:
            return "Folders are stored as part of each item. An empty folder is shown until you lock the vault; put an item in it to keep it."
        case let .rename(path):
            let n = model.allItems.filter { FolderPath.isInSubtree($0.folder, of: path) }.count
            return "Every item in this folder and its sub-folders (\(n)) is updated. Each keeps its old folder in its history."
        }
    }
}

/// Picker of every folder ("No folder" first), plus a typed path.
struct FolderPicker: View {
    @EnvironmentObject var model: AppModel
    @Binding var path: [String]
    var excluding: [String]? = nil

    var body: some View {
        Picker("Folder", selection: Binding(get: { FolderPath.id(path) }, set: { path = FolderPath.components($0) })) {
            Text("No folder").tag("")
            ForEach(FolderTree.allPaths(model.tree).filter(allowed), id: \.self) { p in
                Text(String(repeating: "    ", count: p.count - 1) + p.last!).tag(FolderPath.id(p))
            }
            if !path.isEmpty, FolderTree.find(path, in: model.tree) == nil {
                Text(path.joined(separator: " › ") + " (new)").tag(FolderPath.id(path))
            }
        }
    }

    private func allowed(_ p: [String]) -> Bool {
        guard let excluding else { return true }
        return !FolderPath.isPrefix(excluding, of: p)
    }
}

struct MoveItemsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let itemIds: [String]
    @State private var path: [String] = []
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(itemIds.count == 1 ? "Move “\(model.summary(itemIds[0])?.title ?? "item")”" : "Move \(itemIds.count) items")
                .font(.title3.bold())
            Form {
                FolderPicker(path: $path)
                TextField("Or type a path", text: $typed, prompt: Text("Social/Instagram"))
                    .onChange(of: typed) { _, t in path = FolderPath.components(t) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move") { model.moveItems(itemIds, to: path); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if itemIds.count == 1, let f = model.summary(itemIds[0])?.folder { path = FolderPath.components(f) }
        }
    }
}

struct MoveFolderSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let path: [String]
    @State private var parent: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move “\(path.last ?? "")” and everything in it").font(.title3.bold())
            Form {
                Picker("Into", selection: Binding(get: { FolderPath.id(parent) }, set: { parent = FolderPath.components($0) })) {
                    Text("Top level").tag("")
                    ForEach(FolderTree.allPaths(model.tree).filter { !FolderPath.isPrefix(path, of: $0) }, id: \.self) { p in
                        Text(String(repeating: "    ", count: p.count - 1) + p.last!).tag(FolderPath.id(p))
                    }
                }
            }
            .formStyle(.grouped)
            if let target = FolderOps.moved(path, toParent: parent) {
                Text("New location: \(target.joined(separator: " › "))").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("It is already there.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move") { model.moveFolder(path, toParent: parent); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!FolderOps.canMove(path, toParent: parent))
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { parent = Array(path.dropLast()) }
    }
}
