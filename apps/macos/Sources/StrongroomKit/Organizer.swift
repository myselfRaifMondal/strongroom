import Foundation

/// What the organizer needs to know about an item. Built from `get_item`;
/// it carries no password or other secret.
public struct OrganizeItem: Equatable, Sendable {
    public let id: String
    public let kind: ItemKind
    public let title: String
    public let username: String?
    public let urls: [String]
    public let folder: String?

    public init(id: String, kind: ItemKind, title: String, username: String?, urls: [String], folder: String?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.username = username
        self.urls = urls
        self.folder = folder
    }

    public init(id: String, input: ItemInput) {
        self.init(id: id, kind: input.kind, title: input.title, username: input.username, urls: input.urls, folder: input.folder)
    }
}

/// One proposed change. Only `folder` and `title` ever change.
public struct OrganizeChange: Identifiable, Equatable, Sendable {
    public let id: String
    public let oldFolder: String?
    public let oldTitle: String
    public let newFolder: String
    public let newTitle: String
    public let category: ServiceCategory
    /// Service display name; "" for items without a URL.
    public let service: String
    /// An item outside the requested scope that moves because its service
    /// gained a second account ("<Category>" -> "<Category>/<Service>").
    public let isPromotion: Bool
}

/// Which items "Organize by Service" looks at.
public enum OrganizeScope: Equatable, Sendable {
    /// Items without a folder (the default).
    case unfiled
    /// Every login.
    case all
    /// Specific items (newly imported ones, or a new item in the editor).
    case ids(Set<String>)
}

/// The editor's suggestion for a new item.
public struct OrganizeSuggestion: Equatable, Sendable {
    public let folder: String
    public let title: String
    public let category: ServiceCategory
    public let service: String
    /// Existing single-account items that should move into
    /// "<Category>/<Service>" now that the service has two accounts.
    public let promotions: [OrganizeChange]
}

/// The previous folder and title of every item a session's organize touched.
/// Kept in memory only and dropped on lock.
public struct OrganizeUndo: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let folder: String?
        public let title: String
    }

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// Records the state before a change. An item organized twice keeps its
    /// original (first) state, so one undo goes all the way back.
    public mutating func record(id: String, folder: String?, title: String) {
        if entries[id] == nil { entries[id] = Entry(folder: folder, title: title) }
    }

    public mutating func merge(_ other: OrganizeUndo) {
        for (id, e) in other.entries where entries[id] == nil { entries[id] = e }
    }
}

/// "Organize by Service". Rules:
/// - Logins only. Each is classified by the first URL that has a host
///   (`ServiceCatalog.classify`). Logins without one go to "Other" with the
///   title unchanged.
/// - Accounts of a service = the logins being organized plus logins already
///   filed under that service ("<Category>" or "<Category>/<Service>").
/// - More than one account: folder "<Category>/<Service>", title = username
///   (multi-tenant services: "<tenant> (<username>)"). Already-filed single
///   accounts in "<Category>" are promoted the same way.
/// - Exactly one account: folder "<Category>", title "<Service> (<username>)".
///   Unknown sites use "Other" as category and the registrable domain as
///   service, so several accounts on one unknown site end up in
///   "Other/<domain>".
/// - Nothing else about an item changes.
public enum Organizer {
    public static let noURLFolder = ServiceCategory.other.folderName

    /// The service of an item: the first URL that classifies.
    public static func match(_ item: OrganizeItem) -> ServiceMatch? {
        for u in item.urls { if let m = ServiceCatalog.classify(url: u) { return m } }
        return nil
    }

