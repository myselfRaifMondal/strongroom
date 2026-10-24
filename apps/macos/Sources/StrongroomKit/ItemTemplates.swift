import Foundation

/// Tags with a meaning to the app. Everything else is a user tag.
///
/// - `favourite`: the item shows under Favourites (`favorite` is accepted
///   when reading).
/// - `template:<id>`: the item was created from that template; the editor and
///   the detail view use it to lay out the fields. Other clients just show it
///   as a tag.
public enum ReservedTags {
    public static let favourite = "favourite"
    public static let templatePrefix = "template:"

    public static func isFavouriteTag(_ tag: String) -> Bool {
        let t = tag.trimmingCharacters(in: .whitespaces).lowercased()
        return t == "favourite" || t == "favorite"
    }

    public static func isTemplateTag(_ tag: String) -> Bool {
        tag.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(templatePrefix)
    }

    public static func isReserved(_ tag: String) -> Bool { isFavouriteTag(tag) || isTemplateTag(tag) }

    public static func isFavourite(_ tags: [String]) -> Bool { tags.contains(where: isFavouriteTag) }

    /// The first template id in the tags, lowercased.
    public static func templateID(in tags: [String]) -> String? {
        for t in tags where isTemplateTag(t) {
            let id = t.trimmingCharacters(in: .whitespaces).dropFirst(templatePrefix.count).lowercased()
            if !id.isEmpty { return String(id) }
        }
        return nil
    }

    public static func template(in tags: [String]) -> ItemTemplate? {
        templateID(in: tags).flatMap(ItemTemplate.named)
    }

    public static func userTags(_ tags: [String]) -> [String] { tags.filter { !isReserved($0) } }

    /// Adds or removes the favourite tag; other tags keep their order.
    public static func settingFavourite(_ tags: [String], _ on: Bool) -> [String] {
        var out = tags.filter { !isFavouriteTag($0) }
        if on { out.append(favourite) }
        return out
    }

    /// Composes the stored tag list: user tags, then template, then favourite.
    public static func compose(user: [String], templateID: String?, favourite isFav: Bool) -> [String] {
        var out: [String] = []
        for t in user where !isReserved(t) && !out.contains(t) { out.append(t) }
        if let templateID, !templateID.isEmpty { out.append(templatePrefix + templateID) }
        if isFav { out.append(favourite) }
        return out
    }
}

/// An item template: one of the six frozen kinds plus a set of named custom
/// fields and sections. No new item kinds (VTF §6.3 allows 0..=5 only); the
/// template id is recorded as the tag `template:<id>`.
public struct ItemTemplate: Identifiable, Hashable, Sendable {
    public struct Field: Hashable, Sendable {
        public let name: String
        public let concealed: Bool
        public let multiline: Bool
        public let hint: String?

        public init(_ name: String, concealed: Bool = false, multiline: Bool = false, hint: String? = nil) {
            self.name = name
            self.concealed = concealed
            self.multiline = multiline
            self.hint = hint
        }
    }

    public enum Section: String, Hashable, Sendable, CaseIterable {
        case recoveryCodes, securityQuestions, twoFactorNote, pins, seedPhrase
    }

    public let id: String
    public let name: String
    public let symbol: String
    public let kind: ItemKind
    public let fields: [Field]
    public let sections: [Section]
    /// An account at a service: offers "Add another account for …".
    public let isAccount: Bool
    public let usernameLabel: String?
    public let passwordLabel: String?
    public let warning: String?
    public let summary: String

    public var tag: String { ReservedTags.templatePrefix + id }

