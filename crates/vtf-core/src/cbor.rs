//! Strict deterministic CBOR (RFC 8949 section 4.2.1) restricted to the
//! subset VTF1 uses: unsigned integers, byte strings, text strings, arrays,
//! maps with unsigned-integer keys, `false` and `true`.
//!
//! The decoder borrows from the (zeroizing) plaintext buffer and never
//! copies string data, so no unzeroized plaintext copies are created. It
//! rejects, rather than normalizes, every non-canonical encoding.

use zeroize::Zeroizing;

use crate::error::Check;

pub const MAX_DEPTH: usize = 16;
pub const MAX_TEXT: usize = 65_536;
pub const MAX_BYTES: usize = 16;
pub const MAX_ARRAY: u64 = 100_000;

#[derive(Debug)]
pub enum V<'a> {
    U(u64),
    B(&'a [u8]),
    T(&'a str),
    A(Vec<V<'a>>),
    M(Vec<(u64, V<'a>)>),
    Bool(bool),
}

struct Decoder<'a> {
    buf: &'a [u8],
    pos: usize,
}

type R<T> = Result<T, Check>;

impl<'a> Decoder<'a> {
    fn remaining(&self) -> usize {
        self.buf.len() - self.pos
    }

    fn take(&mut self, n: usize) -> R<&'a [u8]> {
        if n > self.remaining() {
            return Err(Check::CborWellformed);
        }
        let s = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }

    fn be(&mut self, n: usize) -> R<u64> {
        Ok(self
            .take(n)?
            .iter()
            .fold(0u64, |acc, &b| (acc << 8) | u64::from(b)))
    }

    /// Reads an initial byte and argument for majors 0-6, enforcing the
    /// shortest-form rule. Major 7 is handled by the caller.
    fn argument(&mut self, ai: u8) -> R<u64> {
        let (v, min) = match ai {
            0..=23 => return Ok(u64::from(ai)),
            24 => (self.be(1)?, 24),
            25 => (self.be(2)?, 0x100),
            26 => (self.be(4)?, 0x1_0000),
            27 => (self.be(8)?, 0x1_0000_0000),
            31 => return Err(Check::CborDeterministic), // indefinite length
            _ => return Err(Check::CborWellformed),     // 28..=30 reserved
        };
        if v < min {
            return Err(Check::CborDeterministic);
        }
        Ok(v)
    }

    fn item(&mut self, depth: usize) -> R<V<'a>> {
        let ib = self.take(1)?[0];
        let (major, ai) = (ib >> 5, ib & 0x1f);
        if major == 7 {
            return match ai {
                20 => Ok(V::Bool(false)),
                21 => Ok(V::Bool(true)),
                31 => Err(Check::CborDeterministic), // stray "break"
                28..=30 => Err(Check::CborWellformed),
                // null, undefined, other simple values, floats.
                _ => Err(Check::CborType),
            };
        }
        if major == 6 {
            return Err(Check::CborType); // tags
        }
        if major == 1 && ai == 31 {
            return Err(Check::CborWellformed);
        }
        let arg = self.argument(ai)?;
        match major {
            0 => Ok(V::U(arg)),
            1 => Err(Check::CborType), // negative integers are never used
            2 => {
                let len = usize::try_from(arg).map_err(|_| Check::CborWellformed)?;
                if len > self.remaining() {
                    return Err(Check::CborWellformed);
                }
                if len > MAX_BYTES {
                    return Err(Check::CborLimit);
                }
                Ok(V::B(self.take(len)?))
            }
            3 => {
                let len = usize::try_from(arg).map_err(|_| Check::CborWellformed)?;
                if len > self.remaining() {
                    return Err(Check::CborWellformed);
                }
                if len > MAX_TEXT {
                    return Err(Check::CborLimit);
                }
                let s = core::str::from_utf8(self.take(len)?).map_err(|_| Check::CborWellformed)?;
                Ok(V::T(s))
            }
            4 => {
                if depth > MAX_DEPTH {
                    return Err(Check::CborDepth);
                }
                if arg > self.remaining() as u64 {
                    return Err(Check::CborWellformed);
                }
                if arg > MAX_ARRAY {
                    return Err(Check::CborLimit);
                }
                let mut out = Vec::with_capacity(arg as usize);
                for _ in 0..arg {
                    out.push(self.item(depth + 1)?);
                }
                Ok(V::A(out))
            }
            5 => {
                if depth > MAX_DEPTH {
                    return Err(Check::CborDepth);
                }
                if arg.saturating_mul(2) > self.remaining() as u64 {
                    return Err(Check::CborWellformed);
                }
                if arg > MAX_ARRAY {
                    return Err(Check::CborLimit);
                }
                let mut out: Vec<(u64, V<'a>)> = Vec::with_capacity(arg as usize);
                for _ in 0..arg {
                    let kb = self.take(1)?[0];
                    if kb >> 5 != 0 {
                        return Err(Check::CborUnknownKey); // non-uint key
                    }
                    let key = self.argument(kb & 0x1f)?;
                    if let Some(&(prev, _)) = out.last() {
                        if key == prev {
                            return Err(Check::CborDuplicateKey);
                        }
                        if key < prev {
                            return Err(Check::CborDeterministic);
                        }
                    }
                    let value = self.item(depth + 1)?;
                    out.push((key, value));
                }
                Ok(V::M(out))
            }
            _ => unreachable!("major is 3 bits"),
        }
    }
}

/// Decodes exactly one item from the start of `buf`. Returns the item and
/// the number of bytes it occupied. The top-level item is at depth 1.
pub fn decode(buf: &[u8]) -> R<(V<'_>, usize)> {
    let mut d = Decoder { buf, pos: 0 };
    let v = d.item(1)?;
    Ok((v, d.pos))
}

/// Deterministic encoder writing into a zeroizing buffer.
pub struct Enc(pub Zeroizing<Vec<u8>>);

impl Enc {
    pub fn new() -> Self {
        Enc(Zeroizing::new(Vec::new()))
    }

    fn head(&mut self, major: u8, v: u64) {
        let m = major << 5;
        let out = &mut self.0;
        if v < 24 {
            out.push(m | v as u8);
        } else if v <= 0xff {
            out.extend_from_slice(&[m | 24, v as u8]);
        } else if v <= 0xffff {
            out.push(m | 25);
            out.extend_from_slice(&(v as u16).to_be_bytes());
        } else if v <= 0xffff_ffff {
            out.push(m | 26);
            out.extend_from_slice(&(v as u32).to_be_bytes());
        } else {
            out.push(m | 27);
            out.extend_from_slice(&v.to_be_bytes());
        }
    }

    pub fn uint(&mut self, v: u64) {
        self.head(0, v)
    }
    pub fn bytes(&mut self, b: &[u8]) {
        self.head(2, b.len() as u64);
        self.0.extend_from_slice(b);
    }
    pub fn text(&mut self, s: &str) {
        self.head(3, s.len() as u64);
        self.0.extend_from_slice(s.as_bytes());
    }
    pub fn array(&mut self, n: usize) {
        self.head(4, n as u64)
    }
    pub fn map(&mut self, n: usize) {
        self.head(5, n as u64)
    }
    pub fn key(&mut self, k: u64) {
        self.uint(k)
    }
    pub fn bool(&mut self, b: bool) {
        self.0.push(if b { 0xf5 } else { 0xf4 })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn err(b: &[u8]) -> Check {
        decode(b).unwrap_err()
    }

    #[test]
    fn rejects_non_canonical() {
        assert_eq!(err(&[0x18, 0x05]), Check::CborDeterministic); // 5 in 1-byte form
        assert_eq!(err(&[0x19, 0x00, 0xff]), Check::CborDeterministic);
        assert_eq!(err(&[0x9f, 0x01, 0xff]), Check::CborDeterministic); // indefinite array
        assert_eq!(err(&[0x5f, 0x41, 0x00, 0xff]), Check::CborDeterministic);
        assert_eq!(
            err(&[0xa2, 0x02, 0x00, 0x01, 0x00]),
            Check::CborDeterministic
        ); // unsorted
        assert_eq!(
            err(&[0xa2, 0x01, 0x00, 0x01, 0x00]),
            Check::CborDuplicateKey
        );
    }

    #[test]
    fn rejects_types() {
        assert_eq!(err(&[0xf6]), Check::CborType); // null
        assert_eq!(err(&[0xf7]), Check::CborType); // undefined
        assert_eq!(err(&[0xf9, 0x3c, 0x00]), Check::CborType); // half float
        assert_eq!(err(&[0xc0, 0x00]), Check::CborType); // tag
        assert_eq!(err(&[0x20]), Check::CborType); // -1
        assert_eq!(err(&[0xa1, 0x61, 0x61, 0x00]), Check::CborUnknownKey); // text key
    }

    #[test]
    fn rejects_malformed() {
        assert_eq!(err(&[]), Check::CborWellformed);
        assert_eq!(err(&[0x62, 0x61]), Check::CborWellformed); // truncated text
        assert_eq!(err(&[0x62, 0xff, 0xfe]), Check::CborWellformed); // bad UTF-8
        assert_eq!(err(&[0x1c]), Check::CborWellformed); // reserved ai
        assert_eq!(err(&[0x9a, 0xff, 0xff, 0xff, 0xff]), Check::CborWellformed);
        // huge count
    }

    #[test]
    fn depth_limit() {
        let nest = |n: usize| {
            let mut v = vec![0x81u8; n - 1];
            v.push(0x80);
            v
        };
        assert!(decode(&nest(16)).is_ok());
        assert_eq!(err(&nest(17)), Check::CborDepth);
        assert_eq!(err(&nest(10_000)), Check::CborDepth);
    }

    #[test]
    fn encoder_is_shortest_and_matches_ciborium() {
        for v in [
            0u64,
            23,
            24,
            255,
            256,
            65535,
            65536,
            u32::MAX as u64,
            u32::MAX as u64 + 1,
            u64::MAX,
        ] {
            let mut e = Enc::new();
            e.uint(v);
            let (d, n) = decode(&e.0).unwrap();
            assert_eq!(n, e.0.len());
            assert!(matches!(d, V::U(x) if x == v));
            let mut c = Vec::new();
            ciborium::into_writer(&v, &mut c).unwrap();
            assert_eq!(c, *e.0);
        }
    }
}
