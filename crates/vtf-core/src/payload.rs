//! The VTF1 payload schema (SPEC-VTF section 6.3) and its strict mapping to
//! and from deterministic CBOR.

use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use crate::cbor::{self, Enc, V};
use crate::error::{Check, Error, Result};

pub const PAYLOAD_VERSION: u64 = 1;
pub const MAX_ITEMS: usize = 100_000;
pub const MAX_TOMBSTONES: usize = 100_000;
pub const MAX_REVISIONS: usize = 64;
pub const MAX_FIELDS: usize = 128;
pub const MAX_URLS: usize = 64;
pub const MAX_TAGS: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ItemKind {
    Login = 0,
    SecureNote = 1,
    Card = 2,
    Identity = 3,
    ApiKey = 4,
    SshKey = 5,
}

impl ItemKind {
    fn from_u64(v: u64) -> Option<Self> {
        Some(match v {
            0 => ItemKind::Login,
            1 => ItemKind::SecureNote,
            2 => ItemKind::Card,
            3 => ItemKind::Identity,
            4 => ItemKind::ApiKey,
            5 => ItemKind::SshKey,
            _ => return None,
        })
    }
}

#[derive(Clone, PartialEq, Eq, Zeroize, ZeroizeOnDrop)]
pub struct Field {
    pub name: String,
    pub value: String,
    pub concealed: bool,
}

/// The user-editable content of an item (also what a history revision holds).
#[derive(Clone, PartialEq, Eq, Zeroize, ZeroizeOnDrop)]
pub struct ItemData {
    #[zeroize(skip)]
    pub kind: ItemKind,
    pub title: String,
    pub username: Option<String>,
    pub password: Option<String>,
    pub urls: Vec<String>,
    pub notes: Option<String>,
    pub totp: Option<String>,
    pub folder: Option<String>,
    pub tags: Vec<String>,
    pub fields: Vec<Field>,
    pub travel_safe: bool,
}

#[derive(Clone, PartialEq, Eq, Zeroize, ZeroizeOnDrop)]
pub struct Revision {
    pub modified_at: u64,
    pub data: ItemData,
}

#[derive(Clone, PartialEq, Eq, Zeroize, ZeroizeOnDrop)]
pub struct Item {
    pub id: [u8; 16],
    pub created_at: u64,
    pub modified_at: u64,
    pub hlc: u64,
    pub data: ItemData,
    pub history: Vec<Revision>,
    pub trashed_at: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tombstone {
    pub id: [u8; 16],
    pub deleted_at: u64,
    pub hlc: u64,
}

#[derive(Clone, PartialEq, Eq, Zeroize, ZeroizeOnDrop)]
pub struct Payload {
    pub exported_at: u64,
    pub items: Vec<Item>,
    #[zeroize(skip)]
    pub tombstones: Vec<Tombstone>,
}

// Keys (SPEC-VTF 6.3).
mod k {
    pub const P_VERSION: u64 = 1;
    pub const P_EXPORTED_AT: u64 = 2;
    pub const P_ITEMS: u64 = 3;
    pub const P_TOMBSTONES: u64 = 4;

    pub const ID: u64 = 1;
    pub const KIND: u64 = 2;
    pub const TITLE: u64 = 3;
    pub const CREATED_AT: u64 = 4;
    pub const MODIFIED_AT: u64 = 5;
    pub const HLC: u64 = 6;
    pub const USERNAME: u64 = 7;
    pub const PASSWORD: u64 = 8;
    pub const URLS: u64 = 9;
    pub const NOTES: u64 = 10;
    pub const TOTP: u64 = 11;
    pub const FOLDER: u64 = 12;
    pub const TAGS: u64 = 13;
    pub const FIELDS: u64 = 14;
    pub const TRAVEL_SAFE: u64 = 15;
    pub const HISTORY: u64 = 16;
    pub const TRASHED_AT: u64 = 17;

