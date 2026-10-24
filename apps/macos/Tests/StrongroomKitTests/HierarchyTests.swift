import Foundation
@testable import StrongroomKit
import Testing

@Suite struct FolderPathTests {
    @Test func parsesBothSeparatorsAndSpaces() {
        #expect(FolderPath.components("Social/Instagram") == ["Social", "Instagram"])
        #expect(FolderPath.components("Social / Instagram") == ["Social", "Instagram"])
        #expect(FolderPath.components("  Social//Instagram/ ") == ["Social", "Instagram"])
        #expect(FolderPath.components("Banking") == ["Banking"])
        #expect(FolderPath.components(nil) == [])
        #expect(FolderPath.components("") == [])
        #expect(FolderPath.components(" / ") == [])
        #expect(FolderPath.canonical("Social / Instagram ") == "Social/Instagram")
        #expect(FolderPath.canonical("  ") == nil)
        #expect(FolderPath.join([]) == nil)
    }

    @Test func validNames() {
        #expect(FolderPath.validName("  Work ") == "Work")
        #expect(FolderPath.validName("a/b") == nil)
        #expect(FolderPath.validName("   ") == nil)
    }

    @Test func prefixFiltering() {
        #expect(FolderPath.isInSubtree("Social/Instagram", of: ["Social"]))
        #expect(FolderPath.isInSubtree("Social / Instagram", of: ["Social", "Instagram"]))
        #expect(FolderPath.isInSubtree("Social", of: ["Social"]))
        #expect(FolderPath.isInSubtree(nil, of: []))
        #expect(FolderPath.isInSubtree("Anything/Deep", of: []))
        #expect(!FolderPath.isInSubtree("Socialite", of: ["Social"]), "prefix is per component, not per character")
        #expect(!FolderPath.isInSubtree("Social", of: ["Social", "Instagram"]))
        #expect(!FolderPath.isInSubtree(nil, of: ["Social"]))
        #expect(!FolderPath.isInSubtree("social/instagram", of: ["Social"]), "components compare exactly")
        #expect(FolderPath.isDirectlyIn("Social/Instagram", ["Social", "Instagram"]))
        #expect(!FolderPath.isDirectlyIn("Social/Instagram", ["Social"]))
    }
}

@Suite struct FolderTreeTests {
    let folders: [String?] = [
        "Social/Instagram", "Social / Instagram", "Social/Twitter", "Social",
        "Banking", nil, "", "Work/Servers/Prod", "Work/Servers/Prod",
    ]

    @Test func buildsTreeWithCounts() throws {
        let tree = FolderTree.build(folders: folders)
        #expect(tree.map(\.name) == ["Banking", "Social", "Work"])
        let social = try #require(FolderTree.find(["Social"], in: tree))
        #expect(social.directCount == 1)
        #expect(social.totalCount == 4)
        #expect(social.children?.map(\.name) == ["Instagram", "Twitter"])
        let ig = try #require(FolderTree.find(["Social", "Instagram"], in: tree))
        #expect(ig.totalCount == 2 && ig.directCount == 2)
        #expect(ig.children == nil, "leaves have nil children for OutlineGroup")
        #expect(ig.id == "Social/Instagram")
        let work = try #require(FolderTree.find(["Work"], in: tree))
        #expect(work.directCount == 0 && work.totalCount == 2)
        #expect(FolderTree.find(["Work", "Servers", "Prod"], in: tree)?.totalCount == 2)
        #expect(FolderTree.find(["Nope"], in: tree) == nil)
        #expect(FolderTree.allPaths(tree).count == 7)
    }

    @Test func sortsNaturally() {
        let tree = FolderTree.build(folders: ["b", "A", "a10", "a2"])
        #expect(tree.map(\.name) == ["A", "a2", "a10", "b"])
    }

    @Test func emptySessionFolders() throws {
        let tree = FolderTree.build(folders: ["Social"], extraPaths: [["Social", "New"], ["Empty"]])
        let new = try #require(FolderTree.find(["Social", "New"], in: tree))
        #expect(new.totalCount == 0)
        #expect(FolderTree.find(["Social"], in: tree)?.totalCount == 1)
        #expect(FolderTree.find(["Empty"], in: tree)?.totalCount == 0)
    }
}

