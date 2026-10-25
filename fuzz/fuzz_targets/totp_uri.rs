//! TOTP secret / `otpauth://` URI parser (`vault_core::totp`). These are
//! pasted by the user or come from imported CSV.
//!
//! Input: the secret or URI text (non-UTF-8 inputs are skipped).
//! Invariants:
//! - nothing panics;
//! - accepted parameters are in range (6-10 digits, period 1-3600 s);
//! - a code at a fixed time has exactly `digits` ASCII digits and
//!   1..=period seconds remaining, and `totp_code` gives the same code;
//! - a time before 1970 is rejected, not wrapped.
#![no_main]

use libfuzzer_sys::fuzz_target;
use vault_core::totp::{totp_code, TotpParams};

const NOW: i64 = 1_700_000_000;

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else {
        return;
    };
    let Ok(p) = TotpParams::parse(text) else {
        assert!(
            totp_code(text, NOW).is_err(),
            "totp_code accepted a bad secret"
        );
        return;
    };
    assert!((6..=10).contains(&p.digits), "digits out of range");
    assert!((1..=3600).contains(&p.period), "period out of range");
    let c = p.code(NOW).expect("code at a valid time");
    assert_eq!(c.code.len(), p.digits as usize, "wrong code length");
    assert!(
        c.code.bytes().all(|b| b.is_ascii_digit()),
        "non-digit in code"
    );
    assert!((1..=p.period).contains(&c.seconds_remaining));
    let c2 = totp_code(text, NOW).expect("totp_code agrees with parse");
    assert_eq!(c.code, c2.code, "totp_code and parse disagree");
    assert!(p.code(-1).is_err(), "time before 1970 accepted");
});
