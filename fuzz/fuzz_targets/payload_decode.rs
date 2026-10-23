//! Strict CBOR / payload decoder (SPEC-VTF 6, checks 16-26).
//!
//! The fuzz input is the decrypted plaintext (CBOR item and any trailing
//! bytes), zero-extended to a whole number of chunks (at most 4), fed to the
//! decoder through the `#[cfg(fuzzing)]` hook `vtf_core::fuzz_decode_plaintext`
//! (the end-to-end path seals and opens HPKE per run and is ~100x slower;
//! `chunk_decrypt` covers it). One run in 64 also goes end to end through
//! `export_padded` + `import_with_device` and must agree with the hook.
//!
//! Invariants:
//! - nothing panics, and every failure is one of the payload checks 16-26;
//! - an accepted payload is canonical: re-encoding it with
//!   `vtf_core::payload::encode` reproduces the plaintext prefix exactly, and
//!   the rest of the plaintext is fewer than 65536 zero bytes.
#![no_main]

mod common;

use libfuzzer_sys::fuzz_target;
use vtf_core::container::{export_padded, CHUNK_PLAINTEXT};
use vtf_core::{import_with_device, Check, DeviceKey, Error};

const MAX_CHUNKS: usize = 4;

fuzz_target!(|data: &[u8]| {
    let data = &data[..data.len().min(MAX_CHUNKS * CHUNK_PLAINTEXT)];
    let chunks = data.len().div_ceil(CHUNK_PLAINTEXT).max(1);
    let mut plaintext = data.to_vec();
    plaintext.resize(chunks * CHUNK_PLAINTEXT, 0);

    let result = vtf_core::fuzz_decode_plaintext(&plaintext);
    match &result {
        Ok(p) => {
            let enc = vtf_core::payload::encode(p).expect("accepted payload must re-encode");
            assert!(
                plaintext.starts_with(&enc),
                "accepted payload is not canonical"
            );
            let pad = &plaintext[enc.len()..];
            assert!(
                pad.len() < CHUNK_PLAINTEXT && pad.iter().all(|&b| b == 0),
                "bad padding accepted"
            );
        }
        Err(Error::Rejected(c)) => {
            let idx = Check::ALL.iter().position(|x| x == c).expect("known check");
            let first_payload = Check::ALL
                .iter()
                .position(|x| *x == Check::CborWellformed)
                .unwrap();
            assert!(
                idx >= first_payload,
                "payload rejected by non-payload check {c}"
            );
        }
        Err(e) => panic!("rejected outside a named check: {e}"),
    }

    if data.first().is_some_and(|b| b % 64 == 0) {
        let dev = common::device_a();
        let file = export_padded(
            &plaintext,
            None,
            &[dev.public_key()],
            &common::randomness(1),
        )
        .expect("export");
        let e2e = import_with_device(&file, &dev);
        match (&result, &e2e) {
            (Ok(a), Ok(b)) => assert!(a == b, "hook and import disagree on the payload"),
            (Err(a), Err(b)) => assert_eq!(a, b, "hook and import disagree on the check"),
            _ => panic!("hook and import disagree on acceptance"),
        }
    }
});
