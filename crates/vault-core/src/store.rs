//! The encrypted local vault: SQLCipher database `<path>` plus the plaintext
//! key-wrapping header `<path>.hdr` (see [`crate::header`]).

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use subtle::ConstantTimeEq;
use vtf_core::device::{DeviceKey, PUBLIC_KEY_LEN};
use vtf_core::keys::{self, Key, Password, SecretKey};
use vtf_core::payload::{MAX_FIELDS, MAX_REVISIONS, MAX_TAGS, MAX_URLS};
use vtf_core::{ItemData, PasswordCredentials, Payload, Revision, Tombstone};
use zeroize::Zeroizing;

use crate::audit::{self, AuditItem, HealthReport};
use crate::codec;
use crate::csv::{self, CsvSource};
use crate::domain;
use crate::encoding::{hex, hex_secret, unhex};
use crate::error::{db, io, Error, Result};
use crate::gate::{sync_parent_dir, unique_sibling, write_atomic};
use crate::header::{self, Header};
use crate::totp::{self, TotpCode};

/// Trashed items are kept this long before `purge_expired_trash` removes
/// them (leaving a tombstone).
pub const TRASH_RETENTION_SECS: i64 = 180 * 24 * 60 * 60;
/// Upper bound on decoy candidates (each costs one Argon2id run).
pub const MAX_DECOY_PATHS: usize = 8;
/// A VTF file holds at most 16 slots; one is the password slot.
pub const MAX_DEVICE_RECIPIENTS: usize = 15;
const MAX_TEXT: usize = 65_536;

pub fn header_path(db_path: &Path) -> PathBuf {
    let mut s = db_path.as_os_str().to_owned();
    s.push(".hdr");
    PathBuf::from(s)
}

/// Removes SQLite's side files of `db_path` (`-journal`, `-wal`, `-shm`)
/// and, with `with_db`, the database itself. Errors are ignored: this is
/// cleanup.
fn remove_db_files(db_path: &Path, with_db: bool) {
    if with_db {
        let _ = fs::remove_file(db_path);
    }
    for ext in ["-journal", "-wal", "-shm"] {
        let mut s = db_path.as_os_str().to_owned();
        s.push(ext);
        let _ = fs::remove_file(PathBuf::from(s));
    }
}

