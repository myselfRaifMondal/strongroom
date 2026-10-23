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

    public init(kind: ItemKind = .login) {
        self.kind = kind
        self.fields = kind.templateFields.map { Field(name: $0.name, value: $0.value, concealed: $0.concealed) }
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
        tags = input.tags.joined(separator: ", ")
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
        let tagList = tags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ItemInput(
            kind: kind,
            title: title.trimmingCharacters(in: .whitespaces),
            username: opt(username),
            password: password.isEmpty ? nil : password,
            urls: urls.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            notes: opt(notes),
            totp: opt(totp).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            folder: opt(folder).map { $0.trimmingCharacters(in: .whitespaces) },
            tags: tagList,
            fields: fields
                .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty || !$0.value.isEmpty }
                .map { CustomField(name: $0.name.trimmingCharacters(in: .whitespaces), value: $0.value, concealed: $0.concealed) },
            travelSafe: travelSafe)
    }
}
