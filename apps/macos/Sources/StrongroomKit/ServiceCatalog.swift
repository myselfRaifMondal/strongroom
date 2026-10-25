import Foundation

/// Host and registrable-domain extraction, done locally (no network, no
/// public-suffix download). The suffix list below covers the multi-label
/// public suffixes that matter for consumer accounts (country second-level
/// domains such as .co.uk, .co.in, .com.au) plus a few hosting suffixes whose
/// subdomains belong to different owners (github.io, vercel.app, …). Any
/// other host is treated as "<label>.<tld>".
public enum DomainName {
    /// Multi-label public suffixes. A host ending in one of these keeps one
    /// more label as its registrable domain ("bbc.co.uk", "sbi.co.in").
    public static let multiLabelSuffixes: Set<String> = [
        // United Kingdom
        "co.uk", "org.uk", "me.uk", "ac.uk", "gov.uk", "ltd.uk", "plc.uk", "net.uk", "nhs.uk", "sch.uk",
        // India
        "co.in", "net.in", "org.in", "firm.in", "gen.in", "ind.in", "ac.in", "edu.in", "res.in", "gov.in", "nic.in", "mil.in",
        "bank.in", // RBI-mandated bank domains ("sbi.bank.in")
        // Australia, New Zealand
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "net.nz", "org.nz", "ac.nz", "govt.nz",
        // Asia
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "co.kr", "or.kr", "ac.kr",
        "com.cn", "net.cn", "org.cn", "edu.cn", "gov.cn", "com.hk", "org.hk", "edu.hk",
        "com.tw", "org.tw", "edu.tw", "com.sg", "edu.sg", "gov.sg", "com.my", "edu.my",
        "co.id", "ac.id", "or.id", "go.id", "co.th", "ac.th", "in.th", "com.ph", "edu.ph",
        "com.vn", "edu.vn", "com.pk", "edu.pk", "com.bd", "edu.bd", "com.lk", "edu.lk", "com.np", "edu.np",
        // Middle East, Africa
        "co.il", "ac.il", "org.il", "com.sa", "edu.sa", "ae.org", "co.ae", "com.tr", "edu.tr", "gov.tr",
        "co.za", "org.za", "ac.za", "gov.za", "com.ng", "edu.ng", "co.ke", "ac.ke", "com.eg", "edu.eg",
        // Americas, Europe
        "com.br", "net.br", "org.br", "edu.br", "gov.br", "com.mx", "org.mx", "edu.mx", "gob.mx",
        "com.ar", "edu.ar", "gob.ar", "com.co", "edu.co", "com.pe", "com.cl", "com.uy", "com.ve",
        "com.pl", "net.pl", "org.pl", "co.at", "or.at", "ac.at", "com.es", "org.es", "com.pt", "com.gr",
        "com.ua", "org.ua", "com.ru", "org.ru", "co.ve",
        // Hosting platforms whose subdomains are separate owners
        "github.io", "gitlab.io", "vercel.app", "netlify.app", "herokuapp.com", "pages.dev", "workers.dev",
        "web.app", "firebaseapp.com", "azurewebsites.net", "cloudfront.net", "blogspot.com", "wordpress.com",
        "appspot.com", "onrender.com", "fly.dev", "repl.co", "glitch.me", "surge.sh",
    ]

    /// The lowercased host of a URL or bare domain ("instagram.com/x",
    /// "https://user@Mail.Example.com:8443/"), without a trailing dot.
    public static func host(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let withScheme = s.contains("://") ? s : "https://" + s
        guard let comps = URLComponents(string: withScheme), let scheme = comps.scheme?.lowercased(),
              ["http", "https"].contains(scheme) || !s.contains("://"),
              var h = comps.host?.lowercased(), !h.isEmpty else { return nil }
        while h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("[") { return h } // IPv6 literal
        guard h.contains(where: \.isLetter) || h.contains(".") else { return nil }
        return h
    }

    public static func isIPAddress(_ host: String) -> Bool {
        if host.hasPrefix("[") { return true }
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// "mail.hostinger.com" -> "hostinger.com"; "www.bbc.co.uk" -> "bbc.co.uk".
    /// IP addresses and single-label hosts are returned unchanged.
    public static func registrable(host: String) -> String {
        let h = host.lowercased()
        if isIPAddress(h) { return h }
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return h }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if multiLabelSuffixes.contains(lastTwo) { return labels.suffix(3).joined(separator: ".") }
        return lastTwo
    }

    public static func registrable(url: String) -> String? { host(url).map { registrable(host: $0) } }

    /// The public suffix of a registrable domain: "co.uk" for "bbc.co.uk".
    public static func suffix(ofRegistrable domain: String) -> String {
        let labels = domain.split(separator: ".")
        guard labels.count > 1 else { return "" }
        return labels.dropFirst().joined(separator: ".")
    }

    /// The brand label: "amazon" for "amazon.co.uk".
    public static func brandLabel(ofRegistrable domain: String) -> String {
        String(domain.split(separator: ".").first ?? "")
    }
}

/// Categories of the built-in service map. The raw value is the folder name.
public enum ServiceCategory: String, CaseIterable, Sendable, Hashable, Identifiable {
    case social = "Social"
    case emailIdentity = "Email & Identity"
    case finance = "Finance"
    case developerCloud = "Developer & Cloud"
    case shoppingTravel = "Shopping & Travel"
    case gaming = "Gaming"
    case learning = "Learning & Research"
    case careers = "Careers"
    case work = "Work & Productivity"
    case hosting = "Hosting & Domains"
    case other = "Other"

    public var id: String { rawValue }
    public var folderName: String { rawValue }

    /// Accounts whose takeover hurts most: they reset other accounts (email),
    /// move money (finance) or run infrastructure (developer & cloud).
    public var isCritical: Bool { [.emailIdentity, .finance, .developerCloud].contains(self) }

    public var symbol: String {
        switch self {
        case .social: return "person.2.fill"
        case .emailIdentity: return "envelope.fill"
        case .finance: return "building.columns.fill"
        case .developerCloud: return "chevron.left.forwardslash.chevron.right"
        case .shoppingTravel: return "cart.fill"
        case .gaming: return "gamecontroller.fill"
        case .learning: return "graduationcap.fill"
        case .careers: return "briefcase.fill"
        case .work: return "square.grid.2x2.fill"
        case .hosting: return "server.rack"
        case .other: return "questionmark.folder.fill"
        }
    }

    /// Folder names (first component, case-insensitive) that mean this
    /// category, so items the user filed by hand are recognised too.
    public var folderAliases: [String] {
        switch self {
        case .emailIdentity: return ["email & identity", "email", "e-mail", "mail", "identity", "accounts"]
        case .finance: return ["finance", "banking", "bank", "banks", "money", "investing", "investments", "trading", "crypto", "payments"]
        case .developerCloud: return ["developer & cloud", "developer", "dev", "development", "cloud", "servers", "infrastructure", "infra"]
        default: return [rawValue.lowercased()]
        }
    }

    public static func fromFolder(_ folder: String?) -> ServiceCategory? {
        guard let first = FolderPath.components(folder).first?.lowercased() else { return nil }
        return allCases.first { $0.folderAliases.contains(first) }
    }
}

