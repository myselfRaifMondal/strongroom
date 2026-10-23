//! Key material, key derivation (SPEC-VTF section 4) and the AEAD wrapper.

use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::aead::{Aead, Generate, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use hkdf::Hkdf;
use sha2::Sha256;
use unicode_normalization::UnicodeNormalization;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use crate::error::{Error, Result};

pub const ARGON2_M_KIB: u32 = 262_144;
pub const ARGON2_T: u32 = 3;
pub const ARGON2_P: u32 = 4;

pub const KEY_LEN: usize = 32;
pub const NONCE_LEN: usize = 24;
pub const TAG_LEN: usize = 16;
pub const SECRET_KEY_LEN: usize = 16;

pub type Key = Zeroizing<[u8; KEY_LEN]>;

/// A master password, normalized to NFKC and encoded as UTF-8.
#[derive(Zeroize, ZeroizeOnDrop)]
pub struct Password(Vec<u8>);

impl Password {
    /// Normalizes `password` to NFKC. Empty passwords are refused.
    pub fn new(password: &str) -> Result<Self> {
        // Reserve generously up front so the normalized string is not
        // reallocated (each reallocation would leave an unzeroized copy).
        let mut s = Zeroizing::new(String::with_capacity(password.len().saturating_mul(4)));
        s.extend(password.nfkc());
        if s.is_empty() {
            return Err(Error::InvalidInput("empty password"));
        }
        let mut bytes = Vec::with_capacity(s.len());
        bytes.extend_from_slice(s.as_bytes());
        Ok(Password(bytes))
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

/// The 128-bit Secret Key. Never written to a VTF file.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct SecretKey([u8; SECRET_KEY_LEN]);

const B32: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

impl SecretKey {
    pub fn from_bytes(bytes: [u8; SECRET_KEY_LEN]) -> Self {
        SecretKey(bytes)
    }

    pub fn generate() -> Result<Self> {
        let mut b = [0u8; SECRET_KEY_LEN];
        fill_random(&mut b)?;
        let k = SecretKey(b);
        b.zeroize();
        Ok(k)
    }

    pub fn as_bytes(&self) -> &[u8; SECRET_KEY_LEN] {
        &self.0
    }

    /// Display encoding of SPEC-VTF Appendix A: `SR1-AAAAA-BBBBB-CCCCC-DDDDD-EEEEEE`.
    pub fn to_display(&self) -> Zeroizing<String> {
        let mut chars = Zeroizing::new([0u8; 26]);
        let mut acc: u32 = 0;
        let mut bits = 0u32;
        let mut n = 0;
        for &byte in self.0.iter() {
            acc = (acc << 8) | u32::from(byte);
            bits += 8;
            while bits >= 5 {
                bits -= 5;
                chars[n] = B32[((acc >> bits) & 31) as usize];
                n += 1;
            }
            acc &= (1 << bits) - 1;
        }
        // 128 = 25*5 + 3: final char carries 3 data bits and 2 zero bits.
        chars[n] = B32[((acc << (5 - bits)) & 31) as usize];
        let mut out = Zeroizing::new(String::with_capacity(34));
        out.push_str("SR1-");
        for (i, &c) in chars.iter().enumerate() {
            if matches!(i, 5 | 10 | 15 | 20) {
                out.push('-');
            }
            out.push(c as char);
        }
        out
    }

    /// Parses the display encoding. Accepts lowercase, ignores whitespace.
    pub fn parse(display: &str) -> Result<Self> {
        let invalid = Error::InvalidInput("malformed secret key");
        let mut compact = Zeroizing::new(String::with_capacity(display.len()));
        compact.extend(display.chars().filter(|c| !c.is_whitespace()).map(|c| c.to_ascii_uppercase()));
        let body = compact.strip_prefix("SR1-").ok_or(invalid)?;
        let mut acc: u32 = 0;
        let mut bits = 0u32;
        let mut out = Zeroizing::new([0u8; SECRET_KEY_LEN]);
        let mut n = 0usize;
        let mut count = 0usize;
        for (i, c) in body.bytes().enumerate() {
            if c == b'-' {
                if !matches!(i, 5 | 11 | 17 | 23) {
                    return Err(invalid);
                }
                continue;
            }
            let v = B32.iter().position(|&b| b == c).ok_or(invalid)? as u32;
            count += 1;
            if count > 26 {
                return Err(invalid);
            }
            acc = (acc << 5) | v;
            bits += 5;
            if bits >= 8 {
                bits -= 8;
                if n < SECRET_KEY_LEN {
                    out[n] = (acc >> bits) as u8;
                    n += 1;
                }
                acc &= (1 << bits) - 1;
            }
        }
        // 26 chars = 130 bits: 16 bytes plus 2 trailing bits that must be zero.
        if count != 26 || n != SECRET_KEY_LEN || bits != 2 || acc != 0 {
            return Err(invalid);
        }
        Ok(SecretKey(*out))
    }
}

/// Fills `buf` from the OS CSPRNG.
pub fn fill_random(buf: &mut [u8]) -> Result<()> {
    for chunk in buf.chunks_mut(32) {
        let mut block = <[u8; 32]>::try_generate().map_err(|_| Error::Entropy)?;
        chunk.copy_from_slice(&block[..chunk.len()]);
        block.zeroize();
    }
    Ok(())
}

/// HKDF-SHA-256, extract then expand, 32-byte output.
pub fn hkdf32(ikm: &[u8], salt: &[u8], info: &[u8]) -> Key {
    let hk = Hkdf::<Sha256>::new(Some(salt), ikm);
    let mut okm = Zeroizing::new([0u8; KEY_LEN]);
    hk.expand(info, okm.as_mut()).expect("32 bytes is a valid HKDF-SHA-256 length");
    okm
}

/// `KEK = HKDF(Argon2id(pw) || HKDF(sk, "VTF1/secret-key"), "VTF1/kek")`.
pub fn derive_kek(password: &Password, secret_key: &SecretKey, salt: &[u8; 32]) -> Result<Key> {
    let params = Params::new(ARGON2_M_KIB, ARGON2_T, ARGON2_P, Some(KEY_LEN))
        .map_err(|_| Error::InvalidInput("argon2 parameters"))?;
    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut ikm = Zeroizing::new([0u8; 2 * KEY_LEN]);
    argon
        .hash_password_into(password.as_bytes(), salt, &mut ikm[..KEY_LEN])
        .map_err(|_| Error::InvalidInput("argon2 input"))?;
    let sk_key = hkdf32(secret_key.as_bytes(), salt, b"VTF1/secret-key");
    ikm[KEY_LEN..].copy_from_slice(sk_key.as_ref());
    Ok(hkdf32(ikm.as_ref(), salt, b"VTF1/kek"))
}

/// XChaCha20-Poly1305 seal. Output is ciphertext || 16-byte tag.
pub fn seal(key: &[u8; KEY_LEN], nonce: &[u8; NONCE_LEN], aad: &[u8], pt: &[u8]) -> Vec<u8> {
    let cipher = XChaCha20Poly1305::new(key.into());
    cipher
        .encrypt(&XNonce::from(*nonce), Payload { msg: pt, aad })
        .expect("XChaCha20-Poly1305 encryption of in-range lengths cannot fail")
}

/// XChaCha20-Poly1305 open. Tag verification is constant-time (RustCrypto).
pub fn open(key: &[u8; KEY_LEN], nonce: &[u8; NONCE_LEN], aad: &[u8], ct: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    let cipher = XChaCha20Poly1305::new(key.into());
    cipher
        .decrypt(&XNonce::from(*nonce), Payload { msg: ct, aad })
        .ok()
        .map(Zeroizing::new)
}

/// In-place variant used for 64 KiB chunks to avoid extra plaintext copies.
pub fn open_in_place(key: &[u8; KEY_LEN], nonce: &[u8; NONCE_LEN], aad: &[u8], buf: &mut [u8]) -> bool {
    use chacha20poly1305::aead::AeadInOut;
    if buf.len() < TAG_LEN {
        return false;
    }
    let (ct, tag) = buf.split_at_mut(buf.len() - TAG_LEN);
    let cipher = XChaCha20Poly1305::new(key.into());
    let tag = chacha20poly1305::Tag::try_from(&*tag).expect("16-byte tag");
    let ok = cipher
        .decrypt_inout_detached(&XNonce::from(*nonce), aad, ct.into(), &tag)
        .is_ok();
    if !ok {
        ct.zeroize();
    }
    ok
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secret_key_round_trip() {
        let sk = SecretKey::from_bytes([0xA5; 16]);
        let d = sk.to_display();
        assert_eq!(d.len(), 34);
        let back = SecretKey::parse(&d.to_lowercase()).unwrap();
        assert_eq!(back.as_bytes(), sk.as_bytes());
        let spaced: String = d.chars().flat_map(|c| [c, ' ']).collect();
        assert!(SecretKey::parse(&spaced).is_ok());
    }

    #[test]
    fn secret_key_rejects_bad_tail_bits_and_lengths() {
        let d = SecretKey::from_bytes([0; 16]).to_display().to_string();
        assert!(d.ends_with('A'));
        let mut bad = d.clone();
        bad.pop();
        bad.push('B'); // low bits non-zero
        assert!(SecretKey::parse(&bad).is_err());
        assert!(SecretKey::parse(&d[..d.len() - 1]).is_err());
        assert!(SecretKey::parse(&format!("{d}A")).is_err());
        assert!(SecretKey::parse(&d.replace("SR1-", "SR2-")).is_err());
    }

    #[test]
    fn nfkc_normalization() {
        // U+FB01 LATIN SMALL LIGATURE FI -> "fi"; Angstrom sign -> A-ring.
        assert_eq!(Password::new("\u{FB01}").unwrap().as_bytes(), b"fi");
        assert_eq!(
            Password::new("\u{212B}").unwrap().as_bytes(),
            Password::new("A\u{030A}").unwrap().as_bytes()
        );
        assert!(Password::new("").is_err());
    }
}
