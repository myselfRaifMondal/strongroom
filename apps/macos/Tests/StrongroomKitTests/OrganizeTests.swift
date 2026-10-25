import Foundation
@testable import StrongroomKit
import Testing

@Suite struct DomainNameTests {
    @Test func hosts() {
        #expect(DomainName.host("https://www.Instagram.com/accounts/login/") == "www.instagram.com")
        #expect(DomainName.host("instagram.com") == "instagram.com")
        #expect(DomainName.host("instagram.com/path?q=1") == "instagram.com")
        #expect(DomainName.host("https://user@mail.example.com:8443/x") == "mail.example.com")
        #expect(DomainName.host("https://example.com./") == "example.com")
        #expect(DomainName.host("") == nil)
        #expect(DomainName.host("   ") == nil)
        #expect(DomainName.host("android://abc@com.example.app") == nil, "app links are not websites")
    }

    @Test func collapsesSubdomains() {
        #expect(DomainName.registrable(url: "https://mail.hostinger.com") == "hostinger.com")
        #expect(DomainName.registrable(url: "https://hpanel.hostinger.com/login") == "hostinger.com")
        #expect(DomainName.registrable(url: "a.b.c.example.org") == "example.org")
        #expect(DomainName.registrable(url: "example.org") == "example.org")
    }

    @Test func multiLabelSuffixes() {
        #expect(DomainName.registrable(url: "https://www.irctc.co.in/nget") == "irctc.co.in")
        #expect(DomainName.registrable(url: "https://retail.onlinesbi.sbi.co.in") == "sbi.co.in")
        #expect(DomainName.registrable(url: "https://www.bbc.co.uk") == "bbc.co.uk")
        #expect(DomainName.registrable(url: "login.amazon.co.uk") == "amazon.co.uk")
        #expect(DomainName.registrable(url: "co.uk") == "co.uk")
        #expect(DomainName.registrable(url: "shop.example.com.au") == "example.com.au")
        #expect(DomainName.registrable(url: "me.github.io") == "me.github.io", "hosting suffixes keep the owner")
    }

    @Test func ipAndSingleLabel() {
        #expect(DomainName.registrable(url: "http://192.168.1.1/admin") == "192.168.1.1")
        #expect(DomainName.registrable(url: "http://localhost:3000") == "localhost")
    }
}

@Suite struct ServiceClassificationTests {
    func m(_ url: String) -> ServiceMatch { ServiceCatalog.classify(url: url)! }

    @Test func wellKnownServices() {
        #expect(m("https://www.instagram.com/").service == "Instagram")
        #expect(m("https://www.instagram.com/").category == .social)
        #expect(m("twitter.com").service == m("https://x.com").service)
        #expect(m("https://accounts.google.com/signin").category == .emailIdentity)
        #expect(m("https://login.live.com").service == "Microsoft")
        #expect(m("https://appleid.apple.com").service == "Apple Account")
        #expect(m("https://www.interactivebrokers.com").category == .finance)
        #expect(m("https://kite.zerodha.com").service == "Zerodha")
        #expect(m("https://trade.angelone.in").service == "Angel One")
        #expect(m("https://www.angelbroking.com").service == "Angel One")
        #expect(m("https://dashboard.stripe.com").category == .finance)
        #expect(m("https://github.com/login").category == .developerCloud)
        #expect(m("https://huggingface.co").service == "Hugging Face")
        #expect(m("https://www.irctc.co.in").category == .shoppingTravel)
        #expect(m("https://auth.riotgames.com").category == .gaming)
        #expect(m("https://www.ssrn.com").category == .learning)
        #expect(m("https://www.odoo.com/web/login").category == .work)
        #expect(m("https://hpanel.hostinger.com").category == .hosting)
        #expect(m("https://mail.hostinger.com").service == "Hostinger", "subdomains collapse to the service")
    }

    @Test func awsIsNotAmazonRetail() {
        #expect(m("https://signin.aws.amazon.com/console").service == "AWS")
        #expect(m("https://us-east-1.console.aws.amazon.com").service == "AWS")
        #expect(m("https://signin.aws").service == "AWS")
        #expect(m("https://s3.amazonaws.com").service == "AWS")
        #expect(m("https://www.amazon.com").service == "Amazon")
        #expect(m("https://www.amazon.in").service == "Amazon", "brand under another suffix")
        #expect(m("https://www.amazon.co.uk/ap/signin").service == "Amazon")
        #expect(m("https://www.amazon.in").category == .shoppingTravel)
    }

