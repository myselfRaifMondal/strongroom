//! CSV import (`vault_core::csv`): the hand-written RFC 4180 parser and the
//! column mapping for every `CsvSource`. CSV files are not authenticated
//! (THREAT-MODEL A4), so anyone who hands the user a file reaches this code.
//!
//! Input: the CSV text (inputs that are not UTF-8 are skipped; the core API
//! takes `&str`). Invariants:
//! - nothing panics;
//! - `parse` is stable: quoting every field of the parsed rows and parsing
//!   that text again gives the same rows;
//! - `items` fails with the parser's error whenever `parse` fails, and
//!   otherwise yields at most one item per non-header row.
#![no_main]

use libfuzzer_sys::fuzz_target;
use vault_core::csv::{items, parse};
use vault_core::CsvSource;

const SOURCES: [CsvSource; 4] = [
    CsvSource::Bitwarden,
    CsvSource::OnePassword,
    CsvSource::LastPass,
    CsvSource::Chrome,
];

fn quote_all(rows: &[Vec<String>]) -> String {
    rows.iter()
        .map(|r| {
            r.iter()
                .map(|f| format!("\"{}\"", f.replace('"', "\"\"")))
                .collect::<Vec<_>>()
                .join(",")
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else {
        return;
    };
    let parsed = parse(text);
    if let Ok(rows) = &parsed {
        assert!(rows.iter().all(|r| !r.is_empty()), "empty row");
        let again = parse(&quote_all(rows)).expect("re-quoted rows must parse");
        assert!(*again == **rows, "re-quoted rows parse differently");
    }
    for source in SOURCES {
        let result = items(source, text);
        match (&parsed, &result) {
            (Err(e), Err(f)) => assert_eq!(e, f, "items and parse disagree on the error"),
            (Err(_), Ok(_)) => panic!("items accepted text that parse rejected"),
            (Ok(rows), Ok(out)) => assert!(out.len() <= rows.len().saturating_sub(1)),
            (Ok(_), Err(_)) => {}
        }
    }
});
