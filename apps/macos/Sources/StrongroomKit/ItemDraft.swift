import Foundation

extension ItemKind: CaseIterable, Identifiable {
    public static var allCases: [ItemKind] { [.login, .secureNote, .card, .identity, .apiKey, .sshKey] }
    public var id: String { displayName }

    public var displayName: String {
        switch self {
        case .login: return "Login"
        case .secureNote: return "Secure Note"
        case .card: return "Card"
        case .identity: return "Identity"
        case .apiKey: return "API Key"
        case .sshKey: return "SSH Key"
        }
    }

    public var symbolName: String {
        switch self {
        case .login: return "key.fill"
        case .secureNote: return "note.text"
        case .card: return "creditcard.fill"
        case .identity: return "person.text.rectangle.fill"
        case .apiKey: return "chevron.left.forwardslash.chevron.right"
        case .sshKey: return "terminal.fill"
        }
    }

    /// Which built-in fields the editor shows for this kind.
    public var usesUsername: Bool { [.login, .apiKey, .sshKey].contains(self) }
    public var usesPassword: Bool { [.login, .apiKey, .sshKey].contains(self) }
    public var usesURLs: Bool { [.login, .apiKey].contains(self) }
    public var usesTOTP: Bool { self == .login }

    public var passwordLabel: String {
        switch self {
        case .apiKey: return "Key"
        case .sshKey: return "Passphrase"
        default: return "Password"
        }
    }

    /// Kind-specific fields live in `fields` (the contract has no dedicated
    /// card / identity / SSH columns). These are the starting set.
    public var templateFields: [CustomField] {
        switch self {
        case .card:
            return [CustomField(name: "Cardholder", value: "", concealed: false),
                    CustomField(name: "Number", value: "", concealed: true),
                    CustomField(name: "Expiry", value: "", concealed: false),
                    CustomField(name: "Security code", value: "", concealed: true)]
        case .identity:
            return [CustomField(name: "Full name", value: "", concealed: false),
                    CustomField(name: "Email", value: "", concealed: false),
                    CustomField(name: "Phone", value: "", concealed: false),
                    CustomField(name: "Address", value: "", concealed: false)]
        case .sshKey:
            return [CustomField(name: "Private key", value: "", concealed: true),
                    CustomField(name: "Public key", value: "", concealed: false)]
        case .apiKey:
            return [CustomField(name: "Secret", value: "", concealed: true)]
        case .login, .secureNote:
            return []
        }
    }
}

/// Mutable editor model for `ItemInput`.
public struct ItemDraft: Equatable {
    public struct Field: Equatable, Identifiable {
        public var id = UUID()
        public var name: String
        public var value: String
        public var concealed: Bool

        public init(name: String, value: String, concealed: Bool) {
            self.name = name
            self.value = value
            self.concealed = concealed
        }
    }

    public var kind: ItemKind
    public var title = ""
    public var username = ""
    public var password = ""
    public var urls: [String] = [""]
    public var notes = ""
    public var totp = ""
    public var folder = ""
    public var tags = ""
    public var fields: [Field] = []
    public var travelSafe = false
    /// Stored as the reserved tag `favourite`; not part of `tags`.
    public var favourite = false
    /// Stored as the reserved tag `template:<id>`; not part of `tags`.
    public var templateID: String?

    public var template: ItemTemplate? { templateID.flatMap(ItemTemplate.named) }

    public init(kind: ItemKind = .login) {
        self.kind = kind
        self.fields = kind.templateFields.map { Field(name: $0.name, value: $0.value, concealed: $0.concealed) }
    }

    /// A new item from a template: its kind, its named fields (empty) and the
    /// starting rows of its sections.
    public init(template: ItemTemplate) {
        kind = template.kind
        templateID = template.id
        fields = template.fields.map { Field(name: $0.name, value: "", concealed: $0.concealed) }
        if template.sections.contains(.securityQuestions) { addSecurityQuestion() }
        if template.sections.contains(.seedPhrase) { setSeedWordCount(12) }
    }

    /// "Add another account for <service>": same kind, template, folder and
    /// websites as `item`; everything else empty.
    public static func sibling(of item: ItemInput) -> ItemDraft {
        var d: ItemDraft
        if let t = ReservedTags.template(in: item.tags) {
            d = ItemDraft(template: t)
        } else {
            d = ItemDraft(kind: item.kind)
        }
        d.folder = item.folder ?? ""
        d.urls = item.urls.isEmpty ? [""] : item.urls
        return d
    }