    @Test func specificSubdomainBeatsParent() {
        #expect(m("https://scholar.google.com").service == "Google Scholar")
        #expect(m("https://console.cloud.google.com").service == "Google Cloud")
        #expect(m("https://mail.google.com").service == "Google")
    }

    @Test func multiTenantKeepsTenant() {
        let w = m("https://acme.wd5.myworkdayjobs.com/en-US/careers")
        #expect(w.service == "Workday" && w.category == .careers && w.tenant == "acme")
        #expect(m("https://globex.taleo.net/careersection").tenant == "globex")
        #expect(m("https://www.myworkdayjobs.com").tenant == nil)
        #expect(m("https://uni.instructure.com").service == "Canvas")
    }

    @Test func unknownDomainsAreOther() {
        let u = m("https://portal.some-local-gym.co.in/login")
        #expect(u.category == .other && !u.known)
        #expect(u.service == "some-local-gym.co.in")
        #expect(ServiceCatalog.classify(url: "") == nil)
    }

    @Test func catalogIsWellFormed() {
        var seen = Set<String>()
        for s in ServiceCatalog.services {
            #expect(!s.name.contains("/"), "\(s.name) cannot be a folder component")
            #expect(s.category != .other)
            for d in s.domains {
                #expect(d == d.lowercased())
                #expect(!seen.contains(d), "duplicate domain \(d)")
                seen.insert(d)
            }
        }
    }
}

private func login(_ id: String, _ title: String, user: String?, url: String?, folder: String? = nil) -> OrganizeItem {
    OrganizeItem(id: id, kind: .login, title: title, username: user, urls: url.map { [$0] } ?? [], folder: folder)
}

@Suite struct OrganizePlanTests {
    let items: [OrganizeItem] = [
        login("1", "instagram.com (alpha)", user: "alpha", url: "https://instagram.com"),
        login("2", "instagram.com (beta)", user: "beta", url: "https://www.instagram.com/"),
        login("3", "github.com (dev)", user: "dev", url: "https://github.com"),
        login("4", "mail.hostinger.com (me@x.io)", user: "me@x.io", url: "https://mail.hostinger.com"),
        login("5", "hpanel.hostinger.com (me@x.io)", user: "admin", url: "https://hpanel.hostinger.com"),
        login("6", "Router", user: "admin", url: nil),
        login("7", "smallsite.example (z)", user: "z", url: "https://smallsite.example"),
        login("8", "Already filed", user: "q", url: "https://reddit.com", folder: "Mine"),
        OrganizeItem(id: "9", kind: .secureNote, title: "Note", username: nil, urls: ["https://instagram.com"], folder: nil),
    ]

    func change(_ id: String, _ c: [OrganizeChange]) -> OrganizeChange? { c.first { $0.id == id } }

    @Test func multiAccountServicesGetASubfolderAndUsernameTitles() throws {
        let plan = Organizer.plan(items: items, scope: .unfiled)
        let a = try #require(change("1", plan))
        #expect(a.newFolder == "Social/Instagram" && a.newTitle == "alpha")
        #expect(change("2", plan)?.newFolder == "Social/Instagram")
        #expect(change("2", plan)?.newTitle == "beta")
        // Two Hostinger subdomains are one service with two accounts.
        #expect(change("4", plan)?.newFolder == "Hosting & Domains/Hostinger")
        #expect(change("5", plan)?.newTitle == "admin")
    }

    @Test func singleAccountServicesStayInTheCategory() {
        let plan = Organizer.plan(items: items, scope: .unfiled)
        #expect(change("3", plan)?.newFolder == "Developer & Cloud")
        #expect(change("3", plan)?.newTitle == "GitHub (dev)")
        #expect(change("7", plan)?.newFolder == "Other")
        #expect(change("7", plan)?.newTitle == "smallsite.example (z)")
    }

    @Test func noURLGoesToOtherUnchanged() {
        let plan = Organizer.plan(items: items, scope: .unfiled)
        #expect(change("6", plan)?.newFolder == "Other")
        #expect(change("6", plan)?.newTitle == "Router")
    }

    @Test func scopeAndKinds() {
        let unfiled = Organizer.plan(items: items, scope: .unfiled)
        #expect(change("8", unfiled) == nil, "items with a folder are left alone by default")
        #expect(change("9", unfiled) == nil, "only logins are organized")
        let all = Organizer.plan(items: items, scope: .all)
        #expect(change("8", all)?.newFolder == "Social")
        #expect(change("8", all)?.newTitle == "Reddit (q)")
        #expect(Organizer.plan(items: items, scope: .ids(["3"])).map(\.id) == ["3"])
    }

