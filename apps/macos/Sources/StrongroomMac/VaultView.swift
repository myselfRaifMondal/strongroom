import StrongroomKit
import SwiftUI

struct VaultView: View {
    @EnvironmentObject var model: AppModel
    @State private var showGenerator = false

    var body: some View {
        NavigationSplitView {
            List(model.items, id: \.id, selection: $model.selection) { item in
                ItemRow(item: item).tag(item.id)
            }
            .overlay {
                if model.items.isEmpty {
                    ContentUnavailableView(model.query.isEmpty ? "No items yet" : "No matches",
                                           systemImage: model.query.isEmpty ? "tray" : "magnifyingglass")
                }
            }
            .searchable(text: $model.query, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let id = model.selection {
                ItemDetailView(itemId: id)
                    .id("\(id)-\(model.revision)")
            } else {
                ContentUnavailableView("Select an item", systemImage: "key.horizontal")
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    ForEach(ItemKind.allCases) { kind in
                        Button { model.requestNewItem(kind: kind) } label: {
                            Label(kind.displayName, systemImage: kind.symbolName)
                        }
                    }
                } label: {
                    Label("New Item", systemImage: "plus")
                } primaryAction: {
                    model.requestNewItem()
                }
                Button { showGenerator = true } label: { Label("Generator", systemImage: "wand.and.stars") }
                Menu {
                    Button("Import VTF…") { model.beginImport() }
                    Button("Export VTF…") { model.beginExport() }
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

struct ItemRow: View {
    let item: ItemSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.symbolName)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                if let sub = item.subtitle, !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if item.hasTotp {
                Image(systemName: "clock.badge.checkmark").foregroundStyle(.secondary).help("Has a one-time code")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: detail

struct ItemDetailView: View {
    @EnvironmentObject var model: AppModel
    let itemId: String
    @State private var item: Item?
    @State private var confirmTrash = false

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: item.data.kind.symbolName).font(.title).foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(item.data.title).font(.title2.bold())
                            Text(item.data.kind.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            if let u = item.data.username { FieldRow(label: "Username", value: u, concealed: false) }
                            if let p = item.data.password { FieldRow(label: item.data.kind.passwordLabel, value: p, concealed: true) }
                            if item.data.totp != nil { TOTPRow(itemId: item.id) }
                            ForEach(item.data.urls, id: \.self) { FieldRow(label: "URL", value: $0, concealed: false) }
                            ForEach(Array(item.data.fields.enumerated()), id: \.offset) { _, f in
                                FieldRow(label: f.name, value: f.value, concealed: f.concealed)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                    if let notes = item.data.notes {
                        GroupBox("Notes") {
                            Text(notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        if let folder = item.data.folder { Text("Folder: \(folder)") }
                        if !item.data.tags.isEmpty { Text("Tags: \(item.data.tags.joined(separator: ", "))") }
                        if item.data.travelSafe { Text("Travel safe") }
                        Text("Modified \(Date(timeIntervalSince1970: TimeInterval(item.modifiedAt)).formatted())")
                        Text("Created \(Date(timeIntervalSince1970: TimeInterval(item.createdAt)).formatted())")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            } else {
                ProgressView().padding()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let item, item.data.password != nil {
                    Button {
                        AutoType.confirmAndType(item.data.password ?? "", itemTitle: item.data.title, target: AutoType.lastExternalTarget())
                    } label: {
                        Label("Auto-Type…", systemImage: "keyboard")
                    }
                    .help("Type the password into the app you used last (asks first)")
                }
                Button { model.requestEdit(itemId) } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { confirmTrash = true } label: { Label("Move to Trash", systemImage: "trash") }
            }
        }
        .confirmationDialog("Move this item to the trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { model.trash(itemId) }
        }
        .task(id: itemId) { item = model.item(itemId) }
    }
}

struct FieldRow: View {
    @EnvironmentObject var model: AppModel
    let label: String
    let value: String
    let concealed: Bool
    @State private var revealed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
            Group {
                if concealed && !revealed {
                    Text(String(repeating: "•", count: min(max(value.count, 8), 24)))
                } else {
                    Text(value).textSelection(.enabled)
                }
            }
            .font(.system(.body, design: concealed ? .monospaced : .default))
            .lineLimit(concealed && !revealed ? 1 : nil)
            Spacer()
            if concealed {
                Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless).help(revealed ? "Hide" : "Reveal")
            }
            Button { model.copy(value, label: label) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy (clears in \(Int(SecureClipboard.defaultClearAfter)) s)")
        }
    }
}

/// Live TOTP: recomputed every second from the core.
struct TOTPRow: View {
    @EnvironmentObject var model: AppModel
    let itemId: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let code = model.totp(itemId)
            HStack(alignment: .firstTextBaseline) {
                Text("One-time code").foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                if let code {
                    Text(Self.grouped(code.code)).font(.system(.title3, design: .monospaced).bold())
                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: CGFloat(code.secondsRemaining) / CGFloat(max(code.period, 1)))
                            .stroke(code.secondsRemaining <= 5 ? Color.red : Color.accentColor, lineWidth: 3)
                            .rotationEffect(.degrees(-90))
                        Text("\(code.secondsRemaining)").font(.system(size: 9)).monospacedDigit()
                    }
                    .frame(width: 22, height: 22)
                    Spacer()
                    Button { model.copy(code.code, label: "One-time code") } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                } else {
                    Text("Invalid TOTP secret").foregroundStyle(.red)
                    Spacer()
                }
            }
        }
    }

    static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}
