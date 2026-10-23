//! Single source of truth for the VTF1 test vectors in `vectors/`.
//!
//! `examples/gen_vectors.rs` writes them; `tests/vectors.rs` regenerates them
//! in-process and requires the committed files to match byte-for-byte.
//!
//! Every value here is a deliberate, public test fixture.
#![allow(dead_code)]

use p256::elliptic_curve::sec1::ToSec1Point;
use sha2::{Digest, Sha256};
use vtf_core::container::{self, ExportRandomness, PasswordCredentials};
use vtf_core::device::DeviceKey;
use vtf_core::*;
use zeroize::Zeroizing;

pub const PASSWORD: &str = "correct horse battery staple / VTF1 test vector";
/// NFC form; NFKC folds the ligature, roman numeral and fullwidth digits.
pub const UNICODE_PASSWORD: &str =
    "\u{C5}ngstr\u{F6}m \u{FB03} \u{216B} \u{FF12}\u{FF10}\u{FF12}\u{FF16}";
pub const UNICODE_ALTERNATES: &[&str] = &[
    // NFD of the same text.
    "A\u{30A}ngstro\u{308}m \u{FB03} \u{216B} \u{FF12}\u{FF10}\u{FF12}\u{FF16}",
    // Already-NFKC text.
    "\u{C5}ngstr\u{F6}m ffi XII 2026",
];
pub const SECRET_KEY: [u8; 16] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
pub const DEVICE_A_SK: [u8; 32] = [0x11; 32];
pub const DEVICE_B_SK: [u8; 32] = [0x22; 32];
pub const DEVICE_C_SK: [u8; 32] = [0x33; 32]; // never a recipient

pub struct SoftDevice(pub p256::SecretKey);

impl SoftDevice {
    pub fn new(sk: &[u8; 32]) -> Self {
        SoftDevice(p256::SecretKey::from_slice(sk).unwrap())
    }
}

impl DeviceKey for SoftDevice {
    fn public_key(&self) -> [u8; 65] {
        self.0
            .public_key()
            .to_sec1_point(false)
            .as_bytes()
            .try_into()
            .unwrap()
    }
    fn agree(&self, peer: &[u8; 65]) -> core::result::Result<Zeroizing<[u8; 32]>, ()> {
        let peer = p256::PublicKey::from_sec1_bytes(peer).map_err(|_| ())?;
        let shared = p256::ecdh::diffie_hellman(self.0.to_nonzero_scalar(), peer.as_affine());
        let mut out = Zeroizing::new([0u8; 32]);
        out.copy_from_slice(shared.raw_secret_bytes());
        Ok(out)
    }
}

fn seq<const N: usize>(start: u8) -> [u8; N] {
    core::array::from_fn(|i| start.wrapping_add(i as u8))
}

pub fn randomness(devices: usize) -> ExportRandomness {
    ExportRandomness {
        salt: seq(0x40),
        chunk_nonce_prefix: seq(0x80),
        vtk: seq(0xC0),
        password_slot_nonce: seq(0x20),
        device: (0..devices)
            .map(|d| (seq(0x50 + 0x10 * d as u8), seq(0x60 + 0x10 * d as u8)))
            .collect(),
    }
}

fn filler(seed: &str, len: usize) -> String {
    seed.chars().cycle().take(len).collect()
}

