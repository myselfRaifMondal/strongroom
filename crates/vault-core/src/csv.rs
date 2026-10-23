//! RFC 4180 CSV parser (hand-written) and the column mappings for exports
//! from Bitwarden, 1Password, LastPass and Chrome.
//!
//! Parser rules: fields separated by `,`; records end at CRLF, LF or CR; a
//! field that starts with `"` is quoted, may contain separators and line
//! breaks, and escapes `"` as `""`. A leading UTF-8 BOM is ignored. Text
//! after a closing quote (other than a separator or line end) is an error.
//! Every field buffer is allocated at its final size and zeroized on drop.

use vtf_core::{Field, ItemData, ItemKind};
use zeroize::Zeroizing;

use crate::error::{Error, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CsvSource {
    Bitwarden,
    OnePassword,
    LastPass,
    Chrome,
}

pub type Rows = Zeroizing<Vec<Vec<String>>>;

pub fn parse(input: &str) -> Result<Rows> {
    let s = input.strip_prefix('\u{FEFF}').unwrap_or(input);
    let b = s.as_bytes();
    let mut rows: Rows = Zeroizing::new(Vec::new());
    let mut row: Zeroizing<Vec<String>> = Zeroizing::new(Vec::new());
    let mut i = 0;
    if b.is_empty() {
        return Ok(rows);
    }
    loop {
        // One field starting at i.
        let field = if b.get(i) == Some(&b'"') {
            let start = i + 1;
            let mut j = start;
            loop {
                match b.get(j) {
                    None => return Err(Error::InvalidInput("CSV: unterminated quoted field")),
                    Some(b'"') if b.get(j + 1) == Some(&b'"') => j += 2,
                    Some(b'"') => break,
                    Some(_) => j += 1,
                }
            }
            let raw = &s[start..j];
            let mut f = String::with_capacity(raw.len());
            let mut k = 0;
            let rb = raw.as_bytes();
            while k < rb.len() {
                let next = raw[k..].find('"').map_or(rb.len(), |p| k + p);
                f.push_str(&raw[k..next]);
                if next < rb.len() {
                    f.push('"');
                    k = next + 2;
                } else {
                    k = next;
                }
            }
            i = j + 1;
            match b.get(i) {
                None | Some(b',') | Some(b'\n') | Some(b'\r') => {}
                Some(_) => return Err(Error::InvalidInput("CSV: text after closing quote")),
            }
            f
        } else {
            let start = i;
            while i < b.len() && !matches!(b[i], b',' | b'\n' | b'\r') {
                if b[i] == b'"' {
                    return Err(Error::InvalidInput("CSV: quote inside unquoted field"));
                }
                i += 1;
            }
            s[start..i].to_string()
        };
        row.push(field);
        match b.get(i) {
            Some(b',') => {
                i += 1;
            }
            None => {
                rows.push(core::mem::take(&mut *row));
                break;
            }
            Some(b'\r') | Some(b'\n') => {
                if b[i] == b'\r' && b.get(i + 1) == Some(&b'\n') {
                    i += 1;
                }
                i += 1;
                rows.push(core::mem::take(&mut *row));
                if i >= b.len() {
                    break;
                }
            }
            Some(_) => unreachable!(),
        }
    }
    Ok(rows)
}

struct Columns {
    names: Vec<String>,
}

impl Columns {
    fn idx(&self, cands: &[&str]) -> Option<usize> {
        cands.iter().find_map(|c| self.names.iter().position(|n| n == c))
    }
}

fn get<'a>(row: &'a [String], i: Option<usize>) -> Option<&'a str> {
    let v = row.get(i?)?.trim();
    (!v.is_empty()).then_some(v)
}

fn opt(row: &[String], i: Option<usize>) -> Option<String> {
    get(row, i).map(str::to_string)
}

fn blank(kind: ItemKind, title: String) -> ItemData {
    ItemData {
        kind,
        title,
        username: None,
        password: None,
        urls: vec![],
        notes: None,
        totp: None,
        folder: None,
        tags: vec![],
        fields: vec![],
        travel_safe: false,
    }
}

fn title_or_host(title: Option<String>, url: Option<&str>) -> String {
    title
        .or_else(|| url.and_then(crate::domain::host))
        .unwrap_or_else(|| "Imported item".to_string())
}

