//! VTF1 container: fixed header, key slots, chunked AEAD (SPEC-VTF 3, 5, 7, 8).

use sha2::{Digest, Sha256};
use subtle::{ConditionallySelectable, ConstantTimeEq};
use zeroize::{Zeroize, Zeroizing};

use crate::device::{self, DeviceKey, ENC_LEN, KEY_ID_LEN, PUBLIC_KEY_LEN};
use crate::error::{Check, Error, Result};
use crate::keys::{self, Key, Password, SecretKey, ARGON2_M_KIB, ARGON2_P, ARGON2_T, KEY_LEN, NONCE_LEN, TAG_LEN};
use crate::payload::{self, Payload};

pub const MAGIC: [u8; 4] = *b"VTF1";
pub const VERSION: u16 = 1;
pub const HEADER_LEN: usize = 84;
pub const KDF_ARGON2ID: u8 = 0x01;
pub const AEAD_XCHACHA20POLY1305: u8 = 0x01;
pub const KEM_DHKEM_P256: u16 = 0x0010;
pub const FLAG_HAS_DEVICE_SLOTS: u16 = 0x0001;

pub const SLOT_PASSWORD: u8 = 0x01;
pub const SLOT_DEVICE: u8 = 0x02;
pub const PASSWORD_SLOT_LEN: usize = 73;
pub const DEVICE_SLOT_LEN: usize = 146;
pub const MAX_SLOTS: usize = 16;

pub const CHUNK_PLAINTEXT: usize = 65_536;
pub const CHUNK_LEN: usize = CHUNK_PLAINTEXT + TAG_LEN;
pub const MAX_CHUNKS: u32 = 4096;
const NONCE_PREFIX_LEN: usize = 19;
const WRAPPED_LEN: usize = KEY_LEN + TAG_LEN;

const LABEL_PAYLOAD: &[u8] = b"VTF1/payload";
const LABEL_HPKE_INFO: &[u8] = b"VTF1/hpke-info";
const LABEL_DEVICE_WRAP: &[u8] = b"VTF1/device-wrap";

/// Public, unauthenticated information about a file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Info {
    pub version: u16,
    pub password_slots: u8,
    pub device_slots: u8,
    pub chunk_count: u32,
}

enum Slot<'a> {
    Password { nonce: &'a [u8; NONCE_LEN], wrapped: &'a [u8] },
    Device { key_id: &'a [u8; KEY_ID_LEN], enc: &'a [u8; ENC_LEN], nonce: &'a [u8; NONCE_LEN], wrapped: &'a [u8], aad_tail: &'a [u8] },
}

struct Parsed<'a> {
    fixed: &'a [u8; HEADER_LEN],
    salt: [u8; 32],
    nonce_prefix: [u8; NONCE_PREFIX_LEN],
    slots: Vec<Slot<'a>>,
    slot_table: &'a [u8],
    chunks: &'a [u8],
    chunk_count: u32,
}

fn be16(b: &[u8]) -> u16 {
    u16::from_be_bytes([b[0], b[1]])
}
fn be32(b: &[u8]) -> u32 {
    u32::from_be_bytes([b[0], b[1], b[2], b[3]])
}

