import Foundation
@testable import StrongroomKit
import Testing

@Suite struct RiskScoreTests {
    func x(_ s: UInt8, reused: Int = 0, age: Int = 0, totp: Bool = false, _ i: Importance = .normal) -> RiskInputs {
        RiskInputs(strength: s, reusedWith: reused, ageDays: age, hasTOTP: totp, importance: i)
    }

    @Test func components() {
        #expect([0, 1, 2, 3, 4].map { RiskScore.strengthPoints(UInt8($0)) } == [40, 30, 18, 8, 0])
        #expect([0, 1, 2, 3, 4, 9].map(RiskScore.reusePoints) == [0, 25, 30, 30, 35, 35])
        #expect([0, 179, 180, 364, 365, 729, 730, 5000].map(RiskScore.agePoints) == [0, 0, 5, 5, 10, 10, 15, 15])
        #expect(RiskScore.totpPoints(true) == 0 && RiskScore.totpPoints(false) == 5)
    }

    @Test func fixedInputs() {
        // strong, unique, new, with TOTP: nothing to do
        #expect(RiskScore.score(x(4, totp: true, .critical)) == 0)
        // strong, unique, new, no TOTP
        #expect(RiskScore.score(x(4)) == 5)
        #expect(RiskScore.score(x(4, .critical)) == 8)      // 5 × 1.5 = 7.5 -> 8
        // reused once on a critical account: High
        #expect(RiskScore.score(x(4, reused: 1, .critical)) == 45)
        #expect(RiskScore.priority(45) == .high)
        // same on a normal account: Medium
        #expect(RiskScore.score(x(4, reused: 1)) == 30)
        // low importance damps it to Low
        #expect(RiskScore.score(x(4, reused: 1, .low)) == 18)
        // weak (score 1), reused by 3 others, a year old, critical: Critical
        #expect(RiskScore.score(x(1, reused: 3, age: 400, .critical)) == 100) // (30+30+10+5)×1.5 = 112.5 -> 100
        // very weak, unique, normal
        #expect(RiskScore.score(x(0)) == 45)
        // fair (2), two years old, with TOTP, normal
        #expect(RiskScore.score(x(2, age: 800, totp: true)) == 33)
        #expect(RiskScore.score(x(0, reused: 9, age: 9999)) == 95)
    }

    @Test func priorityBands() {
        #expect(RiskScore.priority(0) == .low && RiskScore.priority(19) == .low)
        #expect(RiskScore.priority(20) == .medium && RiskScore.priority(44) == .medium)
        #expect(RiskScore.priority(69) == .high && RiskScore.priority(70) == .critical && RiskScore.priority(100) == .critical)
    }
}

@Suite struct ImportanceTests {
    @Test func tagsOverrideEverything() {
        #expect(Importance.infer(kind: .login, tags: ["priority:critical"], folder: "Gaming", urls: []) == .critical)
        #expect(Importance.infer(kind: .login, tags: ["Priority:Low"], folder: "Finance", urls: ["https://chase.com"]) == .low)
    }

    @Test func folderTemplateKindURL() {
        #expect(Importance.infer(kind: .login, tags: [], folder: "Finance/Zerodha", urls: []) == .critical)
        #expect(Importance.infer(kind: .login, tags: [], folder: "Banking", urls: []) == .critical)
        #expect(Importance.infer(kind: .login, tags: [], folder: "Email & Identity", urls: []) == .critical)
        #expect(Importance.infer(kind: .login, tags: [], folder: "Social", urls: ["https://github.com"]) == .normal, "the user's folder wins over the URL")
        #expect(Importance.infer(kind: .login, tags: ["template:bank"], folder: nil, urls: []) == .critical)
        #expect(Importance.infer(kind: .apiKey, tags: [], folder: nil, urls: []) == .critical)
        #expect(Importance.infer(kind: .login, tags: [], folder: nil, urls: ["https://accounts.google.com"]) == .critical)
        #expect(Importance.infer(kind: .login, tags: [], folder: nil, urls: ["https://signin.aws.amazon.com"]) == .critical)
        #expect(Importance.infer(kind: .login, tags: [], folder: nil, urls: ["https://instagram.com"]) == .normal)
        #expect(Importance.infer(kind: .login, tags: [], folder: nil, urls: []) == .normal)
    }
}