    public init(id: String, name: String, symbol: String, kind: ItemKind, fields: [Field] = [],
                sections: [Section] = [], isAccount: Bool = false, usernameLabel: String? = nil,
                passwordLabel: String? = nil, warning: String? = nil, summary: String) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.kind = kind
        self.fields = fields
        self.sections = sections
        self.isAccount = isAccount
        self.usernameLabel = usernameLabel
        self.passwordLabel = passwordLabel
        self.warning = warning
        self.summary = summary
    }

    public static func named(_ id: String) -> ItemTemplate? {
        let key = id.lowercased()
        return all.first { $0.id == key }
    }

    public func hasField(named name: String) -> Bool {
        fields.contains { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }

    public static let seedPhraseWarning = """
        Anyone who sees this seed phrase can take everything in the wallet, and \
        nobody can reverse it. Never type it into a website or share it with \
        "support". Keep an offline copy too: if this vault is lost, Strongroom \
        cannot recover it.
        """

    public static let all: [ItemTemplate] = [
        ItemTemplate(id: "social", name: "Social / Website Account", symbol: "person.crop.circle", kind: .login,
                     sections: [.recoveryCodes, .securityQuestions, .twoFactorNote], isAccount: true,
                     summary: "Login with recovery codes and security questions"),
        ItemTemplate(id: "email", name: "Email Account", symbol: "envelope.fill", kind: .login,
                     fields: [.init("Recovery email"), .init("Recovery phone"),
                              .init("App password", concealed: true),
                              .init("IMAP / SMTP server")],
                     sections: [.recoveryCodes, .securityQuestions, .twoFactorNote], isAccount: true,
                     usernameLabel: "Email address",
                     summary: "Mailbox login, recovery details, app passwords"),
        ItemTemplate(id: "bank", name: "Bank Account", symbol: "building.columns.fill", kind: .login,
                     fields: [.init("Bank"), .init("Account holder"),
                              .init("Account number", concealed: true),
                              .init("IFSC / routing number"), .init("Branch"),
                              .init("Account type", hint: "Savings, current, …"),
                              .init("Customer ID")],
                     sections: [.pins, .securityQuestions, .twoFactorNote], isAccount: true,
                     usernameLabel: "Net-banking user ID", passwordLabel: "Net-banking password",
                     summary: "Account number, IFSC/routing, branch, net-banking login"),
        ItemTemplate(id: "card", name: "Credit / Debit Card", symbol: "creditcard.fill", kind: .card,
                     fields: [.init("Cardholder"), .init("Number", concealed: true),
                              .init("Expiry", hint: "MM/YY"),
                              .init("Security code", concealed: true, hint: "CVV"),
                              .init("PIN", concealed: true), .init("Issuer")],
                     summary: "Number, expiry, CVV, PIN, issuer"),
        ItemTemplate(id: "wifi", name: "Wi-Fi Network", symbol: "wifi", kind: .secureNote,
                     fields: [.init("Network name (SSID)"), .init("Password", concealed: true),
                              .init("Security", hint: "WPA2, WPA3, …")],
                     summary: "Network name, password, security type"),
        ItemTemplate(id: "id-document", name: "Passport / ID / Licence", symbol: "person.text.rectangle.fill", kind: .identity,
                     fields: [.init("Document type", hint: "Passport, national ID, driving licence"),
                              .init("Full name"), .init("Number", concealed: true),
                              .init("Nationality"), .init("Date of birth"),
                              .init("Issue date"), .init("Expiry date"),
                              .init("Issuing authority"), .init("Place of issue")],
                     summary: "Document number, issue and expiry dates, authority"),
        ItemTemplate(id: "recovery-codes", name: "Recovery Codes", symbol: "lifepreserver.fill", kind: .secureNote,
                     fields: [.init("Service")], sections: [.recoveryCodes],
                     summary: "A standalone list of one-time backup codes"),
        ItemTemplate(id: "crypto-wallet", name: "Crypto Wallet", symbol: "bitcoinsign.circle.fill", kind: .secureNote,
                     fields: [.init("Wallet"), .init("Network", hint: "Bitcoin, Ethereum, …"),
                              .init("Receive address"),
                              .init("Passphrase (25th word)", concealed: true)],
                     sections: [.seedPhrase], warning: seedPhraseWarning,
                     summary: "Seed phrase stored as concealed words"),
        ItemTemplate(id: "software-licence", name: "Software Licence", symbol: "checkmark.seal.fill", kind: .secureNote,
                     fields: [.init("Product"), .init("Version"),
                              .init("Licence key", concealed: true, multiline: true),
                              .init("Licensed to"), .init("Registered email"),
                              .init("Order number"), .init("Purchase date")],
                     summary: "Licence key, owner, order details"),
        ItemTemplate(id: "server", name: "Server / SSH", symbol: "server.rack", kind: .sshKey,
                     fields: [.init("Host"), .init("Port", hint: "22"),
                              .init("Private key", concealed: true, multiline: true),
                              .init("Public key", multiline: true),
                              .init("Host key fingerprint")],
                     usernameLabel: "User", passwordLabel: "Password / key passphrase",
                     summary: "Host, user, password, SSH keys"),
        ItemTemplate(id: "api-key", name: "API Key", symbol: "chevron.left.forwardslash.chevron.right", kind: .apiKey,
                     fields: [.init("Secret", concealed: true), .init("Environment", hint: "production, staging, …"),
                              .init("Scopes"), .init("Expires")],
                     usernameLabel: "Key ID", passwordLabel: "Key",
                     summary: "Key, secret, environment, expiry"),
        ItemTemplate(id: "secure-note", name: "Secure Note", symbol: "note.text", kind: .secureNote,
                     summary: "Free text, encrypted"),
        ItemTemplate(id: "insurance", name: "Insurance Policy", symbol: "umbrella.fill", kind: .secureNote,
                     fields: [.init("Insurer"), .init("Policy number", concealed: true),
                              .init("Policy holder"), .init("Insured"), .init("Coverage"),
                              .init("Start date"), .init("Renewal date"), .init("Premium"),
                              .init("Agent / helpline")],
                     summary: "Policy number, cover, renewal date"),
        ItemTemplate(id: "medical", name: "Medical Record IDs", symbol: "cross.case.fill", kind: .secureNote,
                     fields: [.init("Patient"), .init("Health ID / member number", concealed: true),
                              .init("Insurer"), .init("Blood group"), .init("Allergies"),
                              .init("Primary doctor"), .init("Hospital record number (MRN)", concealed: true)],
                     summary: "Health IDs, insurer, doctor, allergies"),
        ItemTemplate(id: "membership", name: "Membership / Loyalty", symbol: "wallet.pass.fill", kind: .secureNote,
                     fields: [.init("Programme"), .init("Member name"), .init("Member number"),
                              .init("Tier"), .init("Expiry"), .init("PIN", concealed: true)],
                     summary: "Member number, tier, expiry"),
    ]
}

/// Icons and labels for an item from its summary or input.
public enum ItemPresentation {
    public static func symbol(kind: ItemKind, tags: [String]) -> String {
        ReservedTags.template(in: tags)?.symbol ?? kind.symbolName
    }

    public static func typeName(kind: ItemKind, tags: [String]) -> String {
        ReservedTags.template(in: tags)?.name ?? kind.displayName
    }

    /// Accounts get "Add another account for <service>".
    public static func isAccount(kind: ItemKind, tags: [String]) -> Bool {
        if let t = ReservedTags.template(in: tags) { return t.isAccount }
        return kind == .login
    }

    /// The service name for the shortcut: the last folder component, else the
    /// first URL's host, else the title.
    public static func serviceName(folder: String?, urls: [String], title: String) -> String {
        if let last = FolderPath.components(folder).last { return last }
        if let u = urls.first, let host = URL(string: u.contains("://") ? u : "https://\(u)")?.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return title
    }
}