fn data(kind: ItemKind, title: &str) -> ItemData {
    ItemData {
        kind,
        title: title.into(),
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

fn item(id: u8, d: ItemData) -> Item {
    Item {
        id: [id; 16],
        created_at: 1_700_000_000 + u64::from(id),
        modified_at: 1_750_000_000 + u64::from(id),
        hlc: (1_750_000_000u64 << 16) | u64::from(id),
        data: d,
        history: vec![],
        trashed_at: None,
    }
}

/// Two chunks: exercises chunk indices and the last-chunk flag.
pub fn payload_unbound() -> Payload {
    let mut login = data(ItemKind::Login, "Example Mail");
    login.username = Some("alice@example.com".into());
    login.password = Some("Tr0ub4dor&3".into());
    login.urls = vec![
        "https://mail.example.com/".into(),
        "https://example.com/login".into(),
    ];
    login.totp = Some("otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&issuer=Example".into());
    login.folder = Some("Work".into());
    login.tags = vec!["email".into(), "work".into()];
    login.fields = vec![
        Field {
            name: "Recovery PIN".into(),
            value: "4815".into(),
            concealed: true,
        },
        Field {
            name: "Account".into(),
            value: "12345".into(),
            concealed: false,
        },
    ];
    login.travel_safe = true;
    let mut login_item = item(1, login.clone());
    let mut old = login.clone();
    old.password = Some("hunter2".into());
    login_item.history = vec![Revision {
        modified_at: 1_720_000_000,
        data: old,
    }];

    let mut note = data(ItemKind::SecureNote, "Long note \u{1F512}");
    note.notes = Some(filler("Grüße aus dem Tresor. ", 40_000));
    let mut card = data(ItemKind::Card, "Test card");
    card.fields = vec![Field {
        name: "Number".into(),
        value: "4111 1111 1111 1111".into(),
        concealed: true,
    }];
    let mut card_item = item(3, card);
    card_item.trashed_at = Some(1_760_000_000);
    let mut api = data(ItemKind::ApiKey, "Build server token");
    api.password = Some("tok_test_0000000000000000".into());
    api.notes = Some(filler("0123456789abcdef", 30_000));

    Payload {
        exported_at: 1_761_000_000,
        items: vec![
            login_item,
            item(2, note),
            card_item,
            item(4, data(ItemKind::Identity, "Me")),
            item(5, api),
            item(6, data(ItemKind::SshKey, "deploy key")),
        ],
        tombstones: vec![Tombstone {
            id: [0xEE; 16],
            deleted_at: 1_755_000_000,
            hlc: 42,
        }],
    }
}

pub fn payload_small() -> Payload {
    let mut login = data(ItemKind::Login, "Router");
    login.username = Some("admin".into());
    login.password = Some("pa55w0rd".into());
    Payload {
        exported_at: 1_761_000_000,
        items: vec![item(9, login)],
        tombstones: vec![],
    }
}

pub fn creds<'a>(pw: &'a Password, sk: &'a SecretKey) -> Option<PasswordCredentials<'a>> {
    Some(PasswordCredentials {
        password: pw,
        secret_key: sk,
    })
}

pub fn pk(sk: &[u8; 32]) -> [u8; 65] {
    SoftDevice::new(sk).public_key()
}

pub struct Positive {
    pub name: &'static str,
    pub description: &'static str,
    pub password: Option<&'static str>,
    pub password_alternates: &'static [&'static str],
    pub devices: Vec<[u8; 32]>,
    pub cbor: Vec<u8>,
    pub file: Vec<u8>,
}

pub fn positives() -> &'static [Positive] {
    static CACHE: std::sync::OnceLock<Vec<Positive>> = std::sync::OnceLock::new();
    CACHE.get_or_init(build_positives)
}

fn build_positives() -> Vec<Positive> {
    let sk = SecretKey::from_bytes(SECRET_KEY);
    let pw = Password::new(PASSWORD).unwrap();
    let upw = Password::new(UNICODE_PASSWORD).unwrap();
    let unbound = payload_unbound();
    let small = payload_small();
    let enc = |p: &Payload| payload::encode(p).unwrap().to_vec();
    vec![
        Positive {
            name: "unbound",
            description: "Password + Secret Key slot only; two chunks; all item kinds, history, trash, tombstone.",
            password: Some(PASSWORD),
            password_alternates: &[],
            devices: vec![],
            cbor: enc(&unbound),
            file: container::export_with(&unbound, creds(&pw, &sk), &[], &randomness(0)).unwrap(),
        },
        Positive {
            name: "device-bound",
            description: "Two device slots (HPKE DHKEM P-256), no password slot.",
            password: None,
            password_alternates: &[],
            devices: vec![DEVICE_A_SK, DEVICE_B_SK],
            cbor: enc(&small),
            file: container::export_with(&small, None, &[pk(&DEVICE_A_SK), pk(&DEVICE_B_SK)], &randomness(2)).unwrap(),
        },
        Positive {
            name: "mixed",
            description: "Password slot followed by one device slot.",
            password: Some(PASSWORD),
            password_alternates: &[],
            devices: vec![DEVICE_A_SK],
            cbor: enc(&small),
            file: container::export_with(&small, creds(&pw, &sk), &[pk(&DEVICE_A_SK)], &randomness(1)).unwrap(),
        },
        Positive {
            name: "unicode-password",
            description: "Password must be NFKC-normalized; every alternate form opens the file and reproduces it.",
            password: Some(UNICODE_PASSWORD),
            password_alternates: UNICODE_ALTERNATES,
            devices: vec![],
            cbor: enc(&small),
            file: container::export_with(&small, creds(&upw, &sk), &[], &randomness(0)).unwrap(),
        },
    ]
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Cred {
    Password,
    WrongPassword,
    WrongSecretKey,
    DeviceA,
    DeviceC,
}

impl Cred {
    pub fn name(self) -> &'static str {
        match self {
            Cred::Password => "password",
            Cred::WrongPassword => "wrong-password",
            Cred::WrongSecretKey => "wrong-secret-key",
            Cred::DeviceA => "device-a",
            Cred::DeviceC => "device-c",
        }
    }
}