    pub const TOP: &[u64] = &[P_VERSION, P_EXPORTED_AT, P_ITEMS, P_TOMBSTONES];
    pub const ITEM: &[u64] = &[
        ID,
        KIND,
        TITLE,
        CREATED_AT,
        MODIFIED_AT,
        HLC,
        USERNAME,
        PASSWORD,
        URLS,
        NOTES,
        TOTP,
        FOLDER,
        TAGS,
        FIELDS,
        TRAVEL_SAFE,
        HISTORY,
        TRASHED_AT,
    ];
    pub const REV_DATA: &[u64] = &[
        KIND,
        TITLE,
        USERNAME,
        PASSWORD,
        URLS,
        NOTES,
        TOTP,
        FOLDER,
        TAGS,
        FIELDS,
        TRAVEL_SAFE,
    ];
    pub const FIELD: &[u64] = &[1, 2, 3];
    pub const REVISION: &[u64] = &[1, 2];
    pub const TOMBSTONE: &[u64] = &[1, 2, 3];
}

// ------------------------------------------------------------------ decode

type R<T> = core::result::Result<T, Check>;

struct Map<'v, 'a> {
    entries: &'v [(u64, V<'a>)],
}

impl<'v, 'a> Map<'v, 'a> {
    fn new(v: &'v V<'a>, allowed: &[u64], required: &[u64]) -> R<Self> {
        let V::M(entries) = v else {
            return Err(Check::CborType);
        };
        if entries.iter().any(|(key, _)| !allowed.contains(key)) {
            return Err(Check::CborUnknownKey);
        }
        let m = Map { entries };
        if required.iter().any(|key| m.get(*key).is_none()) {
            return Err(Check::CborMissingKey);
        }
        Ok(m)
    }

    fn get(&self, key: u64) -> Option<&'v V<'a>> {
        self.entries.iter().find(|(k, _)| *k == key).map(|(_, v)| v)
    }

    fn uint(&self, key: u64) -> R<u64> {
        match self.get(key) {
            Some(V::U(x)) => Ok(*x),
            Some(_) => Err(Check::CborType),
            None => Err(Check::CborMissingKey),
        }
    }

    fn opt_uint(&self, key: u64) -> R<Option<u64>> {
        match self.get(key) {
            None => Ok(None),
            Some(V::U(x)) => Ok(Some(*x)),
            Some(_) => Err(Check::CborType),
        }
    }

    fn text(&self, key: u64) -> R<String> {
        self.opt_text(key)?.ok_or(Check::CborMissingKey)
    }

    fn opt_text(&self, key: u64) -> R<Option<String>> {
        match self.get(key) {
            None => Ok(None),
            Some(V::T(s)) => Ok(Some((*s).to_owned())),
            Some(_) => Err(Check::CborType),
        }
    }

    fn id(&self, key: u64) -> R<[u8; 16]> {
        match self.get(key) {
            Some(V::B(b)) => (*b).try_into().map_err(|_| Check::CborType),
            Some(_) => Err(Check::CborType),
            None => Err(Check::CborMissingKey),
        }
    }

    /// Optional `true` flag: absent = false, `false` encoded = rejected.
    fn flag(&self, key: u64) -> R<bool> {
        match self.get(key) {
            None => Ok(false),
            Some(V::Bool(true)) => Ok(true),
            Some(V::Bool(false)) => Err(Check::CborEmptyOptional),
            Some(_) => Err(Check::CborType),
        }
    }

    /// Optional array: absent = empty, present-but-empty = rejected.
    fn opt_array(&self, key: u64, max: usize) -> R<&'v [V<'a>]> {
        match self.get(key) {
            None => Ok(&[]),
            Some(V::A(a)) if a.is_empty() => Err(Check::CborEmptyOptional),
            Some(V::A(a)) if a.len() > max => Err(Check::CborLimit),
            Some(V::A(a)) => Ok(a),
            Some(_) => Err(Check::CborType),
        }
    }

    fn texts(&self, key: u64, max: usize) -> R<Vec<String>> {
        self.opt_array(key, max)?
            .iter()
            .map(|v| match v {
                V::T(s) => Ok((*s).to_owned()),
                _ => Err(Check::CborType),
            })
            .collect()
    }
}