    /// Adds the template's named fields that an older item does not have yet.
    public mutating func ensureTemplateFields() {
        guard let template else { return }
        for f in template.fields where !fields.contains(where: { $0.name.caseInsensitiveCompare(f.name) == .orderedSame }) {
            fields.append(Field(name: f.name, value: "", concealed: f.concealed))
        }
    }

    public mutating func addSecurityQuestion() {
        let used = fields.compactMap { f -> Int? in
            switch SensitiveField.classify(f.name) {
            case let .securityQuestion(n), let .securityAnswer(n): return n
            default: return nil
            }
        }
        let n = (used.max() ?? 0) + 1
        fields.append(Field(name: SensitiveField.securityQuestionName(n), value: "", concealed: true))
        fields.append(Field(name: SensitiveField.securityAnswerName(n), value: "", concealed: true))
    }

    public mutating func addRecoveryCodes(_ codes: [String]) {
        for f in RecoveryCodes.newFields(for: codes, existingNames: fields.map(\.name)) {
            fields.append(Field(name: f.name, value: f.value, concealed: true))
        }
    }

    /// Keeps exactly `count` seed-word fields (12, 15, 18, 21 or 24), keeping
    /// words already typed.
    public mutating func setSeedWordCount(_ count: Int) {
        var words: [Int: Field] = [:]
        var rest: [Field] = []
        for f in fields {
            if case let .seedWord(n) = SensitiveField.classify(f.name) { words[n] = f } else { rest.append(f) }
        }
        let kept = (1 ... max(count, 1)).map { n in
            words[n] ?? Field(name: SensitiveField.seedWordName(n), value: "", concealed: true)
        }
        // Words beyond the new count that hold text are kept, not dropped.
        let extra = words.filter { $0.key > count && !$0.value.value.isEmpty }.sorted { $0.key < $1.key }.map(\.value)
        fields = rest + kept + extra
    }

    public var seedWordCount: Int {
        fields.filter { if case .seedWord = SensitiveField.classify($0.name) { return true } else { return false } }.count
    }

    public init(_ input: ItemInput) {
        kind = input.kind
        title = input.title
        username = input.username ?? ""
        password = input.password ?? ""
        urls = input.urls.isEmpty ? [""] : input.urls
        notes = input.notes ?? ""
        totp = input.totp ?? ""
        folder = input.folder ?? ""
        tags = ReservedTags.userTags(input.tags).joined(separator: ", ")
        favourite = ReservedTags.isFavourite(input.tags)
        templateID = ReservedTags.templateID(in: input.tags)
        fields = input.fields.map { Field(name: $0.name, value: $0.value, concealed: $0.concealed) }
        travelSafe = input.travelSafe
    }

    /// Switching kind adds the new kind's template fields that are missing,
    /// and never drops data the user typed.
    public mutating func changeKind(to newKind: ItemKind) {
        kind = newKind
        for t in newKind.templateFields where !fields.contains(where: { $0.name == t.name }) {
            fields.append(Field(name: t.name, value: t.value, concealed: t.concealed))
        }
    }

    public var isValid: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    public func toInput() -> ItemInput {
        func opt(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : s
        }
        let userTags = tags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tagList = ReservedTags.compose(user: userTags, templateID: templateID, favourite: favourite)
        let template = self.template
        // Empty template fields and empty section rows are placeholders the
        // editor recreates; they are not stored.
        func isPlaceholder(_ f: Field) -> Bool {
            guard f.value.isEmpty else { return false }
            if template?.hasField(named: f.name) == true { return true }
            return SensitiveField.classify(f.name) != .other
        }
        return ItemInput(
            kind: kind,
            title: title.trimmingCharacters(in: .whitespaces),
            username: opt(username),
            password: password.isEmpty ? nil : password,
            urls: urls.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            notes: opt(notes),
            totp: opt(totp).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            folder: FolderPath.canonical(folder),
            tags: tagList,
            fields: fields
                .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty || !$0.value.isEmpty }
                .filter { !isPlaceholder($0) }
                .map { CustomField(name: $0.name.trimmingCharacters(in: .whitespaces), value: $0.value, concealed: $0.concealed) },
            travelSafe: travelSafe)
    }
}
