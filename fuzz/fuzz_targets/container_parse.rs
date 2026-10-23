//! Header and slot-table parser (SPEC-VTF checks 1-13) plus the device
//! unlock path (key_id match, HPKE Decap of an attacker-chosen `enc`).
//!
//! Input: an arbitrary byte string treated as a whole VTF file.
//! Invariants:
//! - nothing panics;
//! - `inspect` and `import_with_device` agree on checks 1-13: if `inspect`
//!   rejects, the import is rejected by the same check; if the import gets
//!   past the parser (slot-unwrap or later), `inspect` accepts;
//! - an accepted import implies `inspect` accepted.
#![no_main]

mod common;

use libfuzzer_sys::fuzz_target;
use vtf_core::{import_with_device, inspect, Check, Error};

const PARSER_CHECKS: [Check; 13] = [
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
];

fuzz_target!(|data: &[u8]| {
    let info = inspect(data);
    let dev = common::device_a();
    let imported = import_with_device(data, &dev);
    match (&info, &imported) {
        (Err(e), Err(f)) => assert_eq!(e, f, "inspect and import disagree on a parser check"),
        (Err(_), Ok(_)) => panic!("import accepted a file inspect rejected"),
        (Ok(i), Err(Error::Rejected(c))) => {
            assert!(
                !PARSER_CHECKS.contains(c),
                "import failed parser check {c} that inspect passed"
            );
            assert!(i.password_slots <= 1 && usize::from(i.password_slots + i.device_slots) <= 16);
            assert!((1..=4096).contains(&i.chunk_count));
        }
        (Ok(_), Err(e)) => panic!("import failed outside a named check: {e}"),
        (Ok(i), Ok(_)) => assert!(i.device_slots >= 1),
    }
});