fn decode_data(m: &Map<'_, '_>) -> R<ItemData> {
    let kind = ItemKind::from_u64(m.uint(k::KIND)?).ok_or(Check::CborType)?;
    let fields = m
        .opt_array(k::FIELDS, MAX_FIELDS)?
        .iter()
        .map(|f| {
            let f = Map::new(f, k::FIELD, &[1, 2])?;
            Ok(Field {
                name: f.text(1)?,
                value: f.text(2)?,
                concealed: f.flag(3)?,
            })
        })
        .collect::<R<Vec<_>>>()?;
    Ok(ItemData {
        kind,
        title: m.text(k::TITLE)?,
        username: m.opt_text(k::USERNAME)?,
        password: m.opt_text(k::PASSWORD)?,
        urls: m.texts(k::URLS, MAX_URLS)?,
        notes: m.opt_text(k::NOTES)?,
        totp: m.opt_text(k::TOTP)?,
        folder: m.opt_text(k::FOLDER)?,
        tags: m.texts(k::TAGS, MAX_TAGS)?,
        fields,
        travel_safe: m.flag(k::TRAVEL_SAFE)?,
    })
}

fn decode_item(v: &V<'_>) -> R<Item> {
    let m = Map::new(
        v,
        k::ITEM,
        &[
            k::ID,
            k::KIND,
            k::TITLE,
            k::CREATED_AT,
            k::MODIFIED_AT,
            k::HLC,
        ],
    )?;
    let history = m
        .opt_array(k::HISTORY, MAX_REVISIONS)?
        .iter()
        .map(|r| {
            let r = Map::new(r, k::REVISION, &[1, 2])?;
            let modified_at = r.uint(1)?;
            let d = Map::new(
                r.get(2).expect("required"),
                k::REV_DATA,
                &[k::KIND, k::TITLE],
            )?;
            Ok(Revision {
                modified_at,
                data: decode_data(&d)?,
            })
        })
        .collect::<R<Vec<_>>>()?;
    Ok(Item {
        id: m.id(k::ID)?,
        created_at: m.uint(k::CREATED_AT)?,
        modified_at: m.uint(k::MODIFIED_AT)?,
        hlc: m.uint(k::HLC)?,
        data: decode_data(&m)?,
        history,
        trashed_at: m.opt_uint(k::TRASHED_AT)?,
    })
}

/// Parses `plaintext` = deterministic CBOR item || zero padding.
pub(crate) fn decode_plaintext(plaintext: &[u8]) -> Result<Payload> {
    let (v, used) = cbor::decode(plaintext).map_err(Error::Rejected)?;
    let padding = &plaintext[used..];
    if padding.len() >= crate::container::CHUNK_PLAINTEXT || padding.iter().any(|&b| b != 0) {
        return Err(Check::Padding.into());
    }
    decode_payload(&v).map_err(Error::Rejected)
}

fn decode_payload(v: &V<'_>) -> R<Payload> {
    let m = Map::new(v, k::TOP, &[k::P_VERSION, k::P_EXPORTED_AT, k::P_ITEMS])?;
    // A different payload version may have a different schema: check first.
    if m.uint(k::P_VERSION)? != PAYLOAD_VERSION {
        return Err(Check::PayloadVersion);
    }
    let items = match m.get(k::P_ITEMS) {
        Some(V::A(a)) if a.len() > MAX_ITEMS => return Err(Check::CborLimit),
        Some(V::A(a)) => a.iter().map(decode_item).collect::<R<Vec<_>>>()?,
        _ => return Err(Check::CborType),
    };
    let tombstones = m
        .opt_array(k::P_TOMBSTONES, MAX_TOMBSTONES)?
        .iter()
        .map(|t| {
            let t = Map::new(t, k::TOMBSTONE, &[1, 2, 3])?;
            Ok(Tombstone {
                id: t.id(1)?,
                deleted_at: t.uint(2)?,
                hlc: t.uint(3)?,
            })
        })
        .collect::<R<Vec<_>>>()?;
    Ok(Payload {
        exported_at: m.uint(k::P_EXPORTED_AT)?,
        items,
        tombstones,
    })
}

// ------------------------------------------------------------------ encode

fn check_len(s: &str) -> Result<()> {
    if s.len() > cbor::MAX_TEXT {
        return Err(Error::InvalidInput("text field longer than 65536 bytes"));
    }
    Ok(())
}

