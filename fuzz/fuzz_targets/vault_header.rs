//! Plaintext vault header (`<vault>.hdr`, `vault_core::header`) and the
//! device key wrap blob. Both are read from disk before any authentication.
//!
//! The first input byte picks a mode:
//! - even: the rest is a whole header file and, at the same time, a device
//!   blob. A parsed header is exactly `HEADER_LEN` bytes and `to_bytes`
//!   gives the input back; `open_with_kek` and `unwrap_with_device` do not
//!   panic.
//! - odd: the rest is a list of (position, xor) byte pairs applied to a
//!   valid device blob for device a (at most 8 edits). The blob opens, with
//!   the right vault key, if and only if it is unchanged.
#![no_main]

mod common;

use std::sync::OnceLock;

use libfuzzer_sys::fuzz_target;
use vault_core::header::{unwrap_with_device, wrap_for_device, Header, HEADER_LEN};
use vtf_core::DeviceKey;
use zeroize::Zeroizing;

const VAULT_ID: [u8; 16] = [0x44; 16];
const VAULT_KEY: [u8; 32] = [0x55; 32];

fn base_blob() -> &'static [u8] {
    static B: OnceLock<Vec<u8>> = OnceLock::new();
    B.get_or_init(|| {
        let key = Zeroizing::new(VAULT_KEY);
        wrap_for_device(&key, &VAULT_ID, &common::device_a().public_key()).expect("wrap")
    })
}

fuzz_target!(|data: &[u8]| {
    let Some((&mode, rest)) = data.split_first() else {
        return;
    };
    let dev = common::device_a();
    if mode % 2 == 0 {
        if let Some(h) = Header::parse(rest) {
            assert_eq!(
                rest.len(),
                HEADER_LEN,
                "parsed a header of the wrong length"
            );
            assert!(h.to_bytes()[..] == *rest, "header does not round-trip");
            let _ = h.open_with_kek(&Zeroizing::new([0x33; 32]));
        }
        let _ = unwrap_with_device(rest, &VAULT_ID, &dev);
        return;
    }
    let base = base_blob();
    let mut blob = base.to_vec();
    for e in rest.chunks_exact(2).take(8) {
        let at = usize::from(e[0]) % blob.len();
        blob[at] ^= e[1];
    }
    match unwrap_with_device(&blob, &VAULT_ID, &dev) {
        Some(k) => {
            assert!(blob == base, "tampered device blob opened");
            assert_eq!(*k, VAULT_KEY, "wrong vault key");
        }
        None => assert!(blob != base, "valid device blob rejected"),
    }
});