fn split_list(v: Option<&str>, seps: &[char]) -> Vec<String> {
    v.map(|s| s.split(seps).map(str::trim).filter(|t| !t.is_empty()).map(str::to_string).collect())
        .unwrap_or_default()
}

/// Maps parsed CSV text to items. The first row must be the header.
pub fn items(source: CsvSource, text: &str) -> Result<Vec<ItemData>> {
    let rows = parse(text)?;
    let Some((header, body)) = rows.split_first() else {
        return Ok(vec![]);
    };
    let cols = Columns { names: header.iter().map(|h| h.trim().to_lowercase()).collect() };
    let mut out = Vec::new();
    match source {
        CsvSource::Bitwarden => {
            let (folder, typ, name, notes, fields, uri, user, pass, totp) = (
                cols.idx(&["folder"]),
                cols.idx(&["type"]),
                cols.idx(&["name"]),
                cols.idx(&["notes"]),
                cols.idx(&["fields"]),
                cols.idx(&["login_uri"]),
                cols.idx(&["login_username"]),
                cols.idx(&["login_password"]),
                cols.idx(&["login_totp"]),
            );
            if name.is_none() || typ.is_none() {
                return Err(Error::InvalidInput("not a Bitwarden CSV export (missing name/type columns)"));
            }
            for row in body.iter().filter(|r| r.iter().any(|f| !f.trim().is_empty())) {
                let kind = match get(row, typ).map(str::to_ascii_lowercase).as_deref() {
                    Some("note") => ItemKind::SecureNote,
                    Some("card") => ItemKind::Card,
                    Some("identity") => ItemKind::Identity,
                    _ => ItemKind::Login,
                };
                let urls = split_list(get(row, uri), &[',', '\n']);
                let mut d = blank(kind, title_or_host(opt(row, name), urls.first().map(String::as_str)));
                d.urls = urls;
                d.folder = opt(row, folder);
                d.notes = opt(row, notes);
                d.username = opt(row, user);
                d.password = opt(row, pass);
                d.totp = opt(row, totp);
                if let Some(fs) = get(row, fields) {
                    for line in fs.lines().filter(|l| !l.trim().is_empty()) {
                        let (n, v) = line.split_once(": ").unwrap_or((line, ""));
                        d.fields.push(Field { name: n.trim().to_string(), value: v.to_string(), concealed: false });
                    }
                }
                out.push(d);
            }
        }
        CsvSource::OnePassword => {
            let title = cols.idx(&["title", "name"]);
            let url = cols.idx(&["url", "website", "urls", "login_uri"]);
            let user = cols.idx(&["username", "login_username"]);
            let pass = cols.idx(&["password", "login_password"]);
            let otp = cols.idx(&["otpauth", "one-time password", "totp"]);
            let notes = cols.idx(&["notes", "notesplain"]);
            let tags = cols.idx(&["tags"]);
            if title.is_none() && url.is_none() {
                return Err(Error::InvalidInput("not a 1Password CSV export (missing title/url columns)"));
            }
            for row in body.iter().filter(|r| r.iter().any(|f| !f.trim().is_empty())) {
                let urls = split_list(get(row, url), &[',', '\n']);
                let (u, p) = (opt(row, user), opt(row, pass));
                let kind = if u.is_none() && p.is_none() && urls.is_empty() { ItemKind::SecureNote } else { ItemKind::Login };
                let mut d = blank(kind, title_or_host(opt(row, title), urls.first().map(String::as_str)));
                d.urls = urls;
                d.username = u;
                d.password = p;
                d.totp = opt(row, otp);
                d.notes = opt(row, notes);
                d.tags = split_list(get(row, tags), &[';', ',']);
                out.push(d);
            }
        }
        CsvSource::LastPass => {
            let (url, user, pass, totp, extra, name, grouping) = (
                cols.idx(&["url"]),
                cols.idx(&["username"]),
                cols.idx(&["password"]),
                cols.idx(&["totp"]),
                cols.idx(&["extra"]),
                cols.idx(&["name"]),
                cols.idx(&["grouping"]),
            );
            if url.is_none() || name.is_none() {
                return Err(Error::InvalidInput("not a LastPass CSV export (missing url/name columns)"));
            }
            for row in body.iter().filter(|r| r.iter().any(|f| !f.trim().is_empty())) {
                let u = get(row, url);
                let is_note = u == Some("http://sn");
                let kind = if is_note { ItemKind::SecureNote } else { ItemKind::Login };
                let mut d = blank(kind, title_or_host(opt(row, name), if is_note { None } else { u }));
                if !is_note {
                    d.urls = u.map(|v| vec![v.to_string()]).unwrap_or_default();
                }
                d.username = opt(row, user);
                d.password = opt(row, pass);
                d.totp = opt(row, totp);
                d.notes = opt(row, extra);
                d.folder = opt(row, grouping);
                out.push(d);
            }
        }
        CsvSource::Chrome => {
            let (name, url, user, pass, note) = (
                cols.idx(&["name"]),
                cols.idx(&["url"]),
                cols.idx(&["username"]),
                cols.idx(&["password"]),
                cols.idx(&["note", "notes"]),
            );
            if url.is_none() || pass.is_none() {
                return Err(Error::InvalidInput("not a Chrome CSV export (missing url/password columns)"));
            }
            for row in body.iter().filter(|r| r.iter().any(|f| !f.trim().is_empty())) {
                let u = get(row, url);
                let mut d = blank(ItemKind::Login, title_or_host(opt(row, name), u));
                d.urls = u.map(|v| vec![v.to_string()]).unwrap_or_default();
                d.username = opt(row, user);
                d.password = opt(row, pass);
                d.notes = opt(row, note);
                out.push(d);
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfc4180_parsing() {
        let r = parse("a,b,c\r\n1,\"x,y\",\"he said \"\"hi\"\"\"\n\"multi\nline\",,\n").unwrap();
        assert_eq!(r.len(), 3);
        assert_eq!(r[0], ["a", "b", "c"]);
        assert_eq!(r[1], ["1", "x,y", "he said \"hi\""]);
        assert_eq!(r[2], ["multi\nline", "", ""]);
        let r = parse("\u{FEFF}h\nv").unwrap();
        assert_eq!(*r, vec![vec!["h".to_string()], vec!["v".to_string()]]);
        assert!(parse("\"open").is_err());
        assert!(parse("\"a\"b,c").is_err());
        assert!(parse("a\"b").is_err());
        assert_eq!(parse("").unwrap().len(), 0);
        assert_eq!(parse("a,b\r\n").unwrap().len(), 1);
        assert_eq!(parse("\"\"").unwrap()[0], [""]);
    }

    #[test]
    fn bitwarden() {
        let csv = "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n\
                   Work,,login,Mail,,\"PIN: 1234\nRecovery: abc\",0,\"https://mail.example.com,https://example.com\",alice,s3cret,JBSWY3DPEHPK3PXP\n\
                   ,,note,Diary,dear diary,,0,,,,\n";
        let items = items(CsvSource::Bitwarden, csv).unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].title, "Mail");
        assert_eq!(items[0].folder.as_deref(), Some("Work"));
        assert_eq!(items[0].urls, ["https://mail.example.com", "https://example.com"]);
        assert_eq!(items[0].password.as_deref(), Some("s3cret"));
        assert_eq!(items[0].fields.len(), 2);
        assert_eq!(items[0].fields[0].value, "1234");
        assert!(items[1].kind == ItemKind::SecureNote);
        assert_eq!(items[1].notes.as_deref(), Some("dear diary"));
    }

    #[test]
    fn onepassword_lastpass_chrome() {
        let op = "Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\n\
                  Bank,https://bank.example,bob,pw1,,false,false,finance;money,note\n";
        let i = items(CsvSource::OnePassword, op).unwrap();
        assert_eq!(i[0].tags, ["finance", "money"]);
        assert_eq!(i[0].username.as_deref(), Some("bob"));

        let lp = "url,username,password,totp,extra,name,grouping,fav\n\
                  https://shop.example,carol,pw2,,,Shop,Personal,0\n\
                  http://sn,,,,secret note body,Wifi,Home,0\n";
        let i = items(CsvSource::LastPass, lp).unwrap();
        assert_eq!(i.len(), 2);
        assert_eq!(i[0].folder.as_deref(), Some("Personal"));
        assert!(i[1].kind == ItemKind::SecureNote && i[1].urls.is_empty());

        let ch = "name,url,username,password,note\n,https://www.example.org/login,dave,pw3,\n";
        let i = items(CsvSource::Chrome, ch).unwrap();
        assert_eq!(i[0].title, "www.example.org");
        assert!(items(CsvSource::Chrome, "foo,bar\n1,2\n").is_err());
    }
}