fn data_entries(d: &ItemData) -> Result<Vec<u64>> {
    if d.urls.len() > MAX_URLS || d.tags.len() > MAX_TAGS || d.fields.len() > MAX_FIELDS {
        return Err(Error::InvalidInput("too many urls, tags or fields"));
    }
    let mut keys = vec![k::KIND, k::TITLE];
    let opt = [
        (k::USERNAME, d.username.is_some()),
        (k::PASSWORD, d.password.is_some()),
        (k::URLS, !d.urls.is_empty()),
        (k::NOTES, d.notes.is_some()),
        (k::TOTP, d.totp.is_some()),
        (k::FOLDER, d.folder.is_some()),
        (k::TAGS, !d.tags.is_empty()),
        (k::FIELDS, !d.fields.is_empty()),
        (k::TRAVEL_SAFE, d.travel_safe),
    ];
    keys.extend(
        opt.iter()
            .filter(|(_, present)| *present)
            .map(|(key, _)| *key),
    );
    Ok(keys)
}

fn encode_data_value(e: &mut Enc, d: &ItemData, key: u64) -> Result<()> {
    let text = |e: &mut Enc, s: &str| -> Result<()> {
        check_len(s)?;
        e.text(s);
        Ok(())
    };
    match key {
        k::KIND => e.uint(d.kind as u64),
        k::TITLE => text(e, &d.title)?,
        k::USERNAME => text(e, d.username.as_deref().unwrap_or_default())?,
        k::PASSWORD => text(e, d.password.as_deref().unwrap_or_default())?,
        k::NOTES => text(e, d.notes.as_deref().unwrap_or_default())?,
        k::TOTP => text(e, d.totp.as_deref().unwrap_or_default())?,
        k::FOLDER => text(e, d.folder.as_deref().unwrap_or_default())?,
        k::URLS | k::TAGS => {
            let list = if key == k::URLS { &d.urls } else { &d.tags };
            e.array(list.len());
            for s in list {
                text(e, s)?;
            }
        }
        k::FIELDS => {
            e.array(d.fields.len());
            for f in &d.fields {
                e.map(if f.concealed { 3 } else { 2 });
                e.key(1);
                text(e, &f.name)?;
                e.key(2);
                text(e, &f.value)?;
                if f.concealed {
                    e.key(3);
                    e.bool(true);
                }
            }
        }
        k::TRAVEL_SAFE => e.bool(true),
        _ => unreachable!("not an item-data key"),
    }
    Ok(())
}

fn encode_item(e: &mut Enc, item: &Item) -> Result<()> {
    if item.history.len() > MAX_REVISIONS {
        return Err(Error::InvalidInput("too many revisions"));
    }
    let mut keys = data_entries(&item.data)?;
    keys.extend([k::ID, k::CREATED_AT, k::MODIFIED_AT, k::HLC]);
    if !item.history.is_empty() {
        keys.push(k::HISTORY);
    }
    if item.trashed_at.is_some() {
        keys.push(k::TRASHED_AT);
    }
    keys.sort_unstable();
    e.map(keys.len());
    for key in keys {
        e.key(key);
        match key {
            k::ID => e.bytes(&item.id),
            k::CREATED_AT => e.uint(item.created_at),
            k::MODIFIED_AT => e.uint(item.modified_at),
            k::HLC => e.uint(item.hlc),
            k::TRASHED_AT => e.uint(item.trashed_at.unwrap_or_default()),
            k::HISTORY => {
                e.array(item.history.len());
                for r in &item.history {
                    e.map(2);
                    e.key(1);
                    e.uint(r.modified_at);
                    e.key(2);
                    let dk = data_entries(&r.data)?;
                    e.map(dk.len());
                    for d in dk {
                        e.key(d);
                        encode_data_value(e, &r.data, d)?;
                    }
                }
            }
            _ => encode_data_value(e, &item.data, key)?,
        }
    }
    Ok(())
}

