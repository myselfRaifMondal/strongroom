import Foundation

/// How much an account matters, for ranking.
public enum Importance: Int, Comparable, Sendable, CaseIterable {
    case low = 0, normal = 1, critical = 2

    public static func < (a: Importance, b: Importance) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .low: return "Low importance"
        case .normal: return "Normal"
        case .critical: return "Critical account"
        }
    }

    /// Tags that override the inferred importance.
    public static let criticalTag = "priority:critical"
    public static let lowTag = "priority:low"

    /// Order: the `priority:critical` / `priority:low` tag; then the folder's
    /// category (first component: "Finance", "Banking", "Email & Identity",
    /// "Developer & Cloud", …); then the template (email, bank, card, server,
    /// API key, crypto wallet); then the kind (API and SSH keys); then the
    /// category of the first URL. Critical categories: Email & Identity,
    /// Finance, Developer & Cloud.
    public static func infer(kind: ItemKind, tags: [String], folder: String?, urls: [String]) -> Importance {
        let lowered = tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if lowered.contains(criticalTag) { return .critical }
        if lowered.contains(lowTag) { return .low }
        if let cat = ServiceCategory.fromFolder(folder) { return cat.isCritical ? .critical : .normal }
        if let t = ReservedTags.templateID(in: tags), ["email", "bank", "card", "server", "api-key", "crypto-wallet"].contains(t) {
            return .critical
        }
        if kind == .apiKey || kind == .sshKey { return .critical }
        for u in urls {
            if let m = ServiceCatalog.classify(url: u) { return m.category.isCritical ? .critical : .normal }
        }
        return .normal
    }
}

public enum RiskPriority: Int, Comparable, Sendable, CaseIterable {
    case low = 0, medium = 1, high = 2, critical = 3

    public static func < (a: RiskPriority, b: RiskPriority) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }
}

/// Inputs of one item's risk score. No password, no hash.
public struct RiskInputs: Equatable, Sendable {
    /// `estimate_strength` score, 0 (very weak) ... 4 (very strong).
    public var strength: UInt8
    /// How many *other* items use the same password.
    public var reusedWith: Int
    /// Days since the password last changed.
    public var ageDays: Int
    public var hasTOTP: Bool
    public var importance: Importance

    public init(strength: UInt8, reusedWith: Int, ageDays: Int, hasTOTP: Bool, importance: Importance) {
        self.strength = strength
        self.reusedWith = reusedWith
        self.ageDays = ageDays
        self.hasTOTP = hasTOTP
        self.importance = importance
    }
}

/// Risk score, 0 (fine) ... 100 (fix first).
///
///     base = strength + reuse + age + noTOTP                       (0 ... 95)
///       strength  score 0: 40, 1: 30, 2: 18, 3: 8, 4: 0
///       reuse     used by 0 others: 0, 1: 25, 2-3: 30, 4 or more: 35
///       age       < 180 days: 0, 180-364: 5, 365-729: 10, 730+: 15
///       noTOTP    no one-time code set: 5, else 0
///     risk = min(100, round(base × weight))
///       weight    critical account 1.5, normal 1.0, low importance 0.6
///
///     priority    risk >= 70 Critical, >= 45 High, >= 20 Medium, else Low
///
/// So a reused password on a critical account is at least High (45), a
/// weak password anywhere is at least Medium, and a strong, unique, recent
/// password stays Low whatever the account.
public enum RiskScore {
    public static func strengthPoints(_ s: UInt8) -> Int {
        switch s {
        case 0: return 40
        case 1: return 30
        case 2: return 18
        case 3: return 8
        default: return 0
        }
    }

    public static func reusePoints(_ others: Int) -> Int {
        switch others {
        case ..<1: return 0
        case 1: return 25
        case 2 ... 3: return 30
        default: return 35
        }
    }

    public static func agePoints(_ days: Int) -> Int {
        switch days {
        case ..<180: return 0
        case 180 ..< 365: return 5
        case 365 ..< 730: return 10
        default: return 15
        }
    }

    public static func totpPoints(_ hasTOTP: Bool) -> Int { hasTOTP ? 0 : 5 }

    public static func weight(_ i: Importance) -> Double {
        switch i {
        case .critical: return 1.5
        case .normal: return 1.0
        case .low: return 0.6
        }
    }

    public static func base(_ x: RiskInputs) -> Int {
        strengthPoints(x.strength) + reusePoints(x.reusedWith) + agePoints(x.ageDays) + totpPoints(x.hasTOTP)
    }

    public static func score(_ x: RiskInputs) -> Int {
        min(100, Int((Double(base(x)) * weight(x.importance)).rounded()))
    }

    public static func priority(_ risk: Int) -> RiskPriority {
        switch risk {
        case 70...: return .critical
        case 45 ..< 70: return .high
        case 20 ..< 45: return .medium
        default: return .low
        }
    }
}

/// Groups of items sharing one password. Passwords are compared in memory
/// and dropped when this returns; only item ids come out.
public enum ReuseClusters {
    /// Each group has two or more ids, in input order. Empty passwords are
    /// not grouped.
    public static func compute(_ pairs: [(id: String, password: String)]) -> [[String]] {
        var byPassword: [String: [String]] = [:]
        var order: [String] = []
        for p in pairs where !p.password.isEmpty {
            if byPassword[p.password] == nil { order.append(p.password) }
            byPassword[p.password, default: []].append(p.id)
        }
        let groups = order.compactMap { pw -> [String]? in
            let ids = byPassword[pw]!
            return ids.count > 1 ? ids : nil
        }
        byPassword.removeAll()
        order.removeAll()
        return groups
    }
}

