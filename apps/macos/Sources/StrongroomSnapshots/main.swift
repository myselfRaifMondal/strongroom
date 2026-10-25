// Strongroom snapshot harness (debug builds only).
//
// Renders the app's screens offscreen to PNG at several window sizes, in light
// and dark mode, so layout can be reviewed without a screen capture (every
// Strongroom window is excluded from capture, OQ-M5, and stays that way).
//
//   swift build --product StrongroomSnapshots
//   .build/debug/StrongroomSnapshots --out /path/to/dir [--only name,name] [--sizes 760x480,1280x800] [--light-only]
//
// How it works: each screen is the real SwiftUI view from StrongroomMacUI
// hosted in an NSHostingView inside an offscreen NSWindow (never ordered on
// screen). The window is sized, laid out, and drawn with
// cacheDisplay(in:to:) into a 1x bitmap, which is written as PNG. Sheets are
// drawn the same way at their own ideal size (limited to the window) and
// composited over the dimmed main window, roughly as macOS shows them.
//
// Data: a throwaway vault in a new temporary directory, selected through
// STRONGROOM_DATA_DIR before any AppModel exists, filled with made-up items
// (example.test sites, fake users) and a random password generated here. The
// directory is deleted when the run ends. The harness refuses to run if the
// data directory would be the real one.
import AppKit
import CryptoKit
import StrongroomKit
import SwiftUI

#if DEBUG
@testable import StrongroomMacUI

// MARK: options

struct Options {
    var out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("snapshots")
    var only: Set<String>?
    var sizes: [CGSize] = [
        CGSize(width: 760, height: 480), CGSize(width: 1024, height: 640), CGSize(width: 1280, height: 800),
        CGSize(width: 1440, height: 900), CGSize(width: 1920, height: 1080), CGSize(width: 2560, height: 1440),
    ]
    var appearances: [Bool] = [false, true] // dark?

    static func parse() -> Options {
        var o = Options()
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let a = args.next() {
            switch a {
            case "--out": if let v = args.next() { o.out = URL(fileURLWithPath: v) }
            case "--only": if let v = args.next() { o.only = Set(v.split(separator: ",").map(String.init)) }
            case "--sizes":
                if let v = args.next() {
                    o.sizes = v.split(separator: ",").compactMap { s in
                        let p = s.split(separator: "x").compactMap { Double($0) }
                        return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
                    }
                }
            case "--light-only": o.appearances = [false]
            case "--dark-only": o.appearances = [true]
            default:
                FileHandle.standardError.write(Data("unknown option \(a)\n".utf8))
                exit(2)
            }
        }
        return o
    }
}

// MARK: throwaway data

enum Fixture {
    /// A fresh 0700 directory under the per-user temporary folder.
    static func makeTempDir(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("strongroom-snapshots-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Points DataDirectory.standard() (and so the next AppModel) at `dir`.
    static func use(_ dir: URL) {
        let real = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false))?
            .appendingPathComponent("Strongroom").standardizedFileURL.path ?? "/nonexistent"
        precondition(!dir.standardizedFileURL.path.hasPrefix(real), "refusing to use the real data directory")
        setenv("STRONGROOM_DATA_DIR", dir.path, 1)
        precondition((try? DataDirectory.standard().url.standardizedFileURL.path) == dir.standardizedFileURL.path)
    }

    static func randomPassword() -> String {
        (try? generatePassword(policy: PasswordPolicy(length: 28, lowercase: true, uppercase: true, digits: true,
                                                      symbols: true, avoidAmbiguous: true))) ?? UUID().uuidString
    }

    static let day: Int64 = 86_400

