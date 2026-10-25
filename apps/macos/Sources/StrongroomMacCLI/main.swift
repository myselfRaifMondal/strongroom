// strongroom-mac-cli: headless harness over the same Swift bindings as the
// app. Used by CI and by Phase 3's cross-platform VTF round-trip. Mirrors the
// Windows strongroom-cli. Secrets come from environment variables, never argv
// (argv is visible to other processes):
//
//   STRONGROOM_PASSWORD       master password (vault + VTF password slot)
//   STRONGROOM_SECRET_KEY     Secret Key for an existing vault / VTF file
//   STRONGROOM_ITEM_PASSWORD  optional password for `add`
//
// Exit codes: 0 ok, 1 failure, 2 usage, 3 the core reported Unsupported
// (a feature missing from the linked core; CI treats it as a failure).

import Foundation
import StrongroomKit

let exitOk: Int32 = 0, exitFail: Int32 = 1, exitUsage: Int32 = 2, exitUnsupported: Int32 = 3

struct UsageError: Error { let message: String }

struct Args {
    private var values: [String: String] = [:]

    init(_ argv: ArraySlice<String>) throws {
        var it = argv.makeIterator()
        while let key = it.next() {
            guard key.hasPrefix("--") else { throw UsageError(message: "unexpected argument '\(key)'") }
            guard let value = it.next() else { throw UsageError(message: "missing value for \(key)") }
            values[String(key.dropFirst(2))] = value
        }
    }

    func required(_ name: String) throws -> String {
        guard let v = values[name] else { throw UsageError(message: "--\(name) is required") }
        return v
    }

    func optional(_ name: String) -> String? { values[name] }
}

func out(_ s: String) { print(s) }
func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func env(_ name: String) throws -> String {
    guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else {
        throw UsageError(message: "\(name) is not set")
    }
    return v
}

func password() throws -> String { try env("STRONGROOM_PASSWORD") }
func secretKey() throws -> String {
    try env("STRONGROOM_SECRET_KEY").trimmingCharacters(in: .whitespacesAndNewlines)
}

func newSecretKey() throws -> String {
    let key = generateSecretKey()
    if key.isEmpty {
        throw StrongroomError.Unsupported(reason: "generate_secret_key returned an empty Secret Key")
    }
    return key
}

func open(_ a: Args) throws -> Vault {
    try Vault.unlockWithPassword(path: try a.required("vault"), password: try password(), secretKey: try secretKey(), now: Clock.now())
}

func login(_ title: String, _ username: String?, _ password: String?, _ url: String?, _ totp: String?, _ notes: String?) -> ItemInput {
    ItemInput(kind: .login, title: title, username: username, password: password,
              urls: url.map { [$0] } ?? [], notes: notes, totp: totp, folder: nil,
              tags: [], fields: [], travelSafe: false)
}

func printTitles(_ vault: Vault) throws {
    let items = try vault.search(query: "", folder: nil, tag: nil).sorted { $0.title.utf8.lexicographicallyPrecedes($1.title.utf8) }
    out("ITEMS: \(items.count)")
    for i in items { out("TITLE: \(i.title)") }
}

func create(_ a: Args) throws -> Int32 {
    let path = try a.required("vault")
    let sk = try newSecretKey()
    let vault = try Vault.create(path: path, password: try password(), secretKey: sk, now: Clock.now())
    vault.lock()
    try? SecureFile.chmod(URL(fileURLWithPath: path), 0o600)
    if let file = a.optional("secret-key-out") {
        try SecureFile.write(Data(sk.utf8), to: URL(fileURLWithPath: file))
        out("created \(path); Secret Key written to \(file)")
    } else {
        out("created \(path)")
        out("SECRET KEY: \(sk)")
    }
    out("A lost master password or Secret Key means permanent, unrecoverable data loss.")
    return exitOk
}

