//! Compact binary encoding of [`ItemData`] for rows inside the SQLCipher
//! store. Not a wire format: it never leaves the encrypted database (VTF
//! export uses vtf-core's deterministic CBOR). Buffers are zeroizing.

use vtf_core::{Field, ItemData, ItemKind};
use zeroize::Zeroizing;

const VERSION: u8 = 1;

pub fn kind_to_u8(k: ItemKind) -> u8 {
    k as u8
}

pub fn kind_from_u8(v: u8) -> Option<ItemKind> {
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

fn str_len(s: &str) -> usize {
    4 + s.len()
}

fn opt_len(s: &Option<String>) -> usize {
    1 + s.as_deref().map_or(0, str_len)
}

fn encoded_len(d: &ItemData) -> usize {
    3 + str_len(&d.title)
        + opt_len(&d.username)
        + opt_len(&d.password)
        + 4
        + d.urls.iter().map(|u| str_len(u)).sum::<usize>()
        + opt_len(&d.notes)
        + opt_len(&d.totp)
        + opt_len(&d.folder)
        + 4
        + d.tags.iter().map(|t| str_len(t)).sum::<usize>()
        + 4
        + d.fields.iter().map(|f| str_len(&f.name) + str_len(&f.value) + 1).sum::<usize>()
}

struct W(Zeroizing<Vec<u8>>);

impl W {
    fn u8(&mut self, v: u8) {
        self.0.push(v);
    }
    fn u32(&mut self, v: usize) {
        self.0.extend_from_slice(&(v as u32).to_be_bytes());
    }
    fn str(&mut self, s: &str) {
        self.u32(s.len());
        self.0.extend_from_slice(s.as_bytes());
    }
    fn opt(&mut self, s: &Option<String>) {
        match s {
            None => self.u8(0),
            Some(s) => {
                self.u8(1);
                self.str(s);
            }
        }
    }
    fn strs(&mut self, v: &[String]) {
        self.u32(v.len());
        for s in v {
            self.str(s);
        }
    }
}

pub fn encode(d: &ItemData) -> Zeroizing<Vec<u8>> {
    // Exact capacity: the buffer is never reallocated, so no unzeroized
    // copy of the plaintext is left behind.
    let mut w = W(Zeroizing::new(Vec::with_capacity(encoded_len(d))));
    w.u8(VERSION);
    w.u8(kind_to_u8(d.kind));
    w.u8(u8::from(d.travel_safe));
    w.str(&d.title);
    w.opt(&d.username);
    w.opt(&d.password);
    w.strs(&d.urls);
    w.opt(&d.notes);
    w.opt(&d.totp);
    w.opt(&d.folder);
    w.strs(&d.tags);
    w.u32(d.fields.len());
    for f in &d.fields {
        w.str(&f.name);
        w.str(&f.value);
        w.u8(u8::from(f.concealed));
    }
    debug_assert_eq!(w.0.len(), w.0.capacity());
    w.0
}

struct R<'a>(&'a [u8]);

impl R<'_> {
    fn u8(&mut self) -> Option<u8> {
        let (&b, rest) = self.0.split_first()?;
        self.0 = rest;
        Some(b)
    }
    fn u32(&mut self) -> Option<usize> {
        if self.0.len() < 4 {
            return None;
        }
        let (h, rest) = self.0.split_at(4);
        self.0 = rest;
        Some(u32::from_be_bytes(h.try_into().ok()?) as usize)
    }
    fn str(&mut self) -> Option<String> {
        let n = self.u32()?;
        if self.0.len() < n {
            return None;
        }
        let (h, rest) = self.0.split_at(n);
        self.0 = rest;
        // Validate first so a failed conversion never leaves a copy behind.
        core::str::from_utf8(h).ok()?;
        String::from_utf8(h.to_vec()).ok()
    }
    fn opt(&mut self) -> Option<Option<String>> {
        match self.u8()? {
            0 => Some(None),
            1 => Some(Some(self.str()?)),
            _ => None,
        }
    }
    fn strs(&mut self) -> Option<Vec<String>> {
        let n = self.u32()?;
        if n > self.0.len() / 4 {
            return None;
        }
        let mut v = Vec::with_capacity(n);
        for _ in 0..n {
            v.push(self.str()?);
        }
        Some(v)
    }
}

pub fn decode(bytes: &[u8]) -> Option<ItemData> {
    let mut r = R(bytes);
    if r.u8()? != VERSION {
        return None;
    }
    let kind = kind_from_u8(r.u8()?)?;
    let travel_safe = match r.u8()? {
        0 => false,
        1 => true,
        _ => return None,
    };
    let mut d = ItemData {
        kind,
        title: r.str()?,
        username: None,
        password: None,
        urls: vec![],
        notes: None,
        totp: None,
        folder: None,
        tags: vec![],
        fields: vec![],
        travel_safe,
    };
    d.username = r.opt()?;
    d.password = r.opt()?;
    d.urls = r.strs()?;
    d.notes = r.opt()?;
    d.totp = r.opt()?;
    d.folder = r.opt()?;
    d.tags = r.strs()?;
    let n = r.u32()?;
    if n > r.0.len() / 9 {
        return None;
    }
    d.fields.reserve_exact(n);
    for _ in 0..n {
        let name = r.str()?;
        let value = r.str()?;
        let concealed = match r.u8()? {
            0 => false,
            1 => true,
            _ => return None,
        };
        d.fields.push(Field { name, value, concealed });
    }
    if !r.0.is_empty() {
        return None;
    }
    Some(d)
}

#[cfg(test)]
mod tests {
    use super::*;

    pub fn sample() -> ItemData {
        ItemData {
            kind: ItemKind::Card,
            title: "Visa \u{1F4B3}".into(),
            username: Some("alice".into()),
            password: None,
            urls: vec!["https://a.example".into(), "b.example".into()],
            notes: Some(String::new()),
            totp: None,
            folder: Some("Finance".into()),
            tags: vec!["x".into()],
            fields: vec![Field { name: "PIN".into(), value: "1234".into(), concealed: true }],
            travel_safe: true,
        }
    }

    #[test]
    fn round_trip_and_rejects_garbage() {
        let d = sample();
        let e = encode(&d);
        assert!(decode(&e).unwrap() == d);
        for cut in 0..e.len() {
            assert!(decode(&e[..cut]).is_none(), "truncated at {cut}");
        }
        let mut extra = e.to_vec();
        extra.push(0);
        assert!(decode(&extra).is_none());
        let mut bad_kind = e.to_vec();
        bad_kind[1] = 9;
        assert!(decode(&bad_kind).is_none());
    }
}