    /// Fills `vault` with made-up items. `now` is the creation time used for
    /// each item, so some passwords are old.
    static func seed(_ vault: Vault) throws {
        let now = Clock.now()
        let reused = randomPassword()
        func add(_ d: ItemDraft, age days: Int64 = 20) throws -> String {
            try vault.addItem(input: d.toInput(), now: now - days * day)
        }
        func login(_ title: String, _ user: String, _ site: String, folder: String = "", password: String? = nil,
                   age: Int64 = 30, tags: String = "", fav: Bool = false, totp: Bool = false) throws {
            var d = ItemDraft(kind: .login)
            d.title = title
            d.username = user
            d.password = password ?? randomPassword()
            d.urls = ["https://\(site)"]
            d.folder = folder
            d.tags = tags
            d.favourite = fav
            if totp { d.totp = "JBSWY3DPEHPK3PXP" }
            _ = try add(d, age: age)
        }

        // Social/Instagram: two accounts with recovery codes and a question.
        var ig = ItemDraft(template: ItemTemplate.named("social")!)
        ig.title = "@river.photos"
        ig.username = "river.photos"
        ig.password = randomPassword()
        ig.urls = ["https://instagram.example.test"]
        ig.folder = "Social/Instagram"
        ig.favourite = true
        ig.totp = "JBSWY3DPEHPK3PXP"
        ig.fields.removeAll()
        ig.addRecoveryCodes(["4821-9932", "1170-5521", "8834-0021", "5512-7781", "3307-4419", "9921-0034", "6612-8890", "2245-1198"])
        for i in [0, 1, 2] { ig.fields[i].name = SensitiveField.settingUsed(ig.fields[i].name, true) }
        ig.addSecurityQuestion()
        ig.fields[ig.fields.count - 2].value = "Name of your first pet"
        ig.fields[ig.fields.count - 1].value = "Captain Biscuit"
        ig.fields.append(.init(name: SensitiveField.twoFactorNoteName, value: "Authenticator app on the old phone in the desk drawer.", concealed: true))
        ig.notes = "Main photography account. Linked to the work email."
        let igID = try add(ig, age: 400)
        // Two later edits so History has versions.
        var ig2 = ig
        ig2.password = randomPassword()
        try vault.updateItem(id: igID, input: ig2.toInput(), now: now - 200 * day)
        ig2.notes = "Main photography account. Linked to the work email. Business profile since spring."
        try vault.updateItem(id: igID, input: ig2.toInput(), now: now - 10 * day)

        var ig3 = ItemDraft(template: ItemTemplate.named("social")!)
        ig3.title = "@river.travels"
        ig3.username = "river.travels"
        ig3.password = reused
        ig3.urls = ["https://instagram.example.test"]
        ig3.folder = "Social/Instagram"
        ig3.fields.removeAll()
        ig3.addRecoveryCodes(["7712-0091", "4410-2287"])
        ig3.fields[0].name = SensitiveField.settingUsed(ig3.fields[0].name, true)
        _ = try add(ig3, age: 90)

        try login("Mastodon", "river@social.example.test", "social.example.test", folder: "Social", age: 60)
        try login("Photo forum", "riverp", "forum.example.test", folder: "Social", password: "sunshine1", age: 900)
        try login("Video site", "river.v", "video.example.test", folder: "Social", password: reused, age: 300)

        // Email, finance, developer.
        var mail = ItemDraft(template: ItemTemplate.named("email")!)
        mail.title = "Personal mail"
        mail.username = "river@mail.example.test"
        mail.password = randomPassword()
        mail.urls = ["https://mail.example.test"]
        mail.folder = "Email"
        mail.favourite = true
        mail.totp = "JBSWY3DPEHPK3PXP"
        _ = try add(mail, age: 120)
        try login("Work mail", "r.lee@acme.example.test", "mail.acme.example.test", folder: "Email", password: reused, age: 500, tags: "work")

        var bank = ItemDraft(template: ItemTemplate.named("bank")!)
        bank.title = "Example Bank"
        bank.username = "RLEE0042"
        bank.password = randomPassword()
        bank.urls = ["https://bank.example.test"]
        bank.folder = "Finance"
        for i in bank.fields.indices {
            switch bank.fields[i].name {
            case "Bank": bank.fields[i].value = "Example Bank"
            case "Account holder": bank.fields[i].value = "River Lee"
            case "Account number": bank.fields[i].value = "000123456789"
            case "IFSC / routing number": bank.fields[i].value = "EXMP0000001"
            case "Branch": bank.fields[i].value = "High Street"
            case "Account type": bank.fields[i].value = "Savings"
            default: break
            }
        }
        _ = try add(bank, age: 800)

        var card = ItemDraft(template: ItemTemplate.named("card")!)
        card.title = "Travel card"
        card.folder = "Finance"
        for i in card.fields.indices {
            switch card.fields[i].name {
            case "Cardholder": card.fields[i].value = "RIVER LEE"
            case "Number": card.fields[i].value = "4000 0000 0000 0002"
            case "Expiry": card.fields[i].value = "09/29"
            case "Security code": card.fields[i].value = "123"
            case "Issuer": card.fields[i].value = "Example Bank"
            default: break
            }
        }
        card.favourite = true
        _ = try add(card, age: 50)

        var ssh = ItemDraft(template: ItemTemplate.named("server")!)
        ssh.title = "Build server"
        ssh.username = "deploy"
        ssh.password = randomPassword()
        ssh.folder = "Developer"
        for i in ssh.fields.indices {
            switch ssh.fields[i].name {
            case "Host": ssh.fields[i].value = "build.example.test"
            case "Port": ssh.fields[i].value = "22"
            case "Private key": ssh.fields[i].value = "-----BEGIN OPENSSH PRIVATE KEY-----\nFAKEFAKEFAKEFAKEFAKE\n-----END OPENSSH PRIVATE KEY-----"
            case "Public key": ssh.fields[i].value = "ssh-ed25519 AAAAFAKEKEYFORSNAPSHOTS deploy@example.test"
            case "Host key fingerprint": ssh.fields[i].value = "SHA256:fakefakefakefakefakefakefake"
            default: break
            }
        }
        _ = try add(ssh, age: 700)

        var api = ItemDraft(template: ItemTemplate.named("api-key")!)
        api.title = "Weather API"
        api.username = "key_8812"
        api.password = randomPassword()
        api.urls = ["https://api.example.test"]
        api.folder = "Developer"
        _ = try add(api, age: 40)

        var note = ItemDraft(template: ItemTemplate.named("secure-note")!)
        note.title = "Locker combination"
        note.notes = "Gym locker 114: 28-04-19. Spare key with the neighbour."
        note.tags = "family"
        _ = try add(note, age: 15)

        var wifi = ItemDraft(template: ItemTemplate.named("wifi")!)
        wifi.title = "Home Wi-Fi"
        wifi.folder = "Home"
        for i in wifi.fields.indices {
            switch wifi.fields[i].name {
            case "Network name (SSID)": wifi.fields[i].value = "Lee-Home"
            case "Password": wifi.fields[i].value = randomPassword()
            case "Security": wifi.fields[i].value = "WPA3"
            default: break
            }
        }
        wifi.tags = "family"
        _ = try add(wifi, age: 25)

        var wallet = ItemDraft(template: ItemTemplate.named("crypto-wallet")!)
        wallet.title = "Test wallet"
        wallet.folder = "Finance/Crypto"
        let words = ["apple", "river", "candle", "orbit", "silver", "meadow", "copper", "lantern", "harbor", "violet", "pepper", "summit"]
        var w = 0
        for i in wallet.fields.indices {
            if case .seedWord = SensitiveField.classify(wallet.fields[i].name) {
                wallet.fields[i].value = words[w % words.count]
                w += 1
            }
        }
        _ = try add(wallet, age: 30)

        // Many plain logins so lists scroll.
        let shops = ["Bookshop", "Grocer", "Hardware store", "Garden centre", "Music shop", "Tea merchant", "Camera store", "Shoe shop"]
        for (i, s) in shops.enumerated() {
            try login(s, "river\(i)@mail.example.test", "\(s.lowercased().replacingOccurrences(of: " ", with: "-")).example.test",
                      folder: "Shopping", password: i == 2 ? "qwerty12" : (i == 5 ? reused : nil), age: Int64(30 + i * 97),
                      fav: i == 0)
        }
        let work = ["Issue tracker", "Wiki", "Chat", "Payroll", "Timesheets", "Design tool", "Code review", "VPN"]
        for (i, s) in work.enumerated() {
            try login(s, "r.lee", "\(s.lowercased().replacingOccurrences(of: " ", with: "-")).acme.example.test",
                      folder: i < 4 ? "Work" : "Work/Projects/Atlas", age: Int64(10 + i * 61), tags: "work", totp: i % 3 == 0)
        }
        let misc = ["Library card", "Parking app", "Train tickets", "Recipe site", "Weather station", "Podcast host",
                    "News site", "Cloud photos", "Fitness tracker", "Language course", "Museum membership", "Car share",
                    "Electric company", "Water utility", "Phone carrier", "Pharmacy"]
        for (i, s) in misc.enumerated() {
            try login(s, "river.lee", "\(s.lowercased().replacingOccurrences(of: " ", with: "-")).example.test",
                      password: i == 4 ? "password" : nil, age: Int64(5 + i * 53))
        }

        // Trash.
        for s in ["Old forum", "Expired trial", "Former ISP"] {
            var d = ItemDraft(kind: .login)
            d.title = s
            d.username = "river"
            d.password = randomPassword()
            d.urls = ["https://\(s.lowercased().replacingOccurrences(of: " ", with: "-")).example.test"]
            let id = try add(d, age: 400)
            try vault.trashItem(id: id, now: now - 3 * day)
        }
    }