func add(_ a: Args) throws -> Int32 {
    let vault = try open(a)
    defer { vault.lock() }
    let id = try vault.addItem(
        input: login(try a.required("title"), a.optional("username"),
                     ProcessInfo.processInfo.environment["STRONGROOM_ITEM_PASSWORD"],
                     a.optional("url"), a.optional("totp"), a.optional("notes")),
        now: Clock.now())
    out("added \(id)")
    return exitOk
}

func list(_ a: Args) throws -> Int32 {
    let vault = try open(a)
    defer { vault.lock() }
    try printTitles(vault)
    return exitOk
}

func export(_ a: Args) throws -> Int32 {
    let vault = try open(a)
    defer { vault.lock() }
    let outPath = try a.required("out")
    let bytes = try vault.exportVtf(password: try password(), secretKey: try secretKey(), deviceRecipients: [], now: Clock.now())
    try SecureFile.write(bytes, to: URL(fileURLWithPath: outPath))
    out("exported \(bytes.count) bytes to \(outPath)")
    return exitOk
}

func importFile(_ a: Args) throws -> Int32 {
    let file = try Data(contentsOf: URL(fileURLWithPath: try a.required("in")))
    var tempDir: URL?
    let vault: Vault
    if a.optional("vault") != nil {
        vault = try open(a)
    } else {
        // Fresh throwaway vault with its own Secret Key; the file is opened
        // with the exporting vault's password + Secret Key (password slot).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("strongroom-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        tempDir = dir
        vault = try Vault.create(path: dir.appendingPathComponent("import.srdb").path, password: try password(),
                                 secretKey: try newSecretKey(), now: Clock.now())
    }
    defer {
        vault.lock()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }
    let s = try vault.importVtf(file: file, password: try password(), secretKey: try secretKey(), now: Clock.now())
    out("IMPORTED: added=\(s.added) updated=\(s.updated) unchanged=\(s.unchanged) conflicts=\(s.conflicts)")
    try printTitles(vault)
    return exitOk
}

func inspect(_ a: Args) throws -> Int32 {
    let info = try vtfInspect(file: try Data(contentsOf: URL(fileURLWithPath: try a.required("in"))))
    out("VTF version=\(info.version) password_slots=\(info.passwordSlots) device_slots=\(info.deviceSlots) chunks=\(info.chunkCount)")
    return exitOk
}