@Suite struct FolderOpsTests {
    @Test func renameAndMovePaths() {
        #expect(FolderOps.renamed(["Social", "Insta"], to: " Instagram ") == ["Social", "Instagram"])
        #expect(FolderOps.renamed(["Social"], to: "a/b") == nil)
        #expect(FolderOps.renamed([], to: "x") == nil)
        #expect(FolderOps.moved(["Social", "Instagram"], toParent: []) == ["Instagram"])
        #expect(FolderOps.moved(["Instagram"], toParent: ["Social"]) == ["Social", "Instagram"])
        #expect(FolderOps.moved(["Social"], toParent: ["Social", "Instagram"]) == nil, "not into a descendant")
        #expect(FolderOps.moved(["Social"], toParent: ["Social"]) == nil, "not into itself")
        #expect(FolderOps.moved(["Social", "Instagram"], toParent: ["Social"]) == nil, "already there")
        #expect(FolderOps.canMove(["Socialite"], toParent: ["Social"]))
    }

    @Test func relocatesOnlyTheSubtree() {
        #expect(FolderOps.relocated("Social/Instagram", from: ["Social"], to: ["Personal", "Social"]) == "Personal/Social/Instagram")
        #expect(FolderOps.relocated("Social", from: ["Social"], to: ["Friends"]) == "Friends")
        #expect(FolderOps.relocated("Socialite", from: ["Social"], to: ["Friends"]) == nil)
        #expect(FolderOps.relocated(nil, from: ["Social"], to: ["Friends"]) == nil)
        #expect(FolderOps.relocated("Social / Instagram", from: ["Social", "Instagram"], to: ["IG"]) == "IG")
    }

    @Test func planSkipsUnaffectedAndUnchanged() {
        let items: [(id: String, folder: String?)] = [
            ("1", "Social/Instagram"), ("2", "Social"), ("3", "Banking"), ("4", nil), ("5", "Social/Twitter/Old"),
        ]
        let plan = FolderOps.plan(items: items, from: ["Social"], to: ["Online", "Social"])
        #expect(plan == [
            .init(id: "1", folder: "Online/Social/Instagram"),
            .init(id: "2", folder: "Online/Social"),
            .init(id: "5", folder: "Online/Social/Twitter/Old"),
        ])
        #expect(FolderOps.plan(items: items, from: ["Social"], to: ["Social"]).isEmpty)
        // A non-canonical spelling is rewritten even when the path is equal.
        let plan2 = FolderOps.plan(items: [("9", "A / B")], from: ["A"], to: ["A2"])
        #expect(plan2 == [.init(id: "9", folder: "A2/B")])
        #expect(FolderOps.relocatePaths([["Social", "New"], ["Other"]], from: ["Social"], to: ["S"]) == [["S", "New"], ["Other"]])
    }
}

@Suite struct SensitiveFieldTests {
    @Test func classification() {
        #expect(SensitiveField.classify("Recovery code 1") == .recoveryCode(number: 1, used: false))
        #expect(SensitiveField.classify("recovery  CODE 12") == .recoveryCode(number: 12, used: false))
        #expect(SensitiveField.classify("[used] Recovery code 3") == .recoveryCode(number: 3, used: true))
        #expect(SensitiveField.classify("[USED]Recovery code 3") == .recoveryCode(number: 3, used: true))
        #expect(SensitiveField.classify("Backup code") == .recoveryCode(number: nil, used: false))
        #expect(SensitiveField.classify("Recovery codes") == .other)
        #expect(SensitiveField.classify("Recovery code x") == .other)
        #expect(SensitiveField.classify("[used] Something") == .other)
        #expect(SensitiveField.classify("Security question 2") == .securityQuestion(number: 2))
        #expect(SensitiveField.classify("Security answer 2") == .securityAnswer(number: 2))
        #expect(SensitiveField.classify("Security question") == .securityQuestion(number: 0))
        #expect(SensitiveField.classify("2FA backup note") == .twoFactorNote)
        #expect(SensitiveField.classify("PIN") == .pin)
        #expect(SensitiveField.classify("PIN (ATM)") == .pin)
        #expect(SensitiveField.classify("Transaction PIN") == .pin)
        #expect(SensitiveField.classify("Pinterest") == .other)
        #expect(SensitiveField.classify("Seed word 7") == .seedWord(number: 7))
        #expect(SensitiveField.classify("Seed word") == .other)
        #expect(SensitiveField.classify("Number") == .other)
    }