/// Checks 1-13: everything that can be verified without any key.
fn parse(file: &[u8]) -> Result<Parsed<'_>> {
    if file.len() < HEADER_LEN {
        return Err(Check::LengthMin.into());
    }
    let fixed: &[u8; HEADER_LEN] = file[..HEADER_LEN].try_into().expect("84 bytes");
    if fixed[0..4] != MAGIC {
        return Err(Check::Magic.into());
    }
    if be16(&fixed[4..6]) != VERSION {
        return Err(Check::Version.into());
    }
    let flags = be16(&fixed[6..8]);
    if flags & !FLAG_HAS_DEVICE_SLOTS != 0 {
        return Err(Check::FlagsReserved.into());
    }
    if fixed[8] != KDF_ARGON2ID {
        return Err(Check::KdfId.into());
    }
    if fixed[9] != AEAD_XCHACHA20POLY1305 {
        return Err(Check::AeadId.into());
    }
    if be16(&fixed[10..12]) != KEM_DHKEM_P256 {
        return Err(Check::KemId.into());
    }
    if be32(&fixed[12..16]) != ARGON2_M_KIB || be32(&fixed[16..20]) != ARGON2_T || be32(&fixed[20..24]) != ARGON2_P {
        return Err(Check::Argon2Params.into());
    }
    if fixed[80..84] != [0, 0, 0, 0] {
        return Err(Check::Reserved.into());
    }
    let slot_count = usize::from(fixed[75]);
    if slot_count == 0 || slot_count > MAX_SLOTS {
        return Err(Check::SlotCount.into());
    }

    let mut pos = HEADER_LEN;
    let mut slots = Vec::with_capacity(slot_count);
    let mut password_slots = 0;
    let mut device_ids: Vec<&[u8; KEY_ID_LEN]> = Vec::new();
    for _ in 0..slot_count {
        let ty = *file.get(pos).ok_or(Check::SlotTable)?;
        let len = match ty {
            SLOT_PASSWORD => PASSWORD_SLOT_LEN,
            SLOT_DEVICE => DEVICE_SLOT_LEN,
            _ => return Err(Check::SlotTable.into()),
        };
        let s = file.get(pos..pos + len).ok_or(Check::SlotTable)?;
        if ty == SLOT_PASSWORD {
            password_slots += 1;
            if password_slots > 1 {
                return Err(Check::SlotTable.into());
            }
            slots.push(Slot::Password { nonce: s[1..25].try_into().expect("24"), wrapped: &s[25..73] });
        } else {
            let key_id: &[u8; KEY_ID_LEN] = s[1..9].try_into().expect("8");
            if device_ids.iter().any(|id| bool::from(id.ct_eq(key_id))) {
                return Err(Check::SlotTable.into());
            }
            device_ids.push(key_id);
            slots.push(Slot::Device {
                key_id,
                enc: s[9..74].try_into().expect("65"),
                nonce: s[74..98].try_into().expect("24"),
                wrapped: &s[98..146],
                aad_tail: &s[..74],
            });
        }
        pos += len;
    }
    let has_device = !device_ids.is_empty();
    if has_device != (flags & FLAG_HAS_DEVICE_SLOTS != 0) {
        return Err(Check::FlagsDeviceSlots.into());
    }
    let chunk_count = be32(&fixed[76..80]);
    if chunk_count == 0 || chunk_count > MAX_CHUNKS {
        return Err(Check::Length.into());
    }
    let expected = pos as u64 + u64::from(chunk_count) * CHUNK_LEN as u64;
    if file.len() as u64 != expected {
        return Err(Check::Length.into());
    }
    Ok(Parsed {
        fixed,
        salt: fixed[24..56].try_into().expect("32"),
        nonce_prefix: fixed[56..75].try_into().expect("19"),
        slots,
        slot_table: &file[HEADER_LEN..pos],
        chunks: &file[pos..],
        chunk_count,
    })
}

/// Parses only the public parts (checks 1-13).
pub fn inspect(file: &[u8]) -> Result<Info> {
    let p = parse(file)?;
    let pw = p.slots.iter().filter(|s| matches!(s, Slot::Password { .. })).count() as u8;
    Ok(Info { version: VERSION, password_slots: pw, device_slots: p.slots.len() as u8 - pw, chunk_count: p.chunk_count })
}

fn chunk_nonce(prefix: &[u8; NONCE_PREFIX_LEN], index: u32, last: bool) -> [u8; NONCE_LEN] {
    let mut n = [0u8; NONCE_LEN];
    n[..NONCE_PREFIX_LEN].copy_from_slice(prefix);
    n[19..23].copy_from_slice(&index.to_be_bytes());
    n[23] = u8::from(last);
    n
}