pub struct ItemRecord {
    pub id: String,
    pub data: ItemData,
    pub created_at: i64,
    pub modified_at: i64,
    pub trashed_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Summary {
    pub id: String,
    pub kind: vtf_core::ItemKind,
    pub title: String,
    pub subtitle: Option<String>,
    pub folder: Option<String>,
    pub tags: Vec<String>,
    pub urls: Vec<String>,
    pub modified_at: i64,
    pub has_totp: bool,
}

pub struct HistoryEntry {
    pub modified_at: i64,
    pub data: ItemData,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrashEntry {
    pub item: Summary,
    pub deleted_at: i64,
    pub purge_at: i64,
}

/// Result of a merge. `conflicts` counts items where both sides had diverged
/// (the losing side's state is kept in history) or a deletion raced an edit;
/// such an item is also counted in exactly one of the other three fields.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ImportSummary {
    pub added: u32,
    pub updated: u32,
    pub unchanged: u32,
    pub conflicts: u32,
}

struct Row {
    id: [u8; 16],
    created_at: i64,
    modified_at: i64,
    hlc: u64,
    trashed_at: Option<i64>,
    data: ItemData,
}

/// An unlocked vault. Dropping it closes the database and zeroizes the key.
pub struct Vault {
    conn: Connection,
    key: Key,
    header: Header,
}

fn ts(now: i64) -> Result<i64> {
    if now < 0 {
        return Err(Error::InvalidInput("timestamp before 1970"));
    }
    Ok(now)
}

fn parse_id(id: &str) -> Result<[u8; 16]> {
    unhex::<16>(id).ok_or(Error::NotFound)
}

fn validate(d: &ItemData) -> Result<()> {
    let long = |s: &str| s.len() > MAX_TEXT;
    let opt_long = |s: &Option<String>| s.as_deref().is_some_and(long);
    if long(&d.title)
        || [&d.username, &d.password, &d.notes, &d.totp, &d.folder]
            .into_iter()
            .any(opt_long)
        || d.urls.iter().any(|u| long(u))
        || d.tags.iter().any(|t| long(t))
        || d.fields.iter().any(|f| long(&f.name) || long(&f.value))
    {
        return Err(Error::InvalidInput("a text value exceeds 65536 bytes"));
    }
    if d.urls.len() > MAX_URLS || d.tags.len() > MAX_TAGS || d.fields.len() > MAX_FIELDS {
        return Err(Error::InvalidInput("too many URLs, tags or fields"));
    }
    Ok(())
}

fn apply_key(conn: &Connection, key: &Key) -> Result<()> {
    // `PRAGMA cipher_memory_security` is deliberately NOT enabled. With it
    // on, every SQLite allocation is mlock()ed/VirtualLock()ed; once the lock
    // quota is exhausted (Windows working-set quota, ERROR 1453; small
    // RLIMIT_MEMLOCK on Linux/Android) SQLCipher logs a warning, its logger
    // allocates through the same locking allocator, which fails and logs
    // again: unbounded recursion and a stack overflow. SQLCipher still wipes
    // its own key material and codec buffers when freeing them.
    let hexkey = hex_secret(key.as_ref());
    let mut sql = Zeroizing::new(String::with_capacity(24 + hexkey.len()));
    sql.push_str("PRAGMA key = \"x'");
    sql.push_str(&hexkey);
    sql.push_str("'\";");
    // Error is replaced wholesale: it could quote the statement.
    conn.execute_batch(&sql).map_err(|_| Error::Internal)
}

fn open_db(path: &Path, key: &Key, create: bool) -> Result<Connection> {
    let mut flags = OpenFlags::default();
    if !create {
        flags.remove(OpenFlags::SQLITE_OPEN_CREATE);
    }
    let conn = Connection::open_with_flags(path, flags).map_err(|e| {
        if create {
            db("open")(e)
        } else {
            Error::UnlockFailed
        }
    })?;
    apply_key(&conn, key)?;
    conn.query_row("SELECT count(*) FROM sqlite_master", [], |r| {
        r.get::<_, i64>(0)
    })
    .map_err(|_| Error::UnlockFailed)?;
    conn.execute_batch("PRAGMA secure_delete = ON; PRAGMA journal_mode = DELETE;")
        .map_err(db("configure"))?;
    Ok(conn)
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS items(
  id BLOB PRIMARY KEY, created_at INTEGER NOT NULL, modified_at INTEGER NOT NULL,
  hlc INTEGER NOT NULL, trashed_at INTEGER, data BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS revisions(
  item_id BLOB NOT NULL, seq INTEGER NOT NULL, modified_at INTEGER NOT NULL, data BLOB NOT NULL,
  PRIMARY KEY(item_id, seq));
CREATE TABLE IF NOT EXISTS tombstones(id BLOB PRIMARY KEY, deleted_at INTEGER NOT NULL, hlc INTEGER NOT NULL);
INSERT OR IGNORE INTO meta(k, v) VALUES ('schema', 1);
";

fn summary(id: &[u8; 16], d: &ItemData, modified_at: i64) -> Summary {
    Summary {
        id: hex(id),
        kind: d.kind,
        title: d.title.clone(),
        subtitle: d
            .username
            .clone()
            .or_else(|| d.urls.first().and_then(|u| domain::host(u))),
        folder: d.folder.clone(),
        tags: d.tags.clone(),
        urls: d.urls.clone(),
        modified_at,
        has_totp: d.totp.as_deref().is_some_and(|t| !t.trim().is_empty()),
    }
}

fn contains_ci(hay: &str, needle_lower: &str) -> bool {
    Zeroizing::new(hay.to_lowercase()).contains(needle_lower)
}

/// Total order used to break HLC ties deterministically on every device.
fn version_key(hlc: u64, modified_at: i64, d: &ItemData) -> (u64, i64, Zeroizing<Vec<u8>>) {
    (hlc, modified_at, codec::encode(d))
}

fn newer(a: &(u64, i64, Zeroizing<Vec<u8>>), b: &(u64, i64, Zeroizing<Vec<u8>>)) -> bool {
    (a.0, a.1)
        .cmp(&(b.0, b.1))
        .then_with(|| a.2.as_slice().cmp(b.2.as_slice()))
        .is_gt()
}

impl Vault {
    // ------------------------------------------------------------ lifecycle

    pub fn create(path: &Path, password: &str, secret_key: &str, now: i64) -> Result<Vault> {
        ts(now)?;
        let pw = Password::new(password)
            .map_err(|_| Error::InvalidInput("password must not be empty"))?;
        let sk = SecretKey::parse(secret_key)
            .map_err(|_| Error::InvalidInput("malformed Secret Key"))?;
        // A vault exists at `path` if anything is there: create never
        // overwrites a file. A header with no database is the leftover of an
        // interrupted create (the header is written before the database is
        // moved into place) and holds no items, so it is removed.
        let hp = header_path(path);
        if fs::symlink_metadata(path).is_ok() {
            return Err(Error::InvalidInput("a vault already exists at this path"));
        }
        if fs::symlink_metadata(&hp).is_ok() {
            fs::remove_file(&hp).map_err(io("remove stale header"))?;
        }
        let key = header::random_key()?;
        let header = Header::seal(&key, &pw, &sk)?;
        // Order: build the database under a unique name and close it, write
        // the header, rename the database into place (the commit point),
        // sync the directory, reopen. A crash before the rename leaves no
        // database at `path`, so create can be retried.
        let tmp = unique_sibling(path, "creating");
        let mut wrote_header = false;
        let mut placed = false;
        let result = (|| {
            let conn = open_db(&tmp, &key, true)?;
            conn.execute_batch(SCHEMA).map_err(db("create schema"))?;
            drop(conn);
            write_atomic(&hp, &header.to_bytes())?;
            wrote_header = true;
            // No database is at `path`, so any side file there is stale and
            // must not be replayed into the new database.
            remove_db_files(path, false);
            fs::rename(&tmp, path).map_err(io("rename"))?;
            placed = true;
            sync_parent_dir(path)?;
            open_db(path, &key, false)
        })();
        match result {
            Ok(conn) => Ok(Vault { conn, key, header }),
            Err(e) => {
                remove_db_files(&tmp, true);
                if placed {
                    remove_db_files(path, true);
                }
                if wrote_header {
                    let _ = fs::remove_file(&hp);
                }
                Err(e)
            }
        }
    }

    pub fn unlock_with_password(path: &Path, password: &str, secret_key: &str) -> Result<Vault> {
        Self::unlock_first_matching(&[path], password, secret_key)
    }

    /// Decoy support. Every candidate costs exactly one Argon2id run (a
    /// missing or unreadable header uses a placeholder salt), the loop never
    /// exits early, and every failure is `UnlockFailed`, so timing and error
    /// do not reveal how many candidates exist or match. The first match
    /// wins.
    pub fn unlock_first_matching(
        paths: &[&Path],
        password: &str,
        secret_key: &str,
    ) -> Result<Vault> {
        if paths.is_empty() || paths.len() > MAX_DECOY_PATHS {
            return Err(Error::InvalidInput("between 1 and 8 vault paths"));
        }
        let pw = Password::new(password).ok();
        let sk = SecretKey::parse(secret_key).ok();
        let placeholder_pw = Password::new("placeholder").map_err(|_| Error::Internal)?;
        let placeholder_sk = SecretKey::from_bytes([0u8; 16]);
        let valid = pw.is_some() && sk.is_some();
        let (pw_ref, sk_ref) = match (&pw, &sk) {
            (Some(p), Some(s)) => (p, s),
            _ => (&placeholder_pw, &placeholder_sk),
        };
        let mut found: Option<(usize, Key, Header)> = None;
        for (i, p) in paths.iter().enumerate() {
            let hdr = fs::read(header_path(p))
                .ok()
                .and_then(|b| Header::parse(&b));
            let salt = hdr.as_ref().map_or([0u8; 32], |h| *h.salt());
            let kek = keys::derive_kek(pw_ref, sk_ref, &salt).ok();
            let opened = match (&hdr, &kek) {
                (Some(h), Some(k)) if valid => h.open_with_kek(k),
                _ => None,
            };
            if let (Some(k), Some(h)) = (opened, hdr) {
                if found.is_none() {
                    found = Some((i, k, h));
                }
            }
        }
        let (i, key, header) = found.ok_or(Error::UnlockFailed)?;
        let conn = open_db(paths[i], &key, false)?;
        Ok(Vault { conn, key, header })
    }

    /// Biometric unlock: `blob` from [`Vault::wrap_vault_key_for_device`],
    /// opened with one ECDH in the device's secure hardware.
    pub fn unlock_with_device_key(
        path: &Path,
        blob: &[u8],
        device: &dyn DeviceKey,
    ) -> Result<Vault> {
        let header = fs::read(header_path(path))
            .ok()
            .and_then(|b| Header::parse(&b))
            .ok_or(Error::UnlockFailed)?;
        let key = header::unwrap_with_device(blob, &header.vault_id, device)
            .ok_or(Error::UnlockFailed)?;
        let conn = open_db(path, &key, false)?;
        Ok(Vault { conn, key, header })
    }

    pub fn wrap_vault_key_for_device(&self, device_public_key: &[u8]) -> Result<Vec<u8>> {
        header::wrap_for_device(&self.key, &self.header.vault_id, device_public_key)
    }

    /// Checks that `password` + `secret_key` are this vault's credentials.
    fn verify_credentials(&self, pw: &Password, sk: &SecretKey) -> Result<()> {
        let k = self.header.open(pw, sk).ok_or(Error::UnlockFailed)?;
        if bool::from(k.as_ref().ct_eq(self.key.as_ref())) {
            Ok(())
        } else {
            Err(Error::UnlockFailed)
        }
    }

    // ----------------------------------------------------------- meta / HLC

    fn meta(&self, k: &str) -> Result<Option<i64>> {
        self.conn
            .query_row("SELECT v FROM meta WHERE k = ?1", [k], |r| r.get(0))
            .optional()
            .map_err(db("read meta"))
    }

    fn set_meta(&self, k: &str, v: i64) -> Result<()> {
        self.conn
            .execute("INSERT INTO meta(k, v) VALUES (?1, ?2) ON CONFLICT(k) DO UPDATE SET v = excluded.v", params![k, v])
            .map(|_| ())
            .map_err(db("write meta"))
    }

    /// Hybrid logical clock: `(unix_seconds << 16) | counter`, strictly
    /// increasing per vault and never behind any HLC this vault has seen.
    fn tick(&self, now: i64) -> Result<u64> {
        let last = self.meta("hlc")?.unwrap_or(0) as u64;
        let next = ((now.max(0) as u64) << 16).max(last + 1);
        self.set_meta("hlc", next as i64)?;
        Ok(next)
    }

    fn observe(&self, remote: u64) -> Result<()> {
        let last = self.meta("hlc")?.unwrap_or(0) as u64;
        if remote > last {
            self.set_meta("hlc", remote as i64)?;
        }
        Ok(())
    }

    // --------------------------------------------------------------- rows

    fn decode_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Option<Row>> {
        let id_ref = r.get_ref(0)?;
        let id: [u8; 16] = match id_ref.as_blob()?.try_into() {
            Ok(v) => v,
            Err(_) => return Ok(None),
        };
        let data = match codec::decode(r.get_ref(5)?.as_blob()?) {
            Some(d) => d,
            None => return Ok(None),
        };
        Ok(Some(Row {
            id,
            created_at: r.get(1)?,
            modified_at: r.get(2)?,
            hlc: r.get::<_, i64>(3)? as u64,
            trashed_at: r.get(4)?,
            data,
        }))
    }

    fn load(&self, id: &[u8; 16]) -> Result<Option<Row>> {
        let row = self
            .conn
            .query_row(
                "SELECT id, created_at, modified_at, hlc, trashed_at, data FROM items WHERE id = ?1",
                [&id[..]],
                Self::decode_row,
            )
            .optional()
            .map_err(db("read item"))?;
        match row {
            None => Ok(None),
            Some(None) => Err(Error::Internal),
            Some(Some(r)) => Ok(Some(r)),
        }
    }

    fn load_all(&self, include_trashed: bool) -> Result<Vec<Row>> {
        let sql = if include_trashed {
            "SELECT id, created_at, modified_at, hlc, trashed_at, data FROM items ORDER BY id"
        } else {
            "SELECT id, created_at, modified_at, hlc, trashed_at, data FROM items WHERE trashed_at IS NULL ORDER BY id"
        };
        let mut st = self.conn.prepare(sql).map_err(db("read items"))?;
        let rows = st
            .query_map([], Self::decode_row)
            .map_err(db("read items"))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r.map_err(db("read items"))?.ok_or(Error::Internal)?);
        }
        Ok(out)
    }

    fn write_row(&self, r: &Row) -> Result<()> {
        let blob = codec::encode(&r.data);
        self.conn
            .execute(
                "INSERT INTO items(id, created_at, modified_at, hlc, trashed_at, data) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(id) DO UPDATE SET created_at = excluded.created_at, modified_at = excluded.modified_at,
                 hlc = excluded.hlc, trashed_at = excluded.trashed_at, data = excluded.data",
                params![&r.id[..], r.created_at, r.modified_at, r.hlc as i64, r.trashed_at, &blob[..]],
            )
            .map(|_| ())
            .map_err(db("write item"))
    }

    fn history_of(&self, id: &[u8; 16]) -> Result<Vec<Revision>> {
        let mut st = self
            .conn
            .prepare("SELECT modified_at, data FROM revisions WHERE item_id = ?1 ORDER BY seq")
            .map_err(db("read history"))?;
        let rows = st
            .query_map([&id[..]], |r| {
                Ok((r.get::<_, i64>(0)?, codec::decode(r.get_ref(1)?.as_blob()?)))
            })
            .map_err(db("read history"))?;
        let mut out = Vec::new();
        for r in rows {
            let (m, d) = r.map_err(db("read history"))?;
            out.push(Revision {
                modified_at: m as u64,
                data: d.ok_or(Error::Internal)?,
            });
        }
        Ok(out)
    }

    fn write_history(&self, id: &[u8; 16], revs: &[Revision]) -> Result<()> {
        self.conn
            .execute("DELETE FROM revisions WHERE item_id = ?1", [&id[..]])
            .map_err(db("write history"))?;
        let start = revs.len().saturating_sub(MAX_REVISIONS);
        for (seq, r) in revs[start..].iter().enumerate() {
            let blob = codec::encode(&r.data);
            self.conn
                .execute(
                    "INSERT INTO revisions(item_id, seq, modified_at, data) VALUES (?1, ?2, ?3, ?4)",
                    params![&id[..], seq as i64, r.modified_at as i64, &blob[..]],
                )
                .map_err(db("write history"))?;
        }
        Ok(())
    }

    fn delete_item(&self, id: &[u8; 16]) -> Result<()> {
        self.conn
            .execute("DELETE FROM revisions WHERE item_id = ?1", [&id[..]])
            .map_err(db("delete item"))?;
        self.conn
            .execute("DELETE FROM items WHERE id = ?1", [&id[..]])
            .map_err(db("delete item"))?;
        Ok(())
    }

    fn tombstone_hlc(&self, id: &[u8; 16]) -> Result<Option<u64>> {
        self.conn
            .query_row("SELECT hlc FROM tombstones WHERE id = ?1", [&id[..]], |r| {
                r.get::<_, i64>(0)
            })
            .optional()
            .map(|o| o.map(|v| v as u64))
            .map_err(db("read tombstone"))
    }

    /// Inserts a tombstone, keeping the newer one if it already exists.
    fn put_tombstone(&self, id: &[u8; 16], deleted_at: i64, hlc: u64) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO tombstones(id, deleted_at, hlc) VALUES (?1, ?2, ?3)
                 ON CONFLICT(id) DO UPDATE SET deleted_at = excluded.deleted_at, hlc = excluded.hlc
                 WHERE excluded.hlc > tombstones.hlc",
                params![&id[..], deleted_at, hlc as i64],
            )
            .map(|_| ())
            .map_err(db("write tombstone"))
    }

    fn live(&self, id: &str) -> Result<Row> {
        let id = parse_id(id)?;
        let row = self.load(&id)?.ok_or(Error::NotFound)?;
        Ok(row)
    }

    // -------------------------------------------------------------- items

    pub fn add_item(&mut self, data: ItemData, now: i64) -> Result<String> {
        ts(now)?;
        validate(&data)?;
        let mut id = [0u8; 16];
        keys::fill_random(&mut id).map_err(|_| Error::Internal)?;
        let tx = self.conn.unchecked_transaction().map_err(db("begin"))?;
        let hlc = self.tick(now)?;
        self.write_row(&Row {
            id,
            created_at: now,
            modified_at: now,
            hlc,
            trashed_at: None,
            data,
        })?;
        tx.commit().map_err(db("commit"))?;
        Ok(hex(&id))
    }

    pub fn update_item(&mut self, id: &str, data: ItemData, now: i64) -> Result<()> {
        ts(now)?;
        validate(&data)?;
        let mut row = self.live(id)?;
        if row.trashed_at.is_some() {
            return Err(Error::InvalidInput(
                "item is in the trash; restore it first",
            ));
        }
        if row.data == data {
            return Ok(());
        }
        let tx = self.conn.unchecked_transaction().map_err(db("begin"))?;
        let mut hist = self.history_of(&row.id)?;
        hist.push(Revision {
            modified_at: row.modified_at.max(0) as u64,
            data: row.data.clone(),
        });
        row.data = data;
        row.modified_at = now;
        row.hlc = self.tick(now)?;
        self.write_row(&row)?;
        self.write_history(&row.id, &hist)?;
        tx.commit().map_err(db("commit"))
    }

    pub fn get_item(&self, id: &str) -> Result<ItemRecord> {
        let r = self.live(id)?;
        Ok(ItemRecord {
            id: hex(&r.id),
            created_at: r.created_at,
            modified_at: r.modified_at,
            trashed_at: r.trashed_at,
            data: r.data,
        })
    }

    /// Case-insensitive substring match on title, username, URLs, tags,
    /// folder and non-concealed field names. Folder and tag filters are
    /// exact (case-insensitive). Trashed items are excluded. Sorted by title.
    pub fn search(
        &self,
        query: &str,
        folder: Option<&str>,
        tag: Option<&str>,
    ) -> Result<Vec<Summary>> {
        let q = Zeroizing::new(query.trim().to_lowercase());
        let mut out: Vec<Summary> = self
            .load_all(false)?
            .iter()
            .filter(|r| {
                let d = &r.data;
                folder.is_none_or(|f| {
                    d.folder.as_deref().is_some_and(|x| {
                        x.eq_ignore_ascii_case(f) || x.to_lowercase() == f.to_lowercase()
                    })
                }) && tag
                    .is_none_or(|t| d.tags.iter().any(|x| x.to_lowercase() == t.to_lowercase()))
                    && (q.is_empty()
                        || contains_ci(&d.title, &q)
                        || d.username.as_deref().is_some_and(|u| contains_ci(u, &q))
                        || d.urls.iter().any(|u| contains_ci(u, &q))
                        || d.tags.iter().any(|t| contains_ci(t, &q))
                        || d.folder.as_deref().is_some_and(|f| contains_ci(f, &q))
                        || d.fields
                            .iter()
                            .any(|f| !f.concealed && contains_ci(&f.name, &q)))
            })
            .map(|r| summary(&r.id, &r.data, r.modified_at))
            .collect();
        out.sort_by(|a, b| {
            a.title
                .to_lowercase()
                .cmp(&b.title.to_lowercase())
                .then_with(|| a.id.cmp(&b.id))
        });
        Ok(out)
    }

    /// Live items with a URL whose registrable domain equals that of
    /// `url_or_domain` (see [`crate::domain`] for the suffix-list limits).
    pub fn match_domain(&self, url_or_domain: &str) -> Result<Vec<Summary>> {
        let host = domain::host(url_or_domain).ok_or(Error::InvalidInput("not a URL or domain"))?;
        let Some(want) = domain::registrable(&host) else {
            return Ok(vec![]);
        };
        let mut out: Vec<Summary> = self
            .load_all(false)?
            .iter()
            .filter(|r| {
                r.data
                    .urls
                    .iter()
                    .any(|u| domain::registrable_of(u).as_deref() == Some(want.as_str()))
            })
            .map(|r| summary(&r.id, &r.data, r.modified_at))
            .collect();
        out.sort_by(|a, b| {
            a.title
                .to_lowercase()
                .cmp(&b.title.to_lowercase())
                .then_with(|| a.id.cmp(&b.id))
        });
        Ok(out)
    }

    /// Revisions, oldest first (at most 64).
    pub fn item_history(&self, id: &str) -> Result<Vec<HistoryEntry>> {
        let r = self.live(id)?;
        let mut hist = self.history_of(&r.id)?;
        Ok(hist
            .iter_mut()
            .map(|h| HistoryEntry {
                modified_at: h.modified_at as i64,
                data: h.data.clone(),
            })
            .collect())
    }

    pub fn trash_item(&mut self, id: &str, now: i64) -> Result<()> {
        ts(now)?;
        let mut r = self.live(id)?;
        if r.trashed_at.is_some() {
            return Ok(());
        }
        let tx = self.conn.unchecked_transaction().map_err(db("begin"))?;
        r.trashed_at = Some(now);
        r.hlc = self.tick(now)?;
        self.write_row(&r)?;
        tx.commit().map_err(db("commit"))
    }

    pub fn restore_item(&mut self, id: &str, now: i64) -> Result<()> {
        ts(now)?;
        let mut r = self.live(id)?;
        if r.trashed_at.is_none() {
            return Ok(());
        }
        let tx = self.conn.unchecked_transaction().map_err(db("begin"))?;
        r.trashed_at = None;
        r.hlc = self.tick(now)?;
        self.write_row(&r)?;
        tx.commit().map_err(db("commit"))
    }

    pub fn list_trash(&self) -> Result<Vec<TrashEntry>> {
        let mut out: Vec<TrashEntry> = self
            .load_all(true)?
            .iter()
            .filter_map(|r| {
                r.trashed_at.map(|t| TrashEntry {
                    item: summary(&r.id, &r.data, r.modified_at),
                    deleted_at: t,
                    purge_at: t.saturating_add(TRASH_RETENTION_SECS),
                })
            })
            .collect();
        out.sort_by(|a, b| {
            b.deleted_at
                .cmp(&a.deleted_at)
                .then_with(|| a.item.id.cmp(&b.item.id))
        });
        Ok(out)
    }

    /// Permanently deletes items trashed at least 180 days ago, leaving a
    /// tombstone (kept indefinitely) so the deletion wins over older copies
    /// in later imports.
    pub fn purge_expired_trash(&mut self, now: i64) -> Result<u32> {
        ts(now)?;
        let tx = self.conn.unchecked_transaction().map_err(db("begin"))?;
        let mut n = 0;
        for r in self.load_all(true)? {
            if r.trashed_at
                .is_some_and(|t| now.saturating_sub(t) >= TRASH_RETENTION_SECS)
            {
                let hlc = self.tick(now)?;
                self.delete_item(&r.id)?;
                self.put_tombstone(&r.id, now, hlc)?;
                n += 1;
            }
        }
        tx.commit().map_err(db("commit"))?;
        Ok(n)
    }

    pub fn list_folders(&self) -> Result<Vec<String>> {
        let set: BTreeSet<String> = self
            .load_all(false)?
            .iter()
            .filter_map(|r| r.data.folder.clone())
            .collect();
        Ok(set.into_iter().collect())
    }

    pub fn list_tags(&self) -> Result<Vec<String>> {
        let set: BTreeSet<String> = self
            .load_all(false)?
            .iter()
            .flat_map(|r| r.data.tags.clone())
            .collect();
        Ok(set.into_iter().collect())
    }

    pub fn item_totp(&self, id: &str, now: i64) -> Result<TotpCode> {
        let r = self.live(id)?;
        let t = r
            .data
            .totp
            .as_deref()
            .filter(|t| !t.trim().is_empty())
            .ok_or(Error::NotFound)?;
        totp::totp_code(t, now)
    }

    pub fn password_health(&self, now: i64) -> Result<HealthReport> {
        ts(now)?;
        let rows = self.load_all(false)?;
        let mut hists = Vec::with_capacity(rows.len());
        let mut ids = Vec::with_capacity(rows.len());
        for r in &rows {
            hists.push(self.history_of(&r.id)?);
            ids.push(hex(&r.id));
        }
        let items: Vec<AuditItem<'_>> = rows
            .iter()
            .zip(&hists)
            .zip(&ids)
            .map(|((r, h), id)| AuditItem {
                id,
                data: &r.data,
                created_at: r.created_at,
                modified_at: r.modified_at,
                history: h,
            })
            .collect();
        Ok(audit::health(&items, now))
    }

    // --------------------------------------------------------- travel mode

    pub fn travel_mode(&self) -> Result<bool> {
        Ok(self.meta("travel_mode")?.unwrap_or(0) != 0)
    }

    /// Enabling removes every item not marked travel_safe (with its history)
    /// from this device's store, without tombstones, then VACUUMs so the
    /// pages are rewritten. Disabling only clears the flag: removed items
    /// come back by importing a VTF export or restoring a backup. While
    /// travel mode is on, imports skip items not marked travel_safe.
    pub fn set_travel_mode(&mut self, enabled: bool, now: i64) -> Result<()> {
        ts(now)?;
        let tx = self.conn.unchecked_transaction().map_err(db("begin"))?;
        if enabled {
            for r in self.load_all(true)? {
                if !r.data.travel_safe {
                    self.delete_item(&r.id)?;
                }
            }
        }
        self.set_meta("travel_mode", i64::from(enabled))?;
        tx.commit().map_err(db("commit"))?;
        if enabled {
            self.conn.execute_batch("VACUUM;").map_err(db("vacuum"))?;
        }
        Ok(())
    }

    // ------------------------------------------------------------ VTF / CSV

    fn to_payload(&self, now: i64) -> Result<Payload> {
        let mut items = Vec::new();
        for r in self.load_all(true)? {
            let history = self.history_of(&r.id)?;
            items.push(vtf_core::Item {
                id: r.id,
                created_at: r.created_at.max(0) as u64,
                modified_at: r.modified_at.max(0) as u64,
                hlc: r.hlc,
                data: r.data.clone(),
                history,
                trashed_at: r.trashed_at.map(|t| t.max(0) as u64),
            });
        }
        let mut st = self
            .conn
            .prepare("SELECT id, deleted_at, hlc FROM tombstones ORDER BY id")
            .map_err(db("read tombstones"))?;
        let rows = st
            .query_map([], |r| {
                Ok((
                    r.get::<_, Vec<u8>>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, i64>(2)?,
                ))
            })
            .map_err(db("read tombstones"))?;
        let mut tombstones = Vec::new();
        for t in rows {
            let (id, d, h) = t.map_err(db("read tombstones"))?;
            tombstones.push(Tombstone {
                id: id.try_into().map_err(|_| Error::Internal)?,
                deleted_at: d.max(0) as u64,
                hlc: h as u64,
            });
        }
        Ok(Payload {
            exported_at: now as u64,
            items,
            tombstones,
        })
    }

    /// Exports the whole store (live and trashed items, history,
    /// tombstones). The password slot uses this vault's own master password
    /// and Secret Key, which are verified first (`UnlockFailed` otherwise).
    pub fn export_vtf(
        &self,
        password: &str,
        secret_key: &str,
        device_recipients: &[Vec<u8>],
        now: i64,
    ) -> Result<Vec<u8>> {
        ts(now)?;
        if device_recipients.len() > MAX_DEVICE_RECIPIENTS {
            return Err(Error::InvalidInput("at most 15 device recipients"));
        }
        let mut pks = Vec::with_capacity(device_recipients.len());
        for r in device_recipients {
            let pk: [u8; PUBLIC_KEY_LEN] = r
                .as_slice()
                .try_into()
                .map_err(|_| Error::InvalidInput("device public key must be 65 bytes"))?;
            vtf_core::device::validate_public_key(&pk)?;
            pks.push(pk);
        }
        let pw = Password::new(password).map_err(|_| Error::UnlockFailed)?;
        let sk = SecretKey::parse(secret_key).map_err(|_| Error::UnlockFailed)?;
        self.verify_credentials(&pw, &sk)?;
        let payload = self.to_payload(now)?;
        Ok(vtf_core::export(
            &payload,
            Some(PasswordCredentials {
                password: &pw,
                secret_key: &sk,
            }),
            &pks,
        )?)
    }

    pub fn import_vtf(
        &mut self,
        file: &[u8],
        password: &str,
        secret_key: &str,
        now: i64,
    ) -> Result<ImportSummary> {
        ts(now)?;
        let pw = Password::new(password).map_err(|_| Error::UnlockFailed)?;
        let sk = SecretKey::parse(secret_key).map_err(|_| Error::UnlockFailed)?;
        let payload = vtf_core::import_with_password(file, &pw, &sk)?;
        self.merge(payload)
    }

    pub fn import_vtf_with_device_key(
        &mut self,
        file: &[u8],
        device: &dyn DeviceKey,
        now: i64,
    ) -> Result<ImportSummary> {
        ts(now)?;
        let payload = vtf_core::import_with_device(file, device)?;
        self.merge(payload)
    }

    /// Per-item merge. See `docs/VAULT-CORE.md` for the full rule set:
    /// HLC last-writer-wins per item (ties broken by modified_at, then the
    /// item encoding), tombstones win over edits with an equal or older HLC,
    /// histories are unioned, a diverged loser is kept as a revision, and a
    /// stale file that would change nothing is refused as `rollback`.
    fn merge(&mut self, payload: Payload) -> Result<ImportSummary> {
        let tx = self.conn.unchecked_transaction().map_err(db("begin"))?;
        let travel = self.travel_mode()?;
        let mut s = ImportSummary::default();
        let mut max_hlc = 0u64;

        for t in &payload.tombstones {
            max_hlc = max_hlc.max(t.hlc);
            let deleted_at = t.deleted_at.min(i64::MAX as u64) as i64;
            match self.load(&t.id)? {
                Some(local) if local.hlc <= t.hlc => {
                    self.delete_item(&t.id)?;
                    self.put_tombstone(&t.id, deleted_at, t.hlc)?;
                    s.updated += 1;
                }
                // A local edit newer than the remote deletion survives.
                Some(_) => s.conflicts += 1,
                None => self.put_tombstone(&t.id, deleted_at, t.hlc)?,
            }
        }

        for it in &payload.items {
            max_hlc = max_hlc.max(it.hlc);
            if travel && !it.data.travel_safe {
                s.unchanged += 1;
                continue;
            }
            let remote_row = || Row {
                id: it.id,
                created_at: it.created_at.min(i64::MAX as u64) as i64,
                modified_at: it.modified_at.min(i64::MAX as u64) as i64,
                hlc: it.hlc,
                trashed_at: it.trashed_at.map(|t| t.min(i64::MAX as u64) as i64),
                data: it.data.clone(),
            };
            if let Some(tomb) = self.tombstone_hlc(&it.id)? {
                if tomb >= it.hlc {
                    s.unchanged += 1;
                    continue;
                }
                // Edited elsewhere after this device deleted it: resurrect.
                self.conn
                    .execute("DELETE FROM tombstones WHERE id = ?1", [&it.id[..]])
                    .map_err(db("delete tombstone"))?;
                self.write_row(&remote_row())?;
                self.write_history(&it.id, &it.history)?;
                s.added += 1;
                s.conflicts += 1;
                continue;
            }
            let Some(local) = self.load(&it.id)? else {
                self.write_row(&remote_row())?;
                self.write_history(&it.id, &it.history)?;
                s.added += 1;
                continue;
            };
            let local_hist = self.history_of(&local.id)?;
            let lk = version_key(local.hlc, local.modified_at, &local.data);
            let rk = version_key(it.hlc, it.modified_at.min(i64::MAX as u64) as i64, &it.data);
            let remote_wins = newer(&rk, &lk);
            let (win_data, win_hist, lose_data, lose_modified, lose_hist) = if remote_wins {
                (
                    &it.data,
                    &it.history,
                    &local.data,
                    local.modified_at.max(0) as u64,
                    &local_hist,
                )
            } else {
                (
                    &local.data,
                    &local_hist,
                    &it.data,
                    it.modified_at,
                    &it.history,
                )
            };
            let diverged = win_data != lose_data && !win_hist.iter().any(|r| r.data == *lose_data);

            let mut merged: Vec<Revision> =
                Vec::with_capacity(win_hist.len() + lose_hist.len() + 1);
            for r in win_hist.iter().chain(lose_hist.iter()) {
                if !merged
                    .iter()
                    .any(|m| m.modified_at == r.modified_at && m.data == r.data)
                {
                    merged.push(r.clone());
                }
            }
            if diverged && !merged.iter().any(|m| m.data == *lose_data) {
                merged.push(Revision {
                    modified_at: lose_modified,
                    data: lose_data.clone(),
                });
            }
            merged.sort_by_key(|r| r.modified_at);
            let keep = merged.len().saturating_sub(MAX_REVISIONS);
            merged.drain(..keep);

            if diverged {
                s.conflicts += 1;
            }
            let hist_changed = merged.len() != local_hist.len()
                || merged
                    .iter()
                    .zip(&local_hist)
                    .any(|(a, b)| a.modified_at != b.modified_at || a.data != b.data);
            if remote_wins {
                let mut row = remote_row();
                row.created_at = row.created_at.min(local.created_at);
                let visible_change = local.data != it.data || local.trashed_at != row.trashed_at;
                self.write_row(&row)?;
                self.write_history(&it.id, &merged)?;
                if visible_change {
                    s.updated += 1;
                } else {
                    s.unchanged += 1;
                }
            } else {
                if hist_changed {
                    self.write_history(&local.id, &merged)?;
                }
                s.unchanged += 1;
            }
        }
        self.observe(max_hlc)?;

        // Rollback rule: a file older (by exported_at) than the newest file
        // already imported, that would add, change or conflict nothing, is
        // refused so the UI can tell the user it is stale.
        let exported_at = payload.exported_at.min(i64::MAX as u64) as i64;
        let last = self.meta("import_exported_at")?.unwrap_or(-1);
        if exported_at < last && s.added == 0 && s.updated == 0 && s.conflicts == 0 {
            return Err(Error::FormatRejected("rollback"));
        }
        if exported_at > last {
            self.set_meta("import_exported_at", exported_at)?;
        }
        tx.commit().map_err(db("commit"))?;
        Ok(s)
    }

    pub fn import_csv(&mut self, source: CsvSource, text: &str, now: i64) -> Result<ImportSummary> {
        ts(now)?;
        let items = csv::items(source, text)?;
        for d in &items {
            validate(d)?;
        }
        let tx = self.conn.unchecked_transaction().map_err(db("begin"))?;
        let mut s = ImportSummary::default();
        for data in items {
            let mut id = [0u8; 16];
            keys::fill_random(&mut id).map_err(|_| Error::Internal)?;
            let hlc = self.tick(now)?;
            self.write_row(&Row {
                id,
                created_at: now,
                modified_at: now,
                hlc,
                trashed_at: None,
                data,
            })?;
            s.added += 1;
        }
        tx.commit().map_err(db("commit"))?;
        Ok(s)
    }

    // --------------------------------------------------------------- backup

    /// Consistent copy of the encrypted database (SQLite online backup into
    /// a destination keyed with the same vault key) plus its header at
    /// `<path>.hdr`. Opens with the same password + Secret Key. Refuses to
    /// overwrite an existing file.
    pub fn backup_to(&self, path: &Path) -> Result<()> {
        let hp = header_path(path);
        if path.exists() || hp.exists() {
            return Err(Error::InvalidInput("backup destination already exists"));
        }
        let result = (|| {
            let mut dst = Connection::open(path).map_err(db("open backup"))?;
            apply_key(&dst, &self.key)?;
            {
                let b =
                    rusqlite::backup::Backup::new(&self.conn, &mut dst).map_err(db("backup"))?;
                b.run_to_completion(256, Duration::ZERO, None)
                    .map_err(db("backup"))?;
            }
            dst.query_row("SELECT count(*) FROM items", [], |r| r.get::<_, i64>(0))
                .map_err(db("verify backup"))?;
            drop(dst);
            write_atomic(&hp, &self.header.to_bytes())
        })();
        if result.is_err() {
            remove_db_files(path, true);
            let _ = fs::remove_file(&hp);
        }
        result
    }
}