    @Test func markUsedIsReversibleAndKeepsValue() {
        let fields = (1 ... 4).map { CustomField(name: SensitiveField.recoveryCodeName($0), value: "code-\($0)", concealed: true) }
        #expect(RecoveryCodes.unusedCount(fields) == 4)
        var f = RecoveryCodes.setUsed(fields, index: 1, used: true)
        #expect(f[1].name == "[used] Recovery code 2")
        #expect(f[1].value == "code-2", "the code itself is never changed")
        #expect(f[1].concealed)
        #expect(RecoveryCodes.unusedCount(f) == 3)
        #expect(RecoveryCodes.totalCount(f) == 4)
        // Marking twice is idempotent.
        #expect(RecoveryCodes.setUsed(f, index: 1, used: true) == f)
        f = RecoveryCodes.setUsed(f, index: 1, used: false)
        #expect(f == fields)
        // Other spellings of the marker are cleared too.
        let odd = [CustomField(name: "[USED]   Recovery code 9", value: "x", concealed: true)]
        #expect(RecoveryCodes.setUsed(odd, index: 0, used: false)[0].name == "Recovery code 9")
        // Non-code fields are left alone; empty codes are not counted.
        let mixed = [CustomField(name: "PIN", value: "1234", concealed: true),
                     CustomField(name: "Recovery code 1", value: " ", concealed: true)]
        #expect(RecoveryCodes.setUsed(mixed, index: 0, used: true) == mixed)
        #expect(RecoveryCodes.unusedCount(mixed) == 0)
        #expect(RecoveryCodes.setUsed(mixed, index: 7, used: true) == mixed)
    }

    @Test func parsesPastedCodes() {
        #expect(RecoveryCodes.parse("abcd-efgh\nijkl-mnop\r\n\n  qrst-uvwx ") == ["abcd-efgh", "ijkl-mnop", "qrst-uvwx"])
        #expect(RecoveryCodes.parse("1. 1111-2222\n2) 3333-4444") == ["1111-2222", "3333-4444"])
        #expect(RecoveryCodes.parse("aaaaaaaa bbbbbbbb cccccccc") == ["aaaaaaaa", "bbbbbbbb", "cccccccc"])
        #expect(RecoveryCodes.parse("1234 5678") == ["1234 5678"], "one grouped code")
        #expect(RecoveryCodes.parse("a1, b2; c3") == ["a1", "b2", "c3"])
        #expect(RecoveryCodes.parse("  \n ") == [])
    }

    @Test func numbersNewCodesAfterExisting() {
        let names = ["Recovery code 1", "[used] Recovery code 4", "Username"]
        #expect(RecoveryCodes.nextNumber(names) == 5)
        let new = RecoveryCodes.newFields(for: ["x", "y"], existingNames: names)
        #expect(new.map(\.name) == ["Recovery code 5", "Recovery code 6"])
        #expect(new.allSatisfy { $0.concealed })
        #expect(RecoveryCodes.nextNumber([]) == 1)
    }

    @Test func groupsFieldsTemplateFirst() throws {
        let card = try #require(ItemTemplate.named("card"))
        let names = ["Security answer 1", "PIN", "Number", "Recovery code 1", "Other thing",
                     "Security question 1", "Seed word 2", "Seed word 1", "2FA backup note", "PIN (ATM)", "Cardholder"]
        let g = FieldGroups.group(names: names, template: card)
        #expect(g.template == [10, 2, 1], "template order: Cardholder, Number, PIN")
        #expect(g.recoveryCodes == [3])
        #expect(g.securityPairs == [.init(number: 1, question: 5, answer: 0)])
        #expect(g.seedWords == [7, 6])
        #expect(g.twoFactorNotes == [8])
        #expect(g.pins == [9], "the card's own PIN stays with the card fields")
        #expect(g.other == [4])
        let noTemplate = FieldGroups.group(names: ["PIN", "Number"], template: nil)
        #expect(noTemplate.pins == [0] && noTemplate.other == [1])
    }
}

