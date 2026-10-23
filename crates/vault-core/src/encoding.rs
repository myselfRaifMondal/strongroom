//! Hex and RFC 4648 base32 helpers (non-cryptographic).

use zeroize::Zeroizing;

const HEX: &[u8; 16] = b"0123456789abcdef";
const B32: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

pub fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(HEX[usize::from(b >> 4)] as char);
        s.push(HEX[usize::from(b & 15)] as char);
    }
    s
}

/// Hex into a zeroizing string (for key material handed to SQLCipher).
pub fn hex_secret(bytes: &[u8]) -> Zeroizing<String> {
    let mut s = Zeroizing::new(String::with_capacity(bytes.len() * 2));
    for b in bytes {
        s.push(HEX[usize::from(b >> 4)] as char);
        s.push(HEX[usize::from(b & 15)] as char);
    }
    s
}

pub fn unhex<const N: usize>(s: &str) -> Option<[u8; N]> {
    let b = s.as_bytes();
    if b.len() != 2 * N {
        return None;
    }
    let nib = |c: u8| match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    };
    let mut out = [0u8; N];
    for (i, o) in out.iter_mut().enumerate() {
        *o = (nib(b[2 * i])? << 4) | nib(b[2 * i + 1])?;
    }
    Some(out)
}

/// Base32 without padding.
pub fn base32(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(5) * 8);
    let mut acc: u32 = 0;
    let mut bits = 0u32;
    for &b in bytes {
        acc = (acc << 8) | u32::from(b);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            out.push(B32[((acc >> bits) & 31) as usize] as char);
        }
        acc &= (1 << bits) - 1;
    }
    if bits > 0 {
        out.push(B32[((acc << (5 - bits)) & 31) as usize] as char);
    }
    out
}

/// Lenient base32 decode for TOTP secrets and pairing payloads: ignores
/// case, spaces, hyphens and trailing `=`. Returns `None` on any other
/// character. Trailing bits that do not fill a byte are discarded.
pub fn base32_decode(s: &str) -> Option<Zeroizing<Vec<u8>>> {
    let mut out = Zeroizing::new(Vec::with_capacity(s.len() * 5 / 8 + 1));
    let mut acc: u32 = 0;
    let mut bits = 0u32;
    let trimmed = s.trim_end_matches('=');
    for c in trimmed.bytes() {
        if c == b' ' || c == b'-' {
            continue;
        }
        let up = c.to_ascii_uppercase();
        let v = B32.iter().position(|&x| x == up)? as u32;
        acc = (acc << 5) | v;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base32_rfc4648_vectors() {
        for (pt, enc) in [
            ("", ""),
            ("f", "MY"),
            ("fo", "MZXQ"),
            ("foo", "MZXW6"),
            ("foob", "MZXW6YQ"),
            ("fooba", "MZXW6YTB"),
            ("foobar", "MZXW6YTBOI"),
        ] {
            assert_eq!(base32(pt.as_bytes()), enc);
            assert_eq!(base32_decode(enc).unwrap().as_slice(), pt.as_bytes());
        }
        assert_eq!(
            base32_decode("mzxw6ytboi======").unwrap().as_slice(),
            b"foobar"
        );
        assert!(base32_decode("MZ1").is_none());
    }

    #[test]
    fn hex_round_trip() {
        let h = hex(&[0, 0xab, 0xff]);
        assert_eq!(h, "00abff");
        assert_eq!(unhex::<3>(&h).unwrap(), [0, 0xab, 0xff]);
        assert!(unhex::<3>("00abf").is_none());
        assert!(unhex::<2>("zz00").is_none());
    }
}