    /// A paired device made of a throwaway software key.
    static func pairFakeDevice(_ dirURL: URL) {
        let dir = DataDirectory(url: dirURL)
        let key = P256.KeyAgreement.PrivateKey()
        _ = try? PairedDeviceStore(dir: dir).add(name: "Test phone", payload: pairingPayload(devicePublicKey: key.publicKey.x963Representation),
                                               now: Clock.now())
    }
}

// MARK: rendering

@MainActor
final class Renderer {
    let opts: Options
    var written = 0

    init(opts: Options) { self.opts = opts }

    func wants(_ name: String) -> Bool { opts.only.map { $0.contains(name) } ?? true }

    static func appearance(_ dark: Bool) -> NSAppearance { NSAppearance(named: dark ? .darkAqua : .aqua)! }

    /// Lays out `view` in an offscreen titled window of `size` and returns the
    /// window frame (titlebar and toolbar included) as a 1x bitmap.
    func capture<V: View>(_ view: V, size: CGSize, dark: Bool, titled: Bool = true, settle: Double = 0.9) async -> NSBitmapImageRep? {
        let style: NSWindow.StyleMask = titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.appearance = Self.appearance(dark)
        window.toolbarStyle = .unified
        window.title = "Strongroom"
        let host = NSHostingView(rootView: view)
        if #available(macOS 14.0, *) { host.sceneBridgingOptions = [.toolbars, .title] }
        window.contentView = host
        window.setContentSize(size)
        for _ in 0 ..< 3 {
            try? await Task.sleep(for: .seconds(settle / 3))
            host.layoutSubtreeIfNeeded()
            window.contentView?.superview?.layoutSubtreeIfNeeded()
        }
        let root = window.contentView?.superview ?? host
        if ProcessInfo.processInfo.environment["SNAP_DUMP"] == "1" { dump(root, 0) }
        let rep = compose(root, dark: dark)
        window.contentView = nil
        window.close()
        return rep
    }