@Suite struct TemplateTests {
    @Test func catalogueIsValid() {
        let ids = ItemTemplate.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ItemTemplate.all.count == 15)
        for t in ItemTemplate.all {
            #expect(ItemTemplate.named(t.id) == t)
            #expect(t.tag == "template:\(t.id)")
            let names = t.fields.map { $0.name.lowercased() }
            #expect(Set(names).count == names.count, "\(t.id) has duplicate field names")
            #expect(ItemKind.allCases.contains(t.kind))
        }
        #expect(ItemTemplate.named("crypto-wallet")?.warning != nil)
        #expect(ItemTemplate.named("CARD")?.id == "card")
    }

    /// Encode an item from every template, read it back, and get the same
    /// template, the same values and the same input again.
    @Test func everyTemplateRoundTrips() throws {
        for t in ItemTemplate.all {
            var d = ItemDraft(template: t)
            #expect(d.kind == t.kind)
            #expect(d.templateID == t.id)
            d.title = "\(t.name) item"
            d.folder = "Personal / \(t.name.replacingOccurrences(of: "/", with: "-"))"
            for i in d.fields.indices { d.fields[i].value = "v-\(d.fields[i].name)" }
            if t.sections.contains(.recoveryCodes) { d.addRecoveryCodes(["c1", "c2"]) }
            if t.kind.usesPassword { d.password = "pw" }
            d.favourite = true
            let input = d.toInput()
            #expect(input.kind == t.kind)
            #expect(input.tags.contains("template:\(t.id)"))
            #expect(input.tags.contains("favourite"))
            #expect(input.folder == "Personal/\(t.name.replacingOccurrences(of: "/", with: "-"))")
            for f in t.fields {
                let stored = try #require(input.fields.first { $0.name == f.name }, "\(t.id): \(f.name)")
                #expect(stored.value == "v-\(f.name)")
                #expect(stored.concealed == f.concealed)
            }
            let back = ItemDraft(input)
            #expect(back.template == t)
            #expect(back.favourite)
            #expect(back.tags.isEmpty, "reserved tags stay out of the free-text tags")
            #expect(back.toInput() == input)
            let groups = FieldGroups.group(names: input.fields.map(\.name), template: t)
            #expect(groups.template.count == t.fields.count)
            if t.sections.contains(.recoveryCodes) {
                #expect(RecoveryCodes.unusedCount(input.fields) == 2)
                #expect(groups.recoveryCodes.count == 2)
            }
            if t.sections.contains(.seedPhrase) { #expect(groups.seedWords.count == 12) }
            if t.sections.contains(.securityQuestions) { #expect(groups.securityPairs.count == 1) }
        }
    }

    @Test func emptyPlaceholdersAreNotStored() throws {
        let t = try #require(ItemTemplate.named("insurance"))
        var d = ItemDraft(template: t)
        d.title = "Policy"
        d.fields[0].value = "Acme"
        let input = d.toInput()
        #expect(input.fields == [CustomField(name: "Insurer", value: "Acme", concealed: false)])
        var again = ItemDraft(input)
        again.ensureTemplateFields()
        #expect(again.fields.count == t.fields.count)
        #expect(again.toInput() == input)
        // Plain kinds keep their starting fields as before.
        var card = ItemDraft(kind: .card)
        card.title = "c"
        #expect(card.toInput().fields.count == ItemKind.card.templateFields.count)
    }

    @Test func seedWordsResizeWithoutLosingWords() throws {
        var d = ItemDraft(template: try #require(ItemTemplate.named("crypto-wallet")))
        #expect(d.seedWordCount == 12)
        let i5 = try #require(d.fields.firstIndex { $0.name == "Seed word 5" })
        d.fields[i5].value = "apple"
        d.setSeedWordCount(24)
        #expect(d.seedWordCount == 24)
        #expect(d.fields.first { $0.name == "Seed word 5" }?.value == "apple")
        d.setSeedWordCount(12)
        #expect(d.seedWordCount == 12)
        d.setSeedWordCount(24)
        d.fields[d.fields.firstIndex { $0.name == "Seed word 20" }!].value = "zebra"
        d.setSeedWordCount(12)
        #expect(d.seedWordCount == 13, "a typed word past the new count is kept")
        #expect(d.fields.allSatisfy { SensitiveField.classify($0.name) == .other || $0.concealed })
    }

    @Test func seedWordPositionsSurviveEmptyWords() throws {
        var d = ItemDraft(template: try #require(ItemTemplate.named("crypto-wallet")))
        d.title = "w"
        d.fields[d.fields.firstIndex { $0.name == "Seed word 2" }!].value = "abandon"
        d.fields[d.fields.firstIndex { $0.name == "Seed word 5" }!].value = "zoo"
        let input = d.toInput()
        #expect(input.fields.map(\.name) == ["Seed word 2", "Seed word 5"])
        #expect(SeedPhrase.words(input.fields) == ["", "abandon", "", "", "zoo"])
        var again = ItemDraft(input)
        again.ensureTemplateFields()
        #expect(again.seedWordCount == 12)
        #expect(again.fields.first { $0.name == "Seed word 5" }?.value == "zoo")
        #expect(again.toInput() == input)
        #expect(SeedPhrase.highestWordNumber(["Seed word 13"]) == 13)
        #expect(SeedPhrase.words([]).isEmpty)
    }

    @Test func siblingAccount() throws {
        var d = ItemDraft(template: try #require(ItemTemplate.named("social")))
        d.title = "@personal"
        d.username = "me"
        d.password = "secret"
        d.folder = "Social/Instagram"
        d.urls = ["https://instagram.com"]
        d.addRecoveryCodes(["a", "b"])
        let item = d.toInput()
        let s = ItemDraft.sibling(of: item)
        #expect(s.templateID == "social")
        #expect(s.folder == "Social/Instagram")
        #expect(s.urls == ["https://instagram.com"])
        #expect(s.title.isEmpty && s.username.isEmpty && s.password.isEmpty)
        #expect(!s.fields.contains { $0.value == "a" })
        #expect(ItemPresentation.serviceName(folder: item.folder, urls: item.urls, title: item.title) == "Instagram")
        #expect(ItemPresentation.serviceName(folder: nil, urls: ["https://www.github.com/x"], title: "t") == "github.com")
        #expect(ItemPresentation.isAccount(kind: .login, tags: []))
        #expect(!ItemPresentation.isAccount(kind: .card, tags: ["template:card"]))
        #expect(ItemPresentation.symbol(kind: .secureNote, tags: ["template:wifi"]) == "wifi")
    }
}

@Suite struct ReservedTagTests {
    @Test func favourites() {
        #expect(ReservedTags.isFavourite(["work", "favourite"]))
        #expect(ReservedTags.isFavourite(["Favorite"]))
        #expect(!ReservedTags.isFavourite(["fav"]))
        #expect(ReservedTags.settingFavourite(["a", "b"], true) == ["a", "b", "favourite"])
        #expect(ReservedTags.settingFavourite(["a", "favourite", "b"], false) == ["a", "b"])
        #expect(ReservedTags.settingFavourite(["favourite"], true) == ["favourite"])
    }

    @Test func templatesAndUserTags() {
        #expect(ReservedTags.templateID(in: ["x", "template:WiFi"]) == "wifi")
        #expect(ReservedTags.templateID(in: ["template:"]) == nil)
        #expect(ReservedTags.template(in: ["template:unknown"]) == nil)
        #expect(ReservedTags.userTags(["work", "favourite", "template:bank", "home"]) == ["work", "home"])
        #expect(ReservedTags.compose(user: ["a", "a", "favourite"], templateID: "bank", favourite: true)
            == ["a", "template:bank", "favourite"])
    }

    @Test func draftKeepsReservedTagsOutOfFreeText() {
        let input = ItemInput(kind: .login, title: "t", username: nil, password: nil, urls: [], notes: nil, totp: nil,
                              folder: nil, tags: ["work", "favourite", "template:email"], fields: [], travelSafe: false)
        var d = ItemDraft(input)
        #expect(d.tags == "work")
        #expect(d.favourite)
        #expect(d.templateID == "email")
        d.favourite = false
        #expect(d.toInput().tags == ["work", "template:email"])
    }
}