/// One well-known service. `domains` match a host or any of its parent
/// domains ("console.aws.amazon.com" matches "aws.amazon.com" before
/// "amazon.com"). `brands` match the brand label under any public suffix
/// ("amazon" matches amazon.de, amazon.co.uk, amazon.in). `multiTenant`
/// services host many organisations on subdomains (careers portals, LMS):
/// their account titles keep the tenant so accounts stay distinguishable.
public struct KnownService: Sendable, Hashable {
    public let name: String
    public let category: ServiceCategory
    public let domains: [String]
    public let brands: [String]
    public let multiTenant: Bool

    public init(_ name: String, _ category: ServiceCategory, _ domains: [String], brands: [String] = [], multiTenant: Bool = false) {
        self.name = name
        self.category = category
        self.domains = domains
        self.brands = brands
        self.multiTenant = multiTenant
    }
}

/// The result of classifying a URL.
public struct ServiceMatch: Equatable, Sendable {
    public let category: ServiceCategory
    /// Display name ("Instagram"), or the registrable domain for unknown sites.
    public let service: String
    public let known: Bool
    /// Subdomain naming the organisation on a multi-tenant service ("acme"
    /// for acme.wd5.myworkdayjobs.com).
    public let tenant: String?
    public let registrableDomain: String

    /// Groups accounts of the same service.
    public var key: String { known ? "svc:" + service.lowercased() : "dom:" + registrableDomain }
}