/// Encodes the payload as deterministic CBOR (unpadded).
pub fn encode(p: &Payload) -> Result<Zeroizing<Vec<u8>>> {
    if p.items.len() > MAX_ITEMS || p.tombstones.len() > MAX_TOMBSTONES {
        return Err(Error::InvalidInput("too many items or tombstones"));
    }
    let mut e = Enc::new();
    e.map(if p.tombstones.is_empty() { 3 } else { 4 });
    e.key(k::P_VERSION);
    e.uint(PAYLOAD_VERSION);
    e.key(k::P_EXPORTED_AT);
    e.uint(p.exported_at);
    e.key(k::P_ITEMS);
    e.array(p.items.len());
    for item in &p.items {
        encode_item(&mut e, item)?;
    }
    if !p.tombstones.is_empty() {
        e.key(k::P_TOMBSTONES);
        e.array(p.tombstones.len());
        for t in &p.tombstones {
            e.map(3);
            e.key(1);
            e.bytes(&t.id);
            e.key(2);
            e.uint(t.deleted_at);
            e.key(3);
            e.uint(t.hlc);
        }
    }
    Ok(e.0)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub fn sample_data(title: &str) -> ItemData {
        ItemData {
            kind: ItemKind::Login,
            title: title.into(),
            username: Some("alice@example.com".into()),
            password: Some("correct horse battery staple".into()),
            urls: vec!["https://example.com/login".into()],
            notes: None,
            totp: Some("JBSWY3DPEHPK3PXP".into()),
            folder: Some("Personal".into()),
            tags: vec!["email".into(), "work".into()],
            fields: vec![Field {
                name: "PIN".into(),
                value: "1234".into(),
                concealed: true,
            }],
            travel_safe: true,
        }
    }

    pub fn sample() -> Payload {
        Payload {
            exported_at: 1_760_000_000,
            items: vec![Item {
                id: [1; 16],
                created_at: 1_700_000_000,
                modified_at: 1_750_000_000,
                hlc: 0x0001_9000_0000_0001,
                data: sample_data("Example"),
                history: vec![Revision {
                    modified_at: 1_700_000_000,
                    data: sample_data("Old"),
                }],
                trashed_at: None,
            }],
            tombstones: vec![Tombstone {
                id: [2; 16],
                deleted_at: 1_740_000_000,
                hlc: 7,
            }],
        }
    }

    #[test]
    fn round_trip_and_ciborium_agrees() {
        let p = sample();
        let bytes = encode(&p).unwrap();
        let back = decode_plaintext(&bytes).unwrap();
        assert!(back == p);
        // Independent decoder accepts it and re-encodes it identically
        // (ciborium preserves map order and uses shortest-form arguments).
        let v: ciborium::Value = ciborium::from_reader(&bytes[..]).unwrap();
        let mut again = Vec::new();
        ciborium::into_writer(&v, &mut again).unwrap();
        assert_eq!(again, *bytes);
    }

    #[test]
    fn schema_violations() {
        let check = |b: &[u8]| decode_plaintext(b).err().unwrap();
        // {1:1, 2:0} missing items
        assert_eq!(
            check(&[0xa2, 0x01, 0x01, 0x02, 0x00]),
            Error::Rejected(Check::CborMissingKey)
        );
        // {1:2, 2:0, 3:[]} wrong version
        assert_eq!(
            check(&[0xa3, 0x01, 0x02, 0x02, 0x00, 0x03, 0x80]),
            Error::Rejected(Check::PayloadVersion)
        );
        // {1:1, 2:0, 3:[], 9:0} unknown key
        assert_eq!(
            check(&[0xa4, 0x01, 0x01, 0x02, 0x00, 0x03, 0x80, 0x09, 0x00]),
            Error::Rejected(Check::CborUnknownKey)
        );
        // {1:1, 2:0, 3:[], 4:[]} empty optional
        assert_eq!(
            check(&[0xa4, 0x01, 0x01, 0x02, 0x00, 0x03, 0x80, 0x04, 0x80]),
            Error::Rejected(Check::CborEmptyOptional)
        );
        // {1:1, 2:0, 3:0} wrong type
        assert_eq!(
            check(&[0xa3, 0x01, 0x01, 0x02, 0x00, 0x03, 0x00]),
            Error::Rejected(Check::CborType)
        );
        // valid minimal payload, then non-zero padding
        assert!(decode_plaintext(&[0xa3, 0x01, 0x01, 0x02, 0x00, 0x03, 0x80, 0, 0]).is_ok());
        assert_eq!(
            check(&[0xa3, 0x01, 0x01, 0x02, 0x00, 0x03, 0x80, 0, 1]),
            Error::Rejected(Check::Padding)
        );
    }
}
