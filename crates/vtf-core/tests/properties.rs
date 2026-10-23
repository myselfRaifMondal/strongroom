//! Property tests driven by a tiny deterministic generator (SplitMix64), so no
//! property-testing crate is needed and every run checks the same cases.
//!
//! - random payloads round-trip through export -> import unchanged, and
//!   encoding is deterministic;
//! - every single-byte substitution in the header and slot table, and in a
//!   sample of chunk positions, is rejected; so are sampled single-byte
//!   insertions and deletions;
//! - chunk reordering, duplication, deletion and truncation are rejected,
//!   with and without patching `chunk_count`.
//!
//! The device path (software P-256 key) is used throughout: the password path
//! costs a 256 MiB Argon2id per import and is covered by the vector suite.

mod common;

use common::{randomness, SoftDevice, DEVICE_A_SK, DEVICE_B_SK};
use vtf_core::container::{export_with, CHUNK_LEN, DEVICE_SLOT_LEN, HEADER_LEN};
use vtf_core::device::DeviceKey;
use vtf_core::*;

/// SplitMix64 (Steele, Lea, Flood 2014). Deterministic; test use only.
struct Gen(u64);

impl Gen {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
    fn usize(&mut self, n: usize) -> usize {
        self.below(n as u64) as usize
    }
    fn bool(&mut self) -> bool {
        self.next() & 1 == 1
    }
    fn chance(&mut self, one_in: u64) -> bool {
        self.below(one_in) == 0
    }
    fn uint(&mut self) -> u64 {
        // Mix small and large values so every CBOR head width is exercised.
        match self.below(5) {
            0 => self.below(24),
            1 => self.below(0x100),
            2 => self.below(0x1_0000),
            3 => self.below(0x1_0000_0000),
            _ => self.next(),
        }
    }
    fn text(&mut self, max_chars: usize) -> String {
        const POOL: &[char] = &[
            'a',
            'Z',
            '0',
            ' ',
            '/',
            '\u{e9}',
            '\u{3b1}',
            '\u{4e2d}',
            '\u{1f512}',
            '\u{0}',
            '"',
        ];
        let n = self.usize(max_chars + 1);
        (0..n).map(|_| POOL[self.usize(POOL.len())]).collect()
    }
    fn opt_text(&mut self) -> Option<String> {
        self.bool().then(|| self.text(24))
    }
    fn texts(&mut self, max: usize) -> Vec<String> {
        let n = if self.bool() { 0 } else { 1 + self.usize(max) };
        (0..n).map(|_| self.text(12)).collect()
    }
    fn id(&mut self) -> [u8; 16] {
        core::array::from_fn(|_| self.next() as u8)
    }
    fn kind(&mut self) -> ItemKind {
        [
            ItemKind::Login,
            ItemKind::SecureNote,
            ItemKind::Card,
            ItemKind::Identity,
            ItemKind::ApiKey,
            ItemKind::SshKey,
        ][self.usize(6)]
    }
    fn data(&mut self) -> ItemData {
        let n_fields = if self.bool() { 0 } else { 1 + self.usize(4) };
        ItemData {
            kind: self.kind(),
            title: self.text(24),
            username: self.opt_text(),
            password: self.opt_text(),
            urls: self.texts(3),
            notes: if self.chance(16) {
                Some("n".repeat(40_000 + self.usize(25_536)))
            } else {
                self.opt_text()
            },
            totp: self.opt_text(),
            folder: self.opt_text(),
            tags: self.texts(4),
            fields: (0..n_fields)
                .map(|_| Field {
                    name: self.text(8),
                    value: self.text(16),
                    concealed: self.bool(),
                })
                .collect(),
            travel_safe: self.bool(),
        }
    }
    fn payload(&mut self) -> Payload {
        let items = (0..self.usize(5))
            .map(|_| Item {
                id: self.id(),
                created_at: self.uint(),
                modified_at: self.uint(),
                hlc: self.uint(),
                data: self.data(),
                history: (0..if self.chance(3) { 1 + self.usize(3) } else { 0 })
                    .map(|_| Revision {
                        modified_at: self.uint(),
                        data: self.data(),
                    })
                    .collect(),
                trashed_at: self.bool().then(|| self.uint()),
            })
            .collect();
        let tombstones = (0..if self.bool() { 0 } else { 1 + self.usize(3) })
            .map(|_| Tombstone {
                id: self.id(),
                deleted_at: self.uint(),
                hlc: self.uint(),
            })
            .collect();
        Payload {
            exported_at: self.uint(),
            items,
            tombstones,
        }
    }
}

