package app.strongroom.android.core

/*
 * Service categories for Security Ranking (which accounts are critical), a
 * port of apps/macos/Sources/StrongroomKit/ServiceCatalog.swift (OQ-M9).
 * Everything is local: no network, no public-suffix download. Keep the
 * service list in step with the Swift file.
 */

/**
 * Host and registrable-domain extraction. The suffix list covers the
 * multi-label public suffixes that matter for consumer accounts (.co.uk,
 * .co.in, .com.au) plus a few hosting suffixes whose subdomains belong to
 * different owners (github.io, vercel.app, ...). Any other host is treated as
 * "<label>.<tld>".
 */
object DomainName {
    val multiLabelSuffixes: Set<String> = setOf(
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
    )

    /**
     * The lowercased host of a URL or bare domain ("instagram.com/x",
     * "https://user@Mail.Example.com:8443/"), without a trailing dot. Only
     * http(s) URLs (or bare domains) have a host here.
     */
    fun host(raw: String): String? {
        val s = raw.trim()
        if (s.isEmpty() || s.any { it.isWhitespace() }) return null
        val sep = s.indexOf("://")
        val rest = if (sep >= 0) {
            val scheme = s.substring(0, sep).lowercase()
            if (scheme != "http" && scheme != "https") return null
            s.substring(sep + 3)
        } else {
            s
        }
        var authority = rest.substring(0, rest.indexOfFirst { it == '/' || it == '?' || it == '#' }.let { if (it < 0) rest.length else it })
        authority = authority.substringAfterLast('@')
        var h = if (authority.startsWith("[")) {
            val end = authority.indexOf(']')
            if (end < 0) return null
            authority.substring(0, end + 1)
        } else {
            authority.substringBefore(':')
        }.lowercase()
        if (h.isEmpty()) return null
        while (h.endsWith(".")) h = h.dropLast(1)
        if (h.startsWith("[")) return h // IPv6 literal
        if (h.isEmpty() || !(h.any { it.isLetter() } || h.contains('.'))) return null
        return h
    }

    fun isIpAddress(host: String): Boolean {
        if (host.startsWith("[")) return true
        val parts = host.split('.')
        return parts.size == 4 && parts.all { p -> p.isNotEmpty() && p.all { it in '0'..'9' } && p.length <= 3 && p.toInt() <= 255 }
    }

    /** "mail.hostinger.com" -> "hostinger.com"; "www.bbc.co.uk" -> "bbc.co.uk". */
    fun registrable(host: String): String {
        val h = host.lowercase()
        if (isIpAddress(h)) return h
        val labels = h.split('.').filter { it.isNotEmpty() }
        if (labels.size <= 2) return h
        val lastTwo = labels.takeLast(2).joinToString(".")
        if (lastTwo in multiLabelSuffixes) return labels.takeLast(3).joinToString(".")
        return lastTwo
    }

    fun registrableOfUrl(url: String): String? = host(url)?.let { registrable(it) }

    /** The brand label: "amazon" for "amazon.co.uk". */
    fun brandLabel(registrableDomain: String): String = registrableDomain.split('.').firstOrNull { it.isNotEmpty() } ?: ""
}

/** Categories of the built-in service map. [folderName] is the folder name. */
enum class ServiceCategory(val folderName: String) {
    SOCIAL("Social"),
    EMAIL_IDENTITY("Email & Identity"),
    FINANCE("Finance"),
    DEVELOPER_CLOUD("Developer & Cloud"),
    SHOPPING_TRAVEL("Shopping & Travel"),
    GAMING("Gaming"),
    LEARNING("Learning & Research"),
    CAREERS("Careers"),
    WORK("Work & Productivity"),
    HOSTING("Hosting & Domains"),
    OTHER("Other"),
    ;

    /**
     * Accounts whose takeover hurts most: they reset other accounts (email),
     * move money (finance) or run infrastructure (developer & cloud).
     */
    val isCritical: Boolean get() = this == EMAIL_IDENTITY || this == FINANCE || this == DEVELOPER_CLOUD

    /**
     * Folder names (first component, case-insensitive) that mean this
     * category, so items the user filed by hand are recognised too.
     */
    val folderAliases: List<String>
        get() = when (this) {
            EMAIL_IDENTITY -> listOf("email & identity", "email", "e-mail", "mail", "identity", "accounts")
            FINANCE -> listOf("finance", "banking", "bank", "banks", "money", "investing", "investments", "trading", "crypto", "payments")
            DEVELOPER_CLOUD -> listOf("developer & cloud", "developer", "dev", "development", "cloud", "servers", "infrastructure", "infra")
            else -> listOf(folderName.lowercase())
        }

    companion object {
        fun fromFolder(folder: String?): ServiceCategory? {
            val first = FolderPath.components(folder).firstOrNull()?.lowercase() ?: return null
            return entries.firstOrNull { first in it.folderAliases }
        }
    }
}

/**
 * One well-known service. [domains] match a host or any of its parent
 * domains; [brands] match the brand label under any public suffix;
 * [multiTenant] services host many organisations on subdomains.
 */
data class KnownService(
    val name: String,
    val category: ServiceCategory,
    val domains: List<String>,
    val brands: List<String> = emptyList(),
    val multiTenant: Boolean = false,
)

/** The result of classifying a URL. */
data class ServiceMatch(
    val category: ServiceCategory,
    /** Display name ("Instagram"), or the registrable domain for unknown sites. */
    val service: String,
    val known: Boolean,
    /** Subdomain naming the organisation on a multi-tenant service. */
    val tenant: String?,
    val registrableDomain: String,
)

/**
 * Generic built-in map of well-known services. Deliberately not
 * personalised: it lists widely used services only.
 */
object ServiceCatalog {
    private fun S(
        name: String,
        category: ServiceCategory,
        domains: List<String>,
        brands: List<String> = emptyList(),
        multiTenant: Boolean = false,
    ) = KnownService(name, category, domains, brands, multiTenant)

    private val SOCIAL = ServiceCategory.SOCIAL
    private val EMAIL_IDENTITY = ServiceCategory.EMAIL_IDENTITY
    private val FINANCE = ServiceCategory.FINANCE
    private val DEVELOPER_CLOUD = ServiceCategory.DEVELOPER_CLOUD
    private val SHOPPING_TRAVEL = ServiceCategory.SHOPPING_TRAVEL
    private val GAMING = ServiceCategory.GAMING
    private val LEARNING = ServiceCategory.LEARNING
    private val CAREERS = ServiceCategory.CAREERS
    private val WORK = ServiceCategory.WORK
    private val HOSTING = ServiceCategory.HOSTING

