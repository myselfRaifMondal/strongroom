//! Registrable-domain extraction for autofill matching.
//!
//! Limits (documented on purpose): this is not the full Public Suffix List.
//! Every single-label TLD is treated as a public suffix (the PSL default
//! `*` rule), plus the embedded multi-label suffixes below (common
//! second-level country suffixes and popular shared-hosting domains). There
//! are no wildcard or exception rules and no IDNA processing beyond ASCII
//! lowercasing; non-ASCII hosts are compared as given (lowercased). IP
//! addresses match only exactly. A domain missing from the subset can match
//! too broadly (e.g. two tenants of an unlisted shared-hosting domain).

const MULTI_LABEL_SUFFIXES: &[&str] = &[
    // Country second-level domains.
    "co.uk",
    "org.uk",
    "me.uk",
    "ltd.uk",
    "plc.uk",
    "net.uk",
    "ac.uk",
    "gov.uk",
    "nhs.uk",
    "sch.uk",
    "com.au",
    "net.au",
    "org.au",
    "edu.au",
    "gov.au",
    "asn.au",
    "id.au",
    "co.nz",
    "net.nz",
    "org.nz",
    "govt.nz",
    "ac.nz",
    "co.jp",
    "ne.jp",
    "or.jp",
    "ac.jp",
    "go.jp",
    "ad.jp",
    "ed.jp",
    "gr.jp",
    "lg.jp",
    "co.in",
    "net.in",
    "org.in",
    "firm.in",
    "gen.in",
    "ind.in",
    "ac.in",
    "edu.in",
    "gov.in",
    "res.in",
    "nic.in",
    "com.br",
    "net.br",
    "org.br",
    "gov.br",
    "edu.br",
    "com.cn",
    "net.cn",
    "org.cn",
    "gov.cn",
    "edu.cn",
    "ac.cn",
    "com.hk",
    "net.hk",
    "org.hk",
    "gov.hk",
    "edu.hk",
    "com.tw",
    "net.tw",
    "org.tw",
    "gov.tw",
    "edu.tw",
    "co.kr",
    "or.kr",
    "ne.kr",
    "go.kr",
    "ac.kr",
    "com.sg",
    "net.sg",
    "org.sg",
    "gov.sg",
    "edu.sg",
    "com.my",
    "net.my",
    "org.my",
    "gov.my",
    "edu.my",
    "co.id",
    "or.id",
    "go.id",
    "ac.id",
    "web.id",
    "com.ph",
    "net.ph",
    "org.ph",
    "gov.ph",
    "com.vn",
    "net.vn",
    "org.vn",
    "gov.vn",
    "co.th",
    "in.th",
    "or.th",
    "go.th",
    "ac.th",
    "com.pk",
    "net.pk",
    "org.pk",
    "gov.pk",
    "com.bd",
    "net.bd",
    "org.bd",
    "gov.bd",
    "com.mx",
    "net.mx",
    "org.mx",
    "gob.mx",
    "com.ar",
    "net.ar",
    "org.ar",
    "gob.ar",
    "com.co",
    "net.co",
    "org.co",
    "gov.co",
    "com.pe",
    "net.pe",
    "org.pe",
    "gob.pe",
    "com.tr",
    "net.tr",
    "org.tr",
    "gov.tr",
    "edu.tr",
    "co.za",
    "org.za",
    "gov.za",
    "ac.za",
    "com.ng",
    "org.ng",
    "gov.ng",
    "com.eg",
    "gov.eg",
    "edu.eg",
    "com.sa",
    "gov.sa",
    "edu.sa",
    "co.il",
    "org.il",
    "gov.il",
    "ac.il",
    "com.ua",
    "net.ua",
    "org.ua",
    "gov.ua",
    "com.ru",
    "net.ru",
    "org.ru",
    "com.pl",
    "net.pl",
    "org.pl",
    "co.at",
    "or.at",
    "com.es",
    "org.es",
    "gob.es",
    "com.pt",
    "org.pt",
    "com.gr",
    "org.gr",
    "co.ke",
    "or.ke",
    "go.ke",
    // Shared hosting where each subdomain belongs to a different owner.
    "github.io",
    "gitlab.io",
    "herokuapp.com",
    "appspot.com",
    "blogspot.com",
    "azurewebsites.net",
    "cloudfront.net",
    "vercel.app",
    "netlify.app",
    "pages.dev",
    "workers.dev",
    "web.app",
    "firebaseapp.com",
    "fly.dev",
    "onrender.com",
    "glitch.me",
    "ngrok.io",
    "ngrok-free.app",
    "s3.amazonaws.com",
    "elasticbeanstalk.com",
    "azurestaticapps.net",
    "surge.sh",
    "now.sh",
    "readthedocs.io",
    "wordpress.com",
    "tumblr.com",
    "wixsite.com",
    "squarespace.com",
    "myshopify.com",
    "duckdns.org",
    "dyndns.org",
    "no-ip.org",
];

