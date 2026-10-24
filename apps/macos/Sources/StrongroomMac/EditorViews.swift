import StrongroomKit
import SwiftUI

// MARK: template picker

/// Shown when creating an item. Picking a template turns this sheet into the
/// editor (no second sheet), with the folder prefilled.
struct TemplatePickerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let folder: [String]
    @State private var draft: ItemDraft?

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 10)]

    var body: some View {
        if let draft {
            ItemEditorView(itemId: nil, draft: draft)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New item").font(.title2.bold())
                    Text(folder.isEmpty ? "Choose what you are storing." : "In \(folder.joined(separator: " › ")). Choose what you are storing.")
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(ItemTemplate.all) { t in
                                Button { choose(ItemDraft(template: t)) } label: {
                                    TemplateCard(symbol: t.symbol, name: t.name, summary: t.summary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text("Blank item").font(.headline).foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(ItemKind.allCases) { k in
                                Button { choose(ItemDraft(kind: k)) } label: {
                                    TemplateCard(symbol: k.symbolName, name: k.displayName, summary: "No template")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .padding(12)
            }
            .frame(width: 640, height: 600)
        }
    }

    private func choose(_ d: ItemDraft) {
        var d = d
        d.folder = FolderPath.join(folder) ?? ""
        draft = d
    }
}

struct TemplateCard: View {
    let symbol: String
    let name: String
    let summary: String
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout.weight(.semibold)).lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hover ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.15)))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hover = $0 }
    }
}

// MARK: editor

