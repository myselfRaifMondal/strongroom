//! QR pairing payload: `"SR1PAIR:" || base32(pk)` where `pk` is the 65-byte
//! uncompressed SEC1 P-256 public key. The fingerprint shown on both devices
//! is the first 10 bytes of `SHA-256(pk)` in base32, grouped `XXXX-XXXX-XXXX-XXXX`
//! (80 bits).

use sha2::{Digest, Sha256};
use vtf_core::device::{validate_public_key, PUBLIC_KEY_LEN};

use crate::encoding::{base32, base32_decode};
use crate::error::{Error, Result};

pub const PREFIX: &str = "SR1PAIR:";

pub fn payload(device_public_key: &[u8]) -> String {
    format!("{PREFIX}{}", base32(device_public_key))
}

pub fn fingerprint(pk: &[u8]) -> String {
    let d = Sha256::digest(pk);
    let b = base32(&d[..10]);
    format!("{}-{}-{}-{}", &b[0..4], &b[4..8], &b[8..12], &b[12..16])
}

pub fn parse(payload: &str) -> Result<([u8; PUBLIC_KEY_LEN], String)> {
    let bad = Error::InvalidInput("not a Strongroom pairing code");
    let t = payload.trim();
    let body = t
        .get(..PREFIX.len())
        .filter(|p| p.eq_ignore_ascii_case(PREFIX))
        .map(|_| &t[PREFIX.len()..])
        .ok_or(bad.clone())?;
    let bytes = base32_decode(body).ok_or(bad.clone())?;
    let pk: [u8; PUBLIC_KEY_LEN] = bytes.as_slice().try_into().map_err(|_| bad.clone())?;
    // Canonical encoding only: re-encoding must give the same text.
    if !base32(&pk).eq_ignore_ascii_case(body) {
        return Err(bad);
    }
    validate_public_key(&pk)
        .map_err(|_| Error::InvalidInput("pairing code does not hold a valid P-256 key"))?;
    let fp = fingerprint(&pk);
    Ok((pk, fp))
}
