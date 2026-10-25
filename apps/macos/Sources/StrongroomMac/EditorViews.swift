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

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: DS.Space.s + 2)]

    var body: some View {
        if let draft {
            ItemEditorView(itemId: nil, draft: draft)
        } else {
            SheetScaffold(title: "New item",
                          subtitle: folder.isEmpty ? "Choose what you are storing. Each template has the right fields ready."
                                                   : "In \(folder.joined(separator: " › ")). Choose what you are storing.",
                          symbol: "plus.square.on.square", size: DS.Sheet.large) {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.s + 2) {
                        ForEach(ItemTemplate.all) { t in
                            Button { choose(ItemDraft(template: t)) } label: {
                                TemplateCard(symbol: t.symbol, name: t.name, summary: t.summary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(t.name): \(t.summary)")
                        }
                    }
                    Text("Blank item").font(.sectionTitle).foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.s + 2) {
                        ForEach(ItemKind.allCases) { k in
                            Button { choose(ItemDraft(kind: k)) } label: {
                                TemplateCard(symbol: k.symbolName, name: k.displayName, summary: "No template")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Blank \(k.displayName)")
                        }
                    }
                }
            } footer: {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
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

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s + 2) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(name).font(.callout.weight(.semibold)).lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card(minHeight: 64)
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
    /// Opened from the ranking's "Change password…".
    let changePassword: Bool
    /// Organize-by-service suggestion for a new login (folder + title).
    @State private var existing: [OrganizeItem] = []
    @State private var suggestion: OrganizeSuggestion?
    @State private var suggestedFolder: String?
    @State private var suggestedTitle: String?
    @State private var suggestionDismissed = false
    @State private var confirmPromotion = false

    init(itemId: String?, draft: ItemDraft, changePassword: Bool = false) {
        self.itemId = itemId
        self.changePassword = changePassword
        _draft = State(initialValue: draft)
    }

    private var template: ItemTemplate? { draft.template }
    private var groups: FieldGroups { FieldGroups.group(names: draft.fields.map(\.name), template: template) }

    var body: some View {
        let g = groups
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.m) {
                    editorTitle
                    Spacer(minLength: DS.Space.s)
                    editorHeaderControls
                }
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    editorTitle
                    HStack(spacing: DS.Space.m) { editorHeaderControls }
                }
            }
            .padding(.horizontal, DS.Space.xl).padding(.top, DS.Space.l).padding(.bottom, DS.Space.m)
            if changePassword {
                Callout(.info, "Change the password on the website first (Open Website), then pick a new one in the generator, use it there, and save here. Nothing is replaced until you save.")
                    .padding(.horizontal, DS.Space.xl).padding(.bottom, DS.Space.s)
            }
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
                            Label("Choose Folder", systemImage: "folder").labelStyle(.iconOnly)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Choose an existing folder")
                    }
                    if let s = suggestion, FolderPath.canonical(draft.folder) == FolderPath.canonical(s.folder) {
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars").foregroundStyle(.tint)
                            Text("Filed under \(FolderPath.components(s.folder).joined(separator: " › ")) from the website. Edit the folder to choose another.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Don't File") { dismissSuggestion() }.controlSize(.small)
                        }
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
            HStack(spacing: DS.Space.s) {
                if let t = template {
                    Label("Template: \(t.name)", systemImage: t.symbol).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: DS.Space.s)
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(itemId == nil ? "Add" : "Save") {
                    if !pendingPromotions.isEmpty {
                        confirmPromotion = true
                    } else if model.save(draft, id: itemId) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
                .help(draft.isValid ? "" : "Give the item a title first")
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.m)
        }
        .confirmationDialog(promotionTitle, isPresented: $confirmPromotion) {
            Button("Move and Retitle") {
                let promotions = pendingPromotions
                if model.save(draft, id: itemId) {
                    model.applyOrganize(promotions)
                    dismiss()
                }
            }
            Button("Save Only") { if model.save(draft, id: itemId) { dismiss() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(promotionMessage)
        }
        .onAppear {
            if itemId == nil && model.rotation.suggestFolders {
                existing = model.organizeItems()
                updateSuggestion()
            }
            if changePassword {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showGenerator = true }
            }
        }
        .onChange(of: draft.urls) { _, _ in updateSuggestion() }
        .onChange(of: draft.username) { _, _ in updateSuggestion() }
        .onChange(of: draft.kind) { _, _ in updateSuggestion() }
        .frame(minWidth: 520, idealWidth: DS.Sheet.large.width, maxWidth: 1000,
               minHeight: DS.Sheet.minHeight + 80, idealHeight: 720)
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

    // MARK: header

    private var editorTitle: some View {
        HStack(spacing: DS.Space.s + 2) {
            Image(systemName: template?.symbol ?? draft.kind.symbolName).font(.title2).foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(itemId == nil ? "New \(template?.name ?? draft.kind.displayName)" : "Edit \(template?.name ?? draft.kind.displayName)")
                .font(.sheetTitle)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var editorHeaderControls: some View {
        if WebsiteOpener.url(draft.urls) != nil {
            Button { WebsiteOpener.open(draft.urls) } label: { Label("Open Website", systemImage: "safari") }
                .controlSize(.small)
                .help("Opens the website in your browser to change the password there")
        }
        Toggle("Show hidden values", isOn: $revealSecrets).toggleStyle(.switch).controlSize(.small)
            .fixedSize()
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
                        Button { revealPassword.toggle() } label: { Label(revealPassword ? "Hide password" : "Show password", systemImage: revealPassword ? "eye.slash" : "eye").labelStyle(.iconOnly) }
                            .buttonStyle(.borderless)
                        Button { showGenerator = true } label: { Label("Generate password", systemImage: "wand.and.stars").labelStyle(.iconOnly) }
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
                LabeledContent("One-time code secret") {
                    TextField("One-time code secret", text: $draft.totp, prompt: Text("Base32 or otpauth://"))
                        .labelsHidden()
                        .font(.secret)
                }
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
                            Label("Remove website", systemImage: "minus.circle").labelStyle(.iconOnly)
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
        Button { draft.fields.removeAll { $0.id == id } } label: { Label("Remove", systemImage: "minus.circle").labelStyle(.iconOnly) }
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

// MARK: folder suggestion (new logins)

extension ItemEditorView {
    /// Promotions to offer on save: only while the suggested folder is kept.
    var pendingPromotions: [OrganizeChange] {
        guard itemId == nil, let s = suggestion, !s.promotions.isEmpty,
              FolderPath.canonical(draft.folder) == FolderPath.canonical(s.folder) else { return [] }
        return s.promotions
    }

    var promotionTitle: String {
        "\(suggestion?.service ?? "This service") now has more than one account"
    }

    var promotionMessage: String {
        let names = pendingPromotions.map { "“\($0.oldTitle)”" }.joined(separator: ", ")
        let folder = FolderPath.components(suggestion?.folder).joined(separator: " › ")
        return "Move \(names) into \(folder) too, and title each account by its username? Only the folder and title change; you can undo it from the Organize menu until you lock."
    }

    /// Prefills folder and title from the website. A value the user typed or
    /// chose is never overwritten: only an empty field, or one still holding
    /// the previous suggestion, follows the new suggestion.
    func updateSuggestion() {
        guard itemId == nil, model.rotation.suggestFolders, !suggestionDismissed, draft.kind == .login else {
            suggestion = nil
            return
        }
        let new = Organizer.suggest(urls: draft.urls, username: draft.username, title: draft.title, existing: existing)
        let folderIsOurs = draft.folder.trimmingCharacters(in: .whitespaces).isEmpty || draft.folder == suggestedFolder
        let titleIsOurs = draft.title.trimmingCharacters(in: .whitespaces).isEmpty || draft.title == suggestedTitle
        if let new {
            if folderIsOurs { draft.folder = new.folder; suggestedFolder = new.folder }
            if titleIsOurs { draft.title = new.title; suggestedTitle = new.title }
        } else {
            if folderIsOurs, suggestedFolder != nil { draft.folder = ""; suggestedFolder = nil }
            if titleIsOurs, suggestedTitle != nil { draft.title = ""; suggestedTitle = nil }
        }
        suggestion = new
    }

    func dismissSuggestion() {
        if draft.folder == suggestedFolder { draft.folder = "" }
        suggestionDismissed = true
        suggestion = nil
        suggestedFolder = nil
    }
}