    val services: List<KnownService> = listOf(
        // Social
        S("Instagram", SOCIAL, listOf("instagram.com")),
        S("X (Twitter)", SOCIAL, listOf("x.com", "twitter.com")),
        S("Facebook", SOCIAL, listOf("facebook.com", "fb.com", "messenger.com")),
        S("LinkedIn", SOCIAL, listOf("linkedin.com")),
        S("Discord", SOCIAL, listOf("discord.com", "discord.gg", "discordapp.com")),
        S("Twitch", SOCIAL, listOf("twitch.tv")),
        S("Reddit", SOCIAL, listOf("reddit.com")),
        S("TikTok", SOCIAL, listOf("tiktok.com")),
        S("Snapchat", SOCIAL, listOf("snapchat.com")),
        S("YouTube", SOCIAL, listOf("youtube.com")),
        S("Pinterest", SOCIAL, listOf("pinterest.com"), brands = listOf("pinterest")),
        S("Tumblr", SOCIAL, listOf("tumblr.com")),
        S("Quora", SOCIAL, listOf("quora.com")),
        S("Medium", SOCIAL, listOf("medium.com")),
        S("Threads", SOCIAL, listOf("threads.net")),
        S("Bluesky", SOCIAL, listOf("bsky.app")),
        S("Mastodon", SOCIAL, listOf("mastodon.social")),
        S("Telegram", SOCIAL, listOf("telegram.org", "t.me")),
        S("WhatsApp", SOCIAL, listOf("whatsapp.com")),
        S("Signal", SOCIAL, listOf("signal.org")),
        S("Spotify", SOCIAL, listOf("spotify.com")),
        S("Netflix", SOCIAL, listOf("netflix.com")),
        S("Vimeo", SOCIAL, listOf("vimeo.com")),
        S("Flickr", SOCIAL, listOf("flickr.com")),
        S("VK", SOCIAL, listOf("vk.com")),
        S("WeChat", SOCIAL, listOf("wechat.com")),
        S("LINE", SOCIAL, listOf("line.me")),
        S("Viber", SOCIAL, listOf("viber.com")),
        S("ShareChat", SOCIAL, listOf("sharechat.com")),
        S("Nextdoor", SOCIAL, listOf("nextdoor.com")),
        S("Goodreads", SOCIAL, listOf("goodreads.com")),
        S("Strava", SOCIAL, listOf("strava.com")),
        S("Substack", SOCIAL, listOf("substack.com")),
        S("Patreon", SOCIAL, listOf("patreon.com")),
        S("Tinder", SOCIAL, listOf("tinder.com")),
        S("Bumble", SOCIAL, listOf("bumble.com")),
        // Streaming (filed with Social, like Netflix and Spotify)
        S("Prime Video", SOCIAL, listOf("primevideo.com")),
        S("Disney+", SOCIAL, listOf("disneyplus.com")),
        S("JioHotstar", SOCIAL, listOf("hotstar.com", "jiohotstar.com")),
        S("Hulu", SOCIAL, listOf("hulu.com")),
        S("Max", SOCIAL, listOf("max.com", "hbomax.com")),
        S("Peacock", SOCIAL, listOf("peacocktv.com")),
        S("Paramount+", SOCIAL, listOf("paramountplus.com")),
        S("SonyLIV", SOCIAL, listOf("sonyliv.com")),
        S("ZEE5", SOCIAL, listOf("zee5.com")),
        S("Crunchyroll", SOCIAL, listOf("crunchyroll.com")),
        S("Plex", SOCIAL, listOf("plex.tv")),
        S("JioSaavn", SOCIAL, listOf("jiosaavn.com")),
        S("Gaana", SOCIAL, listOf("gaana.com")),
        S("SoundCloud", SOCIAL, listOf("soundcloud.com")),
        S("Deezer", SOCIAL, listOf("deezer.com")),
        S("Tidal", SOCIAL, listOf("tidal.com")),
        S("Audible", SOCIAL, listOf("audible.com"), brands = listOf("audible")),

        // Email & Identity
        S("Google", EMAIL_IDENTITY, listOf("google.com", "gmail.com", "accounts.google.com", "googlemail.com"), brands = listOf("google")),
        S("Proton", EMAIL_IDENTITY, listOf("proton.me", "protonmail.com", "protonmail.ch")),
        S("Microsoft", EMAIL_IDENTITY, listOf("microsoft.com", "live.com", "outlook.com", "hotmail.com", "microsoftonline.com", "office.com", "office365.com", "xbox.com", "skype.com")),
        S("Yahoo", EMAIL_IDENTITY, listOf("yahoo.com", "ymail.com"), brands = listOf("yahoo")),
        S("Apple Account", EMAIL_IDENTITY, listOf("apple.com", "icloud.com", "appleid.apple.com", "me.com")),
        S("Zoho Mail", EMAIL_IDENTITY, listOf("zoho.com", "zoho.in", "zoho.eu")),
        S("Fastmail", EMAIL_IDENTITY, listOf("fastmail.com")),
        S("Tuta", EMAIL_IDENTITY, listOf("tuta.com", "tutanota.com")),
        S("AOL", EMAIL_IDENTITY, listOf("aol.com")),
        S("GMX", EMAIL_IDENTITY, listOf("gmx.com", "gmx.net", "gmx.de")),
        S("Okta", EMAIL_IDENTITY, listOf("okta.com"), multiTenant = true),
        S("Auth0", EMAIL_IDENTITY, listOf("auth0.com")),
        S("DigiLocker", EMAIL_IDENTITY, listOf("digilocker.gov.in")),
        S("Aadhaar (UIDAI)", EMAIL_IDENTITY, listOf("uidai.gov.in")),
        S("Mail.com", EMAIL_IDENTITY, listOf("mail.com")),
        S("Yandex", EMAIL_IDENTITY, listOf("yandex.com", "yandex.ru"), brands = listOf("yandex")),
        S("Mail.ru", EMAIL_IDENTITY, listOf("mail.ru")),
        S("Rediffmail", EMAIL_IDENTITY, listOf("rediff.com", "rediffmail.com")),
        S("HEY", EMAIL_IDENTITY, listOf("hey.com")),
        S("Posteo", EMAIL_IDENTITY, listOf("posteo.de")),
        S("mailbox.org", EMAIL_IDENTITY, listOf("mailbox.org")),
        S("Bitwarden", EMAIL_IDENTITY, listOf("bitwarden.com", "bitwarden.eu")),
        S("1Password", EMAIL_IDENTITY, listOf("1password.com", "1password.eu", "1password.ca")),
        S("LastPass", EMAIL_IDENTITY, listOf("lastpass.com")),
        S("Dashlane", EMAIL_IDENTITY, listOf("dashlane.com")),
        S("Authy", EMAIL_IDENTITY, listOf("authy.com")),
        S("Login.gov", EMAIL_IDENTITY, listOf("login.gov")),
        S("ID.me", EMAIL_IDENTITY, listOf("id.me")),
        S("GOV.UK One Login", EMAIL_IDENTITY, listOf("account.gov.uk")),
        S("Government Gateway", EMAIL_IDENTITY, listOf("access.service.gov.uk")),
        S("Passport Seva", EMAIL_IDENTITY, listOf("passportindia.gov.in")),
        S("UMANG", EMAIL_IDENTITY, listOf("umang.gov.in")),

        // Finance: banks
        S("HDFC Bank", FINANCE, listOf("hdfcbank.com", "hdfcbank.net")),
        S("ICICI Bank", FINANCE, listOf("icicibank.com")),
        S("State Bank of India", FINANCE, listOf("onlinesbi.sbi", "sbi.co.in", "onlinesbi.com", "sbi.bank.in")),
        S("Axis Bank", FINANCE, listOf("axisbank.com")),
        S("Kotak", FINANCE, listOf("kotak.com", "kotaksecurities.com")),
        S("Yes Bank", FINANCE, listOf("yesbank.in")),
        S("IDFC FIRST Bank", FINANCE, listOf("idfcfirstbank.com")),
        S("Bank of Baroda", FINANCE, listOf("bankofbaroda.in", "bobibanking.com")),
        S("Punjab National Bank", FINANCE, listOf("pnbindia.in", "netpnb.com")),
        S("Chase", FINANCE, listOf("chase.com")),
        S("Bank of America", FINANCE, listOf("bankofamerica.com")),
        S("Wells Fargo", FINANCE, listOf("wellsfargo.com")),
        S("Citi", FINANCE, listOf("citi.com", "citibank.com", "citibank.co.in")),
        S("Capital One", FINANCE, listOf("capitalone.com")),
        S("American Express", FINANCE, listOf("americanexpress.com")),
        S("HSBC", FINANCE, listOf("hsbc.com"), brands = listOf("hsbc")),
        S("Barclays", FINANCE, listOf("barclays.com", "barclays.co.uk")),
        S("Revolut", FINANCE, listOf("revolut.com")),
        S("Wise", FINANCE, listOf("wise.com", "transferwise.com")),
        S("Monzo", FINANCE, listOf("monzo.com")),
        S("N26", FINANCE, listOf("n26.com")),
        S("Canara Bank", FINANCE, listOf("canarabank.com", "canarabank.in")),
        S("Union Bank of India", FINANCE, listOf("unionbankofindia.co.in", "unionbankonline.co.in")),
        S("Bank of India", FINANCE, listOf("bankofindia.co.in", "bankofindia.com")),
        S("Indian Bank", FINANCE, listOf("indianbank.in", "indianbank.net.in")),
        S("Central Bank of India", FINANCE, listOf("centralbankofindia.co.in")),
        S("Indian Overseas Bank", FINANCE, listOf("iob.in", "iobnet.co.in")),
        S("UCO Bank", FINANCE, listOf("ucobank.com")),
        S("Bank of Maharashtra", FINANCE, listOf("bankofmaharashtra.in")),
        S("IDBI Bank", FINANCE, listOf("idbibank.in")),
        S("IndusInd Bank", FINANCE, listOf("indusind.com")),
        S("Federal Bank", FINANCE, listOf("federalbank.co.in", "fednetbank.com")),
        S("South Indian Bank", FINANCE, listOf("southindianbank.com")),
        S("RBL Bank", FINANCE, listOf("rblbank.com")),
        S("Bandhan Bank", FINANCE, listOf("bandhanbank.com")),
        S("AU Small Finance Bank", FINANCE, listOf("aubank.in")),
        S("Karur Vysya Bank", FINANCE, listOf("kvb.co.in")),
        S("Karnataka Bank", FINANCE, listOf("karnatakabank.com")),
        S("J&K Bank", FINANCE, listOf("jkbank.com")),
        S("SBI Card", FINANCE, listOf("sbicard.com")),
        S("DBS Bank", FINANCE, listOf("dbs.com", "dbs.com.sg")),
        S("Standard Chartered", FINANCE, listOf("sc.com")),
        S("OCBC", FINANCE, listOf("ocbc.com")),
        S("UOB", FINANCE, listOf("uob.com.sg", "uobgroup.com")),
        S("U.S. Bank", FINANCE, listOf("usbank.com")),
        S("Discover", FINANCE, listOf("discover.com")),
        S("Ally", FINANCE, listOf("ally.com")),
        S("PNC", FINANCE, listOf("pnc.com")),
        S("TD Bank", FINANCE, listOf("td.com", "tdbank.com")),
        S("RBC", FINANCE, listOf("rbc.com", "rbcroyalbank.com")),
        S("Scotiabank", FINANCE, listOf("scotiabank.com")),
        S("BMO", FINANCE, listOf("bmo.com")),
        S("Lloyds Bank", FINANCE, listOf("lloydsbank.com", "lloydsbank.co.uk")),
        S("NatWest", FINANCE, listOf("natwest.com")),
        S("Halifax", FINANCE, listOf("halifax.co.uk")),
        S("Nationwide", FINANCE, listOf("nationwide.co.uk")),
        S("Santander", FINANCE, listOf("santander.com", "santander.co.uk"), brands = listOf("santander")),
        S("Starling Bank", FINANCE, listOf("starlingbank.com")),
        S("Commonwealth Bank", FINANCE, listOf("commbank.com.au")),
        S("Westpac", FINANCE, listOf("westpac.com.au")),
        S("ANZ", FINANCE, listOf("anz.com", "anz.com.au")),
        S("NAB", FINANCE, listOf("nab.com.au")),
        S("Deutsche Bank", FINANCE, listOf("db.com", "deutsche-bank.de")),
        S("ING", FINANCE, listOf("ing.com", "ing.nl", "ing.de")),
        S("Chime", FINANCE, listOf("chime.com")),
        S("SoFi", FINANCE, listOf("sofi.com")),
        // Finance: brokers and exchanges
        S("Interactive Brokers", FINANCE, listOf("interactivebrokers.com", "ibkr.com", "interactivebrokers.co.in", "interactivebrokers.co.uk")),
        S("Zerodha", FINANCE, listOf("zerodha.com", "kite.trade", "kite.zerodha.com", "console.zerodha.com")),
        S("Angel One", FINANCE, listOf("angelone.in", "angelbroking.com")),
        S("Upstox", FINANCE, listOf("upstox.com")),
        S("Groww", FINANCE, listOf("groww.in")),
        S("Dhan", FINANCE, listOf("dhan.co")),
        S("5paisa", FINANCE, listOf("5paisa.com")),
        S("Alpaca", FINANCE, listOf("alpaca.markets")),
        S("OANDA", FINANCE, listOf("oanda.com")),
        S("Exness", FINANCE, listOf("exness.com")),
        S("Robinhood", FINANCE, listOf("robinhood.com")),
        S("Fidelity", FINANCE, listOf("fidelity.com")),
        S("Charles Schwab", FINANCE, listOf("schwab.com")),
        S("Vanguard", FINANCE, listOf("vanguard.com")),
        S("E*TRADE", FINANCE, listOf("etrade.com")),
        S("TradingView", FINANCE, listOf("tradingview.com")),
        S("Coinbase", FINANCE, listOf("coinbase.com")),
        S("Binance", FINANCE, listOf("binance.com")),
        S("Kraken", FINANCE, listOf("kraken.com")),
        S("CoinDCX", FINANCE, listOf("coindcx.com")),
        S("WazirX", FINANCE, listOf("wazirx.com")),
        S("CAMS", FINANCE, listOf("camsonline.com")),
        S("ICICI Direct", FINANCE, listOf("icicidirect.com")),
        S("HDFC Securities", FINANCE, listOf("hdfcsec.com")),
        S("Motilal Oswal", FINANCE, listOf("motilaloswal.com")),
        S("Sharekhan", FINANCE, listOf("sharekhan.com")),
        S("Paytm Money", FINANCE, listOf("paytmmoney.com")),
        S("INDmoney", FINANCE, listOf("indmoney.com")),
        S("Kuvera", FINANCE, listOf("kuvera.in")),
        S("smallcase", FINANCE, listOf("smallcase.com")),
        S("Fyers", FINANCE, listOf("fyers.in")),
        S("Sensibull", FINANCE, listOf("sensibull.com")),
        S("NSDL", FINANCE, listOf("nsdl.co.in", "nsdl.com")),
        S("CDSL", FINANCE, listOf("cdslindia.com")),
        S("KFintech", FINANCE, listOf("kfintech.com")),
        S("MF Central", FINANCE, listOf("mfcentral.com")),
        S("LIC", FINANCE, listOf("licindia.in")),
        S("Policybazaar", FINANCE, listOf("policybazaar.com")),
        S("Bajaj Finserv", FINANCE, listOf("bajajfinserv.in")),
        S("CIBIL", FINANCE, listOf("cibil.com")),
        S("Webull", FINANCE, listOf("webull.com")),
        S("eToro", FINANCE, listOf("etoro.com")),
        S("Trading 212", FINANCE, listOf("trading212.com")),
        S("Merrill", FINANCE, listOf("merrilledge.com", "ml.com")),
        S("moomoo", FINANCE, listOf("moomoo.com")),
        S("Crypto.com", FINANCE, listOf("crypto.com")),
        S("Bybit", FINANCE, listOf("bybit.com")),
        S("OKX", FINANCE, listOf("okx.com")),
        S("KuCoin", FINANCE, listOf("kucoin.com")),
        S("Gemini", FINANCE, listOf("gemini.com")),
        S("Bitstamp", FINANCE, listOf("bitstamp.net")),
        S("CoinSwitch", FINANCE, listOf("coinswitch.co")),
        S("Ledger", FINANCE, listOf("ledger.com")),
        S("MetaMask", FINANCE, listOf("metamask.io")),
        S("Intuit", FINANCE, listOf("intuit.com", "turbotax.com", "quickbooks.com", "creditkarma.com")),
        S("Xero", FINANCE, listOf("xero.com")),
        S("Experian", FINANCE, listOf("experian.com"), brands = listOf("experian")),
        S("Equifax", FINANCE, listOf("equifax.com"), brands = listOf("equifax")),
        S("TransUnion", FINANCE, listOf("transunion.com")),
        S("Income Tax India", FINANCE, listOf("incometax.gov.in", "incometaxindiaefiling.gov.in")),
        S("GST Portal", FINANCE, listOf("gst.gov.in")),
        S("EPFO", FINANCE, listOf("epfindia.gov.in")),
        S("IRS", FINANCE, listOf("irs.gov")),
        S("Social Security", FINANCE, listOf("ssa.gov")),
        // Finance: payments
        S("Stripe", FINANCE, listOf("stripe.com")),
        S("Razorpay", FINANCE, listOf("razorpay.com")),
        S("PayPal", FINANCE, listOf("paypal.com"), brands = listOf("paypal")),
        S("Paytm", FINANCE, listOf("paytm.com")),
        S("PhonePe", FINANCE, listOf("phonepe.com")),
        S("Cashfree", FINANCE, listOf("cashfree.com")),
        S("Square", FINANCE, listOf("squareup.com")),
        S("Venmo", FINANCE, listOf("venmo.com")),
        S("MobiKwik", FINANCE, listOf("mobikwik.com")),
        S("CRED", FINANCE, listOf("cred.club")),
        S("BHIM", FINANCE, listOf("bhimupi.org.in")),
        S("PayU", FINANCE, listOf("payu.in", "payu.com")),
        S("Instamojo", FINANCE, listOf("instamojo.com")),
        S("Klarna", FINANCE, listOf("klarna.com")),
        S("Cash App", FINANCE, listOf("cash.app")),
        S("Zelle", FINANCE, listOf("zellepay.com")),

        // Developer & Cloud
        S("AWS", DEVELOPER_CLOUD, listOf("aws.amazon.com", "signin.aws", "amazonaws.com", "aws.com", "awsapps.com")),
        S("Cloudflare", DEVELOPER_CLOUD, listOf("cloudflare.com")),
        S("GitHub", DEVELOPER_CLOUD, listOf("github.com")),
        S("GitLab", DEVELOPER_CLOUD, listOf("gitlab.com")),
        S("Bitbucket", DEVELOPER_CLOUD, listOf("bitbucket.org")),
        S("Vercel", DEVELOPER_CLOUD, listOf("vercel.com")),
        S("Supabase", DEVELOPER_CLOUD, listOf("supabase.com", "supabase.io")),
        S("Netlify", DEVELOPER_CLOUD, listOf("netlify.com")),
        S("Heroku", DEVELOPER_CLOUD, listOf("heroku.com")),
        S("DigitalOcean", DEVELOPER_CLOUD, listOf("digitalocean.com")),
        S("Hugging Face", DEVELOPER_CLOUD, listOf("huggingface.co")),
        S("PyPI", DEVELOPER_CLOUD, listOf("pypi.org")),
        S("npm", DEVELOPER_CLOUD, listOf("npmjs.com")),
        S("Replit", DEVELOPER_CLOUD, listOf("replit.com")),
        S("Oracle Cloud", DEVELOPER_CLOUD, listOf("cloud.oracle.com", "oraclecloud.com", "oracle.com")),
        S("Google Cloud", DEVELOPER_CLOUD, listOf("cloud.google.com", "console.cloud.google.com", "firebase.google.com")),
        S("Microsoft Azure", DEVELOPER_CLOUD, listOf("azure.com", "portal.azure.com", "azure.microsoft.com")),
        S("Docker", DEVELOPER_CLOUD, listOf("docker.com")),
        S("Render", DEVELOPER_CLOUD, listOf("render.com")),
        S("Fly.io", DEVELOPER_CLOUD, listOf("fly.io")),
        S("Railway", DEVELOPER_CLOUD, listOf("railway.app")),
        S("Linode", DEVELOPER_CLOUD, listOf("linode.com")),
        S("Vultr", DEVELOPER_CLOUD, listOf("vultr.com")),
        S("Hetzner", DEVELOPER_CLOUD, listOf("hetzner.com", "hetzner.cloud")),
        S("Firebase", DEVELOPER_CLOUD, listOf("firebase.com")),
        S("MongoDB Atlas", DEVELOPER_CLOUD, listOf("mongodb.com")),
        S("OpenAI", DEVELOPER_CLOUD, listOf("openai.com", "chatgpt.com")),
        S("Anthropic", DEVELOPER_CLOUD, listOf("anthropic.com", "claude.ai")),
        S("Kaggle", DEVELOPER_CLOUD, listOf("kaggle.com")),
        S("Stack Overflow", DEVELOPER_CLOUD, listOf("stackoverflow.com", "stackexchange.com")),
        S("Sentry", DEVELOPER_CLOUD, listOf("sentry.io")),
        S("Postman", DEVELOPER_CLOUD, listOf("postman.com")),
        S("JetBrains", DEVELOPER_CLOUD, listOf("jetbrains.com")),
        S("Expo", DEVELOPER_CLOUD, listOf("expo.dev")),
        S("Apple Developer", DEVELOPER_CLOUD, listOf("developer.apple.com", "appstoreconnect.apple.com")),
        S("IBM Cloud", DEVELOPER_CLOUD, listOf("cloud.ibm.com")),
        S("Alibaba Cloud", DEVELOPER_CLOUD, listOf("alibabacloud.com", "aliyun.com")),
        S("OVHcloud", DEVELOPER_CLOUD, listOf("ovhcloud.com", "ovh.com")),
        S("Scaleway", DEVELOPER_CLOUD, listOf("scaleway.com")),
        S("Backblaze", DEVELOPER_CLOUD, listOf("backblaze.com")),
        S("Wasabi", DEVELOPER_CLOUD, listOf("wasabi.com")),
        S("Cloudinary", DEVELOPER_CLOUD, listOf("cloudinary.com")),
        S("Codeberg", DEVELOPER_CLOUD, listOf("codeberg.org")),
        S("SourceHut", DEVELOPER_CLOUD, listOf("sr.ht")),
        S("HashiCorp", DEVELOPER_CLOUD, listOf("hashicorp.com", "terraform.io")),
        S("Datadog", DEVELOPER_CLOUD, listOf("datadoghq.com", "datadoghq.eu")),
        S("New Relic", DEVELOPER_CLOUD, listOf("newrelic.com")),
        S("Grafana", DEVELOPER_CLOUD, listOf("grafana.com", "grafana.net")),
        S("PagerDuty", DEVELOPER_CLOUD, listOf("pagerduty.com")),
        S("Twilio", DEVELOPER_CLOUD, listOf("twilio.com", "sendgrid.com")),
        S("Mailgun", DEVELOPER_CLOUD, listOf("mailgun.com")),
        S("Algolia", DEVELOPER_CLOUD, listOf("algolia.com")),
        S("Neon", DEVELOPER_CLOUD, listOf("neon.tech")),
        S("PlanetScale", DEVELOPER_CLOUD, listOf("planetscale.com")),
        S("Upstash", DEVELOPER_CLOUD, listOf("upstash.com")),
        S("CircleCI", DEVELOPER_CLOUD, listOf("circleci.com")),
        S("Snyk", DEVELOPER_CLOUD, listOf("snyk.io")),
        S("Tailscale", DEVELOPER_CLOUD, listOf("tailscale.com")),
        S("ngrok", DEVELOPER_CLOUD, listOf("ngrok.com")),
        S("Deno", DEVELOPER_CLOUD, listOf("deno.com")),
        S("CodeSandbox", DEVELOPER_CLOUD, listOf("codesandbox.io")),
        S("Cursor", DEVELOPER_CLOUD, listOf("cursor.com")),
        S("Mistral AI", DEVELOPER_CLOUD, listOf("mistral.ai")),
        S("Perplexity", DEVELOPER_CLOUD, listOf("perplexity.ai")),

        // Shopping & Travel
        S("Amazon", SHOPPING_TRAVEL, listOf("amazon.com"), brands = listOf("amazon")),
        S("Flipkart", SHOPPING_TRAVEL, listOf("flipkart.com")),
        S("Myntra", SHOPPING_TRAVEL, listOf("myntra.com")),
        S("Meesho", SHOPPING_TRAVEL, listOf("meesho.com")),
        S("eBay", SHOPPING_TRAVEL, listOf("ebay.com"), brands = listOf("ebay")),
        S("Walmart", SHOPPING_TRAVEL, listOf("walmart.com")),
        S("AliExpress", SHOPPING_TRAVEL, listOf("aliexpress.com")),
        S("IKEA", SHOPPING_TRAVEL, listOf("ikea.com")),
        S("Swiggy", SHOPPING_TRAVEL, listOf("swiggy.com")),
        S("Zomato", SHOPPING_TRAVEL, listOf("zomato.com")),
        S("IRCTC", SHOPPING_TRAVEL, listOf("irctc.co.in")),
        S("MakeMyTrip", SHOPPING_TRAVEL, listOf("makemytrip.com")),
        S("Goibibo", SHOPPING_TRAVEL, listOf("goibibo.com")),
        S("Cleartrip", SHOPPING_TRAVEL, listOf("cleartrip.com")),
        S("Airbnb", SHOPPING_TRAVEL, listOf("airbnb.com"), brands = listOf("airbnb")),
        S("Booking.com", SHOPPING_TRAVEL, listOf("booking.com")),
        S("Expedia", SHOPPING_TRAVEL, listOf("expedia.com"), brands = listOf("expedia")),
        S("Agoda", SHOPPING_TRAVEL, listOf("agoda.com")),
        S("Uber", SHOPPING_TRAVEL, listOf("uber.com", "ubereats.com")),
        S("Ola", SHOPPING_TRAVEL, listOf("olacabs.com")),
        S("Lyft", SHOPPING_TRAVEL, listOf("lyft.com")),
        S("IndiGo", SHOPPING_TRAVEL, listOf("goindigo.in")),
        S("Air India", SHOPPING_TRAVEL, listOf("airindia.com", "airindia.in")),
        S("Etsy", SHOPPING_TRAVEL, listOf("etsy.com")),
        S("Apple Store", SHOPPING_TRAVEL, listOf("store.apple.com")),
        S("Target", SHOPPING_TRAVEL, listOf("target.com")),
        S("Best Buy", SHOPPING_TRAVEL, listOf("bestbuy.com")),
        S("Costco", SHOPPING_TRAVEL, listOf("costco.com")),
        S("The Home Depot", SHOPPING_TRAVEL, listOf("homedepot.com")),
        S("Shein", SHOPPING_TRAVEL, listOf("shein.com"), brands = listOf("shein")),
        S("Temu", SHOPPING_TRAVEL, listOf("temu.com")),
        S("Zara", SHOPPING_TRAVEL, listOf("zara.com")),
        S("H&M", SHOPPING_TRAVEL, listOf("hm.com")),
        S("Nike", SHOPPING_TRAVEL, listOf("nike.com")),
        S("Alibaba", SHOPPING_TRAVEL, listOf("alibaba.com")),
        S("Taobao", SHOPPING_TRAVEL, listOf("taobao.com")),
        S("Rakuten", SHOPPING_TRAVEL, listOf("rakuten.com", "rakuten.co.jp")),
        S("Mercado Libre", SHOPPING_TRAVEL, listOf("mercadolibre.com"), brands = listOf("mercadolibre")),
        S("Instacart", SHOPPING_TRAVEL, listOf("instacart.com")),
        S("DoorDash", SHOPPING_TRAVEL, listOf("doordash.com")),
        S("Deliveroo", SHOPPING_TRAVEL, listOf("deliveroo.co.uk"), brands = listOf("deliveroo")),
        S("USPS", SHOPPING_TRAVEL, listOf("usps.com")),
        S("Ajio", SHOPPING_TRAVEL, listOf("ajio.com")),
        S("Nykaa", SHOPPING_TRAVEL, listOf("nykaa.com")),
        S("Tata CLiQ", SHOPPING_TRAVEL, listOf("tatacliq.com")),
        S("Croma", SHOPPING_TRAVEL, listOf("croma.com")),
        S("Reliance Digital", SHOPPING_TRAVEL, listOf("reliancedigital.in")),
        S("JioMart", SHOPPING_TRAVEL, listOf("jiomart.com")),
        S("BigBasket", SHOPPING_TRAVEL, listOf("bigbasket.com")),
        S("Blinkit", SHOPPING_TRAVEL, listOf("blinkit.com")),
        S("Zepto", SHOPPING_TRAVEL, listOf("zeptonow.com")),
        S("Snapdeal", SHOPPING_TRAVEL, listOf("snapdeal.com")),
        S("FirstCry", SHOPPING_TRAVEL, listOf("firstcry.com")),
        S("Lenskart", SHOPPING_TRAVEL, listOf("lenskart.com")),
        S("BookMyShow", SHOPPING_TRAVEL, listOf("bookmyshow.com")),
        // Travel
        S("Trip.com", SHOPPING_TRAVEL, listOf("trip.com")),
        S("Skyscanner", SHOPPING_TRAVEL, listOf("skyscanner.com", "skyscanner.net"), brands = listOf("skyscanner")),
        S("Kayak", SHOPPING_TRAVEL, listOf("kayak.com"), brands = listOf("kayak")),
        S("Hotels.com", SHOPPING_TRAVEL, listOf("hotels.com")),
        S("Tripadvisor", SHOPPING_TRAVEL, listOf("tripadvisor.com"), brands = listOf("tripadvisor")),
        S("Vrbo", SHOPPING_TRAVEL, listOf("vrbo.com")),
        S("ixigo", SHOPPING_TRAVEL, listOf("ixigo.com")),
        S("EaseMyTrip", SHOPPING_TRAVEL, listOf("easemytrip.com")),
        S("Yatra", SHOPPING_TRAVEL, listOf("yatra.com")),
        S("redBus", SHOPPING_TRAVEL, listOf("redbus.in")),
        S("OYO", SHOPPING_TRAVEL, listOf("oyorooms.com")),
        S("Rapido", SHOPPING_TRAVEL, listOf("rapido.bike")),
        S("Grab", SHOPPING_TRAVEL, listOf("grab.com")),
        S("Bolt", SHOPPING_TRAVEL, listOf("bolt.eu")),
        S("SpiceJet", SHOPPING_TRAVEL, listOf("spicejet.com")),
        S("Akasa Air", SHOPPING_TRAVEL, listOf("akasaair.com")),
        S("Emirates", SHOPPING_TRAVEL, listOf("emirates.com")),
        S("Qatar Airways", SHOPPING_TRAVEL, listOf("qatarairways.com")),
        S("Singapore Airlines", SHOPPING_TRAVEL, listOf("singaporeair.com")),
        S("Lufthansa", SHOPPING_TRAVEL, listOf("lufthansa.com")),
        S("British Airways", SHOPPING_TRAVEL, listOf("britishairways.com")),
        S("Delta", SHOPPING_TRAVEL, listOf("delta.com")),
        S("United Airlines", SHOPPING_TRAVEL, listOf("united.com")),
        S("American Airlines", SHOPPING_TRAVEL, listOf("aa.com")),
        S("Southwest", SHOPPING_TRAVEL, listOf("southwest.com")),
        S("Ryanair", SHOPPING_TRAVEL, listOf("ryanair.com")),
        S("easyJet", SHOPPING_TRAVEL, listOf("easyjet.com")),
        S("Marriott", SHOPPING_TRAVEL, listOf("marriott.com")),
        S("Hilton", SHOPPING_TRAVEL, listOf("hilton.com")),
        S("IHG", SHOPPING_TRAVEL, listOf("ihg.com")),
        S("Hyatt", SHOPPING_TRAVEL, listOf("hyatt.com")),
        S("Accor", SHOPPING_TRAVEL, listOf("accor.com")),
        S("Amtrak", SHOPPING_TRAVEL, listOf("amtrak.com")),
        S("Trainline", SHOPPING_TRAVEL, listOf("thetrainline.com")),
        S("Parivahan", SHOPPING_TRAVEL, listOf("parivahan.gov.in")),
        // Telecoms, TV and utility bills (filed with Shopping)
        S("Jio", SHOPPING_TRAVEL, listOf("jio.com")),
        S("Airtel", SHOPPING_TRAVEL, listOf("airtel.in", "airtel.com")),
        S("Vi", SHOPPING_TRAVEL, listOf("myvi.in")),
        S("BSNL", SHOPPING_TRAVEL, listOf("bsnl.co.in")),
        S("Tata Play", SHOPPING_TRAVEL, listOf("tataplay.com")),
        S("Tata Power", SHOPPING_TRAVEL, listOf("tatapower.com")),
        S("Adani Electricity", SHOPPING_TRAVEL, listOf("adanielectricity.com")),
        S("Verizon", SHOPPING_TRAVEL, listOf("verizon.com")),
        S("AT&T", SHOPPING_TRAVEL, listOf("att.com")),
        S("T-Mobile", SHOPPING_TRAVEL, listOf("t-mobile.com")),
        S("Xfinity", SHOPPING_TRAVEL, listOf("xfinity.com")),
        S("Vodafone", SHOPPING_TRAVEL, listOf("vodafone.com", "vodafone.co.uk"), brands = listOf("vodafone")),
        S("EE", SHOPPING_TRAVEL, listOf("ee.co.uk")),

        // Gaming
        S("Riot Games", GAMING, listOf("riotgames.com", "leagueoflegends.com", "playvalorant.com")),
        S("Steam", GAMING, listOf("steampowered.com", "steamcommunity.com")),
        S("Epic Games", GAMING, listOf("epicgames.com")),
        S("Chess.com", GAMING, listOf("chess.com")),
        S("Lichess", GAMING, listOf("lichess.org")),
        S("PlayStation", GAMING, listOf("playstation.com", "sonyentertainmentnetwork.com")),
        S("Nintendo", GAMING, listOf("nintendo.com")),
        S("Battle.net", GAMING, listOf("battle.net", "blizzard.com")),
        S("EA", GAMING, listOf("ea.com")),
        S("Ubisoft", GAMING, listOf("ubisoft.com")),
        S("Roblox", GAMING, listOf("roblox.com")),
        S("GOG", GAMING, listOf("gog.com")),
        S("Rockstar Games", GAMING, listOf("rockstargames.com")),
        S("Minecraft", GAMING, listOf("minecraft.net")),
        S("Activision", GAMING, listOf("activision.com")),
        S("Bungie", GAMING, listOf("bungie.net")),
        S("Bethesda", GAMING, listOf("bethesda.net")),
        S("Square Enix", GAMING, listOf("square-enix.com")),
        S("HoYoverse", GAMING, listOf("hoyoverse.com", "mihoyo.com")),
        S("Supercell", GAMING, listOf("supercell.com")),
        S("Garena", GAMING, listOf("garena.com")),
        S("Wargaming", GAMING, listOf("wargaming.net")),
        S("itch.io", GAMING, listOf("itch.io")),
        S("Humble Bundle", GAMING, listOf("humblebundle.com")),
        S("FACEIT", GAMING, listOf("faceit.com")),
        S("Nexus Mods", GAMING, listOf("nexusmods.com")),
        S("Dream11", GAMING, listOf("dream11.com")),

        // Learning & Research
        S("Udemy", LEARNING, listOf("udemy.com")),
        S("Coursera", LEARNING, listOf("coursera.org")),
        S("edX", LEARNING, listOf("edx.org")),
        S("IEEE", LEARNING, listOf("ieee.org")),
        S("SSRN", LEARNING, listOf("ssrn.com")),
        S("ResearchGate", LEARNING, listOf("researchgate.net")),
        S("Canvas", LEARNING, listOf("instructure.com"), multiTenant = true),
        S("Khan Academy", LEARNING, listOf("khanacademy.org")),
        S("Duolingo", LEARNING, listOf("duolingo.com")),
        S("NPTEL", LEARNING, listOf("nptel.ac.in", "swayam.gov.in")),
        S("Google Scholar", LEARNING, listOf("scholar.google.com")),
        S("arXiv", LEARNING, listOf("arxiv.org")),
        S("ORCID", LEARNING, listOf("orcid.org")),
        S("Elsevier", LEARNING, listOf("elsevier.com", "sciencedirect.com")),
        S("Springer", LEARNING, listOf("springer.com", "springernature.com")),
        S("JSTOR", LEARNING, listOf("jstor.org")),
        S("Overleaf", LEARNING, listOf("overleaf.com")),
        S("Mendeley", LEARNING, listOf("mendeley.com")),
        S("Zotero", LEARNING, listOf("zotero.org")),
        S("Brilliant", LEARNING, listOf("brilliant.org")),
        S("LeetCode", LEARNING, listOf("leetcode.com")),
        S("HackerRank", LEARNING, listOf("hackerrank.com")),
        S("Codeforces", LEARNING, listOf("codeforces.com")),
        S("Moodle", LEARNING, listOf("moodlecloud.com"), multiTenant = true),
        S("Blackboard", LEARNING, listOf("blackboard.com"), multiTenant = true),
        S("Skillshare", LEARNING, listOf("skillshare.com")),
        S("Pluralsight", LEARNING, listOf("pluralsight.com")),
        S("Udacity", LEARNING, listOf("udacity.com")),
        S("Codecademy", LEARNING, listOf("codecademy.com")),
        S("DataCamp", LEARNING, listOf("datacamp.com")),
        S("freeCodeCamp", LEARNING, listOf("freecodecamp.org")),
        S("BYJU'S", LEARNING, listOf("byjus.com")),
        S("Unacademy", LEARNING, listOf("unacademy.com")),
        S("Physics Wallah", LEARNING, listOf("pw.live")),
        S("upGrad", LEARNING, listOf("upgrad.com")),
        S("Great Learning", LEARNING, listOf("mygreatlearning.com")),
        S("Scaler", LEARNING, listOf("scaler.com")),
        S("GeeksforGeeks", LEARNING, listOf("geeksforgeeks.org")),
        S("CodeChef", LEARNING, listOf("codechef.com")),
        S("AtCoder", LEARNING, listOf("atcoder.jp")),
        S("Chegg", LEARNING, listOf("chegg.com")),
        S("Quizlet", LEARNING, listOf("quizlet.com")),
        S("Wolfram", LEARNING, listOf("wolfram.com", "wolframalpha.com")),
        S("Wiley", LEARNING, listOf("wiley.com")),
        S("Taylor & Francis", LEARNING, listOf("tandfonline.com")),
        S("Nature", LEARNING, listOf("nature.com")),
        S("ACM", LEARNING, listOf("acm.org")),
        S("Semantic Scholar", LEARNING, listOf("semanticscholar.org")),
        S("Academia.edu", LEARNING, listOf("academia.edu")),

        // Careers
        S("Workday", CAREERS, listOf("myworkdayjobs.com", "myworkday.com", "workday.com"), multiTenant = true),
        S("Taleo", CAREERS, listOf("taleo.net"), multiTenant = true),
        S("Oleeo (tal.net)", CAREERS, listOf("tal.net"), multiTenant = true),
        S("SuccessFactors", CAREERS, listOf("successfactors.com", "successfactors.eu", "sapsf.com", "sapsf.eu"), multiTenant = true),
        S("iCIMS", CAREERS, listOf("icims.com"), multiTenant = true),
        S("Greenhouse", CAREERS, listOf("greenhouse.io"), multiTenant = true),
        S("Lever", CAREERS, listOf("lever.co"), multiTenant = true),
        S("SmartRecruiters", CAREERS, listOf("smartrecruiters.com"), multiTenant = true),
        S("Ashby", CAREERS, listOf("ashbyhq.com"), multiTenant = true),
        S("Jobvite", CAREERS, listOf("jobvite.com"), multiTenant = true),
        S("BambooHR", CAREERS, listOf("bamboohr.com"), multiTenant = true),
        S("Indeed", CAREERS, listOf("indeed.com"), brands = listOf("indeed")),
        S("Naukri", CAREERS, listOf("naukri.com")),
        S("Glassdoor", CAREERS, listOf("glassdoor.com"), brands = listOf("glassdoor")),
        S("Wellfound", CAREERS, listOf("wellfound.com", "angel.co")),
        S("Internshala", CAREERS, listOf("internshala.com")),
        S("Instahyre", CAREERS, listOf("instahyre.com")),
        S("Workable", CAREERS, listOf("workable.com"), multiTenant = true),
        S("Recruitee", CAREERS, listOf("recruitee.com"), multiTenant = true),
        S("Teamtailor", CAREERS, listOf("teamtailor.com"), multiTenant = true),
        S("Personio", CAREERS, listOf("personio.de", "personio.com"), multiTenant = true),
        S("Darwinbox", CAREERS, listOf("darwinbox.in"), multiTenant = true),
        S("Keka", CAREERS, listOf("keka.com"), multiTenant = true),
        S("Monster", CAREERS, listOf("monster.com")),
        S("ZipRecruiter", CAREERS, listOf("ziprecruiter.com")),
        S("Dice", CAREERS, listOf("dice.com")),
        S("foundit", CAREERS, listOf("foundit.in")),
        S("Shine", CAREERS, listOf("shine.com")),
        S("Cutshort", CAREERS, listOf("cutshort.io")),
        S("Upwork", CAREERS, listOf("upwork.com")),
        S("Fiverr", CAREERS, listOf("fiverr.com")),
        S("Freelancer", CAREERS, listOf("freelancer.com")),
        S("Toptal", CAREERS, listOf("toptal.com")),

        // Work & Productivity
        S("Odoo", WORK, listOf("odoo.com"), multiTenant = true),
        S("Notion", WORK, listOf("notion.so", "notion.com")),
        S("Slack", WORK, listOf("slack.com"), multiTenant = true),
        S("Atlassian", WORK, listOf("atlassian.com", "atlassian.net", "jira.com", "trello.com"), multiTenant = true),
        S("Calendly", WORK, listOf("calendly.com")),
        S("Mailchimp", WORK, listOf("mailchimp.com")),
        S("Zoom", WORK, listOf("zoom.us", "zoom.com")),
        S("Dropbox", WORK, listOf("dropbox.com")),
        S("Box", WORK, listOf("box.com")),
        S("Asana", WORK, listOf("asana.com")),
        S("Monday.com", WORK, listOf("monday.com")),
        S("ClickUp", WORK, listOf("clickup.com")),
        S("Linear", WORK, listOf("linear.app")),
        S("Figma", WORK, listOf("figma.com")),
        S("Canva", WORK, listOf("canva.com")),
        S("Miro", WORK, listOf("miro.com")),
        S("Airtable", WORK, listOf("airtable.com")),
        S("HubSpot", WORK, listOf("hubspot.com")),
        S("Salesforce", WORK, listOf("salesforce.com", "force.com"), multiTenant = true),
        S("Zapier", WORK, listOf("zapier.com")),
        S("DocuSign", WORK, listOf("docusign.com", "docusign.net")),
        S("Adobe", WORK, listOf("adobe.com")),
        S("Grammarly", WORK, listOf("grammarly.com")),
        S("Evernote", WORK, listOf("evernote.com")),
        S("Todoist", WORK, listOf("todoist.com")),
        S("Zoho Workplace", WORK, listOf("zohoworkplace.com")),
        S("Microsoft Teams", WORK, listOf("teams.microsoft.com")),
        S("Webex", WORK, listOf("webex.com")),
        S("Loom", WORK, listOf("loom.com")),
        S("Basecamp", WORK, listOf("basecamp.com")),
        S("Smartsheet", WORK, listOf("smartsheet.com")),
        S("Coda", WORK, listOf("coda.io")),
        S("Obsidian", WORK, listOf("obsidian.md")),
        S("Typeform", WORK, listOf("typeform.com")),
        S("SurveyMonkey", WORK, listOf("surveymonkey.com")),
        S("Zendesk", WORK, listOf("zendesk.com"), multiTenant = true),
        S("Freshworks", WORK, listOf("freshworks.com", "freshdesk.com"), multiTenant = true),
        S("Intercom", WORK, listOf("intercom.com")),
        S("ServiceNow", WORK, listOf("service-now.com", "servicenow.com"), multiTenant = true),
        S("Shopify", WORK, listOf("shopify.com")),
        S("Rippling", WORK, listOf("rippling.com")),
        S("Deel", WORK, listOf("deel.com")),

        // Hosting & Domains
        S("Hostinger", HOSTING, listOf("hostinger.com", "hostinger.in", "hpanel.hostinger.com"), brands = listOf("hostinger")),
        S("Namecheap", HOSTING, listOf("namecheap.com")),
        S("GoDaddy", HOSTING, listOf("godaddy.com"), brands = listOf("godaddy")),
        S("cPanel", HOSTING, listOf("cpanel.net", "cpanel.com")),
        S("Bluehost", HOSTING, listOf("bluehost.com", "bluehost.in")),
        S("HostGator", HOSTING, listOf("hostgator.com", "hostgator.in")),
        S("SiteGround", HOSTING, listOf("siteground.com")),
        S("Porkbun", HOSTING, listOf("porkbun.com")),
        S("Squarespace", HOSTING, listOf("squarespace.com")),
        S("Wix", HOSTING, listOf("wix.com")),
        S("WordPress.com", HOSTING, listOf("wordpress.com", "wordpress.org")),
        S("Google Domains", HOSTING, listOf("domains.google")),
        S("Gandi", HOSTING, listOf("gandi.net")),
        S("Dynadot", HOSTING, listOf("dynadot.com")),
        S("Name.com", HOSTING, listOf("name.com")),
        S("BigRock", HOSTING, listOf("bigrock.in")),
        S("DreamHost", HOSTING, listOf("dreamhost.com")),
        S("IONOS", HOSTING, listOf("ionos.com", "ionos.de", "ionos.co.uk"), brands = listOf("ionos")),
        S("Hover", HOSTING, listOf("hover.com")),
        S("Network Solutions", HOSTING, listOf("networksolutions.com")),
        S("Cloudways", HOSTING, listOf("cloudways.com")),
        S("Kinsta", HOSTING, listOf("kinsta.com")),
        S("WP Engine", HOSTING, listOf("wpengine.com")),
        S("Webflow", HOSTING, listOf("webflow.com")),
        S("Contabo", HOSTING, listOf("contabo.com")),
        S("Spaceship", HOSTING, listOf("spaceship.com")),
        S("ResellerClub", HOSTING, listOf("resellerclub.com")),
        S("MilesWeb", HOSTING, listOf("milesweb.in")),
    )