/// Extracts the lowercase host from a URL or bare domain.
pub fn host(input: &str) -> Option<String> {
    let mut s = input.trim();
    if let Some(i) = s.find("://") {
        s = &s[i + 3..];
    }
    let end = s.find(['/', '?', '#']).unwrap_or(s.len());
    s = &s[..end];
    if let Some(at) = s.rfind('@') {
        s = &s[at + 1..];
    }
    let host = if let Some(rest) = s.strip_prefix('[') {
        &rest[..rest.find(']')?]
    } else {
        match s.rfind(':') {
            Some(c) if s[c + 1..].chars().all(|d| d.is_ascii_digit()) => &s[..c],
            Some(_) => return None,
            None => s,
        }
    };
    let host = host.trim_end_matches('.').to_lowercase();
    if host.is_empty()
        || host.contains(char::is_whitespace)
        || host.starts_with('.')
        || host.contains("..")
    {
        return None;
    }
    Some(host)
}

fn is_ip(host: &str) -> bool {
    host.contains(':')
        || (host.split('.').count() == 4
            && host
                .split('.')
                .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit())))
}

/// The registrable domain ("eTLD+1") of a host, or the host itself for IP
/// addresses. `None` for a bare public suffix.
pub fn registrable(host: &str) -> Option<String> {
    if is_ip(host) {
        return Some(host.to_string());
    }
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() < 2 {
        // Single label (e.g. "localhost"): matches only itself.
        return Some(host.to_string());
    }
    let mut suffix_labels = 1;
    for k in (2..=labels.len()).rev() {
        let cand = labels[labels.len() - k..].join(".");
        if MULTI_LABEL_SUFFIXES.contains(&cand.as_str()) {
            suffix_labels = k;
            break;
        }
    }
    if labels.len() <= suffix_labels {
        return None;
    }
    Some(labels[labels.len() - suffix_labels - 1..].join("."))
}

pub fn registrable_of(url_or_domain: &str) -> Option<String> {
    registrable(&host(url_or_domain)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hosts() {
        assert_eq!(
            host("https://user:pw@Mail.Example.COM:8443/path?q#f").unwrap(),
            "mail.example.com"
        );
        assert_eq!(host("example.com").unwrap(), "example.com");
        assert_eq!(host("example.com.").unwrap(), "example.com");
        assert_eq!(host("http://[::1]:80/").unwrap(), "::1");
        assert!(host("").is_none());
        assert!(host("https:///x").is_none());
    }

    #[test]
    fn registrable_domains() {
        let r = |s: &str| registrable_of(s);
        assert_eq!(
            r("https://accounts.google.com/login").as_deref(),
            Some("google.com")
        );
        assert_eq!(r("www.bbc.co.uk").as_deref(), Some("bbc.co.uk"));
        assert_eq!(r("co.uk"), None);
        assert_eq!(
            r("https://alice.github.io/x").as_deref(),
            Some("alice.github.io")
        );
        assert_eq!(r("github.io"), None);
        assert_eq!(r("s3.amazonaws.com"), None);
        assert_eq!(
            r("bucket.s3.amazonaws.com").as_deref(),
            Some("bucket.s3.amazonaws.com")
        );
        assert_eq!(r("http://192.168.1.1:8080").as_deref(), Some("192.168.1.1"));
        assert_eq!(r("localhost").as_deref(), Some("localhost"));
        assert_eq!(r("a.b.example.com.au").as_deref(), Some("example.com.au"));
        assert_ne!(r("evil-example.com"), r("example.com"));
        assert_ne!(r("example.com.evil.net"), r("example.com"));
    }
}