pub struct Negative {
    pub name: String,
    pub description: String,
    pub cred: Cred,
    pub check: Check,
    pub file: Vec<u8>,
}

fn flip(mut f: Vec<u8>, at: usize, mask: u8) -> Vec<u8> {
    f[at] ^= mask;
    f
}

fn set_be32(mut f: Vec<u8>, at: usize, v: u32) -> Vec<u8> {
    f[at..at + 4].copy_from_slice(&v.to_be_bytes());
    f
}

/// Encrypts arbitrary payload bytes under the standard password vector keys.
fn raw(cbor: &[u8]) -> Vec<u8> {
    let sk = SecretKey::from_bytes(SECRET_KEY);
    let pw = Password::new(PASSWORD).unwrap();
    container::export_raw_plaintext(cbor, creds(&pw, &sk), &[], &randomness(0)).unwrap()
}

fn padded(cbor: &[u8], tweak: impl FnOnce(&mut Vec<u8>)) -> Vec<u8> {
    let sk = SecretKey::from_bytes(SECRET_KEY);
    let pw = Password::new(PASSWORD).unwrap();
    let mut buf = cbor.to_vec();
    buf.resize(container::CHUNK_PLAINTEXT, 0);
    tweak(&mut buf);
    container::export_padded(&buf, creds(&pw, &sk), &[], &randomness(0)).unwrap()
}

const MIN_PAYLOAD: [u8; 7] = [0xa3, 0x01, 0x01, 0x02, 0x00, 0x03, 0x80]; // {1:1, 2:0, 3:[]}

pub fn negatives() -> &'static [Negative] {
    static CACHE: std::sync::OnceLock<Vec<Negative>> = std::sync::OnceLock::new();
    CACHE.get_or_init(build_negatives)
}