fn hpke_info(fixed: &[u8; HEADER_LEN]) -> Vec<u8> {
    let mut info = LABEL_HPKE_INFO.to_vec();
    info.extend_from_slice(&Sha256::digest(fixed));
    info
}

/// Checks 15-26 given the VTK.
fn decrypt_payload(p: &Parsed<'_>, vtk: &[u8; KEY_LEN]) -> Result<Payload> {
    let payload_key = keys::hkdf32(vtk, &p.salt, LABEL_PAYLOAD);
    let mut hasher = Sha256::new();
    hasher.update(p.fixed);
    hasher.update(p.slot_table);
    let header_hash = hasher.finalize();

    let n = p.chunk_count as usize;
    let mut plaintext = Zeroizing::new(Vec::with_capacity(n * CHUNK_PLAINTEXT));
    let mut buf = Zeroizing::new(vec![0u8; CHUNK_LEN]);
    for i in 0..n {
        buf.copy_from_slice(&p.chunks[i * CHUNK_LEN..(i + 1) * CHUNK_LEN]);
        let nonce = chunk_nonce(&p.nonce_prefix, i as u32, i == n - 1);
        if !keys::open_in_place(&payload_key, &nonce, &header_hash, &mut buf) {
            return Err(Check::ChunkAuth.into());
        }
        plaintext.extend_from_slice(&buf[..CHUNK_PLAINTEXT]);
    }
    // Every chunk authenticated; only now parse.
    payload::decode_plaintext(&plaintext)
}

fn unwrap_vtk(kek: &[u8; KEY_LEN], nonce: &[u8; NONCE_LEN], aad: &[u8], wrapped: &[u8]) -> Option<Key> {
    let pt = keys::open(kek, nonce, aad, wrapped)?;
    let mut vtk = Zeroizing::new([0u8; KEY_LEN]);
    vtk.copy_from_slice(&pt);
    Some(vtk)
}

/// Opens a file with master password + Secret Key.
pub fn import_with_password(file: &[u8], password: &Password, secret_key: &SecretKey) -> Result<Payload> {
    let p = parse(file)?;
    let kek = keys::derive_kek(password, secret_key, &p.salt)?;
    let mut vtk = None;
    for slot in &p.slots {
        if let Slot::Password { nonce, wrapped } = slot {
            let mut aad = p.fixed.to_vec();
            aad.push(SLOT_PASSWORD);
            vtk = unwrap_vtk(&kek, nonce, &aad, wrapped);
        }
    }
    let vtk = vtk.ok_or(Check::SlotUnwrap)?;
    decrypt_payload(&p, &vtk)
}

/// Opens a file with a hardware device key (one ECDH through `device`).
pub fn import_with_device(file: &[u8], device: &dyn DeviceKey) -> Result<Payload> {
    let p = parse(file)?;
    let my_id = device::key_id(&device.public_key());
    // Constant-time selection of the matching device slot.
    let mut found = subtle::Choice::from(0);
    let mut index = 0u8;
    for (i, slot) in p.slots.iter().enumerate() {
        if let Slot::Device { key_id, .. } = slot {
            let hit = key_id.ct_eq(&my_id);
            index.conditional_assign(&(i as u8), hit);
            found |= hit;
        }
    }
    if !bool::from(found) {
        return Err(Check::SlotUnwrap.into());
    }
    let Slot::Device { enc, nonce, wrapped, aad_tail, .. } = &p.slots[usize::from(index)] else {
        return Err(Check::SlotUnwrap.into());
    };
    let wrap_key = device::open_export(device, enc, &hpke_info(p.fixed), LABEL_DEVICE_WRAP).ok_or(Check::SlotUnwrap)?;
    let mut aad = p.fixed.to_vec();
    aad.extend_from_slice(aad_tail);
    let vtk = unwrap_vtk(&wrap_key, nonce, &aad, wrapped).ok_or(Check::SlotUnwrap)?;
    decrypt_payload(&p, &vtk)
}