fn device_a() -> SoftDevice {
    SoftDevice::new(&DEVICE_A_SK)
}

fn recipients() -> [[u8; 65]; 2] {
    [
        SoftDevice::new(&DEVICE_A_SK).public_key(),
        SoftDevice::new(&DEVICE_B_SK).public_key(),
    ]
}

fn export_ab(p: &Payload) -> Vec<u8> {
    export_with(p, None, &recipients(), &randomness(2)).expect("export")
}

fn chunk_count(file: &[u8]) -> usize {
    u32::from_be_bytes(file[76..80].try_into().unwrap()) as usize
}

fn set_chunk_count(file: &mut [u8], n: usize) {
    file[76..80].copy_from_slice(&(n as u32).to_be_bytes());
}

const SLOTS_END: usize = HEADER_LEN + 2 * DEVICE_SLOT_LEN;

fn must_reject(file: &[u8], what: &str) -> Check {
    match import_with_device(file, &device_a()) {
        Ok(_) => panic!("{what}: accepted"),
        Err(Error::Rejected(c)) => c,
        Err(e) => panic!("{what}: failed outside a named check: {e}"),
    }
}

#[test]
fn random_payloads_round_trip() {
    let mut g = Gen(0x5752_4F4F_4D31);
    let mut multi_chunk = 0;
    for case in 0..128 {
        let p = g.payload();
        let enc1 = payload::encode(&p).expect("encode");
        let enc2 = payload::encode(&p).expect("encode");
        assert_eq!(*enc1, *enc2, "case {case}: encoding is not deterministic");
        let file = export_ab(&p);
        multi_chunk += usize::from(chunk_count(&file) > 1);
        for dev in [SoftDevice::new(&DEVICE_A_SK), SoftDevice::new(&DEVICE_B_SK)] {
            let back =
                import_with_device(&file, &dev).unwrap_or_else(|e| panic!("case {case}: {e}"));
            assert!(back == p, "case {case}: payload changed in round trip");
            assert_eq!(
                *payload::encode(&back).unwrap(),
                *enc1,
                "case {case}: re-encoding differs"
            );
        }
    }
    assert!(
        multi_chunk > 0,
        "generator never produced a multi-chunk payload"
    );
}

#[test]
fn single_byte_mutations_are_rejected() {
    let mut g = Gen(0xB17F_11B5);
    let file = export_ab(&g.payload());
    assert!(import_with_device(&file, &device_a()).is_ok());

    let pre_payload = [
        Check::LengthMin,
        Check::Magic,
        Check::Version,
        Check::FlagsReserved,
        Check::KdfId,
        Check::AeadId,
        Check::KemId,
        Check::Argon2Params,
        Check::Reserved,
        Check::SlotCount,
        Check::SlotTable,
        Check::FlagsDeviceSlots,
        Check::Length,
        Check::SlotUnwrap,
        Check::ChunkAuth,
    ];
    let mut positions: Vec<usize> = (0..SLOTS_END).collect(); // every header and slot byte
    positions.extend(SLOTS_END..SLOTS_END + 16); // first chunk bytes
    positions.extend(file.len() - 32..file.len()); // last ciphertext bytes and tag
    positions.extend((0..256).map(|_| SLOTS_END + g.usize(file.len() - SLOTS_END)));
    for &pos in &positions {
        let mut m = file.clone();
        m[pos] ^= 1 + g.below(255) as u8;
        let c = must_reject(&m, &format!("substitution at {pos}"));
        assert!(
            pre_payload.contains(&c),
            "substitution at {pos} reached payload check {c}"
        );
        if pos >= SLOTS_END {
            assert_eq!(c, Check::ChunkAuth, "substitution at chunk byte {pos}");
        }
    }
    for _ in 0..48 {
        let pos = g.usize(file.len());
        let mut del = file.clone();
        del.remove(pos);
        must_reject(&del, &format!("deletion at {pos}"));
        let mut ins = file.clone();
        ins.insert(g.usize(file.len() + 1), g.next() as u8);
        must_reject(&ins, &format!("insertion near {pos}"));
    }
}

