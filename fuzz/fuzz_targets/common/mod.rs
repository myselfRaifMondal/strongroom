//! Shared fixtures for the fuzz targets. Test code only.
//!
//! Argon2id at the frozen cost (256 MiB, t=3) makes the password path far
//! too slow to fuzz, so the targets that need to get past the slot table use
//! a device slot with a software P-256 key (the vectors' public test keys).
#![allow(dead_code)]

use p256::elliptic_curve::sec1::ToSec1Point;
use vtf_core::container::ExportRandomness;
use vtf_core::{DeviceKey, Field, Item, ItemData, ItemKind, Payload, Tombstone};
use zeroize::Zeroizing;

/// Software stand-in for a hardware key.
pub struct SoftDevice(pub p256::SecretKey);

impl SoftDevice {
    pub fn new(byte: u8) -> Self {
        SoftDevice(p256::SecretKey::from_slice(&[byte; 32]).expect("valid scalar"))
    }
}

impl DeviceKey for SoftDevice {
    fn public_key(&self) -> [u8; 65] {
        let p = self.0.public_key().to_sec1_point(false);
        p.as_bytes().try_into().expect("65 bytes")
    }
    fn agree(&self, peer: &[u8; 65]) -> Result<Zeroizing<[u8; 32]>, ()> {
        let peer = p256::PublicKey::from_sec1_bytes(peer).map_err(|_| ())?;
        let shared = p256::ecdh::diffie_hellman(self.0.to_nonzero_scalar(), peer.as_affine());
        let mut out = Zeroizing::new([0u8; 32]);
        out.copy_from_slice(shared.raw_secret_bytes());
        Ok(out)
    }
}

/// vectors/manifest.json devices a and b.
pub fn device_a() -> SoftDevice {
    SoftDevice::new(0x11)
}
pub fn device_b() -> SoftDevice {
    SoftDevice::new(0x22)
}

/// Fixed randomness (deterministic files; test only).
pub fn randomness(device_recipients: usize) -> ExportRandomness {
    ExportRandomness {
        salt: [0x40; 32],
        chunk_nonce_prefix: [0x80; 19],
        vtk: [0xC0; 32],
        password_slot_nonce: [0x20; 24],
        device: (0..device_recipients)
            .map(|i| ([0x50 + i as u8; 32], [0x60 + i as u8; 24]))
            .collect(),
    }
}

fn data(title: &str, notes_len: usize) -> ItemData {
    ItemData {
        kind: ItemKind::Login,
        title: title.into(),
        username: Some("alice@example.com".into()),
        password: Some("hunter2".into()),
        urls: vec!["https://example.com".into()],
        notes: Some("n".repeat(notes_len)),
        totp: None,
        folder: Some("Work".into()),
        tags: vec!["a".into(), "b".into()],
        fields: vec![Field {
            name: "pin".into(),
            value: "1234".into(),
            concealed: true,
        }],
        travel_safe: true,
    }
}

/// A valid payload whose encoding spans `chunks` chunks (1..=3).
pub fn sample_payload(chunks: usize) -> Payload {
    let per_item = 60_000;
    let n = chunks.max(1);
    let items = (0..n)
        .map(|i| Item {
            id: [i as u8; 16],
            created_at: 1_700_000_000,
            modified_at: 1_700_000_100,
            hlc: 42 + i as u64,
            data: data(&format!("item {i}"), if n == 1 { 10 } else { per_item }),
            history: vec![],
            trashed_at: None,
        })
        .collect();
    Payload {
        exported_at: 1_700_000_200,
        items,
        tombstones: vec![Tombstone {
            id: [0xEE; 16],
            deleted_at: 1,
            hlc: 2,
        }],
    }
}