fn build_negatives() -> Vec<Negative> {
    let pos = positives();
    let unbound = pos[0].file.clone();
    let device = pos[1].file.clone();
    let len = unbound.len();
    let chunk0 = 84 + 73;
    let chunk1 = chunk0 + container::CHUNK_LEN;
    use Check::*;
    use Cred::*;

    let mut v: Vec<(&str, &str, Cred, Check, Vec<u8>)> = vec![
        (
            "bitflip-magic",
            "bit 0 of byte 0 flipped",
            Password,
            Magic,
            flip(unbound.clone(), 0, 0x01),
        ),
        (
            "bitflip-version",
            "version 1 -> 0",
            Password,
            Version,
            flip(unbound.clone(), 5, 0x01),
        ),
        (
            "bitflip-flags-reserved",
            "reserved flag bit 1 set",
            Password,
            FlagsReserved,
            flip(unbound.clone(), 7, 0x02),
        ),
        (
            "bitflip-kdf-id",
            "kdf_id 0x01 -> 0x03",
            Password,
            KdfId,
            flip(unbound.clone(), 8, 0x02),
        ),
        (
            "bitflip-aead-id",
            "aead_id 0x01 -> 0x00",
            Password,
            AeadId,
            flip(unbound.clone(), 9, 0x01),
        ),
        (
            "bitflip-kem-id",
            "kem_id 0x0010 -> 0x0011",
            Password,
            KemId,
            flip(unbound.clone(), 11, 0x01),
        ),
        (
            "bitflip-salt",
            "one salt bit flipped",
            Password,
            SlotUnwrap,
            flip(unbound.clone(), 30, 0x10),
        ),
        (
            "bitflip-nonce-prefix",
            "one chunk-nonce-prefix bit flipped",
            Password,
            SlotUnwrap,
            flip(unbound.clone(), 60, 0x01),
        ),
        (
            "bitflip-reserved",
            "reserved trailing header byte non-zero",
            Password,
            Reserved,
            flip(unbound.clone(), 83, 0x01),
        ),
        (
            "bitflip-slot-type",
            "slot type 0x01 -> 0x05",
            Password,
            SlotTable,
            flip(unbound.clone(), 84, 0x04),
        ),
        (
            "bitflip-slot-nonce",
            "password slot nonce bit flipped",
            Password,
            SlotUnwrap,
            flip(unbound.clone(), 90, 0x80),
        ),
        (
            "bitflip-slot-wrapped",
            "wrapped VTK bit flipped",
            Password,
            SlotUnwrap,
            flip(unbound.clone(), 120, 0x01),
        ),
        (
            "bitflip-chunk0-body",
            "first ciphertext byte of chunk 0 flipped",
            Password,
            ChunkAuth,
            flip(unbound.clone(), chunk0, 0x01),
        ),
        (
            "bitflip-chunk1-tag",
            "last tag byte of final chunk flipped",
            Password,
            ChunkAuth,
            flip(unbound.clone(), len - 1, 0x80),
        ),
        (
            "bitflip-device-flag",
            "HAS_DEVICE_SLOTS cleared on a device-bound file",
            DeviceA,
            FlagsDeviceSlots,
            flip(device.clone(), 7, 0x01),
        ),
        (
            "bitflip-device-enc",
            "device slot HPKE enc bit flipped",
            DeviceA,
            SlotUnwrap,
            flip(device.clone(), 84 + 40, 0x01),
        ),
        (
            "bitflip-device-key-id",
            "device slot key_id bit flipped",
            DeviceA,
            SlotUnwrap,
            flip(device.clone(), 84 + 1, 0x01),
        ),
        (
            "truncated-header",
            "file cut to 50 bytes",
            Password,
            LengthMin,
            unbound[..50].to_vec(),
        ),
        (
            "truncated-slot",
            "file ends inside the slot table",
            Password,
            SlotTable,
            unbound[..100].to_vec(),
        ),
        (
            "truncated-tail",
            "last 100 bytes removed",
            Password,
            Length,
            unbound[..len - 100].to_vec(),
        ),
        (
            "truncated-last-chunk",
            "final chunk removed, header unchanged",
            Password,
            Length,
            unbound[..chunk1].to_vec(),
        ),
        (
            "truncated-last-chunk-recounted",
            "final chunk removed and chunk_count patched to 1",
            Password,
            SlotUnwrap,
            set_be32(unbound[..chunk1].to_vec(), 76, 1),
        ),
        (
            "reordered-chunks",
            "chunk 0 and chunk 1 swapped",
            Password,
            ChunkAuth,
            {
                let mut f = unbound.clone();
                let (a, b) = (unbound[chunk0..chunk1].to_vec(), unbound[chunk1..].to_vec());
                f.truncate(chunk0);
                f.extend_from_slice(&b);
                f.extend_from_slice(&a);
                f
            },
        ),
        (
            "appended-byte",
            "one zero byte appended",
            Password,
            Length,
            [unbound.clone(), vec![0]].concat(),
        ),
        (
            "appended-chunk",
            "copy of the final chunk appended",
            Password,
            Length,
            [unbound.clone(), unbound[chunk1..].to_vec()].concat(),
        ),
        (
            "version-2",
            "version field set to 2",
            Password,
            Version,
            flip(unbound.clone(), 5, 0x03),
        ),
        (
            "argon2-lowered-m",
            "m lowered to 65536 KiB",
            Password,
            Argon2Params,
            set_be32(unbound.clone(), 12, 65_536),
        ),
        (
            "argon2-lowered-t",
            "t lowered to 1",
            Password,
            Argon2Params,
            set_be32(unbound.clone(), 16, 1),
        ),
        (
            "argon2-lowered-p",
            "p lowered to 1",
            Password,
            Argon2Params,
            set_be32(unbound.clone(), 20, 1),
        ),
        (
            "argon2-raised-m",
            "m raised to 1048576 KiB",
            Password,
            Argon2Params,
            set_be32(unbound.clone(), 12, 1_048_576),
        ),
        ("slot-count-0", "slot_count = 0", Password, SlotCount, {
            let mut f = unbound.clone();
            f[75] = 0;
            f
        }),
        ("slot-count-17", "slot_count = 17", Password, SlotCount, {
            let mut f = unbound.clone();
            f[75] = 17;
            f
        }),
        (
            "duplicate-password-slot",
            "password slot repeated, slot_count = 2",
            Password,
            SlotTable,
            {
                let mut f = unbound[..84].to_vec();
                f[75] = 2;
                f.extend_from_slice(&unbound[84..157]);
                f.extend_from_slice(&unbound[84..]);
                f
            },
        ),
        (
            "chunk-count-0",
            "chunk_count = 0",
            Password,
            Length,
            set_be32(unbound.clone(), 76, 0),
        ),
        (
            "chunk-count-4097",
            "chunk_count = 4097",
            Password,
            Length,
            set_be32(unbound.clone(), 76, 4097),
        ),
        (
            "wrong-password",
            "correct file, wrong password",
            WrongPassword,
            SlotUnwrap,
            unbound.clone(),
        ),
        (
            "wrong-secret-key",
            "correct file, wrong Secret Key",
            WrongSecretKey,
            SlotUnwrap,
            unbound.clone(),
        ),
        (
            "wrong-device",
            "device-bound file opened by a non-recipient device",
            DeviceC,
            SlotUnwrap,
            device.clone(),
        ),
        (
            "password-on-device-bound",
            "device-bound file opened with password",
            Password,
            SlotUnwrap,
            device.clone(),
        ),
    ]
    .into_iter()
    .map(|(n, d, c, k, f)| (n, d, c, k, f))
    .collect();

    // Encrypted-and-authenticated payloads that must still be rejected.
    let mut dup = vec![0xa4, 0x01, 0x01, 0x01, 0x01, 0x02, 0x00, 0x03, 0x80]; // key 1 twice
    let mut depth = vec![0xa3, 0x01, 0x01, 0x02, 0x00, 0x03];
    depth.extend(std::iter::repeat_n(0x81u8, 15)); // arrays at depth 2..=16
    depth.push(0x80); // depth 17
    let payload_rows: Vec<(&str, &str, Check, Vec<u8>)> = vec![
        (
            "cbor-duplicate-key",
            "top-level map has key 1 twice",
            CborDuplicateKey,
            raw(&std::mem::take(&mut dup)),
        ),
        (
            "cbor-depth-17",
            "array nested to depth 17",
            CborDepth,
            raw(&depth),
        ),
        (
            "nonzero-padding",
            "valid payload, one padding byte = 0x01",
            Padding,
            padded(&MIN_PAYLOAD, |b| b[1000] = 1),
        ),
        (
            "all-padding-chunk",
            "valid payload followed by an entire chunk of zero padding",
            Padding,
            {
                let sk = SecretKey::from_bytes(SECRET_KEY);
                let pw = vtf_core::Password::new(PASSWORD).unwrap();
                let mut buf = MIN_PAYLOAD.to_vec();
                buf.resize(2 * container::CHUNK_PLAINTEXT, 0);
                container::export_padded(&buf, creds(&pw, &sk), &[], &randomness(0)).unwrap()
            },
        ),
        (
            "cbor-non-shortest",
            "uint 1 encoded in two bytes",
            CborDeterministic,
            raw(&[0xa3, 0x01, 0x18, 0x01, 0x02, 0x00, 0x03, 0x80]),
        ),
        (
            "cbor-indefinite",
            "items array uses indefinite length",
            CborDeterministic,
            raw(&[0xa3, 0x01, 0x01, 0x02, 0x00, 0x03, 0x9f, 0xff]),
        ),
        (
            "cbor-unsorted-keys",
            "map keys out of order",
            CborDeterministic,
            raw(&[0xa3, 0x02, 0x00, 0x01, 0x01, 0x03, 0x80]),
        ),
        (
            "cbor-float",
            "exported_at is a float",
            CborType,
            raw(&[0xa3, 0x01, 0x01, 0x02, 0xf9, 0x00, 0x00, 0x03, 0x80]),
        ),
        (
            "cbor-tag",
            "exported_at is tagged",
            CborType,
            raw(&[0xa3, 0x01, 0x01, 0x02, 0xc1, 0x00, 0x03, 0x80]),
        ),
        (
            "cbor-null",
            "exported_at is null",
            CborType,
            raw(&[0xa3, 0x01, 0x01, 0x02, 0xf6, 0x03, 0x80]),
        ),
        (
            "cbor-unknown-key",
            "top-level key 5",
            CborUnknownKey,
            raw(&[0xa4, 0x01, 0x01, 0x02, 0x00, 0x03, 0x80, 0x05, 0x00]),
        ),
        (
            "cbor-missing-key",
            "items key absent",
            CborMissingKey,
            raw(&[0xa2, 0x01, 0x01, 0x02, 0x00]),
        ),
        (
            "cbor-empty-optional",
            "tombstones present but empty",
            CborEmptyOptional,
            raw(&[0xa4, 0x01, 0x01, 0x02, 0x00, 0x03, 0x80, 0x04, 0x80]),
        ),
        (
            "cbor-truncated",
            "text string length runs past the end of the plaintext",
            CborWellformed,
            raw(&[
                0xa3, 0x01, 0x01, 0x02, 0x00, 0x03, 0x81, 0x7a, 0x00, 0x10, 0x00, 0x00,
            ]),
        ),
        ("cbor-limit", "text string of 65537 bytes", CborLimit, {
            let mut b = vec![
                0xa3, 0x01, 0x01, 0x02, 0x00, 0x03, 0x81, 0x7a, 0x00, 0x01, 0x00, 0x01,
            ];
            b.resize(b.len() + 65_537, 0x61);
            raw(&b)
        }),
        (
            "payload-version-2",
            "payload_version = 2",
            PayloadVersion,
            raw(&[0xa3, 0x01, 0x02, 0x02, 0x00, 0x03, 0x80]),
        ),
    ];
    let mut out: Vec<Negative> = v
        .drain(..)
        .map(|(n, d, cred, check, file)| Negative {
            name: n.into(),
            description: d.into(),
            cred,
            check,
            file,
        })
        .collect();
    out.extend(
        payload_rows
            .into_iter()
            .map(|(n, d, check, file)| Negative {
                name: n.into(),
                description: d.into(),
                cred: Password,
                check,
                file,
            }),
    );
    out
}