struct ItemEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let itemId: String?
    @State var draft: ItemDraft
    @State private var showGenerator = false
    @State private var revealPassword = false
    /// One switch for every concealed field in the sections below.
    @State private var revealSecrets = false
    @State private var showPasteCodes = false
    @State private var pastedCodes = ""

    init(itemId: String?, draft: ItemDraft) {
        self.itemId = itemId
        _draft = State(initialValue: draft)
    }

    private var template: ItemTemplate? { draft.template }
    private var groups: FieldGroups { FieldGroups.group(names: draft.fields.map(\.name), template: template) }

    var body: some View {
        let g = groups
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: template?.symbol ?? draft.kind.symbolName).font(.title2).foregroundStyle(.tint)
                Text(itemId == nil ? "New \(template?.name ?? draft.kind.displayName)" : "Edit \(template?.name ?? draft.kind.displayName)")
                    .font(.title3.bold())
                Spacer()
                Toggle("Show hidden values", isOn: $revealSecrets).toggleStyle(.switch).controlSize(.small)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            Form {
                Section {
                    if template == nil {
                        Picker("Kind", selection: Binding(get: { draft.kind }, set: { draft.changeKind(to: $0) })) {
                            ForEach(ItemKind.allCases) { Label($0.displayName, systemImage: $0.symbolName).tag($0) }
                        }
                    }
                    TextField("Title", text: $draft.title, prompt: Text(template?.isAccount == true ? "@personal, Work account, …" : "Title"))
                    HStack {
                        TextField("Folder", text: $draft.folder, prompt: Text("Social/Instagram"))
                        Menu {
                            Button("No folder") { draft.folder = "" }
                            Divider()
                            ForEach(FolderTree.allPaths(model.tree), id: \.self) { p in
                                Button(String(repeating: "   ", count: p.count - 1) + p.last!) { draft.folder = FolderPath.id(p) }
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Choose an existing folder")
                    }
                    Toggle("Favourite", isOn: $draft.favourite)
                }
                if let warning = template?.warning {
                    Section { WarningBox(text: warning) }
                }
                builtInFields
                if !g.template.isEmpty {
                    Section(template?.name ?? "Details") {
                        ForEach(g.template.map { draft.fields[$0].id }, id: \.self) { fid in
                            templateFieldRow(fid)
                        }
                    }
                }
                if template?.sections.contains(.recoveryCodes) == true || !g.recoveryCodes.isEmpty {
                    recoveryCodesSection(g)
                }
                if template?.sections.contains(.securityQuestions) == true || !g.securityPairs.isEmpty {
                    securityQuestionsSection(g)
                }
                if template?.sections.contains(.twoFactorNote) == true || !g.twoFactorNotes.isEmpty {
                    Section("2FA / backup notes") {
                        ForEach(g.twoFactorNotes.map { draft.fields[$0].id }, id: \.self) { fid in
                            HStack(alignment: .top) {
                                SecretEditor(placeholder: "Where the authenticator lives, backup phone, …", text: value(fid), revealed: revealSecrets, multiline: true)
                                removeButton(fid)
                            }
                        }
                        Button("Add Note") { draft.fields.append(.init(name: SensitiveField.twoFactorNoteName, value: "", concealed: true)) }
                    }
                }
                if template?.sections.contains(.pins) == true || !g.pins.isEmpty {
                    Section("PINs") {
                        ForEach(g.pins.map { draft.fields[$0].id }, id: \.self) { fid in
                            HStack {
                                TextField("Name", text: name(fid)).frame(width: 150)
                                SecretEditor(placeholder: "PIN", text: value(fid), revealed: revealSecrets)
                                removeButton(fid)
                            }
                        }
                        Button("Add PIN") {
                            let n = g.pins.isEmpty ? SensitiveField.pinName : "\(SensitiveField.pinName) \(g.pins.count + 1)"
                            draft.fields.append(.init(name: n, value: "", concealed: true))
                        }
                    }
                }
                if template?.sections.contains(.seedPhrase) == true || !g.seedWords.isEmpty {
                    seedPhraseSection(g)
                }
                Section("Other fields") {
                    ForEach(g.other.map { draft.fields[$0].id }, id: \.self) { fid in
                        HStack {
                            TextField("Name", text: name(fid)).frame(width: 150)
                            if field(fid).concealed {
                                SecretEditor(placeholder: "Value", text: value(fid), revealed: revealSecrets)
                            } else {
                                TextField("Value", text: value(fid))
                            }
                            Toggle("Hidden", isOn: concealed(fid)).toggleStyle(.checkbox)
                            removeButton(fid)
                        }
                    }
                    HStack {
                        Button("Add Field") { draft.fields.append(.init(name: "", value: "", concealed: false)) }
                        Menu("Add Section") {
                            Button("Recovery Codes") { showPasteCodes = true }
                            Button("Security Question") { draft.addSecurityQuestion() }
                            Button("2FA / Backup Note") { draft.fields.append(.init(name: SensitiveField.twoFactorNoteName, value: "", concealed: true)) }
                            Button("PIN") { draft.fields.append(.init(name: SensitiveField.pinName, value: "", concealed: true)) }
                        }
                        .fixedSize()
                    }
                }
                Section {
                    TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3 ... 10)
                    TextField("Tags (comma-separated)", text: $draft.tags)
                    Toggle("Travel safe (kept on this Mac in travel mode)", isOn: $draft.travelSafe)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let t = template { Label("Template: \(t.name)", systemImage: t.symbol).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(itemId == nil ? "Add" : "Save") {
                    if model.save(draft, id: itemId) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
            .padding(12)
        }
        .frame(width: 640, height: 720)
        .popover(isPresented: $showPasteCodes, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Paste recovery codes").font(.headline)
                Text("One per line, or separated by commas or spaces.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $pastedCodes)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 320, height: 160)
                    .border(.quaternary)
                let parsed = RecoveryCodes.parse(pastedCodes)
                HStack {
                    Text("\(parsed.count) code\(parsed.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { pastedCodes = ""; showPasteCodes = false }
                    Button("Add") {
                        draft.addRecoveryCodes(parsed)
                        pastedCodes = ""
                        showPasteCodes = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed.isEmpty)
                }
            }
            .padding(14)
        }
    }

    // MARK: sections

    @ViewBuilder private var builtInFields: some View {
        if draft.kind.usesUsername || draft.kind.usesPassword {
            Section {
                if draft.kind.usesUsername {
                    TextField(template?.usernameLabel ?? "Username", text: $draft.username)
                }
                if draft.kind.usesPassword {
                    HStack {
                        let label = template?.passwordLabel ?? draft.kind.passwordLabel
                        if revealPassword {
                            TextField(label, text: $draft.password).font(.system(.body, design: .monospaced))
                        } else {
                            SecureField(label, text: $draft.password)
                        }
                        Button { revealPassword.toggle() } label: { Image(systemName: revealPassword ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless)
                        Button { showGenerator = true } label: { Image(systemName: "wand.and.stars") }
                            .buttonStyle(.borderless).help("Generate")
                            .popover(isPresented: $showGenerator) {
                                GeneratorView { value in
                                    draft.password = value
                                    showGenerator = false
                                }
                                .padding(16)
                                .frame(width: 420)
                            }
                    }
                    if !draft.password.isEmpty { StrengthMeter(password: draft.password) }
                }
            }
        }
        if draft.kind.usesTOTP {
            Section {
                TextField("One-time code secret (base32 or otpauth://)", text: $draft.totp)
                    .font(.system(.body, design: .monospaced))
                if !draft.totp.trimmingCharacters(in: .whitespaces).isEmpty {
                    TOTPPreview(secret: draft.totp)
                }
            }
        }
        if draft.kind.usesURLs {
            Section("Websites") {
                ForEach(draft.urls.indices, id: \.self) { i in
                    HStack {
                        TextField("https://", text: Binding(
                            get: { i < draft.urls.count ? draft.urls[i] : "" },
                            set: { if i < draft.urls.count { draft.urls[i] = $0 } }))
                        Button { draft.urls.remove(at: i); if draft.urls.isEmpty { draft.urls = [""] } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Website") { draft.urls.append("") }
            }
        }
    }

    @ViewBuilder private func templateFieldRow(_ fid: UUID) -> some View {
        let f = field(fid)
        let spec = template?.fields.first { $0.name.caseInsensitiveCompare(f.name) == .orderedSame }
        LabeledContent(f.name) {
            if f.concealed {
                SecretEditor(placeholder: spec?.hint ?? "", text: value(fid), revealed: revealSecrets, multiline: spec?.multiline ?? false)
            } else if spec?.multiline == true {
                TextField("", text: value(fid), prompt: Text(spec?.hint ?? ""), axis: .vertical).lineLimit(2 ... 8)
            } else {
                TextField("", text: value(fid), prompt: Text(spec?.hint ?? ""))
            }
        }
    }

    private func recoveryCodesSection(_ g: FieldGroups) -> some View {
        let codes = draft.fields.map { CustomField(name: $0.name, value: $0.value, concealed: $0.concealed) }
        return Section {
            ForEach(g.recoveryCodes.map { draft.fields[$0].id }, id: \.self) { fid in
                let f = field(fid)
                let used: Bool = { if case let .recoveryCode(_, u) = SensitiveField.classify(f.name) { return u } else { return false } }()
                HStack {
                    Text(f.name.replacingOccurrences(of: SensitiveField.usedPrefix, with: ""))
                        .foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                    SecretEditor(placeholder: "Code", text: value(fid), revealed: revealSecrets)
                        .strikethrough(used)
                    Toggle("Used", isOn: Binding(
                        get: { used },
                        set: { on in setName(fid, SensitiveField.settingUsed(field(fid).name, on)) }))
                        .toggleStyle(.checkbox)
                    removeButton(fid)
                }
            }
            HStack {
                Button("Paste Codes…") { showPasteCodes = true }
                Button("Add Code") { draft.addRecoveryCodes([""]) }
            }
        } header: {
            HStack {
                Text("Recovery codes")
                Spacer()
                Text("\(RecoveryCodes.unusedCount(codes)) of \(RecoveryCodes.totalCount(codes)) unused").font(.caption)
            }
        } footer: {
            Text("Used codes are marked “[used]” in the field name; the code itself is never changed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func securityQuestionsSection(_ g: FieldGroups) -> some View {
        Section("Security questions") {
            ForEach(g.securityPairs, id: \.number) { pair in
                VStack(spacing: 6) {
                    if let q = pair.question {
                        let fid = draft.fields[q].id
                        HStack {
                            Text("Question").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                            SecretEditor(placeholder: "e.g. Name of your first school", text: value(fid), revealed: revealSecrets)
                        }
                    }
                    if let a = pair.answer {
                        let fid = draft.fields[a].id
                        HStack {
                            Text("Answer").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                            SecretEditor(placeholder: "Answer (a random one is safer)", text: value(fid), revealed: revealSecrets)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Remove Question", role: .destructive) {
                            let ids = [pair.question, pair.answer].compactMap { $0 }.map { draft.fields[$0].id }
                            draft.fields.removeAll { ids.contains($0.id) }
                        }
                        .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
            Button("Add Question") { draft.addSecurityQuestion() }
        }
    }

    private func seedPhraseSection(_ g: FieldGroups) -> some View {
        Section {
            Picker("Words", selection: Binding(get: { draft.seedWordCount }, set: { draft.setSeedWordCount($0) })) {
                ForEach([12, 15, 18, 21, 24], id: \.self) { Text("\($0)").tag($0) }
                if ![12, 15, 18, 21, 24].contains(draft.seedWordCount) { Text("\(draft.seedWordCount)").tag(draft.seedWordCount) }
            }
            .pickerStyle(.segmented)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(Array(g.seedWords.enumerated()), id: \.offset) { n, i in
                    let fid = draft.fields[i].id
                    HStack(spacing: 4) {
                        Text("\(n + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
                        SecretEditor(placeholder: "word", text: value(fid), revealed: revealSecrets)
                    }
                }
            }
        } header: {
            Text("Seed phrase")
        } footer: {
            Text("Each word is a separate hidden field, in order. Check every word against your written backup.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: field bindings (by id, so rows survive inserts and removals)

    private func field(_ id: UUID) -> ItemDraft.Field {
        draft.fields.first { $0.id == id } ?? .init(name: "", value: "", concealed: false)
    }

    private func value(_ id: UUID) -> Binding<String> {
        Binding(get: { field(id).value }, set: { v in
            if let i = draft.fields.firstIndex(where: { $0.id == id }) { draft.fields[i].value = v }
        })
    }

    private func name(_ id: UUID) -> Binding<String> {
        Binding(get: { field(id).name }, set: { setName(id, $0) })
    }

    private func setName(_ id: UUID, _ n: String) {
        if let i = draft.fields.firstIndex(where: { $0.id == id }) { draft.fields[i].name = n }
    }

    private func concealed(_ id: UUID) -> Binding<Bool> {
        Binding(get: { field(id).concealed }, set: { c in
            if let i = draft.fields.firstIndex(where: { $0.id == id }) { draft.fields[i].concealed = c }
        })
    }

    private func removeButton(_ id: UUID) -> some View {
        Button { draft.fields.removeAll { $0.id == id } } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless).help("Remove")
    }
}

/// A concealed value: a secure field until revealed. Multi-line values are
/// only editable when revealed (a secure field is single-line and would
/// flatten them).
struct SecretEditor: View {
    let placeholder: String
    @Binding var text: String
    let revealed: Bool
    var multiline = false

    var body: some View {
        if revealed {
            if multiline {
                TextField("", text: $text, prompt: Text(placeholder), axis: .vertical)
                    .lineLimit(2 ... 8)
                    .font(.system(.body, design: .monospaced))
            } else {
                TextField("", text: $text, prompt: Text(placeholder)).font(.system(.body, design: .monospaced))
            }
        } else if multiline && text.contains("\n") {
            Text("•••••• (turn on “Show hidden values” to edit)").foregroundStyle(.secondary)
        } else {
            SecureField("", text: $text, prompt: Text(placeholder))
        }
    }
}