/// Generic built-in map of well-known services. Deliberately not personalised:
/// it lists widely used services only. Anything else is "Other/<domain>".
public enum ServiceCatalog {
    public static let services: [KnownService] = [
        // Social
        KnownService("Instagram", .social, ["instagram.com"]),
        KnownService("X (Twitter)", .social, ["x.com", "twitter.com"]),
        KnownService("Facebook", .social, ["facebook.com", "fb.com", "messenger.com"]),
        KnownService("LinkedIn", .social, ["linkedin.com"]),
        KnownService("Discord", .social, ["discord.com", "discord.gg", "discordapp.com"]),
        KnownService("Twitch", .social, ["twitch.tv"]),
        KnownService("Reddit", .social, ["reddit.com"]),
        KnownService("TikTok", .social, ["tiktok.com"]),
        KnownService("Snapchat", .social, ["snapchat.com"]),
        KnownService("YouTube", .social, ["youtube.com"]),
        KnownService("Pinterest", .social, ["pinterest.com"], brands: ["pinterest"]),
        KnownService("Tumblr", .social, ["tumblr.com"]),
        KnownService("Quora", .social, ["quora.com"]),
        KnownService("Medium", .social, ["medium.com"]),
        KnownService("Threads", .social, ["threads.net"]),
        KnownService("Bluesky", .social, ["bsky.app"]),
        KnownService("Mastodon", .social, ["mastodon.social"]),
        KnownService("Telegram", .social, ["telegram.org", "t.me"]),
        KnownService("WhatsApp", .social, ["whatsapp.com"]),
        KnownService("Signal", .social, ["signal.org"]),
        KnownService("Spotify", .social, ["spotify.com"]),
        KnownService("Netflix", .social, ["netflix.com"]),
        KnownService("Vimeo", .social, ["vimeo.com"]),
        KnownService("Flickr", .social, ["flickr.com"]),
        KnownService("VK", .social, ["vk.com"]),
        KnownService("WeChat", .social, ["wechat.com"]),
        KnownService("LINE", .social, ["line.me"]),
        KnownService("Viber", .social, ["viber.com"]),
        KnownService("ShareChat", .social, ["sharechat.com"]),
        KnownService("Nextdoor", .social, ["nextdoor.com"]),
        KnownService("Goodreads", .social, ["goodreads.com"]),
        KnownService("Strava", .social, ["strava.com"]),
        KnownService("Substack", .social, ["substack.com"]),
        KnownService("Patreon", .social, ["patreon.com"]),
        KnownService("Tinder", .social, ["tinder.com"]),
        KnownService("Bumble", .social, ["bumble.com"]),
        // Streaming (filed with Social, like Netflix and Spotify)
        KnownService("Prime Video", .social, ["primevideo.com"]),
        KnownService("Disney+", .social, ["disneyplus.com"]),
        KnownService("JioHotstar", .social, ["hotstar.com", "jiohotstar.com"]),
        KnownService("Hulu", .social, ["hulu.com"]),
        KnownService("Max", .social, ["max.com", "hbomax.com"]),
        KnownService("Peacock", .social, ["peacocktv.com"]),
        KnownService("Paramount+", .social, ["paramountplus.com"]),
        KnownService("SonyLIV", .social, ["sonyliv.com"]),
        KnownService("ZEE5", .social, ["zee5.com"]),
        KnownService("Crunchyroll", .social, ["crunchyroll.com"]),
        KnownService("Plex", .social, ["plex.tv"]),
        KnownService("JioSaavn", .social, ["jiosaavn.com"]),
        KnownService("Gaana", .social, ["gaana.com"]),
        KnownService("SoundCloud", .social, ["soundcloud.com"]),
        KnownService("Deezer", .social, ["deezer.com"]),
        KnownService("Tidal", .social, ["tidal.com"]),
        KnownService("Audible", .social, ["audible.com"], brands: ["audible"]),

        // Email & Identity
        KnownService("Google", .emailIdentity, ["google.com", "gmail.com", "accounts.google.com", "googlemail.com"], brands: ["google"]),
        KnownService("Proton", .emailIdentity, ["proton.me", "protonmail.com", "protonmail.ch"]),
        KnownService("Microsoft", .emailIdentity, ["microsoft.com", "live.com", "outlook.com", "hotmail.com", "microsoftonline.com", "office.com", "office365.com", "xbox.com", "skype.com"]),
        KnownService("Yahoo", .emailIdentity, ["yahoo.com", "ymail.com"], brands: ["yahoo"]),
        KnownService("Apple Account", .emailIdentity, ["apple.com", "icloud.com", "appleid.apple.com", "me.com"]),
        KnownService("Zoho Mail", .emailIdentity, ["zoho.com", "zoho.in", "zoho.eu"]),
        KnownService("Fastmail", .emailIdentity, ["fastmail.com"]),
        KnownService("Tuta", .emailIdentity, ["tuta.com", "tutanota.com"]),
        KnownService("AOL", .emailIdentity, ["aol.com"]),
        KnownService("GMX", .emailIdentity, ["gmx.com", "gmx.net", "gmx.de"]),
        KnownService("Okta", .emailIdentity, ["okta.com"], multiTenant: true),
        KnownService("Auth0", .emailIdentity, ["auth0.com"]),
        KnownService("DigiLocker", .emailIdentity, ["digilocker.gov.in"]),
        KnownService("Aadhaar (UIDAI)", .emailIdentity, ["uidai.gov.in"]),
        KnownService("Mail.com", .emailIdentity, ["mail.com"]),
        KnownService("Yandex", .emailIdentity, ["yandex.com", "yandex.ru"], brands: ["yandex"]),
        KnownService("Mail.ru", .emailIdentity, ["mail.ru"]),
        KnownService("Rediffmail", .emailIdentity, ["rediff.com", "rediffmail.com"]),
        KnownService("HEY", .emailIdentity, ["hey.com"]),
        KnownService("Posteo", .emailIdentity, ["posteo.de"]),
        KnownService("mailbox.org", .emailIdentity, ["mailbox.org"]),
        KnownService("Bitwarden", .emailIdentity, ["bitwarden.com", "bitwarden.eu"]),
        KnownService("1Password", .emailIdentity, ["1password.com", "1password.eu", "1password.ca"]),
        KnownService("LastPass", .emailIdentity, ["lastpass.com"]),
        KnownService("Dashlane", .emailIdentity, ["dashlane.com"]),
        KnownService("Authy", .emailIdentity, ["authy.com"]),
        KnownService("Login.gov", .emailIdentity, ["login.gov"]),
        KnownService("ID.me", .emailIdentity, ["id.me"]),
        KnownService("GOV.UK One Login", .emailIdentity, ["account.gov.uk"]),
        KnownService("Government Gateway", .emailIdentity, ["access.service.gov.uk"]),
        KnownService("Passport Seva", .emailIdentity, ["passportindia.gov.in"]),
        KnownService("UMANG", .emailIdentity, ["umang.gov.in"]),

        // Finance: banks
        KnownService("HDFC Bank", .finance, ["hdfcbank.com", "hdfcbank.net"]),
        KnownService("ICICI Bank", .finance, ["icicibank.com"]),
        KnownService("State Bank of India", .finance, ["onlinesbi.sbi", "sbi.co.in", "onlinesbi.com", "sbi.bank.in"]),
        KnownService("Axis Bank", .finance, ["axisbank.com"]),
        KnownService("Kotak", .finance, ["kotak.com", "kotaksecurities.com"]),
        KnownService("Yes Bank", .finance, ["yesbank.in"]),
        KnownService("IDFC FIRST Bank", .finance, ["idfcfirstbank.com"]),
        KnownService("Bank of Baroda", .finance, ["bankofbaroda.in", "bobibanking.com"]),
        KnownService("Punjab National Bank", .finance, ["pnbindia.in", "netpnb.com"]),
        KnownService("Chase", .finance, ["chase.com"]),
        KnownService("Bank of America", .finance, ["bankofamerica.com"]),
        KnownService("Wells Fargo", .finance, ["wellsfargo.com"]),
        KnownService("Citi", .finance, ["citi.com", "citibank.com", "citibank.co.in"]),
        KnownService("Capital One", .finance, ["capitalone.com"]),
        KnownService("American Express", .finance, ["americanexpress.com"]),
        KnownService("HSBC", .finance, ["hsbc.com"], brands: ["hsbc"]),
        KnownService("Barclays", .finance, ["barclays.com", "barclays.co.uk"]),
        KnownService("Revolut", .finance, ["revolut.com"]),
        KnownService("Wise", .finance, ["wise.com", "transferwise.com"]),
        KnownService("Monzo", .finance, ["monzo.com"]),
        KnownService("N26", .finance, ["n26.com"]),
        KnownService("Canara Bank", .finance, ["canarabank.com", "canarabank.in"]),
        KnownService("Union Bank of India", .finance, ["unionbankofindia.co.in", "unionbankonline.co.in"]),
        KnownService("Bank of India", .finance, ["bankofindia.co.in", "bankofindia.com"]),
        KnownService("Indian Bank", .finance, ["indianbank.in", "indianbank.net.in"]),
        KnownService("Central Bank of India", .finance, ["centralbankofindia.co.in"]),
        KnownService("Indian Overseas Bank", .finance, ["iob.in", "iobnet.co.in"]),
        KnownService("UCO Bank", .finance, ["ucobank.com"]),
        KnownService("Bank of Maharashtra", .finance, ["bankofmaharashtra.in"]),
        KnownService("IDBI Bank", .finance, ["idbibank.in"]),
        KnownService("IndusInd Bank", .finance, ["indusind.com"]),
        KnownService("Federal Bank", .finance, ["federalbank.co.in", "fednetbank.com"]),
        KnownService("South Indian Bank", .finance, ["southindianbank.com"]),
        KnownService("RBL Bank", .finance, ["rblbank.com"]),
        KnownService("Bandhan Bank", .finance, ["bandhanbank.com"]),
        KnownService("AU Small Finance Bank", .finance, ["aubank.in"]),
        KnownService("Karur Vysya Bank", .finance, ["kvb.co.in"]),
        KnownService("Karnataka Bank", .finance, ["karnatakabank.com"]),
        KnownService("J&K Bank", .finance, ["jkbank.com"]),
        KnownService("SBI Card", .finance, ["sbicard.com"]),
        KnownService("DBS Bank", .finance, ["dbs.com", "dbs.com.sg"]),
        KnownService("Standard Chartered", .finance, ["sc.com"]),
        KnownService("OCBC", .finance, ["ocbc.com"]),
        KnownService("UOB", .finance, ["uob.com.sg", "uobgroup.com"]),
        KnownService("U.S. Bank", .finance, ["usbank.com"]),
        KnownService("Discover", .finance, ["discover.com"]),
        KnownService("Ally", .finance, ["ally.com"]),
        KnownService("PNC", .finance, ["pnc.com"]),
        KnownService("TD Bank", .finance, ["td.com", "tdbank.com"]),
        KnownService("RBC", .finance, ["rbc.com", "rbcroyalbank.com"]),
        KnownService("Scotiabank", .finance, ["scotiabank.com"]),
        KnownService("BMO", .finance, ["bmo.com"]),
        KnownService("Lloyds Bank", .finance, ["lloydsbank.com", "lloydsbank.co.uk"]),
        KnownService("NatWest", .finance, ["natwest.com"]),
        KnownService("Halifax", .finance, ["halifax.co.uk"]),
        KnownService("Nationwide", .finance, ["nationwide.co.uk"]),
        KnownService("Santander", .finance, ["santander.com", "santander.co.uk"], brands: ["santander"]),
        KnownService("Starling Bank", .finance, ["starlingbank.com"]),
        KnownService("Commonwealth Bank", .finance, ["commbank.com.au"]),
        KnownService("Westpac", .finance, ["westpac.com.au"]),
        KnownService("ANZ", .finance, ["anz.com", "anz.com.au"]),
        KnownService("NAB", .finance, ["nab.com.au"]),
        KnownService("Deutsche Bank", .finance, ["db.com", "deutsche-bank.de"]),
        KnownService("ING", .finance, ["ing.com", "ing.nl", "ing.de"]),
        KnownService("Chime", .finance, ["chime.com"]),
        KnownService("SoFi", .finance, ["sofi.com"]),
        // Finance: brokers and exchanges
        KnownService("Interactive Brokers", .finance, ["interactivebrokers.com", "ibkr.com", "interactivebrokers.co.in", "interactivebrokers.co.uk"]),
        KnownService("Zerodha", .finance, ["zerodha.com", "kite.trade", "kite.zerodha.com", "console.zerodha.com"]),
        KnownService("Angel One", .finance, ["angelone.in", "angelbroking.com"]),
        KnownService("Upstox", .finance, ["upstox.com"]),
        KnownService("Groww", .finance, ["groww.in"]),
        KnownService("Dhan", .finance, ["dhan.co"]),
        KnownService("5paisa", .finance, ["5paisa.com"]),
        KnownService("Alpaca", .finance, ["alpaca.markets"]),
        KnownService("OANDA", .finance, ["oanda.com"]),
        KnownService("Exness", .finance, ["exness.com"]),
        KnownService("Robinhood", .finance, ["robinhood.com"]),
        KnownService("Fidelity", .finance, ["fidelity.com"]),
        KnownService("Charles Schwab", .finance, ["schwab.com"]),
        KnownService("Vanguard", .finance, ["vanguard.com"]),
        KnownService("E*TRADE", .finance, ["etrade.com"]),
        KnownService("TradingView", .finance, ["tradingview.com"]),
        KnownService("Coinbase", .finance, ["coinbase.com"]),
        KnownService("Binance", .finance, ["binance.com"]),
        KnownService("Kraken", .finance, ["kraken.com"]),
        KnownService("CoinDCX", .finance, ["coindcx.com"]),
        KnownService("WazirX", .finance, ["wazirx.com"]),
        KnownService("CAMS", .finance, ["camsonline.com"]),
        KnownService("ICICI Direct", .finance, ["icicidirect.com"]),
        KnownService("HDFC Securities", .finance, ["hdfcsec.com"]),
        KnownService("Motilal Oswal", .finance, ["motilaloswal.com"]),
        KnownService("Sharekhan", .finance, ["sharekhan.com"]),
        KnownService("Paytm Money", .finance, ["paytmmoney.com"]),
        KnownService("INDmoney", .finance, ["indmoney.com"]),
        KnownService("Kuvera", .finance, ["kuvera.in"]),
        KnownService("smallcase", .finance, ["smallcase.com"]),
        KnownService("Fyers", .finance, ["fyers.in"]),
        KnownService("Sensibull", .finance, ["sensibull.com"]),
        KnownService("NSDL", .finance, ["nsdl.co.in", "nsdl.com"]),
        KnownService("CDSL", .finance, ["cdslindia.com"]),
        KnownService("KFintech", .finance, ["kfintech.com"]),
        KnownService("MF Central", .finance, ["mfcentral.com"]),
        KnownService("LIC", .finance, ["licindia.in"]),
        KnownService("Policybazaar", .finance, ["policybazaar.com"]),
        KnownService("Bajaj Finserv", .finance, ["bajajfinserv.in"]),
        KnownService("CIBIL", .finance, ["cibil.com"]),
        KnownService("Webull", .finance, ["webull.com"]),
        KnownService("eToro", .finance, ["etoro.com"]),
        KnownService("Trading 212", .finance, ["trading212.com"]),
        KnownService("Merrill", .finance, ["merrilledge.com", "ml.com"]),
        KnownService("moomoo", .finance, ["moomoo.com"]),
        KnownService("Crypto.com", .finance, ["crypto.com"]),
        KnownService("Bybit", .finance, ["bybit.com"]),
        KnownService("OKX", .finance, ["okx.com"]),
        KnownService("KuCoin", .finance, ["kucoin.com"]),
        KnownService("Gemini", .finance, ["gemini.com"]),
        KnownService("Bitstamp", .finance, ["bitstamp.net"]),
        KnownService("CoinSwitch", .finance, ["coinswitch.co"]),
        KnownService("Ledger", .finance, ["ledger.com"]),
        KnownService("MetaMask", .finance, ["metamask.io"]),
        KnownService("Intuit", .finance, ["intuit.com", "turbotax.com", "quickbooks.com", "creditkarma.com"]),
        KnownService("Xero", .finance, ["xero.com"]),
        KnownService("Experian", .finance, ["experian.com"], brands: ["experian"]),
        KnownService("Equifax", .finance, ["equifax.com"], brands: ["equifax"]),
        KnownService("TransUnion", .finance, ["transunion.com"]),
        KnownService("Income Tax India", .finance, ["incometax.gov.in", "incometaxindiaefiling.gov.in"]),
        KnownService("GST Portal", .finance, ["gst.gov.in"]),
        KnownService("EPFO", .finance, ["epfindia.gov.in"]),
        KnownService("IRS", .finance, ["irs.gov"]),
        KnownService("Social Security", .finance, ["ssa.gov"]),
        // Finance: payments
        KnownService("Stripe", .finance, ["stripe.com"]),
        KnownService("Razorpay", .finance, ["razorpay.com"]),
        KnownService("PayPal", .finance, ["paypal.com"], brands: ["paypal"]),
        KnownService("Paytm", .finance, ["paytm.com"]),
        KnownService("PhonePe", .finance, ["phonepe.com"]),
        KnownService("Cashfree", .finance, ["cashfree.com"]),
        KnownService("Square", .finance, ["squareup.com"]),
        KnownService("Venmo", .finance, ["venmo.com"]),
        KnownService("MobiKwik", .finance, ["mobikwik.com"]),
        KnownService("CRED", .finance, ["cred.club"]),
        KnownService("BHIM", .finance, ["bhimupi.org.in"]),
        KnownService("PayU", .finance, ["payu.in", "payu.com"]),
        KnownService("Instamojo", .finance, ["instamojo.com"]),
        KnownService("Klarna", .finance, ["klarna.com"]),
        KnownService("Cash App", .finance, ["cash.app"]),
        KnownService("Zelle", .finance, ["zellepay.com"]),

        // Developer & Cloud
        KnownService("AWS", .developerCloud, ["aws.amazon.com", "signin.aws", "amazonaws.com", "aws.com", "awsapps.com"]),
        KnownService("Cloudflare", .developerCloud, ["cloudflare.com"]),
        KnownService("GitHub", .developerCloud, ["github.com"]),
        KnownService("GitLab", .developerCloud, ["gitlab.com"]),
        KnownService("Bitbucket", .developerCloud, ["bitbucket.org"]),
        KnownService("Vercel", .developerCloud, ["vercel.com"]),
        KnownService("Supabase", .developerCloud, ["supabase.com", "supabase.io"]),
        KnownService("Netlify", .developerCloud, ["netlify.com"]),
        KnownService("Heroku", .developerCloud, ["heroku.com"]),
        KnownService("DigitalOcean", .developerCloud, ["digitalocean.com"]),
        KnownService("Hugging Face", .developerCloud, ["huggingface.co"]),
        KnownService("PyPI", .developerCloud, ["pypi.org"]),
        KnownService("npm", .developerCloud, ["npmjs.com"]),
        KnownService("Replit", .developerCloud, ["replit.com"]),
        KnownService("Oracle Cloud", .developerCloud, ["cloud.oracle.com", "oraclecloud.com", "oracle.com"]),
        KnownService("Google Cloud", .developerCloud, ["cloud.google.com", "console.cloud.google.com", "firebase.google.com"]),
        KnownService("Microsoft Azure", .developerCloud, ["azure.com", "portal.azure.com", "azure.microsoft.com"]),
        KnownService("Docker", .developerCloud, ["docker.com"]),
        KnownService("Render", .developerCloud, ["render.com"]),
        KnownService("Fly.io", .developerCloud, ["fly.io"]),
        KnownService("Railway", .developerCloud, ["railway.app"]),
        KnownService("Linode", .developerCloud, ["linode.com"]),
        KnownService("Vultr", .developerCloud, ["vultr.com"]),
        KnownService("Hetzner", .developerCloud, ["hetzner.com", "hetzner.cloud"]),
        KnownService("Firebase", .developerCloud, ["firebase.com"]),
        KnownService("MongoDB Atlas", .developerCloud, ["mongodb.com"]),
        KnownService("OpenAI", .developerCloud, ["openai.com", "chatgpt.com"]),
        KnownService("Anthropic", .developerCloud, ["anthropic.com", "claude.ai"]),
        KnownService("Kaggle", .developerCloud, ["kaggle.com"]),
        KnownService("Stack Overflow", .developerCloud, ["stackoverflow.com", "stackexchange.com"]),
        KnownService("Sentry", .developerCloud, ["sentry.io"]),
        KnownService("Postman", .developerCloud, ["postman.com"]),
        KnownService("JetBrains", .developerCloud, ["jetbrains.com"]),
        KnownService("Expo", .developerCloud, ["expo.dev"]),
        KnownService("Apple Developer", .developerCloud, ["developer.apple.com", "appstoreconnect.apple.com"]),
        KnownService("IBM Cloud", .developerCloud, ["cloud.ibm.com"]),
        KnownService("Alibaba Cloud", .developerCloud, ["alibabacloud.com", "aliyun.com"]),
        KnownService("OVHcloud", .developerCloud, ["ovhcloud.com", "ovh.com"]),
        KnownService("Scaleway", .developerCloud, ["scaleway.com"]),
        KnownService("Backblaze", .developerCloud, ["backblaze.com"]),
        KnownService("Wasabi", .developerCloud, ["wasabi.com"]),
        KnownService("Cloudinary", .developerCloud, ["cloudinary.com"]),
        KnownService("Codeberg", .developerCloud, ["codeberg.org"]),
        KnownService("SourceHut", .developerCloud, ["sr.ht"]),
        KnownService("HashiCorp", .developerCloud, ["hashicorp.com", "terraform.io"]),
        KnownService("Datadog", .developerCloud, ["datadoghq.com", "datadoghq.eu"]),
        KnownService("New Relic", .developerCloud, ["newrelic.com"]),
        KnownService("Grafana", .developerCloud, ["grafana.com", "grafana.net"]),
        KnownService("PagerDuty", .developerCloud, ["pagerduty.com"]),
        KnownService("Twilio", .developerCloud, ["twilio.com", "sendgrid.com"]),
        KnownService("Mailgun", .developerCloud, ["mailgun.com"]),
        KnownService("Algolia", .developerCloud, ["algolia.com"]),
        KnownService("Neon", .developerCloud, ["neon.tech"]),
        KnownService("PlanetScale", .developerCloud, ["planetscale.com"]),
        KnownService("Upstash", .developerCloud, ["upstash.com"]),
        KnownService("CircleCI", .developerCloud, ["circleci.com"]),
        KnownService("Snyk", .developerCloud, ["snyk.io"]),
        KnownService("Tailscale", .developerCloud, ["tailscale.com"]),
        KnownService("ngrok", .developerCloud, ["ngrok.com"]),
        KnownService("Deno", .developerCloud, ["deno.com"]),
        KnownService("CodeSandbox", .developerCloud, ["codesandbox.io"]),
        KnownService("Cursor", .developerCloud, ["cursor.com"]),
        KnownService("Mistral AI", .developerCloud, ["mistral.ai"]),
        KnownService("Perplexity", .developerCloud, ["perplexity.ai"]),

        // Shopping & Travel
        KnownService("Amazon", .shoppingTravel, ["amazon.com"], brands: ["amazon"]),
        KnownService("Flipkart", .shoppingTravel, ["flipkart.com"]),
        KnownService("Myntra", .shoppingTravel, ["myntra.com"]),
        KnownService("Meesho", .shoppingTravel, ["meesho.com"]),
        KnownService("eBay", .shoppingTravel, ["ebay.com"], brands: ["ebay"]),
        KnownService("Walmart", .shoppingTravel, ["walmart.com"]),
        KnownService("AliExpress", .shoppingTravel, ["aliexpress.com"]),
        KnownService("IKEA", .shoppingTravel, ["ikea.com"]),
        KnownService("Swiggy", .shoppingTravel, ["swiggy.com"]),
        KnownService("Zomato", .shoppingTravel, ["zomato.com"]),
        KnownService("IRCTC", .shoppingTravel, ["irctc.co.in"]),
        KnownService("MakeMyTrip", .shoppingTravel, ["makemytrip.com"]),
        KnownService("Goibibo", .shoppingTravel, ["goibibo.com"]),
        KnownService("Cleartrip", .shoppingTravel, ["cleartrip.com"]),
        KnownService("Airbnb", .shoppingTravel, ["airbnb.com"], brands: ["airbnb"]),
        KnownService("Booking.com", .shoppingTravel, ["booking.com"]),
        KnownService("Expedia", .shoppingTravel, ["expedia.com"], brands: ["expedia"]),
        KnownService("Agoda", .shoppingTravel, ["agoda.com"]),
        KnownService("Uber", .shoppingTravel, ["uber.com", "ubereats.com"]),
        KnownService("Ola", .shoppingTravel, ["olacabs.com"]),
        KnownService("Lyft", .shoppingTravel, ["lyft.com"]),
        KnownService("IndiGo", .shoppingTravel, ["goindigo.in"]),
        KnownService("Air India", .shoppingTravel, ["airindia.com", "airindia.in"]),
        KnownService("Etsy", .shoppingTravel, ["etsy.com"]),
        KnownService("Apple Store", .shoppingTravel, ["store.apple.com"]),
        KnownService("Target", .shoppingTravel, ["target.com"]),
        KnownService("Best Buy", .shoppingTravel, ["bestbuy.com"]),
        KnownService("Costco", .shoppingTravel, ["costco.com"]),
        KnownService("The Home Depot", .shoppingTravel, ["homedepot.com"]),
        KnownService("Shein", .shoppingTravel, ["shein.com"], brands: ["shein"]),
        KnownService("Temu", .shoppingTravel, ["temu.com"]),
        KnownService("Zara", .shoppingTravel, ["zara.com"]),
        KnownService("H&M", .shoppingTravel, ["hm.com"]),
        KnownService("Nike", .shoppingTravel, ["nike.com"]),
        KnownService("Alibaba", .shoppingTravel, ["alibaba.com"]),
        KnownService("Taobao", .shoppingTravel, ["taobao.com"]),
        KnownService("Rakuten", .shoppingTravel, ["rakuten.com", "rakuten.co.jp"]),
        KnownService("Mercado Libre", .shoppingTravel, ["mercadolibre.com"], brands: ["mercadolibre"]),
        KnownService("Instacart", .shoppingTravel, ["instacart.com"]),
        KnownService("DoorDash", .shoppingTravel, ["doordash.com"]),
        KnownService("Deliveroo", .shoppingTravel, ["deliveroo.co.uk"], brands: ["deliveroo"]),
        KnownService("USPS", .shoppingTravel, ["usps.com"]),
        KnownService("Ajio", .shoppingTravel, ["ajio.com"]),
        KnownService("Nykaa", .shoppingTravel, ["nykaa.com"]),
        KnownService("Tata CLiQ", .shoppingTravel, ["tatacliq.com"]),
        KnownService("Croma", .shoppingTravel, ["croma.com"]),
        KnownService("Reliance Digital", .shoppingTravel, ["reliancedigital.in"]),
        KnownService("JioMart", .shoppingTravel, ["jiomart.com"]),
        KnownService("BigBasket", .shoppingTravel, ["bigbasket.com"]),
        KnownService("Blinkit", .shoppingTravel, ["blinkit.com"]),
        KnownService("Zepto", .shoppingTravel, ["zeptonow.com"]),
        KnownService("Snapdeal", .shoppingTravel, ["snapdeal.com"]),
        KnownService("FirstCry", .shoppingTravel, ["firstcry.com"]),
        KnownService("Lenskart", .shoppingTravel, ["lenskart.com"]),
        KnownService("BookMyShow", .shoppingTravel, ["bookmyshow.com"]),
        // Travel
        KnownService("Trip.com", .shoppingTravel, ["trip.com"]),
        KnownService("Skyscanner", .shoppingTravel, ["skyscanner.com", "skyscanner.net"], brands: ["skyscanner"]),
        KnownService("Kayak", .shoppingTravel, ["kayak.com"], brands: ["kayak"]),
        KnownService("Hotels.com", .shoppingTravel, ["hotels.com"]),
        KnownService("Tripadvisor", .shoppingTravel, ["tripadvisor.com"], brands: ["tripadvisor"]),
        KnownService("Vrbo", .shoppingTravel, ["vrbo.com"]),
        KnownService("ixigo", .shoppingTravel, ["ixigo.com"]),
        KnownService("EaseMyTrip", .shoppingTravel, ["easemytrip.com"]),
        KnownService("Yatra", .shoppingTravel, ["yatra.com"]),
        KnownService("redBus", .shoppingTravel, ["redbus.in"]),
        KnownService("OYO", .shoppingTravel, ["oyorooms.com"]),
        KnownService("Rapido", .shoppingTravel, ["rapido.bike"]),
        KnownService("Grab", .shoppingTravel, ["grab.com"]),
        KnownService("Bolt", .shoppingTravel, ["bolt.eu"]),
        KnownService("SpiceJet", .shoppingTravel, ["spicejet.com"]),
        KnownService("Akasa Air", .shoppingTravel, ["akasaair.com"]),
        KnownService("Emirates", .shoppingTravel, ["emirates.com"]),
        KnownService("Qatar Airways", .shoppingTravel, ["qatarairways.com"]),
        KnownService("Singapore Airlines", .shoppingTravel, ["singaporeair.com"]),
        KnownService("Lufthansa", .shoppingTravel, ["lufthansa.com"]),
        KnownService("British Airways", .shoppingTravel, ["britishairways.com"]),
        KnownService("Delta", .shoppingTravel, ["delta.com"]),
        KnownService("United Airlines", .shoppingTravel, ["united.com"]),
        KnownService("American Airlines", .shoppingTravel, ["aa.com"]),
        KnownService("Southwest", .shoppingTravel, ["southwest.com"]),
        KnownService("Ryanair", .shoppingTravel, ["ryanair.com"]),
        KnownService("easyJet", .shoppingTravel, ["easyjet.com"]),
        KnownService("Marriott", .shoppingTravel, ["marriott.com"]),
        KnownService("Hilton", .shoppingTravel, ["hilton.com"]),
        KnownService("IHG", .shoppingTravel, ["ihg.com"]),
        KnownService("Hyatt", .shoppingTravel, ["hyatt.com"]),
        KnownService("Accor", .shoppingTravel, ["accor.com"]),
        KnownService("Amtrak", .shoppingTravel, ["amtrak.com"]),
        KnownService("Trainline", .shoppingTravel, ["thetrainline.com"]),
        KnownService("Parivahan", .shoppingTravel, ["parivahan.gov.in"]),
        // Telecoms, TV and utility bills (filed with Shopping)
        KnownService("Jio", .shoppingTravel, ["jio.com"]),
        KnownService("Airtel", .shoppingTravel, ["airtel.in", "airtel.com"]),
        KnownService("Vi", .shoppingTravel, ["myvi.in"]),
        KnownService("BSNL", .shoppingTravel, ["bsnl.co.in"]),
        KnownService("Tata Play", .shoppingTravel, ["tataplay.com"]),
        KnownService("Tata Power", .shoppingTravel, ["tatapower.com"]),
        KnownService("Adani Electricity", .shoppingTravel, ["adanielectricity.com"]),
        KnownService("Verizon", .shoppingTravel, ["verizon.com"]),
        KnownService("AT&T", .shoppingTravel, ["att.com"]),
        KnownService("T-Mobile", .shoppingTravel, ["t-mobile.com"]),
        KnownService("Xfinity", .shoppingTravel, ["xfinity.com"]),
        KnownService("Vodafone", .shoppingTravel, ["vodafone.com", "vodafone.co.uk"], brands: ["vodafone"]),
        KnownService("EE", .shoppingTravel, ["ee.co.uk"]),

        // Gaming
        KnownService("Riot Games", .gaming, ["riotgames.com", "leagueoflegends.com", "playvalorant.com"]),
        KnownService("Steam", .gaming, ["steampowered.com", "steamcommunity.com"]),
        KnownService("Epic Games", .gaming, ["epicgames.com"]),
        KnownService("Chess.com", .gaming, ["chess.com"]),
        KnownService("Lichess", .gaming, ["lichess.org"]),
        KnownService("PlayStation", .gaming, ["playstation.com", "sonyentertainmentnetwork.com"]),
        KnownService("Nintendo", .gaming, ["nintendo.com"]),
        KnownService("Battle.net", .gaming, ["battle.net", "blizzard.com"]),
        KnownService("EA", .gaming, ["ea.com"]),
        KnownService("Ubisoft", .gaming, ["ubisoft.com"]),
        KnownService("Roblox", .gaming, ["roblox.com"]),
        KnownService("GOG", .gaming, ["gog.com"]),
        KnownService("Rockstar Games", .gaming, ["rockstargames.com"]),
        KnownService("Minecraft", .gaming, ["minecraft.net"]),
        KnownService("Activision", .gaming, ["activision.com"]),
        KnownService("Bungie", .gaming, ["bungie.net"]),
        KnownService("Bethesda", .gaming, ["bethesda.net"]),
        KnownService("Square Enix", .gaming, ["square-enix.com"]),
        KnownService("HoYoverse", .gaming, ["hoyoverse.com", "mihoyo.com"]),
        KnownService("Supercell", .gaming, ["supercell.com"]),
        KnownService("Garena", .gaming, ["garena.com"]),
        KnownService("Wargaming", .gaming, ["wargaming.net"]),
        KnownService("itch.io", .gaming, ["itch.io"]),
        KnownService("Humble Bundle", .gaming, ["humblebundle.com"]),
        KnownService("FACEIT", .gaming, ["faceit.com"]),
        KnownService("Nexus Mods", .gaming, ["nexusmods.com"]),
        KnownService("Dream11", .gaming, ["dream11.com"]),

        // Learning & Research
        KnownService("Udemy", .learning, ["udemy.com"]),
        KnownService("Coursera", .learning, ["coursera.org"]),
        KnownService("edX", .learning, ["edx.org"]),
        KnownService("IEEE", .learning, ["ieee.org"]),
        KnownService("SSRN", .learning, ["ssrn.com"]),
        KnownService("ResearchGate", .learning, ["researchgate.net"]),
        KnownService("Canvas", .learning, ["instructure.com"], multiTenant: true),
        KnownService("Khan Academy", .learning, ["khanacademy.org"]),
        KnownService("Duolingo", .learning, ["duolingo.com"]),
        KnownService("NPTEL", .learning, ["nptel.ac.in", "swayam.gov.in"]),
        KnownService("Google Scholar", .learning, ["scholar.google.com"]),
        KnownService("arXiv", .learning, ["arxiv.org"]),
        KnownService("ORCID", .learning, ["orcid.org"]),
        KnownService("Elsevier", .learning, ["elsevier.com", "sciencedirect.com"]),
        KnownService("Springer", .learning, ["springer.com", "springernature.com"]),
        KnownService("JSTOR", .learning, ["jstor.org"]),
        KnownService("Overleaf", .learning, ["overleaf.com"]),
        KnownService("Mendeley", .learning, ["mendeley.com"]),
        KnownService("Zotero", .learning, ["zotero.org"]),
        KnownService("Brilliant", .learning, ["brilliant.org"]),
        KnownService("LeetCode", .learning, ["leetcode.com"]),
        KnownService("HackerRank", .learning, ["hackerrank.com"]),
        KnownService("Codeforces", .learning, ["codeforces.com"]),
        KnownService("Moodle", .learning, ["moodlecloud.com"], multiTenant: true),
        KnownService("Blackboard", .learning, ["blackboard.com"], multiTenant: true),
        KnownService("Google Classroom", .learning, ["classroom.google.com"]),
        KnownService("Skillshare", .learning, ["skillshare.com"]),
        KnownService("Pluralsight", .learning, ["pluralsight.com"]),
        KnownService("Udacity", .learning, ["udacity.com"]),
        KnownService("Codecademy", .learning, ["codecademy.com"]),
        KnownService("DataCamp", .learning, ["datacamp.com"]),
        KnownService("freeCodeCamp", .learning, ["freecodecamp.org"]),
        KnownService("BYJU'S", .learning, ["byjus.com"]),
        KnownService("Unacademy", .learning, ["unacademy.com"]),
        KnownService("Physics Wallah", .learning, ["pw.live"]),
        KnownService("upGrad", .learning, ["upgrad.com"]),
        KnownService("Great Learning", .learning, ["mygreatlearning.com"]),
        KnownService("Scaler", .learning, ["scaler.com"]),
        KnownService("GeeksforGeeks", .learning, ["geeksforgeeks.org"]),
        KnownService("CodeChef", .learning, ["codechef.com"]),
        KnownService("AtCoder", .learning, ["atcoder.jp"]),
        KnownService("Chegg", .learning, ["chegg.com"]),
        KnownService("Quizlet", .learning, ["quizlet.com"]),
        KnownService("Wolfram", .learning, ["wolfram.com", "wolframalpha.com"]),
        KnownService("Wiley", .learning, ["wiley.com"]),
        KnownService("Taylor & Francis", .learning, ["tandfonline.com"]),
        KnownService("Nature", .learning, ["nature.com"]),
        KnownService("ACM", .learning, ["acm.org"]),
        KnownService("Semantic Scholar", .learning, ["semanticscholar.org"]),
        KnownService("Academia.edu", .learning, ["academia.edu"]),

        // Careers
        KnownService("Workday", .careers, ["myworkdayjobs.com", "myworkday.com", "workday.com"], multiTenant: true),
        KnownService("Taleo", .careers, ["taleo.net"], multiTenant: true),
        KnownService("Oleeo (tal.net)", .careers, ["tal.net"], multiTenant: true),
        KnownService("SuccessFactors", .careers, ["successfactors.com", "successfactors.eu", "sapsf.com", "sapsf.eu"], multiTenant: true),
        KnownService("iCIMS", .careers, ["icims.com"], multiTenant: true),
        KnownService("Greenhouse", .careers, ["greenhouse.io"], multiTenant: true),
        KnownService("Lever", .careers, ["lever.co"], multiTenant: true),
        KnownService("SmartRecruiters", .careers, ["smartrecruiters.com"], multiTenant: true),
        KnownService("Ashby", .careers, ["ashbyhq.com"], multiTenant: true),
        KnownService("Jobvite", .careers, ["jobvite.com"], multiTenant: true),
        KnownService("BambooHR", .careers, ["bamboohr.com"], multiTenant: true),
        KnownService("Indeed", .careers, ["indeed.com"], brands: ["indeed"]),
        KnownService("Naukri", .careers, ["naukri.com"]),
        KnownService("Glassdoor", .careers, ["glassdoor.com"], brands: ["glassdoor"]),
        KnownService("Wellfound", .careers, ["wellfound.com", "angel.co"]),
        KnownService("Internshala", .careers, ["internshala.com"]),
        KnownService("Instahyre", .careers, ["instahyre.com"]),
        KnownService("Workable", .careers, ["workable.com"], multiTenant: true),
        KnownService("Recruitee", .careers, ["recruitee.com"], multiTenant: true),
        KnownService("Teamtailor", .careers, ["teamtailor.com"], multiTenant: true),
        KnownService("Personio", .careers, ["personio.de", "personio.com"], multiTenant: true),
        KnownService("Darwinbox", .careers, ["darwinbox.in"], multiTenant: true),
        KnownService("Keka", .careers, ["keka.com"], multiTenant: true),
        KnownService("Monster", .careers, ["monster.com"]),
        KnownService("ZipRecruiter", .careers, ["ziprecruiter.com"]),
        KnownService("Dice", .careers, ["dice.com"]),
        KnownService("foundit", .careers, ["foundit.in"]),
        KnownService("Shine", .careers, ["shine.com"]),
        KnownService("Cutshort", .careers, ["cutshort.io"]),
        KnownService("Upwork", .careers, ["upwork.com"]),
        KnownService("Fiverr", .careers, ["fiverr.com"]),
        KnownService("Freelancer", .careers, ["freelancer.com"]),
        KnownService("Toptal", .careers, ["toptal.com"]),

        // Work & Productivity
        KnownService("Odoo", .work, ["odoo.com"], multiTenant: true),
        KnownService("Notion", .work, ["notion.so", "notion.com"]),
        KnownService("Slack", .work, ["slack.com"], multiTenant: true),
        KnownService("Atlassian", .work, ["atlassian.com", "atlassian.net", "jira.com", "trello.com"], multiTenant: true),
        KnownService("Calendly", .work, ["calendly.com"]),
        KnownService("Mailchimp", .work, ["mailchimp.com"]),
        KnownService("Zoom", .work, ["zoom.us", "zoom.com"]),
        KnownService("Dropbox", .work, ["dropbox.com"]),
        KnownService("Box", .work, ["box.com"]),
        KnownService("Asana", .work, ["asana.com"]),
        KnownService("Monday.com", .work, ["monday.com"]),
        KnownService("ClickUp", .work, ["clickup.com"]),
        KnownService("Linear", .work, ["linear.app"]),
        KnownService("Figma", .work, ["figma.com"]),
        KnownService("Canva", .work, ["canva.com"]),
        KnownService("Miro", .work, ["miro.com"]),
        KnownService("Airtable", .work, ["airtable.com"]),
        KnownService("HubSpot", .work, ["hubspot.com"]),
        KnownService("Salesforce", .work, ["salesforce.com", "force.com"], multiTenant: true),
        KnownService("Zapier", .work, ["zapier.com"]),
        KnownService("DocuSign", .work, ["docusign.com", "docusign.net"]),
        KnownService("Adobe", .work, ["adobe.com"]),
        KnownService("Grammarly", .work, ["grammarly.com"]),
        KnownService("Evernote", .work, ["evernote.com"]),
        KnownService("Todoist", .work, ["todoist.com"]),
        KnownService("Zoho Workplace", .work, ["zohoworkplace.com"]),
        KnownService("Microsoft Teams", .work, ["teams.microsoft.com"]),
        KnownService("Webex", .work, ["webex.com"]),
        KnownService("Loom", .work, ["loom.com"]),
        KnownService("Basecamp", .work, ["basecamp.com"]),
        KnownService("Smartsheet", .work, ["smartsheet.com"]),
        KnownService("Coda", .work, ["coda.io"]),
        KnownService("Obsidian", .work, ["obsidian.md"]),
        KnownService("Typeform", .work, ["typeform.com"]),
        KnownService("SurveyMonkey", .work, ["surveymonkey.com"]),
        KnownService("Zendesk", .work, ["zendesk.com"], multiTenant: true),
        KnownService("Freshworks", .work, ["freshworks.com", "freshdesk.com"], multiTenant: true),
        KnownService("Intercom", .work, ["intercom.com"]),
        KnownService("ServiceNow", .work, ["service-now.com", "servicenow.com"], multiTenant: true),
        KnownService("Shopify", .work, ["shopify.com"]),
        KnownService("Rippling", .work, ["rippling.com"]),
        KnownService("Deel", .work, ["deel.com"]),

        // Hosting & Domains
        KnownService("Hostinger", .hosting, ["hostinger.com", "hostinger.in", "hpanel.hostinger.com"], brands: ["hostinger"]),
        KnownService("Namecheap", .hosting, ["namecheap.com"]),
        KnownService("GoDaddy", .hosting, ["godaddy.com"], brands: ["godaddy"]),
        KnownService("cPanel", .hosting, ["cpanel.net", "cpanel.com"]),
        KnownService("Bluehost", .hosting, ["bluehost.com", "bluehost.in"]),
        KnownService("HostGator", .hosting, ["hostgator.com", "hostgator.in"]),
        KnownService("SiteGround", .hosting, ["siteground.com"]),
        KnownService("Porkbun", .hosting, ["porkbun.com"]),
        KnownService("Squarespace", .hosting, ["squarespace.com"]),
        KnownService("Wix", .hosting, ["wix.com"]),
        KnownService("WordPress.com", .hosting, ["wordpress.com", "wordpress.org"]),
        KnownService("Google Domains", .hosting, ["domains.google"]),
        KnownService("Gandi", .hosting, ["gandi.net"]),
        KnownService("Dynadot", .hosting, ["dynadot.com"]),
        KnownService("Name.com", .hosting, ["name.com"]),
        KnownService("BigRock", .hosting, ["bigrock.in"]),
        KnownService("DreamHost", .hosting, ["dreamhost.com"]),
        KnownService("IONOS", .hosting, ["ionos.com", "ionos.de", "ionos.co.uk"], brands: ["ionos"]),
        KnownService("Hover", .hosting, ["hover.com"]),
        KnownService("Network Solutions", .hosting, ["networksolutions.com"]),
        KnownService("Cloudways", .hosting, ["cloudways.com"]),
        KnownService("Kinsta", .hosting, ["kinsta.com"]),
        KnownService("WP Engine", .hosting, ["wpengine.com"]),
        KnownService("Webflow", .hosting, ["webflow.com"]),
        KnownService("Contabo", .hosting, ["contabo.com"]),
        KnownService("Spaceship", .hosting, ["spaceship.com"]),
        KnownService("ResellerClub", .hosting, ["resellerclub.com"]),
        KnownService("MilesWeb", .hosting, ["milesweb.in"]),
    ]

