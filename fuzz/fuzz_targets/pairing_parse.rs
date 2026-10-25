//! Pairing payload parser (`vault_core::pairing::parse`): the
//! `SR1PAIR:<base32>` text read from another device's QR code or pasted.
//!
//! Input: the payload text (non-UTF-8 inputs are skipped). Invariants:
//! - nothing panics;
//! - an accepted payload is canonical: `payload(pk)` equals the trimmed
//!   input up to ASCII case, the key is a valid P-256 point, and the
//!   fingerprint is the one `fingerprint(pk)` gives;
//! - `parse(payload(pk))` gives the same key back.
#![no_main]

use libfuzzer_sys::fuzz_target;
use vault_core::pairing::{fingerprint, parse, payload};
use vtf_core::device::validate_public_key;

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else {
        return;
    };
    let Ok((pk, fp)) = parse(text) else {
        return;
    };
    let canonical = payload(&pk);
    assert!(
        canonical.eq_ignore_ascii_case(text.trim()),
        "accepted a non-canonical payload"
    );
    assert!(validate_public_key(&pk).is_ok(), "accepted an invalid key");
    assert_eq!(fp, fingerprint(&pk), "fingerprint mismatch");
    let (pk2, _) = parse(&canonical).expect("canonical payload must parse");
    assert_eq!(pk, pk2, "round trip changed the key");
});
