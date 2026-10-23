//! Encrypted local vault store and item logic for Strongroom.
//!
//! - [`store::Vault`]: SQLCipher database keyed with a random 32-byte vault
//!   key, wrapped in a plaintext header by an Argon2id-derived KEK
//!   ([`header`]); items, history, trash, tombstones, HLC merge of VTF
//!   imports, travel mode, decoys, backup.
//! - [`totp`], [`generator`], [`strength`], [`audit`], [`csv`],
//!   [`domain`], [`pairing`], [`gate`]: supporting logic.
//!
//! Pure Rust over audited crates; no network access of any kind.
#![forbid(unsafe_code)]

pub mod audit;
mod codec;
pub mod csv;
pub mod domain;
mod encoding;
pub mod error;
pub mod gate;
pub mod generator;
pub mod header;
pub mod pairing;
pub mod store;
pub mod strength;
pub mod totp;

pub use audit::HealthReport;
pub use csv::CsvSource;
pub use error::{Error, Result};
pub use gate::{PasswordRequiredReason, UnlockGate};
pub use store::{HistoryEntry, ImportSummary, ItemRecord, Summary, TrashEntry, Vault};
pub use vtf_core::{Field, ItemData, ItemKind};