    private static let domainIndex: [String: KnownService] = {
        var d: [String: KnownService] = [:]
        for s in services { for dom in s.domains where d[dom] == nil { d[dom] = s } }
        return d
    }()

    private static let brandIndex: [String: KnownService] = {
        var d: [String: KnownService] = [:]
        for s in services { for b in s.brands where d[b] == nil { d[b] = s } }
        return d
    }()

    /// Labels that never name a tenant ("www.", "login.", "wd5.").
    static let genericLabels: Set<String> = [
        "www", "www1", "www2", "m", "mobile", "app", "apps", "web", "login", "signin", "sign-in", "auth", "account",
        "accounts", "secure", "portal", "my", "id", "sso", "careers", "career", "jobs", "job", "boards", "apply",
        "hire", "recruiting", "console", "dashboard", "admin", "api", "en", "us", "eu", "uk", "in",
    ]

    /// Classifies a URL. nil when it has no usable host.
    public static func classify(url: String) -> ServiceMatch? {
        guard let host = DomainName.host(url) else { return nil }
        let reg = DomainName.registrable(host: host)
        let labels = host.split(separator: ".").map(String.init)
        let regCount = reg.split(separator: ".").count
        // Longest parent first, down to (and including) the registrable domain;
        // then shorter catalog keys such as "signin.aws" whose suffix is a TLD.
        if !DomainName.isIPAddress(host) {
            for start in 0 ..< labels.count {
                let candidate = labels[start...].joined(separator: ".")
                if let s = domainIndex[candidate] {
                    return ServiceMatch(category: s.category, service: s.name, known: true,
                                        tenant: s.multiTenant ? tenant(labels: Array(labels[..<start])) : nil,
                                        registrableDomain: reg)
                }
                if labels.count - start <= regCount { break }
            }
            if let s = brandIndex[DomainName.brandLabel(ofRegistrable: reg)] {
                return ServiceMatch(category: s.category, service: s.name, known: true, tenant: nil, registrableDomain: reg)
            }
        }
        return ServiceMatch(category: .other, service: reg, known: false, tenant: nil, registrableDomain: reg)
    }

    /// The organisation label of a multi-tenant host: the first label left of
    /// the matched domain that is not generic or a shard ("wd5", "eu2").
    static func tenant(labels: [String]) -> String? {
        for l in labels {
            let low = l.lowercased()
            if genericLabels.contains(low) { continue }
            if low.range(of: #"^[a-z]{1,3}\d{1,3}$"#, options: .regularExpression) != nil { continue }
            return low
        }
        return nil
    }

    public static func service(named name: String) -> KnownService? { services.first { $0.name == name } }
}