    @Test func unknownDomainWithTwoAccountsGetsOtherSlashDomain() {
        let two = [login("a", "x", user: "u1", url: "https://a.unknown-shop.co.uk"),
                   login("b", "y", user: "u2", url: "https://unknown-shop.co.uk/login")]
        let plan = Organizer.plan(items: two, scope: .unfiled)
        #expect(plan.allSatisfy { $0.newFolder == "Other/unknown-shop.co.uk" })
        #expect(Set(plan.map(\.newTitle)) == ["u1", "u2"])
    }

    @Test func untickingChangesTheCount() {
        // Untick one Instagram account: the other becomes a single account.
        let plan = Organizer.plan(items: items, scope: .unfiled, excludedIDs: ["2"])
        #expect(change("2", plan) == nil)
        #expect(change("1", plan)?.newFolder == "Social")
        #expect(change("1", plan)?.newTitle == "Instagram (alpha)")
        let noSocial = Organizer.plan(items: items, scope: .unfiled, excludedCategories: [.social])
        #expect(change("1", noSocial) == nil && change("3", noSocial) != nil)
    }

    @Test func nothingWhenAlreadyOrganized() {
        let done = [login("1", "GitHub (dev)", user: "dev", url: "https://github.com", folder: "Developer & Cloud")]
        #expect(Organizer.plan(items: done, scope: .all).isEmpty)
    }

    @Test func duplicateTitlesAreNumbered() {
        let dup = [login("a", "x", user: "same", url: "https://github.com"),
                   login("b", "y", user: "same", url: "https://github.com")]
        let titles = Organizer.plan(items: dup, scope: .unfiled).map(\.newTitle).sorted()
        #expect(titles == ["same", "same 2"])
    }

    @Test func multiTenantTitlesKeepTheEmployer() {
        let jobs = [login("a", "x", user: "me@x.io", url: "https://acme.wd5.myworkdayjobs.com"),
                    login("b", "y", user: "me@x.io", url: "https://globex.wd1.myworkdayjobs.com")]
        let plan = Organizer.plan(items: jobs, scope: .unfiled)
        #expect(Set(plan.map(\.newTitle)) == ["acme (me@x.io)", "globex (me@x.io)"])
        #expect(plan.allSatisfy { $0.newFolder == "Careers/Workday" })
        let one = Organizer.plan(items: [jobs[0]], scope: .unfiled)
        #expect(one.first?.newTitle == "Workday – acme (me@x.io)")
    }

    @Test func proposedTreeCounts() throws {
        let tree = Organizer.proposedTree(Organizer.plan(items: items, scope: .unfiled))
        #expect(FolderTree.find(["Social", "Instagram"], in: tree)?.totalCount == 2)
        #expect(FolderTree.find(["Other"], in: tree)?.totalCount == 2)
    }
}

@Suite struct OrganizeSuggestionTests {
    @Test func suggestsFolderAndTitleForANewItem() throws {
        let s = try #require(Organizer.suggest(urls: ["https://www.instagram.com"], username: "alpha", title: "", existing: []))
        #expect(s.folder == "Social" && s.title == "Instagram (alpha)" && s.promotions.isEmpty)
        #expect(Organizer.suggest(urls: [], username: "x", title: "t", existing: []) == nil)
        #expect(Organizer.suggest(urls: [""], username: "x", title: "t", existing: []) == nil)
    }

    @Test func secondAccountPromotesTheFirst() throws {
        let existing = [login("old", "Instagram (alpha)", user: "alpha", url: "https://instagram.com", folder: "Social")]
        let s = try #require(Organizer.suggest(urls: ["instagram.com"], username: "beta", title: "", existing: existing))
        #expect(s.folder == "Social/Instagram" && s.title == "beta")
        let p = try #require(s.promotions.first)
        #expect(s.promotions.count == 1)
        #expect(p.id == "old" && p.isPromotion)
        #expect(p.newFolder == "Social/Instagram" && p.newTitle == "alpha")
        #expect(p.oldFolder == "Social" && p.oldTitle == "Instagram (alpha)")
    }

