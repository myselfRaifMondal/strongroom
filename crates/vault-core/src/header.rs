//! The plaintext vault header (sidecar file `<vault>.hdr`) and the device
//! key wrap.
//!
//! The vault key is 32 random bytes used as the SQLCipher raw key. It is
//! stored only wrapped:
//!
//! ```text
//! header  = "SRV1" || BE16(1) || BE32(262144) || BE32(3) || BE32(4)
//!           || vault_id(16) || salt(32) || nonce(24) || wrapped(48)
//! KEK     = vtf_core::keys::derive_kek(password, secret_key, salt)
//!           (Argon2id m=262144 KiB, t=3, p=4, then HKDF; same as VTF1)
//! wrapped = XChaCha20-Poly1305(KEK, nonce, aad = header[0..90], vault_key)
//! ```
//!
//! The Argon2 parameters are stored for self-description only; a header with
//! any other value is rejected (never lower, never higher).
//!
//! Device wrap (biometric unlock), 146 bytes:
//!
//! ```text
//! blob     = 0x01 || key_id(8) || enc(65) || nonce(24) || wrapped(48)
//! info     = "SR1/hpke-info" || vault_id
//! wrap_key = HPKE(P-256, base mode) Export("SR1/device-wrap", 32)
//! wrapped  = XChaCha20-Poly1305(wrap_key, nonce,
//!              aad = "SR1/device-wrap" || vault_id || blob[0..98], vault_key)
//! ```
//!
//! `vault_id` binds a wrapped key to one vault, so a blob made for one vault
//! cannot unlock another.

use subtle::ConstantTimeEq;
use vtf_core::device::{self, DeviceKey, ENC_LEN, KEY_ID_LEN, PUBLIC_KEY_LEN};
use vtf_core::keys::{self, Key, Password, SecretKey, ARGON2_M_KIB, ARGON2_P, ARGON2_T, KEY_LEN, NONCE_LEN, TAG_LEN};
use zeroize::Zeroizing;

use crate::error::{Error, Result};

pub const MAGIC: [u8; 4] = *b"SRV1";
pub const VERSION: u16 = 1;
const AAD_LEN: usize = 4 + 2 + 12 + 16 + 32 + 24;
pub const HEADER_LEN: usize = AAD_LEN + KEY_LEN + TAG_LEN;

const DEVICE_BLOB_VERSION: u8 = 0x01;
pub const DEVICE_BLOB_LEN: usize = 1 + KEY_ID_LEN + ENC_LEN + NONCE_LEN + KEY_LEN + TAG_LEN;
const LABEL_HPKE_INFO: &[u8] = b"SR1/hpke-info";
const LABEL_DEVICE_WRAP: &[u8] = b"SR1/device-wrap";

pub struct Header {
    pub vault_id: [u8; 16],
    salt: [u8; 32],
    nonce: [u8; NONCE_LEN],
    wrapped: [u8; KEY_LEN + TAG_LEN],
}

fn rand<const N: usize>() -> Result<[u8; N]> {
    let mut b = [0u8; N];
    keys::fill_random(&mut b).map_err(|_| Error::Internal)?;
    Ok(b)
}

/// A fresh random 32-byte key.
pub fn random_key() -> Result<Key> {
    let mut k = Zeroizing::new([0u8; KEY_LEN]);
    keys::fill_random(k.as_mut()).map_err(|_| Error::Internal)?;
    Ok(k)
}

impl Header {
    fn aad(vault_id: &[u8; 16], salt: &[u8; 32], nonce: &[u8; NONCE_LEN]) -> [u8; AAD_LEN] {
        let mut a = [0u8; AAD_LEN];
        a[0..4].copy_from_slice(&MAGIC);
        a[4..6].copy_from_slice(&VERSION.to_be_bytes());
        a[6..10].copy_from_slice(&ARGON2_M_KIB.to_be_bytes());
        a[10..14].copy_from_slice(&ARGON2_T.to_be_bytes());
        a[14..18].copy_from_slice(&ARGON2_P.to_be_bytes());
        a[18..34].copy_from_slice(vault_id);
        a[34..66].copy_from_slice(salt);
        a[66..90].copy_from_slice(nonce);
        a
    }

    /// Wraps `vault_key` under a KEK derived from fresh salt.
    pub fn seal(vault_key: &Key, password: &Password, secret_key: &SecretKey) -> Result<Header> {
        let vault_id = rand::<16>()?;
        let salt = rand::<32>()?;
        let nonce = rand::<NONCE_LEN>()?;
        let kek = keys::derive_kek(password, secret_key, &salt)?;
        let ct = keys::seal(&kek, &nonce, &Self::aad(&vault_id, &salt, &nonce), vault_key.as_ref());
        let mut wrapped = [0u8; KEY_LEN + TAG_LEN];
        wrapped.copy_from_slice(&ct);
        Ok(Header { vault_id, salt, nonce, wrapped })
    }