    static func bitmap(_ size: CGSize) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        return rep
    }

    static func className(_ v: NSView) -> String { String(describing: type(of: v)) }

    /// Draws the window offscreen. macOS 26 draws the sidebar and toolbar
    /// groups as "glass" and scroll edges as blurred "pockets": the window
    /// server composites those, and glass content sits under a plain CALayer
    /// that cacheDisplay does not descend into. So: hide the blur views, paint
    /// a flat stand-in for each glass shape, draw the window, then draw each
    /// glass view's content on top.
    func compose(_ root: NSView, dark: Bool) -> NSBitmapImageRep {
        NSAppearance.current = Self.appearance(dark)
        let bounds = root.bounds
        var glass: [NSView] = []
        var hidden: [NSView] = []
        func walk(_ v: NSView) {
            if v.isHidden { return }
            let name = Self.className(v)
            if name.contains("GlassEffectView") { glass.append(v) }
            if name.contains("Pocket") || name.contains("Backdrop") || name.contains("BlurryAlleyway") {
                hidden.append(v)
                return
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        hidden.forEach { $0.isHidden = true }
        defer { hidden.forEach { $0.isHidden = false } }

        func rect(_ v: NSView, _ r: CGRect) -> CGRect {
            var out = v.convert(r, to: root)
            if root.isFlipped { out.origin.y = bounds.height - out.maxY }
            return out
        }
        func draw(_ v: NSView, in ctx: NSGraphicsContext) {
            let b = v.bounds
            guard b.width >= 1, b.height >= 1 else { return }
            let sub = Self.bitmap(b.size)
            v.cacheDisplay(in: b, to: sub)
            NSGraphicsContext.current = ctx
            sub.draw(in: rect(v, b), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        let rep = Self.bitmap(bounds.size)
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        bounds.fill()
        // The glass views themselves draw an opaque placeholder offscreen.
        glass.forEach { $0.isHidden = true }
        draw(root, in: ctx)
        glass.forEach { $0.isHidden = false }
        for g in glass {
            // Sidebar: a filled panel; toolbar groups: an outline only (their
            // icons are drawn by the toolbar, not inside the glass view).
            let r = rect(g, g.bounds)
            let isSidebar = r.height > 120
            let radius: CGFloat = isSidebar ? 16 : r.height / 2
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            if isSidebar {
                (dark ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 0.975, alpha: 1)).setFill()
                path.fill()
            }
            (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.12)).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        for g in glass {
            // The glass content lives under a layer-only "content holder".
            let parts = g.subviews.filter { !$0.isHidden }.flatMap { s -> [NSView] in
                Self.className(s).contains("ContentHolder") ? s.subviews.filter { !$0.isHidden } : []
            }
            parts.forEach { draw($0, in: ctx) }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    func dump(_ v: NSView, _ depth: Int) {
        guard depth < 14 else { return }
        print(String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame.integral) layer=\(v.layer.map { String(describing: type(of: $0)) } ?? "-") hidden=\(v.isHidden)")
        for s in v.subviews { dump(s, depth + 1) }
    }

    /// The ideal size of a sheet's content, limited to the parent window.
    func idealSize<V: View>(_ view: V, limit: CGSize) async -> CGSize {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        try? await Task.sleep(for: .seconds(0.15))
        host.layoutSubtreeIfNeeded()
        var s = host.fittingSize
        window.contentView = nil
        window.close()
        if s.width < 10 || s.height < 10 { s = CGSize(width: 500, height: 400) }
        return CGSize(width: min(ceil(s.width), limit.width), height: min(ceil(s.height), limit.height))
    }

    func write(_ rep: NSBitmapImageRep, _ name: String) {
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = opts.out.appendingPathComponent(name + ".png")
        try? data.write(to: url)
        written += 1
    }

    static func sizeName(_ s: CGSize) -> String { "\(Int(s.width))x\(Int(s.height))" }

    func shot<V: View>(_ screen: String, _ view: V, size: CGSize, dark: Bool) async -> NSBitmapImageRep? {
        guard let rep = await capture(view, size: size, dark: dark) else { return nil }
        write(rep, "\(screen)_\(Self.sizeName(size))_\(dark ? "dark" : "light")")
        return rep
    }

    /// A sheet over the dimmed main window, top-centred like a macOS sheet.
    func sheet<V: View>(_ screen: String, _ view: V, over backdrop: NSBitmapImageRep, size: CGSize, dark: Bool) async {
        let limit = CGSize(width: size.width - 40, height: size.height - 40)
        let sheetSize = await idealSize(view, limit: limit)
        guard let sheetRep = await capture(view, size: sheetSize, dark: dark, titled: false) else { return }
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        backdrop.draw(in: CGRect(origin: .zero, size: size))
        NSColor.black.withAlphaComponent(dark ? 0.35 : 0.18).setFill()
        CGRect(origin: .zero, size: size).fill()
        let origin = CGPoint(x: floor((size.width - sheetSize.width) / 2), y: size.height - 28 - sheetSize.height)
        let rect = CGRect(origin: CGPoint(x: origin.x, y: max(origin.y, 8)), size: sheetSize)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowOffset = CGSize(width: 0, height: -4)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).addClip()
        sheetRep.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        write(out, "\(screen)_\(Self.sizeName(size))_\(dark ? "dark" : "light")")
    }
}

// MARK: screens

@MainActor
final class Harness {
    let opts = Options.parse()
    lazy var r = Renderer(opts: opts)
    var tempDirs: [URL] = []

    func main() async {
        do {
            try FileManager.default.createDirectory(at: opts.out, withIntermediateDirectories: true)
            try await run()
        } catch {
            FileHandle.standardError.write(Data("snapshot run failed: \(error)\n".utf8))
        }
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        print("wrote \(r.written) PNG files to \(opts.out.path)")
    }

    func root(_ model: AppModel) -> some View {
        RootView().environmentObject(model).frame(minWidth: 760, minHeight: 480)
    }

    func run() async throws {
        // 1. Main vault, created and filled directly through the Vault API.
        let mainDir = try Fixture.makeTempDir("main")
        tempDirs.append(mainDir)
        let password = Fixture.randomPassword()
        let secretKey = generateSecretKey()
        let vault = try Vault.create(path: DataDirectory(url: mainDir).vaultPath.path, password: password,
                                     secretKey: secretKey, now: Clock.now() - 1000 * Fixture.day)
        try Fixture.seed(vault)
        vault.lock()
        Fixture.pairFakeDevice(mainDir)

        // 2. An empty data directory (first run) and one that just created a
        //    vault (Secret Key screen).
        let emptyDir = try Fixture.makeTempDir("empty")
        let newDir = try Fixture.makeTempDir("new")
        tempDirs += [emptyDir, newDir]
        Fixture.use(emptyDir)
        let firstRun = AppModel()
        Fixture.use(newDir)
        let created = AppModel()
        await created.createVault(password: Fixture.randomPassword())
        Fixture.use(mainDir)
        let model = AppModel()

        let quick = QuickAccessController(model: model)

        // Locked screens first.
        for dark in opts.appearances {
            for size in opts.sizes {
                if r.wants("unlock") { _ = await r.shot("unlock", root(model), size: size, dark: dark) }
                if r.wants("create") { _ = await r.shot("create", root(firstRun), size: size, dark: dark) }
                if r.wants("secret-key") { _ = await r.shot("secret-key", root(created), size: size, dark: dark) }
            }
            if r.wants("quick-access-locked") {
                if let rep = await r.capture(QuickAccessView(controller: quick).environmentObject(model),
                                             size: CGSize(width: 560, height: 380), dark: dark, titled: false) {
                    r.write(rep, "quick-access-locked_560x380_\(dark ? "dark" : "light")")
                }
            }
        }

        await model.unlock(password: password, secretKey: secretKey)
        guard model.isUnlocked else { throw NSError(domain: "snapshots", code: 1, userInfo: [NSLocalizedDescriptionKey: "unlock failed"]) }
        model.infoMessage = nil

        func id(_ title: String) -> String? { model.allItems.first { $0.title == title }?.id }
        let igID = id("@river.photos")!
        let mailID = id("Personal mail")

        func state(_ sidebar: SidebarSelection, _ selection: String? = nil, query: String = "", banner: Bool = false) {
            model.query = query
            model.sidebar = sidebar
            model.selection = selection
            model.showRotationBanner = banner
        }

        for dark in opts.appearances {
            if r.wants("quick-access") {
                if let rep = await r.capture(QuickAccessView(controller: quick).environmentObject(model),
                                             size: CGSize(width: 560, height: 380), dark: dark, titled: false) {
                    r.write(rep, "quick-access_560x380_\(dark ? "dark" : "light")")
                }
            }
            for size in opts.sizes {
                let main: [(String, () -> Void)] = [
                    ("vault-all", { state(.all, banner: true) }),
                    ("vault-item", { state(.all, igID) }),
                    ("folder-tree", { state(.folder("Social")) }),
                    ("folder-item", { state(.folder("Social/Instagram"), igID) }),
                    ("favourites", { state(.favourites, mailID) }),
                    ("search", { state(.all, query: "mail") }),
                    ("health", { state(.health) }),
                    ("ranking", { state(.ranking) }),
                    ("trash", { state(.trash) }),
                ]
                var backdrop: NSBitmapImageRep?
                for (name, setup) in main where r.wants(name) || (name == "vault-all" && needsBackdrop) {
                    setup()
                    let rep = await r.shot(name, root(model), size: size, dark: dark)
                    if name == "vault-all" { backdrop = rep }
                }
                state(.all)
                if backdrop == nil && needsBackdrop { backdrop = await r.capture(root(model), size: size, dark: dark) }
                if let backdrop {
                    for (name, view) in sheets(model, igID: igID) where r.wants(name) {
                        await r.sheet(name, view.environmentObject(model), over: backdrop, size: size, dark: dark)
                    }
                }
                if r.wants("settings") {
                    let v = SettingsView().environmentObject(model)
                    let s = await r.idealSize(v, limit: CGSize(width: size.width, height: size.height - 40))
                    _ = await r.shot("settings", v.frame(width: s.width, height: s.height),
                                     size: CGSize(width: s.width, height: s.height), dark: dark)
                    // Keep the size label of the screen it was made for.
                    let src = opts.out.appendingPathComponent("settings_\(Renderer.sizeName(s))_\(dark ? "dark" : "light").png")
                    let dst = opts.out.appendingPathComponent("settings_\(Renderer.sizeName(size))_\(dark ? "dark" : "light").png")
                    if src != dst {
                        try? FileManager.default.removeItem(at: dst)
                        try? FileManager.default.moveItem(at: src, to: dst)
                    }
                }
            }
        }
        model.lock()
    }

    var needsBackdrop: Bool { sheetNames.contains { r.wants($0) } }

    let sheetNames = ["editor", "editor-new", "template-picker", "history", "organize", "folder-new", "move-items",
                      "move-folder", "export", "import", "csv-import", "devices", "generator", "second-vault"]

    func sheets(_ model: AppModel, igID: String) -> [(String, AnyView)] {
        var d = ItemDraft(model.item(igID)!.data)
        d.ensureTemplateFields()
        var newLogin = ItemDraft(template: ItemTemplate.named("social")!)
        newLogin.folder = "Social"
        return [
            ("editor", AnyView(ItemEditorView(itemId: igID, draft: d))),
            ("editor-new", AnyView(ItemEditorView(itemId: nil, draft: newLogin))),
            ("template-picker", AnyView(TemplatePickerView(folder: ["Social"]))),
            ("history", AnyView(HistorySheet(itemId: igID))),
            ("organize", AnyView(OrganizeSheet(request: .init(ids: nil, headline: "Organize by Service")))),
            ("folder-new", AnyView(FolderNameSheet(mode: .create(parent: ["Social"])))),
            ("move-items", AnyView(MoveItemsSheet(itemIds: [igID]))),
            ("move-folder", AnyView(MoveFolderSheet(path: ["Social", "Instagram"]))),
            ("export", AnyView(TransferSheet(request: .export))),
            ("import", AnyView(TransferSheet(request: .importFile(URL(fileURLWithPath: "/tmp/Strongroom-2026-10-25.vtf"),
                                                                  VtfInfo(version: 1, passwordSlots: 1, deviceSlots: 1, chunkCount: 3))))),
            ("csv-import", AnyView(CSVImportSheet())),
            ("devices", AnyView(DevicesSheet())),
            ("generator", AnyView(generatorSheet())),
            ("second-vault", AnyView(SecondVaultSheet())),
        ]
    }

    /// The toolbar's generator sheet (inline in VaultView).
    func generatorSheet() -> some View {
        VStack(alignment: .leading) {
            GeneratorView(onUse: nil)
            HStack { Spacer(); Button("Done") {}.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 460)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    await Harness().main()
    exit(0)
}
app.run()

#else
print("StrongroomSnapshots is a debug-only tool: build it with `swift build` (debug).")
#endif
