import StrongroomKit
import SwiftUI

struct ItemDetailView: View {
    @EnvironmentObject var model: AppModel
    let itemId: String
    @State private var item: Item?
    @State private var confirmTrash = false

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 14) {
                    if !FolderPath.components(item.data.folder).isEmpty {
                        Breadcrumb(path: FolderPath.components(item.data.folder), font: .caption)
                    }
                    header(item)
                    healthNotice
                    ItemContentView(input: item.data, itemId: item.id)
                    VStack(alignment: .leading, spacing: 4) {
                        let tags = ReservedTags.userTags(item.data.tags)
                        if !tags.isEmpty { Text("Tags: \(tags.joined(separator: ", "))") }
                        if item.data.travelSafe { Label("Travel safe", systemImage: "airplane") }
                        Text("Modified \(Date(timeIntervalSince1970: TimeInterval(item.modifiedAt)).formatted())")
                        Text("Created \(Date(timeIntervalSince1970: TimeInterval(item.createdAt)).formatted())")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
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
                if let item, ItemPresentation.isAccount(kind: item.data.kind, tags: item.data.tags) {
                    Button { model.requestSibling(of: itemId) } label: {
                        Label("Add Another Account", systemImage: "person.badge.plus")
                    }
                    .help("Add another account for \(ItemPresentation.serviceName(folder: item.data.folder, urls: item.data.urls, title: item.data.title)) (same folder, websites and template)")
                }
                Button { model.sheet = .history(itemId) } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .help("Past versions of this item")
                Button { model.requestEdit(itemId) } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { confirmTrash = true } label: { Label("Move to Trash", systemImage: "trash") }
            }
        }
        .confirmationDialog("Move this item to the trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { model.trash(itemId) }
        } message: {
            Text("It stays in the trash for 180 days and can be restored until then.")
        }
        .task(id: itemId) { item = model.item(itemId) }
    }

    private func header(_ item: Item) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ItemPresentation.symbol(kind: item.data.kind, tags: item.data.tags))
                .font(.title).foregroundStyle(.tint).frame(width: 36)
            VStack(alignment: .leading) {
                Text(item.data.title).font(.title2.bold()).textSelection(.enabled)
                Text(ItemPresentation.typeName(kind: item.data.kind, tags: item.data.tags)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            let fav = ReservedTags.isFavourite(item.data.tags)
            Button { model.toggleFavourite(itemId) } label: {
                Image(systemName: fav ? "star.fill" : "star").font(.title3).foregroundStyle(fav ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help(fav ? "Remove from Favourites" : "Add to Favourites")
        }
    }

    @ViewBuilder private var healthNotice: some View {
        let notes = [
            model.reusedIDs.contains(itemId) ? "This password is used by another item." : nil,
            model.weakIDs.contains(itemId) ? "This password is weak." : nil,
            model.oldIDs.contains(itemId) ? "This password has not changed in over a year." : nil,
        ].compactMap { $0 }
        if !notes.isEmpty {
            Label(notes.joined(separator: " "), systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.primary)
                .symbolRenderingMode(.multicolor)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// The fields of an item, grouped by template and sensitive sections. With
/// `itemId` set (the live item) recovery codes can be marked used; history
/// views pass nil and are read-only. Every copy goes through the clearing
/// clipboard.
struct ItemContentView: View {
    @EnvironmentObject var model: AppModel
    let input: ItemInput
    let itemId: String?
    var showTOTP = true

    var body: some View {
        let template = ReservedTags.template(in: input.tags)
        let groups = FieldGroups.group(names: input.fields.map(\.name), template: template)
        let f = input.fields
        VStack(alignment: .leading, spacing: 14) {
            if let warning = template?.warning {
                WarningBox(text: warning)
            }
            let hasMain = input.username != nil || input.password != nil || input.totp != nil || !input.urls.isEmpty
                || groups.template.contains { !f[$0].value.isEmpty }
            if hasMain {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        if let u = input.username { FieldRow(label: template?.usernameLabel ?? "Username", value: u, concealed: false) }
                        if let p = input.password {
                            FieldRow(label: template?.passwordLabel ?? input.kind.passwordLabel, value: p, concealed: true)
                        }
                        if input.totp != nil, showTOTP, let itemId { TOTPRow(itemId: itemId) }
                        ForEach(input.urls, id: \.self) { FieldRow(label: "Website", value: $0, concealed: false) }
                        ForEach(groups.template.filter { !f[$0].value.isEmpty }, id: \.self) { i in
                            FieldRow(label: f[i].name, value: f[i].value, concealed: f[i].concealed)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
            if !groups.recoveryCodes.isEmpty {
                RecoveryCodesSection(fields: f, indices: groups.recoveryCodes, itemId: itemId)
            }
            if !groups.securityPairs.isEmpty {
                SectionBox(title: "Security questions", symbol: "questionmark.bubble") {
                    ForEach(groups.securityPairs, id: \.number) { pair in
                        VStack(alignment: .leading, spacing: 6) {
                            if let q = pair.question { FieldRow(label: "Question", value: f[q].value, concealed: f[q].concealed) }
                            if let a = pair.answer { FieldRow(label: "Answer", value: f[a].value, concealed: f[a].concealed) }
                        }
                        if pair.number != groups.securityPairs.last?.number { Divider() }
                    }
                }
            }
            if !groups.twoFactorNotes.isEmpty {
                SectionBox(title: "2FA / backup notes", symbol: "lock.shield") {
                    ForEach(groups.twoFactorNotes, id: \.self) { i in
                        FieldRow(label: "Note", value: f[i].value, concealed: f[i].concealed)
                    }
                }
            }
            if !groups.pins.isEmpty {
                SectionBox(title: "PINs", symbol: "circle.grid.3x3") {
                    ForEach(groups.pins, id: \.self) { i in
                        FieldRow(label: f[i].name, value: f[i].value, concealed: f[i].concealed)
                    }
                }
            }
            if !groups.seedWords.isEmpty {
                SeedPhraseView(words: SeedPhrase.words(f))
            }
            if !groups.other.isEmpty {
                SectionBox(title: "Other fields", symbol: "list.bullet.rectangle") {
                    ForEach(groups.other, id: \.self) { i in
                        FieldRow(label: f[i].name, value: f[i].value, concealed: f[i].concealed)
                    }
                }
            }
            if let notes = input.notes {
                GroupBox("Notes") {
                    Text(notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
        }
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    let symbol: String
    var trailing: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                if let trailing {
                    Spacer()
                    Text(trailing).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct WarningBox: View {
    let text: String
    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct RecoveryCodesSection: View {
    @EnvironmentObject var model: AppModel
    let fields: [CustomField]
    let indices: [Int]
    let itemId: String?

    var body: some View {
        let unused = RecoveryCodes.unusedCount(fields)
        let total = RecoveryCodes.totalCount(fields)
        SectionBox(title: "Recovery codes", symbol: "lifepreserver", trailing: "\(unused) of \(total) unused") {
            ForEach(indices, id: \.self) { i in
                let used: Bool = {
                    if case let .recoveryCode(_, u) = SensitiveField.classify(fields[i].name) { return u }
                    return false
                }()
                RecoveryCodeRow(index: i, field: fields[i], used: used, itemId: itemId)
            }
            if unused <= 2 && total > 0 {
                Text(unused == 0 ? "All codes are used. Generate new ones at the service and paste them in."
                                 : "Only \(unused) unused code\(unused == 1 ? "" : "s") left. Consider generating new ones.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct RecoveryCodeRow: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    let field: CustomField
    let used: Bool
    let itemId: String?
    @State private var revealed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            let label: String = {
                if case let .recoveryCode(n?, _) = SensitiveField.classify(field.name) { return "Code \(n)" }
                return "Code"
            }()
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
            Group {
                if field.concealed && !revealed {
                    Text(String(repeating: "•", count: min(max(field.value.count, 8), 24)))
                } else {
                    Text(field.value).textSelection(.enabled)
                }
            }
            .font(.system(.body, design: .monospaced))
            .strikethrough(used)
            .foregroundStyle(used ? .secondary : .primary)
            if used {
                Text("used").font(.caption2.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
            if field.concealed {
                Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless).help(revealed ? "Hide" : "Reveal")
            }
            Button { model.copy(field.value, label: label) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy (clears in \(Int(SecureClipboard.defaultClearAfter)) s)")
            if let itemId {
                Button { model.setRecoveryCodeUsed(itemId, fieldIndex: index, used: !used) } label: {
                    Image(systemName: used ? "arrow.uturn.backward.circle" : "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .help(used ? "Mark unused" : "Mark used")
            }
        }
        .contextMenu {
            if let itemId, !used {
                Button("Copy and Mark Used") {
                    model.copy(field.value, label: label)
                    model.setRecoveryCodeUsed(itemId, fieldIndex: index, used: true)
                }
            }
        }
    }

    private var label: String {
        if case let .recoveryCode(n?, _) = SensitiveField.classify(field.name) { return "Recovery code \(n)" }
        return "Recovery code"
    }
}

struct SeedPhraseView: View {
    @EnvironmentObject var model: AppModel
    let words: [String]
    @State private var revealed = false
    @State private var confirmCopy = false

    var body: some View {
        let missing = words.filter(\.isEmpty).count
        SectionBox(title: "Seed phrase (\(words.count) word\(words.count == 1 ? "" : "s"))", symbol: "key.horizontal",
                   trailing: missing > 0 ? "\(missing) position\(missing == 1 ? "" : "s") empty" : nil) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                    HStack(spacing: 6) {
                        Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                        Text(revealed ? (w.isEmpty ? "—" : w) : "•••••")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            HStack {
                Button(revealed ? "Hide Words" : "Reveal Words") { revealed.toggle() }
                Button("Copy Phrase…") { confirmCopy = true }
                Spacer()
            }
        }
        .confirmationDialog("Copy the whole seed phrase?", isPresented: $confirmCopy) {
            Button("Copy for \(Int(SecureClipboard.defaultClearAfter)) Seconds") {
                model.copy(words.filter { !$0.isEmpty }.joined(separator: " "), label: "Seed phrase")
            }
        } message: {
            Text("Anything you paste it into can read it. Only paste it into the wallet app you are restoring.")
        }
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
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing).lineLimit(2)
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

// MARK: history

struct HistorySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let itemId: String
    @State private var revisions: [ItemRevision] = []
    @State private var selected: Int?
    @State private var confirmRestore = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History of “\(model.summary(itemId)?.title ?? "item")”").font(.title3.bold())
                Spacer()
                Text("\(revisions.count) earlier version\(revisions.count == 1 ? "" : "s") (up to 64 are kept)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            HSplitView {
                List(selection: $selected) {
                    ForEach(Array(revisions.enumerated()), id: \.offset) { i, r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Date(timeIntervalSince1970: TimeInterval(r.modifiedAt)).formatted(date: .abbreviated, time: .shortened))
                            Text(r.data.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(i)
                    }
                }
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
                .overlay {
                    if revisions.isEmpty {
                        ContentUnavailableView("No earlier versions", systemImage: "clock",
                                               description: Text("A version is kept every time the item is changed."))
                    }
                }
                ScrollView {
                    if let selected, revisions.indices.contains(selected) {
                        let r = revisions[selected]
                        VStack(alignment: .leading, spacing: 12) {
                            Text(r.data.title).font(.title3.bold())
                            if let folder = r.data.folder {
                                Text("Folder: \(FolderPath.components(folder).joined(separator: " › "))").font(.caption).foregroundStyle(.secondary)
                            }
                            ItemContentView(input: r.data, itemId: nil, showTOTP: false)
                            if let t = r.data.totp {
                                FieldRow(label: "TOTP secret", value: t, concealed: true)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !revisions.isEmpty {
                        Text("Select a version to view it.").foregroundStyle(.secondary).padding(30)
                    }
                }
                .frame(minWidth: 380)
            }
            Divider()
            HStack {
                Text("Copying a field from an old version uses the clearing clipboard.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore This Version…") { confirmRestore = true }
                    .disabled(selected == nil)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 760, height: 560)
        .onAppear {
            revisions = model.history(itemId)
            selected = revisions.isEmpty ? nil : 0
        }
        .confirmationDialog("Restore this version?", isPresented: $confirmRestore) {
            Button("Restore") {
                if let selected, revisions.indices.contains(selected) {
                    model.restoreRevision(itemId, revisions[selected])
                    dismiss()
                }
            }
        } message: {
            Text("The current version is kept in the history, so this can be undone.")
        }
    }
}