/// Runs the import a negative vector's manifest names and returns the check
/// that rejected it (panics if it was accepted).
pub fn reject(n: &Negative) -> Check {
    let sk = SecretKey::from_bytes(SECRET_KEY);
    let pw = Password::new(PASSWORD).unwrap();
    let result = match n.cred {
        Cred::Password => import_with_password(&n.file, &pw, &sk),
        Cred::WrongPassword => import_with_password(&n.file, &Password::new("wrong").unwrap(), &sk),
        Cred::WrongSecretKey => {
            import_with_password(&n.file, &pw, &SecretKey::from_bytes([0xFF; 16]))
        }
        Cred::DeviceA => import_with_device(&n.file, &SoftDevice::new(&DEVICE_A_SK)),
        Cred::DeviceC => import_with_device(&n.file, &SoftDevice::new(&DEVICE_C_SK)),
    };
    match result {
        Ok(_) => panic!("negative vector {} was accepted", n.name),
        Err(Error::Rejected(c)) => c,
        Err(e) => panic!(
            "negative vector {} failed outside a named check: {e}",
            n.name
        ),
    }
}

pub fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

pub fn sha256_hex(b: &[u8]) -> String {
    hex(&Sha256::digest(b))
}

fn json_str(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            c if (c as u32) < 0x20 || (c as u32) > 0x7e => {
                let mut buf = [0u16; 2];
                for u in c.encode_utf16(&mut buf) {
                    o.push_str(&format!("\\u{u:04x}"));
                }
            }
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

/// Manifest consumed by the Python reference implementation.
pub fn manifest_json() -> String {
    let r0 = randomness(2);
    let mut s = String::from("{\n");
    s.push_str("  \"format\": \"VTF1\",\n");
    s.push_str(
        "  \"note\": \"Deliberate public test fixtures. Never use these values for real data.\",\n",
    );
    s.push_str(&format!(
        "  \"secret_key_hex\": \"{}\",\n",
        hex(&SECRET_KEY)
    ));
    s.push_str(&format!(
        "  \"secret_key_display\": {},\n",
        json_str(&SecretKey::from_bytes(SECRET_KEY).to_display())
    ));
    s.push_str("  \"devices\": {\n");
    for (i, (name, d)) in [("a", DEVICE_A_SK), ("b", DEVICE_B_SK), ("c", DEVICE_C_SK)]
        .iter()
        .enumerate()
    {
        s.push_str(&format!(
            "    \"{name}\": {{\"private_key_hex\": \"{}\", \"public_key_hex\": \"{}\"}}{}\n",
            hex(d),
            hex(&pk(d)),
            if i < 2 { "," } else { "" }
        ));
    }
    s.push_str("  },\n");
    s.push_str("  \"randomness\": {\n");
    s.push_str(&format!("    \"salt\": \"{}\",\n", hex(&r0.salt)));
    s.push_str(&format!(
        "    \"chunk_nonce_prefix\": \"{}\",\n",
        hex(&r0.chunk_nonce_prefix)
    ));
    s.push_str(&format!("    \"vtk\": \"{}\",\n", hex(&r0.vtk)));
    s.push_str(&format!(
        "    \"password_slot_nonce\": \"{}\",\n",
        hex(&r0.password_slot_nonce)
    ));
    s.push_str("    \"device_slots\": [\n");
    for (i, (ikm, nonce)) in r0.device.iter().enumerate() {
        s.push_str(&format!(
            "      {{\"ikm_e\": \"{}\", \"nonce\": \"{}\"}}{}\n",
            hex(ikm),
            hex(nonce),
            if i + 1 < r0.device.len() { "," } else { "" }
        ));
    }
    s.push_str("    ]\n  },\n");
    s.push_str("  \"positive\": [\n");
    let pos = positives();
    for (i, p) in pos.iter().enumerate() {
        let devs: Vec<String> = p
            .devices
            .iter()
            .map(|d| {
                let n = if *d == DEVICE_A_SK { "a" } else { "b" };
                format!("\"{n}\"")
            })
            .collect();
        let alts: Vec<String> = p.password_alternates.iter().map(|a| json_str(a)).collect();
        s.push_str(&format!(
            "    {{\"name\": \"{}\", \"description\": {}, \"file\": \"positive/{}.vtf\", \"payload\": \"positive/{}.cbor\", \
\"sha256\": \"{}\", \"password\": {}, \"password_alternates\": [{}], \"device_recipients\": [{}]}}{}\n",
            p.name,
            json_str(p.description),
            p.name,
            p.name,
            sha256_hex(&p.file),
            p.password.map(json_str).unwrap_or_else(|| "null".into()),
            alts.join(", "),
            devs.join(", "),
            if i + 1 < pos.len() { "," } else { "" }
        ));
    }
    s.push_str("  ],\n  \"negative\": [\n");
    let neg = negatives();
    for (i, n) in neg.iter().enumerate() {
        s.push_str(&format!(
            "    {{\"name\": \"{}\", \"description\": {}, \"file\": \"negative/{}.vtf\", \"credential\": \"{}\", \"expected_check\": \"{}\"}}{}\n",
            n.name,
            json_str(&n.description),
            n.name,
            n.cred.name(),
            n.check.name(),
            if i + 1 < neg.len() { "," } else { "" }
        ));
    }
    s.push_str("  ]\n}\n");
    s
}