#[test]
fn chunk_reorder_duplicate_delete_truncate_are_rejected() {
    // A payload spanning exactly three chunks.
    let mut g = Gen(0xC4C4_C4C4);
    let mut p = g.payload();
    let mut data = g.data();
    data.notes = Some("x".repeat(65_000));
    p.items = (0..3)
        .map(|i| Item {
            id: [i; 16],
            created_at: 1,
            modified_at: 2,
            hlc: 3,
            data: data.clone(),
            history: vec![],
            trashed_at: None,
        })
        .collect();
    let file = export_ab(&p);
    let n = chunk_count(&file);
    assert_eq!(n, 3, "fixture must have three chunks");
    assert!(import_with_device(&file, &device_a()).is_ok());
    let chunk =
        |f: &[u8], i: usize| f[SLOTS_END + i * CHUNK_LEN..SLOTS_END + (i + 1) * CHUNK_LEN].to_vec();
    let build = |order: &[usize], count: Option<usize>| {
        let mut f = file[..SLOTS_END].to_vec();
        if let Some(c) = count {
            set_chunk_count(&mut f, c);
        }
        for &i in order {
            f.extend(chunk(&file, i));
        }
        f
    };

    // Every non-identity permutation.
    for order in [[0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
        assert_eq!(
            must_reject(&build(&order, None), &format!("order {order:?}")),
            Check::ChunkAuth
        );
    }
    // Duplication in place of another chunk (same length).
    for order in [[0, 0, 2], [0, 1, 1], [2, 1, 2], [0, 0, 0]] {
        assert_eq!(
            must_reject(&build(&order, None), &format!("order {order:?}")),
            Check::ChunkAuth
        );
    }
    // Deleting, appending or duplicating chunks; header unchanged -> length.
    for order in [
        &[0, 1][..],
        &[0, 2],
        &[1, 2],
        &[0],
        &[0, 1, 2, 2],
        &[0, 1, 2, 0],
        &[0, 0, 1, 2],
    ] {
        assert_eq!(
            must_reject(&build(order, None), &format!("order {order:?}")),
            Check::Length
        );
    }
    // Same, with chunk_count patched to match: the fixed header is bound into
    // every slot, so the slot no longer unwraps.
    for order in [
        &[0, 1][..],
        &[0, 2],
        &[1, 2],
        &[0],
        &[2],
        &[0, 1, 2, 2],
        &[0, 1, 1, 2],
    ] {
        let c = must_reject(
            &build(order, Some(order.len())),
            &format!("recounted {order:?}"),
        );
        assert_eq!(c, Check::SlotUnwrap, "recounted {order:?}");
    }
    // Truncation at every chunk boundary and at sampled offsets.
    let mut cuts: Vec<usize> = (0..=n)
        .map(|i| SLOTS_END + i * CHUNK_LEN)
        .filter(|&c| c < file.len())
        .collect();
    cuts.extend((0..64).map(|_| g.usize(file.len())));
    cuts.extend([
        0,
        1,
        HEADER_LEN - 1,
        HEADER_LEN,
        SLOTS_END - 1,
        file.len() - 1,
    ]);
    for cut in cuts {
        must_reject(&file[..cut], &format!("truncated to {cut}"));
    }
}