/// All randomness consumed by one export. Production code fills it from the
/// OS CSPRNG; test-vector generation supplies fixed values.
#[derive(Zeroize)]
#[zeroize(drop)]
pub struct ExportRandomness {
    pub salt: [u8; 32],
    pub chunk_nonce_prefix: [u8; NONCE_PREFIX_LEN],
    pub vtk: [u8; KEY_LEN],
    pub password_slot_nonce: [u8; NONCE_LEN],
    /// Per device recipient, in order: (HPKE ephemeral ikmE, slot nonce).
    pub device: Vec<([u8; 32], [u8; NONCE_LEN])>,
}

impl ExportRandomness {
    pub fn from_os(device_recipients: usize) -> Result<Self> {
        let mut r = ExportRandomness {
            salt: [0; 32],
            chunk_nonce_prefix: [0; NONCE_PREFIX_LEN],
            vtk: [0; KEY_LEN],
            password_slot_nonce: [0; NONCE_LEN],
            device: vec![([0; 32], [0; NONCE_LEN]); device_recipients],
        };
        keys::fill_random(&mut r.salt)?;
        keys::fill_random(&mut r.chunk_nonce_prefix)?;
        keys::fill_random(&mut r.vtk)?;
        keys::fill_random(&mut r.password_slot_nonce)?;
        for (ikm, nonce) in r.device.iter_mut() {
            keys::fill_random(ikm)?;
            keys::fill_random(nonce)?;
        }
        Ok(r)
    }
}

/// Credentials for the password slot.
pub struct PasswordCredentials<'a> {
    pub password: &'a Password,
    pub secret_key: &'a SecretKey,
}

/// Exports `payload` with fresh OS randomness.
pub fn export(payload: &Payload, password: Option<PasswordCredentials<'_>>, device_recipients: &[[u8; PUBLIC_KEY_LEN]]) -> Result<Vec<u8>> {
    let rand = ExportRandomness::from_os(device_recipients.len())?;
    export_with(payload, password, device_recipients, &rand)
}

/// Exports with caller-supplied randomness. Only for test vectors: reusing
/// randomness across exports is catastrophic.
#[doc(hidden)]
pub fn export_with(
    payload: &Payload,
    password: Option<PasswordCredentials<'_>>,
    device_recipients: &[[u8; PUBLIC_KEY_LEN]],
    rand: &ExportRandomness,
) -> Result<Vec<u8>> {
    let cbor = payload::encode(payload)?;
    export_raw_plaintext(&cbor, password, device_recipients, rand)
}

/// Encrypts an arbitrary CBOR byte string as a payload (padding applied).
/// Exposed only so negative vectors can carry malformed payloads.
#[doc(hidden)]
pub fn export_raw_plaintext(
    cbor: &[u8],
    password: Option<PasswordCredentials<'_>>,
    device_recipients: &[[u8; PUBLIC_KEY_LEN]],
    rand: &ExportRandomness,
) -> Result<Vec<u8>> {
    let mut padded = Zeroizing::new(cbor.to_vec());
    let n = padded.len().div_ceil(CHUNK_PLAINTEXT).max(1);
    padded.resize(n * CHUNK_PLAINTEXT, 0);
    export_padded(&padded, password, device_recipients, rand)
}