    pub fn to_bytes(&self) -> [u8; HEADER_LEN] {
        let mut out = [0u8; HEADER_LEN];
        out[..AAD_LEN].copy_from_slice(&Self::aad(&self.vault_id, &self.salt, &self.nonce));
        out[AAD_LEN..].copy_from_slice(&self.wrapped);
        out
    }

    pub fn parse(b: &[u8]) -> Option<Header> {
        if b.len() != HEADER_LEN {
            return None;
        }
        let vault_id: [u8; 16] = b[18..34].try_into().ok()?;
        let salt: [u8; 32] = b[34..66].try_into().ok()?;
        let nonce: [u8; NONCE_LEN] = b[66..90].try_into().ok()?;
        // Exact match of magic, version and the frozen Argon2id cost.
        if b[..AAD_LEN] != Self::aad(&vault_id, &salt, &nonce) {
            return None;
        }
        let wrapped = b[AAD_LEN..].try_into().ok()?;
        Some(Header { vault_id, salt, nonce, wrapped })
    }

    pub fn salt(&self) -> &[u8; 32] {
        &self.salt
    }

    /// Unwraps the vault key with an already derived KEK.
    pub fn open_with_kek(&self, kek: &Key) -> Option<Key> {
        let pt = keys::open(kek, &self.nonce, &Self::aad(&self.vault_id, &self.salt, &self.nonce), &self.wrapped)?;
        let mut k = Zeroizing::new([0u8; KEY_LEN]);
        if pt.len() != KEY_LEN {
            return None;
        }
        k.copy_from_slice(&pt);
        Some(k)
    }

    pub fn open(&self, password: &Password, secret_key: &SecretKey) -> Option<Key> {
        let kek = keys::derive_kek(password, secret_key, &self.salt).ok()?;
        self.open_with_kek(&kek)
    }
}

fn device_aad(vault_id: &[u8; 16], head: &[u8]) -> Vec<u8> {
    let mut aad = Vec::with_capacity(LABEL_DEVICE_WRAP.len() + 16 + head.len());
    aad.extend_from_slice(LABEL_DEVICE_WRAP);
    aad.extend_from_slice(vault_id);
    aad.extend_from_slice(head);
    aad
}

fn hpke_info(vault_id: &[u8; 16]) -> Vec<u8> {
    let mut info = Vec::with_capacity(LABEL_HPKE_INFO.len() + 16);
    info.extend_from_slice(LABEL_HPKE_INFO);
    info.extend_from_slice(vault_id);
    info
}

/// HPKE-seals `vault_key` to a device public key (65-byte SEC1).
pub fn wrap_for_device(vault_key: &Key, vault_id: &[u8; 16], device_pk: &[u8]) -> Result<Vec<u8>> {
    let pk: &[u8; PUBLIC_KEY_LEN] = device_pk
        .try_into()
        .map_err(|_| Error::InvalidInput("device public key must be 65 bytes"))?;
    device::validate_public_key(pk).map_err(|_| Error::InvalidInput("device public key is not a valid P-256 point"))?;
    let ikm_e = Zeroizing::new(rand::<32>()?);
    let (enc, wrap_key) = device::seal_export(pk, &hpke_info(vault_id), LABEL_DEVICE_WRAP, &ikm_e)?;
    let nonce = rand::<NONCE_LEN>()?;
    let mut blob = Vec::with_capacity(DEVICE_BLOB_LEN);
    blob.push(DEVICE_BLOB_VERSION);
    blob.extend_from_slice(&device::key_id(pk));
    blob.extend_from_slice(&enc);
    blob.extend_from_slice(&nonce);
    let ct = keys::seal(&wrap_key, &nonce, &device_aad(vault_id, &blob), vault_key.as_ref());
    blob.extend_from_slice(&ct);
    debug_assert_eq!(blob.len(), DEVICE_BLOB_LEN);
    Ok(blob)
}

/// Opens a device wrap through one hardware ECDH. `None` on any failure.
pub fn unwrap_with_device(blob: &[u8], vault_id: &[u8; 16], device: &dyn DeviceKey) -> Option<Key> {
    if blob.len() != DEVICE_BLOB_LEN || blob[0] != DEVICE_BLOB_VERSION {
        return None;
    }
    let key_id: &[u8; KEY_ID_LEN] = blob[1..9].try_into().ok()?;
    let enc: &[u8; ENC_LEN] = blob[9..74].try_into().ok()?;
    let nonce: &[u8; NONCE_LEN] = blob[74..98].try_into().ok()?;
    let local_id = device::key_id(&device.public_key());
    if !bool::from(local_id.ct_eq(key_id)) {
        return None;
    }
    let wrap_key = device::open_export(device, enc, &hpke_info(vault_id), LABEL_DEVICE_WRAP)?;
    let pt = keys::open(&wrap_key, nonce, &device_aad(vault_id, &blob[..98]), &blob[98..])?;
    if pt.len() != KEY_LEN {
        return None;
    }
    let mut k = Zeroizing::new([0u8; KEY_LEN]);
    k.copy_from_slice(&pt);
    Some(k)
}