func roundTrip(_ a: Args) throws -> Int32 {
    let dir = URL(fileURLWithPath: try a.required("dir"), isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let pw = try password()
    let now = Clock.now()
    let titles = ["macOS: Example Login", "macOS: Bank", "macOS: Ünïcödé ✓"]

    let secretA = try newSecretKey()
    try SecureFile.write(Data(secretA.utf8), to: dir.appendingPathComponent("source.secret-key.txt"))
    let vtfURL = dir.appendingPathComponent("macos-roundtrip.vtf")
    do {
        let source = try Vault.create(path: dir.appendingPathComponent("source.srdb").path, password: pw, secretKey: secretA, now: now)
        defer { source.lock() }
        _ = try source.addItem(input: login(titles[0], "alice@example.com", "correct horse battery staple", "https://example.com", "JBSWY3DPEHPK3PXP", nil), now: now)
        _ = try source.addItem(input: login(titles[1], "alice", "hunter2-but-longer", "https://bank.example", nil, "note"), now: now)
        _ = try source.addItem(input: login(titles[2], nil, "pässwörd", nil, nil, nil), now: now)
        out("source vault: 3 items added")
        let vtf = try source.exportVtf(password: pw, secretKey: secretA, deviceRecipients: [], now: now)
        try SecureFile.write(vtf, to: vtfURL)
        out("EXPORTED: \(vtfURL.path) (\(vtf.count) bytes)")
        let info = try vtfInspect(file: vtf)
        out("VTF version=\(info.version) password_slots=\(info.passwordSlots) device_slots=\(info.deviceSlots) chunks=\(info.chunkCount)")
    }

    let vtfBytes = try Data(contentsOf: vtfURL)
    let target = try Vault.create(path: dir.appendingPathComponent("target.srdb").path, password: pw, secretKey: try newSecretKey(), now: now + 1)
    defer { target.lock() }
    let s = try target.importVtf(file: vtfBytes, password: pw, secretKey: secretA, now: now + 1)
    out("IMPORTED: added=\(s.added) updated=\(s.updated) unchanged=\(s.unchanged) conflicts=\(s.conflicts)")
    try printTitles(target)

    let got = try target.search(query: "", folder: nil, tag: nil).map(\.title).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    let want = titles.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    guard got == want else {
        err("ROUNDTRIP FAILED: imported titles differ from exported titles")
        return exitFail
    }

    // Wrong Secret Key must be rejected with UnlockFailed (no detail).
    do {
        _ = try target.importVtf(file: vtfBytes, password: pw, secretKey: try newSecretKey(), now: now + 2)
        err("ROUNDTRIP FAILED: import with a wrong Secret Key succeeded")
        return exitFail
    } catch StrongroomError.UnlockFailed {
        out("wrong Secret Key correctly rejected (UnlockFailed)")
    }
    out("ROUNDTRIP OK")
    return exitOk
}

/// Nested folders, templates, favourites and recovery codes (one marked used)
/// survive export_vtf -> import_vtf field for field.
func hierarchyRoundTrip(_ a: Args) throws -> Int32 {
    let dir = URL(fileURLWithPath: try a.required("dir"), isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let pw = try password()
    let now = Clock.now()
    let sk = try newSecretKey()
    try SecureFile.write(Data(sk.utf8), to: dir.appendingPathComponent("hier-a.secret-key.txt"))

    func account(_ title: String, _ folder: String, _ codes: [String]) -> ItemInput {
        var d = ItemDraft(template: ItemTemplate.named("social")!)
        d.title = title
        d.username = String(title.dropFirst())
        d.password = "pw-\(title)-7#Lq"
        d.folder = folder
        d.urls = ["https://instagram.com"]
        d.addRecoveryCodes(codes)
        d.favourite = true
        return d.toInput()
    }
    var personal = account("@personal", "Social/Instagram", ["1111-2222", "3333-4444", "5555-6666"])
    personal.fields = RecoveryCodes.setUsed(personal.fields, index: personal.fields.firstIndex { $0.value == "3333-4444" }!, used: true)
    var bank = ItemDraft(template: ItemTemplate.named("bank")!)
    bank.title = "Savings"
    bank.folder = "Finance / Banks / HDFC"
    bank.fields[bank.fields.firstIndex { $0.name == "Account number" }!].value = "000123456789"
    bank.fields.append(.init(name: "PIN (ATM)", value: "4321", concealed: true))
    let originals = [personal, account("@work", "Social/Instagram", ["aaaa-bbbb"]), bank.toInput()]

    let source = try Vault.create(path: dir.appendingPathComponent("hier-a.srdb").path, password: pw, secretKey: sk, now: now)
    for o in originals { _ = try source.addItem(input: o, now: now) }
    let vtf = try source.exportVtf(password: pw, secretKey: sk, deviceRecipients: [], now: now)
    source.lock()
    try SecureFile.write(vtf, to: dir.appendingPathComponent("macos-hierarchy.vtf"))

    let target = try Vault.create(path: dir.appendingPathComponent("hier-b.srdb").path, password: pw, secretKey: try newSecretKey(), now: now + 1)
    defer { target.lock() }
    let s = try target.importVtf(file: vtf, password: pw, secretKey: sk, now: now + 1)
    out("IMPORTED: added=\(s.added) updated=\(s.updated) unchanged=\(s.unchanged) conflicts=\(s.conflicts)")
    let summaries = try target.search(query: "", folder: nil, tag: nil)
    var ok = summaries.count == originals.count
    for o in originals {
        guard let sum = summaries.first(where: { $0.title == o.title }) else { ok = false; continue }
        let got = try target.getItem(id: sum.id).data
        let same = got == o
        ok = ok && same
        // Counts only: field values are secrets and are never printed.
        out("ITEM \(o.title): folder=\(got.folder ?? "-") fields=\(got.fields.count) unused-codes=\(RecoveryCodes.unusedCount(got.fields)) \(same ? "identical" : "DIFFERENT")")
    }
    func printTree(_ nodes: [FolderNode], _ depth: Int) {
        for n in nodes {
            out("TREE \(String(repeating: "  ", count: depth))\(n.name) (\(n.totalCount))")
            printTree(n.children ?? [], depth + 1)
        }
    }
    printTree(FolderTree.build(folders: summaries.map(\.folder)), 0)
    guard ok else {
        err("HIERARCHY ROUNDTRIP FAILED")
        return exitFail
    }
    out("HIERARCHY ROUNDTRIP OK")
    return exitOk
}

func probe() -> Int32 {
    let v = ProcessInfo.processInfo.operatingSystemVersionString
    #if arch(arm64)
    let arch = "arm64"
    #else
    let arch = "x86_64"
    #endif
    out("OS: macOS \(v) (\(arch))")
    let sk = generateSecretKey()
    out("FFI: strongroom_ffi linked; generate_secret_key -> \(sk.isEmpty ? "empty (no Secret Key returned)" : "\(sk.count) chars")")
    let strength = estimateStrength(password: "correct horse battery staple")
    out("FFI: estimate_strength -> score=\(strength.score) entropy=\(String(format: "%.1f", strength.entropyBits))")

    let r = SecureEnclaveProbe.run()
    out("SecureEnclave.isAvailable: \(r.available)")
    out("SE P-256 key (privateKeyUsage only): created=\(r.keyCreated) public_key_len=\(r.publicKeyLength) ecdh-matches-software=\(r.ecdhMatchesSoftware)")
    out("SE P-256 key (.biometryCurrentSet): created=\(r.biometryKeyCreated)")
    if !r.detail.isEmpty { out("detail: \(r.detail)") }
    let bio = DeviceCapabilities.biometryAvailable()
    out("Touch ID (canEvaluatePolicy biometrics): \(bio.available)\(bio.detail.map { " (\($0))" } ?? "")")
    out("kern.boottime: \(BootTime.current().map(String.init) ?? "unavailable")")
    out(DeviceCapabilities.deviceUnlockSupported
        ? "DEVICE UNLOCK: available (Secure Enclave + Touch ID)"
        : "DEVICE UNLOCK: unavailable on this Mac -> Touch ID unlock disabled; password unlock only")
    return exitOk
}

// MARK: organize by service / security ranking (headless)

func printPlan(_ plan: [OrganizeChange]) {
    out("PLAN: \(plan.count) change(s)")
    for c in plan.sorted(by: { ($0.newFolder, $0.newTitle) < ($1.newFolder, $1.newTitle) }) {
        out("MOVE: \(c.newFolder) | \(c.newTitle) <- \(c.oldTitle)\(c.isPromotion ? " [promotion]" : "")")
    }
}

func printRanking(_ r: RankingResult, _ vault: Vault, health: HealthReport?) {
    let titles = Dictionary(uniqueKeysWithValues: ((try? vault.search(query: "", folder: nil, tag: nil)) ?? []).map { ($0.id, $0.title) })
    out("RANKING: \(r.items.count) item(s); health score \(health.map { String($0.securityScore) } ?? "n/a"); "
        + RiskPriority.allCases.reversed().map { "\($0.label) \(r.count($0))" }.joined(separator: ", ")
        + "; \(r.sharedCount) share a password; \(r.dueCount) due")
    for i in r.items {
        out("RANK: \(i.risk) \(i.priority.label) \(i.inputs.importance == .critical ? "critical" : "-") \(i.due ? "due(" + i.dueReasons.map(\.rawValue).joined(separator: ",") + ")" : "-") \(titles[i.id] ?? i.id)")
    }
    for c in r.clusters {
        out("CLUSTER: same password on \(c.itemIDs.count): " + c.itemIDs.map { titles[$0] ?? $0 }.joined(separator: ", "))
    }
}

func organize(_ a: Args) throws -> Int32 {
    let vault = try open(a)
    defer { vault.lock() }
    let scope: OrganizeScope = a.optional("scope") == "all" ? .all : .unfiled
    let plan = Organizer.plan(items: try VaultAnalysis.organizeItems(vault), scope: scope)
    printPlan(plan)
    if a.optional("apply") == "yes" {
        let (undo, failed) = Organizer.apply(plan, vault: vault, now: Clock.now())
        out("APPLIED: \(undo.count) changed, \(failed) failed")
    }
    return exitOk
}

func ranking(_ a: Args) throws -> Int32 {
    let vault = try open(a)
    defer { vault.lock() }
    var cache = VaultAnalysis.StrengthCache()
    let r = try VaultAnalysis.ranking(vault, policy: RotationSettings(), now: Clock.now(), cache: &cache)
    printRanking(r, vault, health: try? vault.passwordHealth(now: Clock.now()))
    out("NOTIFICATION TEXT: \(RotationReminder.body(count: r.dueCount))")
    return exitOk
}

/// A synthetic "Apple Passwords" export (fake accounts, throwaway passwords),
/// imported into a fresh vault, organized, ranked, undone.
func organizeDemo(_ a: Args) throws -> Int32 {
    let dir = URL(fileURLWithPath: try a.required("dir"))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let pw = try password()
    let sk = try newSecretKey()
    let path = dir.appendingPathComponent("demo.srdb").path
    let vault = try Vault.create(path: path, password: pw, secretKey: sk, now: Clock.now())
    defer { vault.lock() }
    try SecureFile.write(Data(sk.utf8), to: dir.appendingPathComponent("demo.secret-key.txt"))
    let shared = "Summer2019!"
    let rows: [(String, String, String, String, String)] = [
        ("instagram.com (alpha.one)", "https://www.instagram.com/", "alpha.one", shared, ""),
        ("instagram.com (beta.two)", "https://instagram.com/accounts/login", "beta.two", "k8#Qz!vR2m@Lp9wX", ""),
        ("accounts.google.com (me@example.com)", "https://accounts.google.com/", "me@example.com", shared, ""),
        ("github.com (octo-dev)", "https://github.com/login", "octo-dev", "Tq7&uW#p2Lr!9zXc", "otpauth://totp/GitHub:octo?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"),
        ("signin.aws.amazon.com (root)", "https://signin.aws.amazon.com/", "root@example.com", "password1", ""),
        ("www.amazon.in (me@example.com)", "https://www.amazon.in/ap/signin", "me@example.com", shared, ""),
        ("kite.zerodha.com (AB1234)", "https://kite.zerodha.com/", "AB1234", shared, ""),
        ("mail.hostinger.com (me@example.com)", "https://mail.hostinger.com/", "me@example.com", "mailpass", ""),
        ("hpanel.hostinger.com (me@example.com)", "https://hpanel.hostinger.com/", "admin@example.com", "Vh4!nQ8#zLp2@wRt", ""),
        ("acme.wd5.myworkdayjobs.com (me@example.com)", "https://acme.wd5.myworkdayjobs.com/careers", "me@example.com", shared, ""),
        ("globex.wd1.myworkdayjobs.com (me@example.com)", "https://globex.wd1.myworkdayjobs.com/", "me@example.com", "Xc9#Lm2!pQ7@vTz4", ""),
        ("www.irctc.co.in (traveller)", "https://www.irctc.co.in/nget/", "traveller", "irctc123", ""),
        ("auth.riotgames.com (gamer)", "https://auth.riotgames.com/", "gamer", shared, ""),
        ("portal.local-gym.co.uk (member)", "https://portal.local-gym.co.uk/", "member", "gym", ""),
        ("Home router", "", "admin", "admin", ""),
    ]
    func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    var csv = "Title,URL,Username,Password,Notes,OTPAuth\n"
    for r in rows { csv += [r.0, r.1, r.2, r.3, "", r.4].map(q).joined(separator: ",") + "\n" }
    let summary = try vault.importCsv(source: .onePassword, csv: csv, now: Clock.now())
    out("IMPORTED: \(summary.added) added")

    var all = try VaultAnalysis.organizeItems(vault)
    var before: [String: ItemInput] = [:]
    for i in all { before[i.id] = try vault.getItem(id: i.id).data }
    let plan = Organizer.plan(items: all, scope: .unfiled)
    printPlan(plan)
    let (undo, failed) = Organizer.apply(plan, vault: vault, now: Clock.now())
    out("APPLIED: \(undo.count) changed, \(failed) failed")
    var cache = VaultAnalysis.StrengthCache()
    printRanking(try VaultAnalysis.ranking(vault, policy: RotationSettings(), now: Clock.now(), cache: &cache), vault,
                 health: try? vault.passwordHealth(now: Clock.now()))

    // A second GitHub account added later: suggestion + promotion of the first.
    all = try VaultAnalysis.organizeItems(vault)
    if let s = Organizer.suggest(urls: ["https://github.com"], username: "octo-work", title: "", existing: all) {
        out("SUGGEST: new github.com login -> \(s.folder) | \(s.title); promotions: "
            + s.promotions.map { "\($0.oldFolder ?? "-")/\($0.oldTitle) -> \($0.newFolder)/\($0.newTitle)" }.joined(separator: "; "))
    }

    let (restored, undoFailed) = Organizer.undo(undo, vault: vault, now: Clock.now())
    var exact = true
    for (id, input) in before where try vault.getItem(id: id).data != input { exact = false }
    out("UNDO: \(restored) restored, \(undoFailed) failed, inputs identical to before organize: \(exact)")
    return exact && undoFailed == 0 && failed == 0 ? exitOk : exitFail
}

func usage() -> Int32 {
    err("""
        strongroom-mac-cli <command> [options]
          create    --vault PATH [--secret-key-out FILE]
          add       --vault PATH --title T [--username U] [--url U] [--totp SECRET] [--notes N]
          list      --vault PATH
          export    --vault PATH --out FILE.vtf
          import    --in FILE.vtf [--vault PATH]     prints imported item titles
          inspect   --in FILE.vtf
          roundtrip --dir DIR                        create, add, export, import into a second vault
          hierarchy --dir DIR                        nested folders + recovery codes survive export/import
          probe                                      FFI link + Secure Enclave / Touch ID availability
          organize  --vault PATH [--scope all] [--apply yes]   Organize by Service plan (and apply)
          ranking   --vault PATH                     Security Ranking, worst first (no passwords printed)
          organize-demo --dir DIR                    synthetic Apple Passwords CSV -> organize -> rank -> undo
        Secrets: STRONGROOM_PASSWORD, STRONGROOM_SECRET_KEY, STRONGROOM_ITEM_PASSWORD (env).
        """)
    return exitUsage
}

func execute(_ argv: [String]) -> Int32 {
    guard argv.count >= 2 else { return usage() }
    do {
        let a = try Args(argv.dropFirst(2))
        switch argv[1] {
        case "create": return try create(a)
        case "add": return try add(a)
        case "list": return try list(a)
        case "export": return try export(a)
        case "import": return try importFile(a)
        case "inspect": return try inspect(a)
        case "roundtrip": return try roundTrip(a)
        case "hierarchy": return try hierarchyRoundTrip(a)
        case "probe": return probe()
        case "organize": return try organize(a)
        case "ranking": return try ranking(a)
        case "organize-demo": return try organizeDemo(a)
        default: return usage()
        }
    } catch let StrongroomError.Unsupported(reason) {
        err("CORE UNSUPPORTED: \(reason)")
        return exitUnsupported
    } catch let e as StrongroomError {
        err("ERROR: \(CoreErrors.describe(e))")
        return exitFail
    } catch let e as UsageError {
        err("usage error: \(e.message)")
        return exitUsage
    } catch {
        err("ERROR: \(error)")
        return exitFail
    }
}

let argv = CommandLine.arguments
let code = (try? CoreThread.runBlocking { execute(argv) }) ?? exitFail
exit(code)