    @Test func thirdAccountNeedsNoPromotion() throws {
        let existing = [login("a", "alpha", user: "alpha", url: "https://instagram.com", folder: "Social/Instagram"),
                        login("b", "beta", user: "beta", url: "https://instagram.com", folder: "Social/Instagram")]
        let s = try #require(Organizer.suggest(urls: ["instagram.com"], username: "gamma", title: "", existing: existing))
        #expect(s.folder == "Social/Instagram" && s.title == "gamma" && s.promotions.isEmpty)
    }

    @Test func itemsFiledElsewhereAreNotPromoted() throws {
        // The user filed this Instagram account by hand under "Work": leave it.
        let existing = [login("a", "Insta work", user: "alpha", url: "https://instagram.com", folder: "Work")]
        let s = try #require(Organizer.suggest(urls: ["instagram.com"], username: "beta", title: "", existing: existing))
        #expect(s.folder == "Social" && s.title == "Instagram (beta)" && s.promotions.isEmpty)
    }

    @Test func importPreviewIsLimitedToNewItems() {
        let existing = [login("old", "Instagram (alpha)", user: "alpha", url: "https://instagram.com", folder: "Social"),
                        login("keep", "unfiled", user: "k", url: "https://github.com")]
        let imported = [login("n1", "instagram.com (beta)", user: "beta", url: "https://instagram.com")]
        let plan = Organizer.plan(items: existing + imported, scope: .ids(["n1"]))
        #expect(Set(plan.map(\.id)) == ["n1", "old"], "unfiled items not in the import are not touched")
        #expect(plan.first { $0.id == "old" }?.isPromotion == true)
    }
}

@Suite struct OrganizeUndoTests {
    @Test func recordKeepsTheFirstState() {
        var u = OrganizeUndo()
        u.record(id: "a", folder: nil, title: "t1")
        u.record(id: "a", folder: "Social", title: "t2")
        #expect(u.entries["a"] == .init(folder: nil, title: "t1"))
        var v = OrganizeUndo()
        v.record(id: "a", folder: "X", title: "t3")
        v.record(id: "b", folder: "Y", title: "t4")
        u.merge(v)
        #expect(u.entries["a"]?.title == "t1" && u.entries["b"]?.folder == "Y" && u.count == 2)
    }

    /// Applies a plan to a real vault and undoes it: every item is byte-for-byte
    /// its original input again (password, fields, tags untouched throughout).
    @Test func undoRestoresExactly() async throws {
        let sk = generateSecretKey()
        guard !sk.isEmpty else { return } // core returned an empty Secret Key
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("strongroom-organize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try await CoreThread.run {
            let now = Clock.now()
            let v = try Vault.create(path: base.appendingPathComponent("o.srdb").path, password: "test-password-1", secretKey: sk, now: now)
            defer { v.lock() }
            func add(_ title: String, _ user: String, _ url: String, folder: String? = nil) throws -> String {
                try v.addItem(input: ItemInput(kind: .login, title: title, username: user, password: "pw-\(title)",
                                               urls: [url], notes: "n", totp: nil, folder: folder, tags: ["t"],
                                               fields: [CustomField(name: "Recovery code 1", value: "c", concealed: true)],
                                               travelSafe: false), now: now)
            }
            let ids = [try add("instagram.com (a)", "a", "https://instagram.com"),
                       try add("instagram.com (b)", "b", "https://instagram.com"),
                       try add("github.com (d)", "d", "https://github.com"),
                       try add("Filed", "f", "https://reddit.com", folder: "Mine")]
            let before = try ids.map { try v.getItem(id: $0).data }
            let plan = Organizer.plan(items: try VaultAnalysis.organizeItems(v), scope: .unfiled)
            #expect(plan.count == 3)
            let (undo, failed) = Organizer.apply(plan, vault: v, now: now + 10)
            #expect(failed == 0 && undo.count == 3)
            let after = try ids.map { try v.getItem(id: $0).data }
            #expect(after[0].folder == "Social/Instagram" && after[0].title == "a")
            #expect(after[2].folder == "Developer & Cloud" && after[2].title == "GitHub (d)")
            for (b, a) in zip(before, after) {
                #expect(a.password == b.password && a.fields == b.fields && a.tags == b.tags && a.urls == b.urls && a.notes == b.notes)
            }
            #expect(after[3] == before[3])
            let (restored, undoFailed) = Organizer.undo(undo, vault: v, now: now + 20)
            #expect(restored == 3 && undoFailed == 0)
            let back = try ids.map { try v.getItem(id: $0).data }
            #expect(back == before)
        }
    }
}
