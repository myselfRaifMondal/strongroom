import Foundation

/// Reads an unlocked vault into the inputs of Organize and the ranking.
/// Passwords are read with `get_item`/`item_history`, compared and scored in
/// this call, and not kept: nothing here is stored or logged.
public enum VaultAnalysis {
    public static func organizeItems(_ vault: Vault) throws -> [OrganizeItem] {
        try vault.search(query: "", folder: nil, tag: nil).compactMap { s in
            guard let item = try? vault.getItem(id: s.id) else { return nil }
            return OrganizeItem(id: s.id, input: item.data)
        }
    }

    /// Strength scores keyed by item id and the `modified_at` they were
    /// computed for, so unchanged items are not re-estimated on every reload.
    /// Holds no password. The app clears it on lock.
    public struct StrengthCache: Sendable {
        var scores: [String: (modifiedAt: Int64, score: UInt8)] = [:]
        public init() {}
        public mutating func clear() { scores.removeAll() }
    }

    public static func ranking(_ vault: Vault, policy: RotationSettings, now: Int64,
                               cache: inout StrengthCache) throws -> RankingResult {
        var entries: [SecurityRanking.Entry] = []
        var pairs: [(id: String, password: String)] = []
        var live = Set<String>()
        for s in try vault.search(query: "", folder: nil, tag: nil) {
            guard let item = try? vault.getItem(id: s.id), let pw = item.data.password, !pw.isEmpty else { continue }
            live.insert(s.id)
            pairs.append((s.id, pw))
            let score: UInt8
            if let c = cache.scores[s.id], c.modifiedAt == item.modifiedAt {
                score = c.score
            } else {
                score = estimateStrength(password: pw).score
                cache.scores[s.id] = (item.modifiedAt, score)
            }
            let revisions = ((try? vault.itemHistory(id: s.id)) ?? []).map { (modifiedAt: $0.modifiedAt, password: $0.data.password) }
            let changed = SecurityRanking.passwordChangedAt(current: pw, modifiedAt: item.modifiedAt,
                                                            createdAt: item.createdAt, revisions: revisions)
            let hasTOTP = !(item.data.totp ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            entries.append(SecurityRanking.Entry(
                id: s.id, strength: score, passwordChangedAt: changed, hasTOTP: hasTOTP,
                importance: Importance.infer(kind: item.data.kind, tags: item.data.tags, folder: item.data.folder, urls: item.data.urls)))
        }
        let clusters = ReuseClusters.compute(pairs)
        pairs.removeAll()
        cache.scores = cache.scores.filter { live.contains($0.key) }
        return SecurityRanking.build(entries: entries, clusters: clusters, policy: policy, now: now)
    }
}
