#![forbid(unsafe_code)]
//! The Strongroom FFI contract, as Rust traits.
//!
//! This module is the documented, compiler-checked mirror of
//! `strongroom.udl`. The exported UniFFI objects in `lib.rs` delegate every
//! call through these traits, so a signature drift between the UDL and the
//! traits fails to compile.
//!
//! FROZEN at the end of Phase 1. Changes after that point must be reported to
//! the project owner first.
//!
//! Invariants every implementation must uphold:
//! - Unlock failures of any cause return [`StrongroomError::UnlockFailed`]
//!   and nothing else; implementations must not short-circuit in a way that
//!   makes the cause observable through timing of the returned error.
//! - No secret (password, Secret Key, vault key, plaintext item data beyond
//!   what the method is defined to return) appears in an error value.
//! - The raw vault key never crosses this boundary.

use crate::types::*;
use crate::{DeviceKeyAgreement, StrongroomError};

pub type R<T> = Result<T, StrongroomError>;

/// Free functions (UDL `namespace strongroom`).
pub trait StrongroomApi {
    /// New random 128-bit Secret Key, formatted for display.
    fn generate_secret_key() -> String;
    fn generate_password(policy: PasswordPolicy) -> R<String>;
    fn generate_passphrase(policy: PassphrasePolicy) -> R<String>;
    fn estimate_strength(password: String) -> StrengthReport;
    /// `secret` is base32 or an `otpauth://` URI.
    fn totp_code(secret: String, now: i64) -> R<TotpCode>;
    /// Parses only the unauthenticated public header and slot table.
    fn vtf_inspect(file: Vec<u8>) -> R<VtfInfo>;
    fn pairing_payload(device_public_key: Vec<u8>) -> String;
    fn parse_pairing_payload(payload: String) -> R<PairedDevice>;
}

/// Non-secret unlock policy state (UDL `interface UnlockGate`).
///
/// Password is required: on first launch after reboot, after 5 failed
/// biometric attempts, every 7 days, and when biometric enrollment changes.
pub trait UnlockGateApi: Sized {
    fn new(state_path: String) -> R<Self>;
    fn check(
        &self,
        now: i64,
        rebooted_since_last_password: bool,
        enrollment_changed: bool,
        has_device_key: bool,
    ) -> PasswordRequiredReason;
    fn record_password_unlock(&self, now: i64) -> R<()>;
    fn record_biometric_failure(&self) -> R<()>;
    fn record_biometric_success(&self) -> R<()>;
}

/// An open (or locked) local vault (UDL `interface Vault`).
pub trait VaultApi: Sized {
    fn create(path: String, password: String, secret_key: String, now: i64) -> R<Self>;
    fn unlock_with_password(path: String, password: String, secret_key: String, now: i64)
        -> R<Self>;
    /// Decoy support: same error and comparable timing regardless of which,
    /// if any, path matches.
    fn unlock_first_matching(
        paths: Vec<String>,
        password: String,
        secret_key: String,
        now: i64,
    ) -> R<Self>;
    fn unlock_with_device_key(
        path: String,
        device_wrapped_key: Vec<u8>,
        device: Box<dyn DeviceKeyAgreement>,
    ) -> R<Self>;

    fn lock(&self);
    fn is_locked(&self) -> bool;
    fn wrap_vault_key_for_device(&self, device_public_key: Vec<u8>) -> R<Vec<u8>>;

    fn add_item(&self, input: ItemInput, now: i64) -> R<String>;
    fn update_item(&self, id: String, input: ItemInput, now: i64) -> R<()>;
    fn get_item(&self, id: String) -> R<Item>;
    fn search(&self, query: String, folder: Option<String>, tag: Option<String>)
        -> R<Vec<ItemSummary>>;
    fn match_domain(&self, url_or_domain: String) -> R<Vec<ItemSummary>>;
    fn item_history(&self, id: String) -> R<Vec<ItemRevision>>;
    fn trash_item(&self, id: String, now: i64) -> R<()>;
    fn restore_item(&self, id: String, now: i64) -> R<()>;
    fn list_trash(&self) -> R<Vec<TrashEntry>>;
    fn purge_expired_trash(&self, now: i64) -> R<u32>;
    fn list_folders(&self) -> R<Vec<String>>;
    fn list_tags(&self) -> R<Vec<String>>;
    fn item_totp(&self, id: String, now: i64) -> R<TotpCode>;
    fn password_health(&self, now: i64) -> R<HealthReport>;
    fn set_travel_mode(&self, enabled: bool, now: i64) -> R<()>;
    fn travel_mode(&self) -> R<bool>;

    fn export_vtf(
        &self,
        password: String,
        secret_key: String,
        device_recipients: Vec<Vec<u8>>,
        now: i64,
    ) -> R<Vec<u8>>;
    fn import_vtf(&self, file: Vec<u8>, password: String, secret_key: String, now: i64)
        -> R<ImportSummary>;
    fn import_vtf_with_device_key(
        &self,
        file: Vec<u8>,
        device: Box<dyn DeviceKeyAgreement>,
        now: i64,
    ) -> R<ImportSummary>;
    fn import_csv(&self, source: CsvSource, csv: String, now: i64) -> R<ImportSummary>;
    fn backup_to(&self, path: String) -> R<()>;
}