/// One ranked item.
public struct RankedItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let inputs: RiskInputs
    public let risk: Int
    public let priority: RiskPriority
    /// Index into `RankingResult.clusters`, when the password is shared.
    public let cluster: Int?
    public let due: Bool
    public let dueReasons: [DueReason]
}

public struct ReuseCluster: Identifiable, Equatable, Sendable {
    public let id: Int
    public let itemIDs: [String]
    public let maxImportance: Importance
    public let maxRisk: Int
}

public struct RankingResult: Equatable, Sendable {
    /// Worst first.
    public let items: [RankedItem]
    /// Sorted by the highest importance in the cluster, then size, then risk.
    public let clusters: [ReuseCluster]

    public static let empty = RankingResult(items: [], clusters: [])

    public var dueCount: Int { items.filter(\.due).count }
    /// Accounts whose password is used on at least one other account.
    public var sharedCount: Int { clusters.reduce(0) { $0 + $1.itemIDs.count } }

    public func count(_ p: RiskPriority) -> Int { items.filter { $0.priority == p }.count }

    public func item(_ id: String) -> RankedItem? { items.first { $0.id == id } }
}

/// Builds the ranking. Inputs carry no secrets: reuse comes in as clusters
/// of ids (from `ReuseClusters`), strength as a score.
public enum SecurityRanking {
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let strength: UInt8
        /// When the current password was set (Unix seconds).
        public let passwordChangedAt: Int64
        public let hasTOTP: Bool
        public let importance: Importance

        public init(id: String, strength: UInt8, passwordChangedAt: Int64, hasTOTP: Bool, importance: Importance) {
            self.id = id
            self.strength = strength
            self.passwordChangedAt = passwordChangedAt
            self.hasTOTP = hasTOTP
            self.importance = importance
        }
    }

    public static func ageDays(since t: Int64, now: Int64) -> Int { max(0, Int((now - t) / 86_400)) }

    public static func build(entries: [Entry], clusters raw: [[String]], policy: RotationSettings, now: Int64) -> RankingResult {
        var clusterOf: [String: Int] = [:]
        for (i, ids) in raw.enumerated() { for id in ids { clusterOf[id] = i } }
        let ranked: [RankedItem] = entries.map { e in
            let cl = clusterOf[e.id]
            let inputs = RiskInputs(strength: e.strength, reusedWith: cl.map { raw[$0].count - 1 } ?? 0,
                                    ageDays: ageDays(since: e.passwordChangedAt, now: now),
                                    hasTOTP: e.hasTOTP, importance: e.importance)
            let risk = RiskScore.score(inputs)
            let reasons = RotationPolicy.dueReasons(inputs, policy: policy)
            return RankedItem(id: e.id, inputs: inputs, risk: risk, priority: RiskScore.priority(risk),
                              cluster: cl, due: !reasons.isEmpty, dueReasons: reasons)
        }
        let byID = Dictionary(uniqueKeysWithValues: ranked.map { ($0.id, $0) })
        var clusters: [ReuseCluster] = raw.enumerated().map { i, ids in
            let members = ids.compactMap { byID[$0] }
            return ReuseCluster(id: i, itemIDs: members.sorted { $0.risk > $1.risk }.map(\.id),
                                maxImportance: members.map(\.inputs.importance).max() ?? .normal,
                                maxRisk: members.map(\.risk).max() ?? 0)
        }
        clusters.sort {
            if $0.maxImportance != $1.maxImportance { return $0.maxImportance > $1.maxImportance }
            if $0.itemIDs.count != $1.itemIDs.count { return $0.itemIDs.count > $1.itemIDs.count }
            return $0.maxRisk > $1.maxRisk
        }
        let sorted = ranked.sorted {
            if $0.risk != $1.risk { return $0.risk > $1.risk }
            if $0.inputs.importance != $1.inputs.importance { return $0.inputs.importance > $1.inputs.importance }
            return $0.id < $1.id
        }
        return RankingResult(items: sorted, clusters: clusters)
    }

    /// When the current password was set: the oldest revision in the
    /// unbroken run of revisions that already had this password, else the
    /// item's creation. `modified_at` alone would reset whenever the folder
    /// or title changes (Organize by Service), so the history is used.
    /// `revisions` are (modified_at, password) pairs of `item_history`.
    public static func passwordChangedAt(current: String?, modifiedAt: Int64, createdAt: Int64,
                                         revisions: [(modifiedAt: Int64, password: String?)]) -> Int64 {
        var changed = modifiedAt
        let older = revisions.filter { $0.modifiedAt <= modifiedAt }.sorted { $0.modifiedAt > $1.modifiedAt }
        var sawDifferent = false
        for r in older {
            if r.password == current { changed = min(changed, r.modifiedAt) } else { sawDifferent = true; break }
        }
        if !sawDifferent { changed = min(changed, createdAt) }
        return changed
    }
}