    private val domainIndex: Map<String, KnownService> = HashMap<String, KnownService>().also { d ->
        for (s in services) for (dom in s.domains) d.putIfAbsent(dom, s)
    }

    private val brandIndex: Map<String, KnownService> = HashMap<String, KnownService>().also { d ->
        for (s in services) for (b in s.brands) d.putIfAbsent(b, s)
    }

    /** Labels that never name a tenant ("www.", "login.", "wd5."). */
    private val genericLabels = setOf(
        "www", "www1", "www2", "m", "mobile", "app", "apps", "web", "login", "signin", "sign-in", "auth", "account",
        "accounts", "secure", "portal", "my", "id", "sso", "careers", "career", "jobs", "job", "boards", "apply",
        "hire", "recruiting", "console", "dashboard", "admin", "api", "en", "us", "eu", "uk", "in",
    )

    private val shardLabel = Regex("^[a-z]{1,3}\\d{1,3}$")

    /** Classifies a URL. null when it has no usable host. */
    fun classify(url: String): ServiceMatch? {
        val host = DomainName.host(url) ?: return null
        val reg = DomainName.registrable(host)
        val labels = host.split('.').filter { it.isNotEmpty() }
        val regCount = reg.split('.').count { it.isNotEmpty() }
        // Longest parent first, down to (and including) the registrable domain;
        // then shorter catalog keys such as "signin.aws" whose suffix is a TLD.
        if (!DomainName.isIpAddress(host)) {
            for (start in labels.indices) {
                val candidate = labels.drop(start).joinToString(".")
                domainIndex[candidate]?.let { s ->
                    return ServiceMatch(
                        s.category, s.name, known = true,
                        tenant = if (s.multiTenant) tenant(labels.take(start)) else null,
                        registrableDomain = reg,
                    )
                }
                if (labels.size - start <= regCount) break
            }
            brandIndex[DomainName.brandLabel(reg)]?.let { s ->
                return ServiceMatch(s.category, s.name, known = true, tenant = null, registrableDomain = reg)
            }
        }
        return ServiceMatch(ServiceCategory.OTHER, reg, known = false, tenant = null, registrableDomain = reg)
    }

    /**
     * The organisation label of a multi-tenant host: the first label left of
     * the matched domain that is not generic or a shard ("wd5", "eu2").
     */
    internal fun tenant(labels: List<String>): String? {
        for (l in labels) {
            val low = l.lowercase()
            if (low in genericLabels) continue
            if (shardLabel.matches(low)) continue
            return low
        }
        return null
    }
}
