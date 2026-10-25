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
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    if !FolderPath.components(item.data.folder).isEmpty {
                        Breadcrumb(path: FolderPath.components(item.data.folder), font: .caption)
                    }
                    header(item)
                    quickActions(item)
                    healthNotice
                    ItemContentView(input: item.data, itemId: item.id)
                    metadata(item)
                }
                .readableWidth()
                .panePadding()
            } else {
                ProgressView().padding()
            }
        }
        .adaptivePane()
        .confirmationDialog("Move this item to the trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { model.trash(itemId) }
        } message: {
            Text("It stays in the trash for 180 days and can be restored until then.")
        }
        .task(id: itemId) { item = model.item(itemId) }
    }

    // MARK: header

    private func header(_ item: Item) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: DS.Space.m) {
                titleBlock(item)
                Spacer(minLength: DS.Space.m)
                actions(item)
            }
            VStack(alignment: .leading, spacing: DS.Space.m) {
                titleBlock(item)
                actions(item)
            }
        }
    }

    private func titleBlock(_ item: Item) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: ItemPresentation.symbol(kind: item.data.kind, tags: item.data.tags))
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.card))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(item.data.title).font(.paneTitle).textSelection(.enabled).lineLimit(2)
                Text(ItemPresentation.typeName(kind: item.data.kind, tags: item.data.tags))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// The item's actions, always here: favourite, Edit, and the rest in a menu.
    private func actions(_ item: Item) -> some View {
        let fav = ReservedTags.isFavourite(item.data.tags)
        return HStack(spacing: DS.Space.s) {
            Button { model.toggleFavourite(itemId) } label: {
                Label(fav ? "Remove from Favourites" : "Add to Favourites", systemImage: fav ? "star.fill" : "star")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(fav ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .font(.title3)
            .help(fav ? "Remove from Favourites" : "Add to Favourites")
            Button { model.requestEdit(itemId) } label: { Label("Edit", systemImage: "pencil") }
                .help("Edit this item")
            Menu {
                if item.data.password != nil {
                    Button {
                        AutoType.confirmAndType(item.data.password ?? "", itemTitle: item.data.title, target: AutoType.lastExternalTarget())
                    } label: {
                        Label("Auto-Type Password…", systemImage: "keyboard")
                    }
                    .help("Type the password into the app you used last (asks first)")
                }
                if ItemPresentation.isAccount(kind: item.data.kind, tags: item.data.tags) {
                    Button { model.requestSibling(of: itemId) } label: {
                        Label("Add Another Account for \(ItemPresentation.serviceName(folder: item.data.folder, urls: item.data.urls, title: item.data.title))…",
                              systemImage: "person.badge.plus")
                    }
                }
                Button { model.sheet = .moveItems([itemId]) } label: { Label("Move to Folder…", systemImage: "folder") }
                Button { model.sheet = .history(itemId) } label: { Label("History…", systemImage: "clock.arrow.circlepath") }
                Divider()
                Button(role: .destructive) { confirmTrash = true } label: { Label("Move to Trash…", systemImage: "trash") }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Auto-type, another account, move, history, trash")
        }
    }

    /// Copy buttons for the values people reach for most.
    @ViewBuilder private func quickActions(_ item: Item) -> some View {
        let d = item.data
        let hasAny = d.password != nil || d.username != nil || d.totp != nil || WebsiteOpener.url(d.urls) != nil
        if hasAny {
            FlowRow(spacing: DS.Space.s, lineSpacing: DS.Space.s) {
                if let p = d.password {
                    Button { model.copy(p, label: ItemPresentation.passwordLabel(kind: d.kind, tags: d.tags)) } label: {
                        Label("Copy \(ItemPresentation.passwordLabel(kind: d.kind, tags: d.tags))", systemImage: "key")
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let u = d.username {
                    Button { model.copy(u, label: "Username") } label: { Label("Copy Username", systemImage: "person") }
                }
                if d.totp != nil {
                    Button {
                        if let code = model.totp(itemId) { model.copy(code.code, label: "One-time code") }
                    } label: {
                        Label("Copy Code", systemImage: "clock")
                    }
                }
                if WebsiteOpener.url(d.urls) != nil {
                    Button { WebsiteOpener.open(d.urls) } label: { Label("Open Website", systemImage: "safari") }
                        .help("Opens the website in your browser")
                }
            }
            .controlSize(.small)
            .labelStyle(QuickActionLabelStyle())
        }
    }

    @ViewBuilder private var healthNotice: some View {
        let notes = [
            model.reusedIDs.contains(itemId) ? "This password is used by another item." : nil,
            model.weakIDs.contains(itemId) ? "This password is weak." : nil,
            model.oldIDs.contains(itemId) ? "This password has not changed in over a year." : nil,
        ].compactMap { $0 }
        if !notes.isEmpty {
            HStack(alignment: .center, spacing: DS.Space.m) {
                Callout(.warning, notes.joined(separator: " "))
                Button("Change…") { model.requestChangePassword(itemId) }
                    .help("Open the editor with the generator ready. Nothing is replaced until you save.")
            }
        }
    }

    private func metadata(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            let tags = ReservedTags.userTags(item.data.tags)
            if !tags.isEmpty { Label(tags.joined(separator: ", "), systemImage: "tag") }
            if item.data.travelSafe { Label("Travel safe", systemImage: "airplane") }
            Text("Modified \(Date(timeIntervalSince1970: TimeInterval(item.modifiedAt)).formatted(date: .abbreviated, time: .shortened))")
            Text("Created \(Date(timeIntervalSince1970: TimeInterval(item.createdAt)).formatted(date: .abbreviated, time: .shortened))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Space.xs)
    }
}

/// Copy buttons drop their icon when the pane is narrow.
private struct QuickActionLabelStyle: LabelStyle {
    @Environment(\.isCompactPane) private var compact

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.title
        } else {
            HStack(spacing: DS.Space.xs) {
                configuration.icon
                configuration.title
            }
        }
    }
}

extension ItemPresentation {
    /// "Password", "PIN", "Key"… for the copy button.
    static func passwordLabel(kind: ItemKind, tags: [String]) -> String {
        ReservedTags.template(in: tags)?.passwordLabel ?? kind.passwordLabel
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
        VStack(alignment: .leading, spacing: DS.Space.l) {
            if let warning = template?.warning {
                Callout(.danger, warning)
            }
            let hasMain = input.username != nil || input.password != nil || input.totp != nil || !input.urls.isEmpty
                || groups.template.contains { !f[$0].value.isEmpty }
            if hasMain {
                SectionBox(title: nil) {
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
            }
            if !groups.recoveryCodes.isEmpty {
                RecoveryCodesSection(fields: f, indices: groups.recoveryCodes, itemId: itemId)
            }
            if !groups.securityPairs.isEmpty {
                SectionBox(title: "Security questions", symbol: "questionmark.bubble") {
                    ForEach(groups.securityPairs, id: \.number) { pair in
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            if let q = pair.question { FieldRow(label: "Question", value: f[q].value, concealed: f[q].concealed) }
                            if let a = pair.answer { FieldRow(label: "Answer", value: f[a].value, concealed: f[a].concealed) }
                        }
                        if pair.number != groups.securityPairs.last?.number { Divider() }
                    }
                }
            }
            if !groups.twoFactorNotes.isEmpty {
                SectionBox(title: "2FA and backup notes", symbol: "lock.shield") {
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
                SectionBox(title: "Notes", symbol: "note.text") {
                    Text(notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// One labelled row of the detail pane: label in a fixed column when there is
/// room, above the value when the pane is narrow. Actions sit at the right.
struct DetailRow<Value: View, Actions: View>: View {
    @Environment(\.isCompactPane) private var compact
    let label: String
    @ViewBuilder let value: Value
    @ViewBuilder let actions: Actions

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    value
                    Spacer(minLength: DS.Space.xs)
                    actions
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(width: DS.Width.label, alignment: .trailing)
                value
                Spacer(minLength: DS.Space.xs)
                actions
            }
        }
    }
}

/// Masked text of a concealed value (length hint only, 8 to 24 dots).
func maskedText(_ value: String) -> String {
    String(repeating: "•", count: min(max(value.count, 8), 24))
}

struct WarningBox: View {
    let text: String
    var body: some View { Callout(.danger, text) }
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
                Callout(.warning, unused == 0 ? "All codes are used. Generate new ones at the service and paste them in."
                                              : "Only \(unused) unused code\(unused == 1 ? "" : "s") left. Consider generating new ones.")
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
        let short: String = {
            if case let .recoveryCode(n?, _) = SensitiveField.classify(field.name) { return "Code \(n)" }
            return "Code"
        }()
        DetailRow(label: short) {
            HStack(spacing: DS.Space.s) {
                Group {
                    if field.concealed && !revealed {
                        Text(maskedText(field.value))
                    } else {
                        Text(field.value).textSelection(.enabled)
                    }
                }
                .font(.secret)
                .lineLimit(1)
                .strikethrough(used)
                .foregroundStyle(used ? .secondary : .primary)
                if used {
                    Text("used").font(.caption2.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
        } actions: {
            if field.concealed {
                IconButton(revealed ? "Hide" : "Reveal", systemImage: revealed ? "eye.slash" : "eye") { revealed.toggle() }
            }
            IconButton("Copy \(label)", systemImage: "doc.on.doc", help: "Copy (clears in \(Int(SecureClipboard.defaultClearAfter)) s)") {
                model.copy(field.value, label: label)
            }
            if let itemId {
                IconButton(used ? "Mark unused" : "Mark used", systemImage: used ? "arrow.uturn.backward.circle" : "checkmark.circle") {
                    model.setRecoveryCodeUsed(itemId, fieldIndex: index, used: !used)
                }
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: DS.Space.s)], alignment: .leading, spacing: DS.Space.s) {
                ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                    HStack(spacing: DS.Space.s) {
                        Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 22, alignment: .trailing)
                        Text(revealed ? (w.isEmpty ? "—" : w) : "•••••")
                            .font(.secret)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 3).padding(.horizontal, DS.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.Radius.small))
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
        DetailRow(label: label) {
            Group {
                if concealed && !revealed {
                    Text(maskedText(value)).lineLimit(1)
                } else if value.contains(where: \.isWhitespace) {
                    Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else {
                    // One long word (URL, key, address): keep it on one line.
                    Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(concealed ? .secret : .body)
        } actions: {
            if concealed {
                IconButton(revealed ? "Hide \(label)" : "Reveal \(label)", systemImage: revealed ? "eye.slash" : "eye",
                           help: revealed ? "Hide" : "Reveal") { revealed.toggle() }
            }
            IconButton("Copy \(label)", systemImage: "doc.on.doc", help: "Copy (clears in \(Int(SecureClipboard.defaultClearAfter)) s)") {
                model.copy(value, label: label)
            }
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
            DetailRow(label: "One-time code") {
                if let code {
                    HStack(spacing: DS.Space.s) {
                        Text(Self.grouped(code.code)).font(.system(.title3, design: .monospaced).bold())
                        ZStack {
                            Circle().stroke(.quaternary, lineWidth: 3)
                            Circle()
                                .trim(from: 0, to: CGFloat(code.secondsRemaining) / CGFloat(max(code.period, 1)))
                                .stroke(code.secondsRemaining <= 5 ? Color.red : Color.accentColor, lineWidth: 3)
                                .rotationEffect(.degrees(-90))
                            Text("\(code.secondsRemaining)").font(.caption2).monospacedDigit()
                        }
                        .frame(width: 24, height: 24)
                        .accessibilityLabel("\(code.secondsRemaining) seconds left")
                    }
                } else {
                    Text("Invalid TOTP secret").foregroundStyle(.red)
                }
            } actions: {
                if let code {
                    IconButton("Copy one-time code", systemImage: "doc.on.doc") { model.copy(code.code, label: "One-time code") }
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
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("History of “\(model.summary(itemId)?.title ?? "item")”").font(.sheetTitle).lineLimit(1)
                    HintText("\(revisions.count) earlier version\(revisions.count == 1 ? "" : "s"). Up to 64 are kept.")
                }
                Spacer()
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, DS.Space.xl)
            .padding(.bottom, DS.Space.m)
            Divider()
            HSplitView {
                List(selection: $selected) {
                    ForEach(Array(revisions.enumerated()), id: \.offset) { i, r in
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text(Date(timeIntervalSince1970: TimeInterval(r.modifiedAt)).formatted(date: .abbreviated, time: .shortened))
                            Text(r.data.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(i)
                    }
                }
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                .overlay {
                    if revisions.isEmpty {
                        ContentUnavailableView("No earlier versions", systemImage: "clock",
                                               description: Text("A version is kept every time the item is changed."))
                    }
                }
                ScrollView {
                    if let selected, revisions.indices.contains(selected) {
                        let r = revisions[selected]
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            Text(r.data.title).font(.sheetTitle)
                            if let folder = r.data.folder {
                                Label(FolderPath.components(folder).joined(separator: " › "), systemImage: "folder")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            ItemContentView(input: r.data, itemId: nil, showTOTP: false)
                            if let t = r.data.totp {
                                SectionBox(title: nil) { FieldRow(label: "TOTP secret", value: t, concealed: true) }
                            }
                        }
                        .padding(DS.Space.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !revisions.isEmpty {
                        Text("Select a version to view it.").foregroundStyle(.secondary).padding(DS.Space.xxl)
                    }
                }
                .adaptivePane()
                .frame(minWidth: 320)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.s) {
                    HintText("Copying a field from an old version uses the clearing clipboard.", font: .caption)
                    Spacer()
                    footerButtons
                }
                HStack(spacing: DS.Space.s) {
                    Spacer()
                    footerButtons
                }
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.m)
        }
        .frame(minWidth: 560, idealWidth: DS.Sheet.wide.width, minHeight: 380, idealHeight: DS.Sheet.wide.height)
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

    @ViewBuilder private var footerButtons: some View {
        Button("Restore This Version…") { confirmRestore = true }
            .disabled(selected == nil)
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
    }
}