#[doc(hidden)]
pub fn export_padded(
    padded: &[u8],
    password: Option<PasswordCredentials<'_>>,
    device_recipients: &[[u8; PUBLIC_KEY_LEN]],
    rand: &ExportRandomness,
) -> Result<Vec<u8>> {
    let slot_count = usize::from(password.is_some()) + device_recipients.len();
    if slot_count == 0 {
        return Err(Error::InvalidInput("export needs a password or a device recipient"));
    }
    if slot_count > MAX_SLOTS {
        return Err(Error::InvalidInput("too many recipients"));
    }
    if rand.device.len() != device_recipients.len() {
        return Err(Error::InvalidInput("randomness does not match recipients"));
    }
    if padded.is_empty() || padded.len() % CHUNK_PLAINTEXT != 0 {
        return Err(Error::InvalidInput("plaintext not padded"));
    }
    let chunk_count = padded.len() / CHUNK_PLAINTEXT;
    if chunk_count > MAX_CHUNKS as usize {
        return Err(Error::InvalidInput("payload larger than 256 MiB"));
    }
    let mut ids = Vec::with_capacity(device_recipients.len());
    for pk in device_recipients {
        device::validate_public_key(pk)?;
        let id = device::key_id(pk);
        if ids.contains(&id) {
            return Err(Error::InvalidInput("duplicate device recipient"));
        }
        ids.push(id);
    }

    let mut fixed = [0u8; HEADER_LEN];
    fixed[0..4].copy_from_slice(&MAGIC);
    fixed[4..6].copy_from_slice(&VERSION.to_be_bytes());
    let flags = if device_recipients.is_empty() { 0 } else { FLAG_HAS_DEVICE_SLOTS };
    fixed[6..8].copy_from_slice(&flags.to_be_bytes());
    fixed[8] = KDF_ARGON2ID;
    fixed[9] = AEAD_XCHACHA20POLY1305;
    fixed[10..12].copy_from_slice(&KEM_DHKEM_P256.to_be_bytes());
    fixed[12..16].copy_from_slice(&ARGON2_M_KIB.to_be_bytes());
    fixed[16..20].copy_from_slice(&ARGON2_T.to_be_bytes());
    fixed[20..24].copy_from_slice(&ARGON2_P.to_be_bytes());
    fixed[24..56].copy_from_slice(&rand.salt);
    fixed[56..75].copy_from_slice(&rand.chunk_nonce_prefix);
    fixed[75] = slot_count as u8;
    fixed[76..80].copy_from_slice(&(chunk_count as u32).to_be_bytes());

    let mut out = Vec::with_capacity(HEADER_LEN + slot_count * DEVICE_SLOT_LEN + chunk_count * CHUNK_LEN);
    out.extend_from_slice(&fixed);

    if let Some(creds) = password {
        let kek = keys::derive_kek(creds.password, creds.secret_key, &rand.salt)?;
        let mut aad = fixed.to_vec();
        aad.push(SLOT_PASSWORD);
        let wrapped = keys::seal(&kek, &rand.password_slot_nonce, &aad, &rand.vtk);
        debug_assert_eq!(wrapped.len(), WRAPPED_LEN);
        out.push(SLOT_PASSWORD);
        out.extend_from_slice(&rand.password_slot_nonce);
        out.extend_from_slice(&wrapped);
    }
    let info = hpke_info(&fixed);
    for ((pk, id), (ikm_e, nonce)) in device_recipients.iter().zip(&ids).zip(&rand.device) {
        let (enc, wrap_key) = device::seal_export(pk, &info, LABEL_DEVICE_WRAP, ikm_e)?;
        let start = out.len();
        out.push(SLOT_DEVICE);
        out.extend_from_slice(id);
        out.extend_from_slice(&enc);
        let mut aad = fixed.to_vec();
        aad.extend_from_slice(&out[start..]);
        let wrapped = keys::seal(&wrap_key, nonce, &aad, &rand.vtk);
        out.extend_from_slice(nonce);
        out.extend_from_slice(&wrapped);
    }

    let payload_key = keys::hkdf32(&rand.vtk, &rand.salt, LABEL_PAYLOAD);
    let header_hash = Sha256::digest(&out);
    for (i, chunk) in padded.chunks(CHUNK_PLAINTEXT).enumerate() {
        let nonce = chunk_nonce(&rand.chunk_nonce_prefix, i as u32, i == chunk_count - 1);
        out.extend_from_slice(&keys::seal(&payload_key, &nonce, &header_hash, chunk));
    }
    Ok(out)
}