@Suite struct ReuseClusterTests {
    @Test func groupsOnlySharedPasswords() {
        let pairs: [(id: String, password: String)] = [("a", "same"), ("b", "unique"), ("c", "same"), ("d", ""), ("e", ""), ("f", "x"), ("g", "x"), ("h", "same")]
        #expect(ReuseClusters.compute(pairs) == [["a", "c", "h"], ["f", "g"]])
        #expect(ReuseClusters.compute([]) == [])
    }

    @Test func rankingAndClusterOrder() {
        let now: Int64 = 1_800_000_000
        let day: Int64 = 86_400
        let entries = [
            SecurityRanking.Entry(id: "game1", strength: 4, passwordChangedAt: now, hasTOTP: true, importance: .normal),
            SecurityRanking.Entry(id: "game2", strength: 4, passwordChangedAt: now, hasTOTP: true, importance: .normal),
            SecurityRanking.Entry(id: "game3", strength: 4, passwordChangedAt: now, hasTOTP: true, importance: .normal),
            SecurityRanking.Entry(id: "bank", strength: 4, passwordChangedAt: now - 10 * day, hasTOTP: false, importance: .critical),
            SecurityRanking.Entry(id: "mail", strength: 4, passwordChangedAt: now, hasTOTP: true, importance: .critical),
            SecurityRanking.Entry(id: "fine", strength: 4, passwordChangedAt: now, hasTOTP: true, importance: .normal),
            SecurityRanking.Entry(id: "weak", strength: 1, passwordChangedAt: now, hasTOTP: true, importance: .normal),
        ]
        let r = SecurityRanking.build(entries: entries, clusters: [["game1", "game2", "game3"], ["bank", "mail"]],
                                      policy: RotationSettings(), now: now)
        #expect(r.items.first?.id == "bank", "worst first")
        #expect(r.items.last?.id == "fine")
        #expect(r.item("game1")?.inputs.reusedWith == 2)
        #expect(r.item("bank")?.risk == 45 && r.item("bank")?.priority == .high)
        // The bank/mail cluster is smaller but holds critical accounts: first.
        #expect(r.clusters.map(\.itemIDs.count) == [2, 3])
        #expect(r.clusters.first?.maxImportance == .critical)
        #expect(r.sharedCount == 5)
        #expect(r.dueCount == 6, "five reused + one weak")
        #expect(r.item("fine")?.due == false)
        #expect(r.count(.high) == 1)
    }

    @Test func scoreUpdatesWhenThePasswordChanges() {
        let now: Int64 = 1_800_000_000
        let before = SecurityRanking.build(
            entries: [.init(id: "a", strength: 1, passwordChangedAt: now - 400 * 86_400, hasTOTP: false, importance: .critical),
                      .init(id: "b", strength: 1, passwordChangedAt: now, hasTOTP: false, importance: .normal)],
            clusters: [["a", "b"]], policy: RotationSettings(), now: now)
        let after = SecurityRanking.build(
            entries: [.init(id: "a", strength: 4, passwordChangedAt: now, hasTOTP: false, importance: .critical),
                      .init(id: "b", strength: 1, passwordChangedAt: now, hasTOTP: false, importance: .normal)],
            clusters: [], policy: RotationSettings(), now: now)
        #expect(before.item("a")!.risk > after.item("a")!.risk)
        #expect(after.item("a")?.due == false && after.sharedCount == 0)
    }