    static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        // A folder component cannot hold "/", and titles stay one line.
        return t.replacingOccurrences(of: "\n", with: " ")
    }

    static func serviceFolderName(_ m: ServiceMatch) -> String {
        m.service.replacingOccurrences(of: "/", with: "-")
    }

    /// True when `folder` is where this service's accounts are filed.
    static func isFiledUnder(_ folder: String?, _ m: ServiceMatch) -> Bool {
        let c = FolderPath.components(folder)
        return c == [m.category.folderName] || c == [m.category.folderName, serviceFolderName(m)]
    }

    static func singleTitle(_ m: ServiceMatch, username: String?, fallback: String) -> String {
        let name = m.tenant.map { "\(m.service) – \($0)" } ?? m.service
        if let u = clean(username) { return "\(name) (\(u))" }
        return name
    }

    static func multiTitle(_ m: ServiceMatch, username: String?, fallback: String) -> String {
        let u = clean(username)
        if let t = m.tenant { return u.map { "\(t) (\($0))" } ?? t }
        return u ?? fallback
    }

    /// The proposed changes. `excludedCategories` and `excludedIDs` are what
    /// the user unticked in the preview: those items stay where they are and
    /// do not count as accounts of their service.
    public static func plan(items: [OrganizeItem], scope: OrganizeScope,
                            excludedCategories: Set<ServiceCategory> = [],
                            excludedIDs: Set<String> = []) -> [OrganizeChange] {
        let logins = items.filter { $0.kind == .login }
        func inScope(_ i: OrganizeItem) -> Bool {
            switch scope {
            case .unfiled: return FolderPath.components(i.folder).isEmpty
            case .all: return true
            case let .ids(ids): return ids.contains(i.id)
            }
        }
        var changes: [OrganizeChange] = []
        // Group candidates (to organize) and already-filed accounts by service.
        struct Group { var match: ServiceMatch; var candidates: [OrganizeItem] = []; var filed: [OrganizeItem] = [] }
        var groups: [String: Group] = [:]
        var order: [String] = []
        for item in logins {
            let m = match(item)
            let candidate = inScope(item) && !excludedIDs.contains(item.id)
            if let m {
                if excludedCategories.contains(m.category) { continue }
                if candidate {
                    if groups[m.key] == nil { groups[m.key] = Group(match: m); order.append(m.key) }
                    groups[m.key]!.candidates.append(item)
                } else if isFiledUnder(item.folder, m) {
                    if groups[m.key] == nil { groups[m.key] = Group(match: m); order.append(m.key) }
                    groups[m.key]!.filed.append(item)
                }
            } else if candidate, !excludedCategories.contains(.other) {
                // No URL: "Other", title unchanged.
                if FolderPath.canonical(item.folder) != noURLFolder {
                    changes.append(OrganizeChange(id: item.id, oldFolder: item.folder, oldTitle: item.title,
                                                  newFolder: noURLFolder, newTitle: item.title,
                                                  category: .other, service: "", isPromotion: false))
                }
            }
        }
        for key in order {
            let g = groups[key]!
            guard !g.candidates.isEmpty else { continue }
            let m = g.match
            let members = g.candidates + g.filed
            let multi = members.count > 1
            let folder = multi ? m.category.folderName + "/" + serviceFolderName(m) : m.category.folderName
            var used: [String: Int] = [:]
            for item in members {
                // Each member uses the match of its own URL for the tenant.
                let own = match(item) ?? m
                var title = multi ? multiTitle(own, username: item.username, fallback: item.title)
                                  : singleTitle(own, username: item.username, fallback: item.title)
                let n = (used[title] ?? 0) + 1
                used[title] = n
                if n > 1 { title += " \(n)" }
                let isCandidate = g.candidates.contains { $0.id == item.id }
                // Unticked items still count as accounts but are not touched.
                if excludedIDs.contains(item.id) { continue }
                guard FolderPath.canonical(item.folder) != folder || item.title != title else { continue }
                changes.append(OrganizeChange(id: item.id, oldFolder: item.folder, oldTitle: item.title,
                                              newFolder: folder, newTitle: title, category: m.category,
                                              service: m.service, isPromotion: !isCandidate))
            }
        }
        return changes
    }

    /// Folder and title for a new item being added (editor), plus the
    /// promotions its arrival implies. nil when it has no usable URL.
    public static func suggest(urls: [String], username: String?, title: String,
                               existing: [OrganizeItem]) -> OrganizeSuggestion? {
        let newID = "\u{0}new-item"
        let draft = OrganizeItem(id: newID, kind: .login, title: title, username: username, urls: urls, folder: nil)
        guard let m = match(draft) else { return nil }
        let changes = plan(items: existing.filter { $0.id != newID } + [draft], scope: .ids([newID]))
        let own = changes.first { $0.id == newID }
        let folder = own?.newFolder ?? m.category.folderName
        let newTitle = own?.newTitle ?? title
        return OrganizeSuggestion(folder: folder, title: newTitle, category: m.category, service: m.service,
                                  promotions: changes.filter { $0.id != newID })
    }

    /// Proposed tree: folder -> number of items that will be in it after the
    /// change (only items the plan moves).
    public static func proposedTree(_ changes: [OrganizeChange]) -> [FolderNode] {
        FolderTree.build(folders: changes.map(\.newFolder))
    }

    /// Applies `changes` with `update_item`, touching only `folder` and
    /// `title`. Returns the undo record of the items it changed and the
    /// number that failed.
    public static func apply(_ changes: [OrganizeChange], vault: Vault, now: Int64) -> (undo: OrganizeUndo, failed: Int) {
        var undo = OrganizeUndo()
        var failed = 0
        for c in changes {
            do {
                var input = try vault.getItem(id: c.id).data
                let before = (input.folder, input.title)
                input.folder = FolderPath.canonical(c.newFolder)
                input.title = c.newTitle
                if input.folder != before.0 || input.title != before.1 {
                    try vault.updateItem(id: c.id, input: input, now: now)
                    undo.record(id: c.id, folder: before.0, title: before.1)
                }
            } catch {
                failed += 1
            }
        }
        return (undo, failed)
    }

    /// Restores every recorded folder and title. Other fields (a password
    /// changed since) are left as they are now.
    public static func undo(_ record: OrganizeUndo, vault: Vault, now: Int64) -> (restored: Int, failed: Int) {
        var restored = 0, failed = 0
        for (id, e) in record.entries.sorted(by: { $0.key < $1.key }) {
            do {
                var input = try vault.getItem(id: id).data
                if input.folder == e.folder && input.title == e.title { restored += 1; continue }
                input.folder = e.folder
                input.title = e.title
                try vault.updateItem(id: id, input: input, now: now)
                restored += 1
            } catch {
                failed += 1
            }
        }
        return (restored, failed)
    }
}
