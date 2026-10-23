//! Chunk decryption path (SPEC-VTF 5, checks 13-15) under structured
//! tampering of a valid file.
//!
//! The fuzzer chooses one of three valid device-bound files (1, 2 or 3
//! chunks; recipients a and b) and a sequence of up to 8 edits: bit flips,
//! byte writes, truncation, insertion, appending, and chunk swap / duplicate
//! / delete. Invariants:
//! - nothing panics;
//! - an unmodified file opens and yields exactly the exported payload;
//! - every modified file is rejected by a named check;
//! - if only chunk bytes changed (same length, header and slots intact), the
//!   rejection is `chunk-auth`.
#![no_main]

mod common;

use std::sync::OnceLock;

use libfuzzer_sys::fuzz_target;
use vtf_core::container::{export_with, CHUNK_LEN};
use vtf_core::{import_with_device, Check, Error, Payload};

struct Base {
    file: Vec<u8>,
    payload: Payload,
    chunks_start: usize,
}

fn bases() -> &'static [Base] {
    static B: OnceLock<Vec<Base>> = OnceLock::new();
    B.get_or_init(|| {
        let recipients = [
            vtf_core::DeviceKey::public_key(&common::device_a()),
            vtf_core::DeviceKey::public_key(&common::device_b()),
        ];
        (1..=3)
            .map(|c| {
                let payload = common::sample_payload(c);
                let file = export_with(&payload, None, &recipients, &common::randomness(2))
                    .expect("export");
                let n = (file.len() - 84 - 2 * 146) / CHUNK_LEN;
                assert_eq!(n, c, "fixture chunk count");
                Base {
                    chunks_start: 84 + 2 * 146,
                    file,
                    payload,
                }
            })
            .collect()
    })
}

fn u24(b: &[u8]) -> usize {
    (usize::from(b[0]) << 16) | (usize::from(b[1]) << 8) | usize::from(b[2])
}

fn apply(file: &mut Vec<u8>, start: usize, op: &[u8]) {
    let n_chunks = file.len().saturating_sub(start) / CHUNK_LEN;
    let chunk = |i: usize| start + i * CHUNK_LEN..start + (i + 1) * CHUNK_LEN;
    let len = file.len();
    match op[0] % 8 {
        0 if len > 0 => file[u24(&op[1..4]) % len] ^= 1 << (op[4] % 8),
        1 if len > 0 => file[u24(&op[1..4]) % len] = op[4],
        2 if len > 0 => file.truncate(u24(&op[1..4]) % len),
        3 if n_chunks > 1 => {
            let (i, j) = (usize::from(op[1]) % n_chunks, usize::from(op[4]) % n_chunks);
            if i != j {
                let a = file[chunk(i)].to_vec();
                let b = file[chunk(j)].to_vec();
                file[chunk(i)].copy_from_slice(&b);
                file[chunk(j)].copy_from_slice(&a);
            }
        }
        4 if n_chunks > 0 => {
            let i = usize::from(op[1]) % n_chunks;
            let copy = file[chunk(i)].to_vec();
            let at = chunk(i).end;
            file.splice(at..at, copy);
        }
        5 if n_chunks > 0 => {
            let i = usize::from(op[1]) % n_chunks;
            file.drain(chunk(i));
        }
        6 => {
            let at = u24(&op[1..4]) % (len + 1);
            file.insert(at, op[4]);
        }
        7 => file.push(op[4]),
        _ => {}
    }
}

fuzz_target!(|data: &[u8]| {
    let Some((&sel, ops)) = data.split_first() else {
        return;
    };
    let base = &bases()[usize::from(sel) % 3];
    let mut file = base.file.clone();
    for op in ops.chunks_exact(5).take(8) {
        apply(&mut file, base.chunks_start, op);
    }
    let result = import_with_device(&file, &common::device_a());
    if file == base.file {
        let p = result.unwrap_or_else(|e| panic!("valid file rejected: {e}"));
        assert!(p == base.payload, "decrypted payload differs");
        return;
    }
    match result {
        Ok(_) => panic!("tampered file accepted"),
        Err(Error::Rejected(c)) => {
            let only_chunks_changed = file.len() == base.file.len()
                && file[..base.chunks_start] == base.file[..base.chunks_start];
            if only_chunks_changed {
                assert_eq!(c, Check::ChunkAuth, "chunk tampering rejected by {c}");
            }
        }
        Err(e) => panic!("rejected outside a named check: {e}"),
    }
});