    @Test func passwordAgeComesFromHistory() {
        // Created day 0 with P1, changed to P2 on day 100, moved on day 300
        // (organize): the password is 200 days old on day 300, not 0.
        let d: Int64 = 86_400
        let revs: [(modifiedAt: Int64, password: String?)] = [(0, "P1"), (100 * d, "P2")]
        #expect(SecurityRanking.passwordChangedAt(current: "P2", modifiedAt: 300 * d, createdAt: 0, revisions: revs) == 100 * d)
        #expect(SecurityRanking.passwordChangedAt(current: "P1", modifiedAt: 300 * d, createdAt: 0, revisions: [(0, "P1")]) == 0)
        #expect(SecurityRanking.passwordChangedAt(current: "P3", modifiedAt: 300 * d, createdAt: 0, revisions: revs) == 300 * d)
        #expect(SecurityRanking.passwordChangedAt(current: "P1", modifiedAt: 50 * d, createdAt: 0, revisions: []) == 0)
    }
}

@Suite struct RotationTests {
    func x(_ s: UInt8, reused: Int = 0, age: Int, _ i: Importance) -> RiskInputs {
        RiskInputs(strength: s, reusedWith: reused, ageDays: age, hasTOTP: true, importance: i)
    }

    @Test func dueRules() {
        let p = RotationSettings()
        #expect(p.critical == .days90 && p.other == .days365 && p.weeklyReminder)
        #expect(!RotationPolicy.isDue(x(4, age: 89, .critical), policy: p))
        #expect(RotationPolicy.dueReasons(x(4, age: 90, .critical), policy: p) == [.old])
        #expect(!RotationPolicy.isDue(x(4, age: 364, .normal), policy: p))
        #expect(RotationPolicy.isDue(x(4, age: 365, .low), policy: p))
        #expect(RotationPolicy.dueReasons(x(1, reused: 2, age: 0, .normal), policy: p) == [.reused, .weak])
        #expect(!RotationPolicy.isDue(x(2, age: 0, .normal), policy: p), "score 2 is not weak")
        var never = p
        never.critical = .never
        never.other = .never
        #expect(!RotationPolicy.isDue(x(4, age: 10_000, .critical), policy: never))
        #expect(RotationPolicy.isDue(x(0, age: 0, .critical), policy: never))
    }

    @Test func settingsRoundTripThroughUserDefaults() throws {
        let suite = "strongroom-test-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        #expect(RotationSettings.load(d) == RotationSettings())
        var s = RotationSettings()
        s.critical = .days30
        s.other = .never
        s.weeklyReminder = false
        s.weekday = 6
        s.hour = 18
        s.minute = 30
        s.snoozedUntil = 1_900_000_000
        s.suggestFolders = false
        s.save(d)
        #expect(RotationSettings.load(d) == s)
        #expect(s.isSnoozed(now: 1_899_999_999) && !s.isSnoozed(now: 1_900_000_000))
    }

    @Test func notificationContentHasOnlyACount() {
        let secrets = ["instagram.com", "Instagram", "alpha", "me@x.io", "Social", "github", "hostinger"]
        for n in [0, 1, 2, 12, 220] {
            let text = RotationReminder.title + " " + RotationReminder.body(count: n) + " " + RotationReminder.bannerText(count: n)
            for s in secrets { #expect(!text.localizedCaseInsensitiveContains(s)) }
            // Only the count's digits appear.
            #expect(text.filter(\.isNumber) == String(repeating: String(n), count: 2))
            #expect(!text.contains("@") && !text.contains("/") && !text.contains(".com"))
        }
        #expect(RotationReminder.body(count: 12) == "Strongroom: 12 passwords are due for a change.")
        #expect(RotationReminder.body(count: 1) == "Strongroom: 1 password is due for a change.")
    }

    @Test func nextWeeklySlot() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "UTC"))
        // 2026-10-24 is a Saturday.
        let sat = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 12)))
        let mon = RotationReminder.nextSlot(onOrAfter: sat, weekday: 2, hour: 10, minute: 0, calendar: cal)
        #expect(cal.dateComponents([.year, .month, .day, .hour, .weekday], from: mon) ==
            DateComponents(year: 2026, month: 10, day: 26, hour: 10, weekday: 2))
        let exact = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 10)))
        #expect(RotationReminder.nextSlot(onOrAfter: exact, weekday: 2, hour: 10, minute: 0, calendar: cal) == exact)
    }
}
