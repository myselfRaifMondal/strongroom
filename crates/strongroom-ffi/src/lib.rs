//! Strongroom FFI crate: the single stable boundary between the Rust security
//! core and the native apps (SwiftUI, Jetpack Compose, WinUI 3).
//!
//! The contract is `src/strongroom.udl`, mirrored by the traits in
//! [`contract`]. The UniFFI-exported objects below are thin wrappers that
//! delegate through those traits.
// `unsafe` here comes only from UniFFI-generated scaffolding; hand-written
// code in this crate must not use it (enforced by `contract` and `types`).

pub mod contract;
pub mod types;

use std::fmt;
use contract::{StrongroomApi, UnlockGateApi, VaultApi, R};
pub use types::*;

uniffi::include_scaffolding!("strongroom");

/// Error returned across the FFI. Never carries secret material.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StrongroomError {
    UnlockFailed,
    FormatRejected { check: String },
    InvalidInput { reason: String },
    NotFound,
    Locked,
    Unsupported { reason: String },
    Storage { reason: String },
    Internal,
}

impl fmt::Display for StrongroomError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnlockFailed => f.write_str("unlock failed"),
            Self::FormatRejected { check } => write!(f, "file rejected: {check}"),
            Self::InvalidInput { reason } => write!(f, "invalid input: {reason}"),
            Self::NotFound => f.write_str("not found"),
            Self::Locked => f.write_str("vault is locked"),
            Self::Unsupported { reason } => write!(f, "unsupported: {reason}"),
            Self::Storage { reason } => write!(f, "storage error: {reason}"),
            Self::Internal => f.write_str("internal error"),
        }
    }
}

impl std::error::Error for StrongroomError {}

impl From<uniffi::UnexpectedUniFFICallbackError> for StrongroomError {
    fn from(_: uniffi::UnexpectedUniFFICallbackError) -> Self {
        // A failing hardware callback is indistinguishable from a wrong key.
        Self::UnlockFailed
    }
}

/// Implemented by each platform over non-exportable P-256 secure hardware.
pub trait DeviceKeyAgreement: Send + Sync {
    /// 65-byte uncompressed SEC1 public key.
    fn public_key(&self) -> Vec<u8>;
    /// Raw 32-byte ECDH shared secret with `peer_public_key`.
    fn agree(&self, peer_public_key: Vec<u8>) -> Result<Vec<u8>, StrongroomError>;
}

fn not_yet<T>() -> R<T> {
    Err(StrongroomError::Unsupported { reason: "not implemented".into() })
}

// ---------------------------------------------------------------- namespace

struct Core;

impl StrongroomApi for Core {
    fn generate_secret_key() -> String {
        String::new()
    }
    fn generate_password(_policy: PasswordPolicy) -> R<String> {
        not_yet()
    }
    fn generate_passphrase(_policy: PassphrasePolicy) -> R<String> {
        not_yet()
    }
    fn estimate_strength(_password: String) -> StrengthReport {
        StrengthReport { score: 0, entropy_bits: 0.0, warnings: vec![] }
    }
    fn totp_code(_secret: String, _now: i64) -> R<TotpCode> {
        not_yet()
    }
    fn vtf_inspect(_file: Vec<u8>) -> R<VtfInfo> {
        not_yet()
    }
    fn pairing_payload(_device_public_key: Vec<u8>) -> String {
        String::new()
    }
    fn parse_pairing_payload(_payload: String) -> R<PairedDevice> {
        not_yet()
    }
}

pub fn generate_secret_key() -> String {
    Core::generate_secret_key()
}
pub fn generate_password(policy: PasswordPolicy) -> R<String> {
    Core::generate_password(policy)
}
pub fn generate_passphrase(policy: PassphrasePolicy) -> R<String> {
    Core::generate_passphrase(policy)
}
pub fn estimate_strength(password: String) -> StrengthReport {
    Core::estimate_strength(password)
}
pub fn totp_code(secret: String, now: i64) -> R<TotpCode> {
    Core::totp_code(secret, now)
}
pub fn vtf_inspect(file: Vec<u8>) -> R<VtfInfo> {
    Core::vtf_inspect(file)
}
pub fn pairing_payload(device_public_key: Vec<u8>) -> String {
    Core::pairing_payload(device_public_key)
}
pub fn parse_pairing_payload(payload: String) -> R<PairedDevice> {
    Core::parse_pairing_payload(payload)
}

// --------------------------------------------------------------- UnlockGate

pub struct UnlockGate {
    _state_path: String,
}

impl UnlockGateApi for UnlockGate {
    fn new(state_path: String) -> R<Self> {
        Ok(Self { _state_path: state_path })
    }
    fn check(&self, _now: i64, _reboot: bool, _enroll: bool, _has_key: bool) -> PasswordRequiredReason {
        // Fail safe until implemented: always demand the password.
        PasswordRequiredReason::NoBiometricKey
    }
    fn record_password_unlock(&self, _now: i64) -> R<()> {
        not_yet()
    }
    fn record_biometric_failure(&self) -> R<()> {
        not_yet()
    }
    fn record_biometric_success(&self) -> R<()> {
        not_yet()
    }
}

impl UnlockGate {
    pub fn new(state_path: String) -> R<Self> {
        <Self as UnlockGateApi>::new(state_path)
    }
    pub fn check(&self, now: i64, rebooted: bool, enrollment_changed: bool, has_key: bool) -> PasswordRequiredReason {
        UnlockGateApi::check(self, now, rebooted, enrollment_changed, has_key)
    }
    pub fn record_password_unlock(&self, now: i64) -> R<()> {
        UnlockGateApi::record_password_unlock(self, now)
    }
    pub fn record_biometric_failure(&self) -> R<()> {
        UnlockGateApi::record_biometric_failure(self)
    }
    pub fn record_biometric_success(&self) -> R<()> {
        UnlockGateApi::record_biometric_success(self)
    }
}

// -------------------------------------------------------------------- Vault

pub struct Vault {
    _private: (),
}

impl VaultApi for Vault {
    fn create(_path: String, _password: String, _secret_key: String, _now: i64) -> R<Self> {
        not_yet()
    }
    fn unlock_with_password(_path: String, _password: String, _secret_key: String, _now: i64) -> R<Self> {
        not_yet()
    }
    fn unlock_first_matching(_paths: Vec<String>, _password: String, _secret_key: String, _now: i64) -> R<Self> {
        not_yet()
    }
    fn unlock_with_device_key(_path: String, _wrapped: Vec<u8>, _device: Box<dyn DeviceKeyAgreement>) -> R<Self> {
        not_yet()
    }
    fn lock(&self) {}
    fn is_locked(&self) -> bool {
        true
    }
    fn wrap_vault_key_for_device(&self, _pk: Vec<u8>) -> R<Vec<u8>> {
        not_yet()
    }
    fn add_item(&self, _input: ItemInput, _now: i64) -> R<String> {
        not_yet()
    }
    fn update_item(&self, _id: String, _input: ItemInput, _now: i64) -> R<()> {
        not_yet()
    }
    fn get_item(&self, _id: String) -> R<Item> {
        not_yet()
    }
    fn search(&self, _q: String, _folder: Option<String>, _tag: Option<String>) -> R<Vec<ItemSummary>> {
        not_yet()
    }
    fn match_domain(&self, _url: String) -> R<Vec<ItemSummary>> {
        not_yet()
    }
    fn item_history(&self, _id: String) -> R<Vec<ItemRevision>> {
        not_yet()
    }
    fn trash_item(&self, _id: String, _now: i64) -> R<()> {
        not_yet()
    }
    fn restore_item(&self, _id: String, _now: i64) -> R<()> {
        not_yet()
    }
    fn list_trash(&self) -> R<Vec<TrashEntry>> {
        not_yet()
    }
    fn purge_expired_trash(&self, _now: i64) -> R<u32> {
        not_yet()
    }
    fn list_folders(&self) -> R<Vec<String>> {
        not_yet()
    }
    fn list_tags(&self) -> R<Vec<String>> {
        not_yet()
    }
    fn item_totp(&self, _id: String, _now: i64) -> R<TotpCode> {
        not_yet()
    }
    fn password_health(&self, _now: i64) -> R<HealthReport> {
        not_yet()
    }
    fn set_travel_mode(&self, _enabled: bool, _now: i64) -> R<()> {
        not_yet()
    }
    fn travel_mode(&self) -> R<bool> {
        not_yet()
    }
    fn export_vtf(&self, _pw: String, _sk: String, _recipients: Vec<Vec<u8>>, _now: i64) -> R<Vec<u8>> {
        not_yet()
    }
    fn import_vtf(&self, _file: Vec<u8>, _pw: String, _sk: String, _now: i64) -> R<ImportSummary> {
        not_yet()
    }
    fn import_vtf_with_device_key(&self, _file: Vec<u8>, _device: Box<dyn DeviceKeyAgreement>, _now: i64) -> R<ImportSummary> {
        not_yet()
    }
    fn import_csv(&self, _source: CsvSource, _csv: String, _now: i64) -> R<ImportSummary> {
        not_yet()
    }
    fn backup_to(&self, _path: String) -> R<()> {
        not_yet()
    }
}

impl Vault {
    pub fn create(path: String, password: String, secret_key: String, now: i64) -> R<Self> {
        <Self as VaultApi>::create(path, password, secret_key, now)
    }
    pub fn unlock_with_password(path: String, password: String, secret_key: String, now: i64) -> R<Self> {
        <Self as VaultApi>::unlock_with_password(path, password, secret_key, now)
    }
    pub fn unlock_first_matching(paths: Vec<String>, password: String, secret_key: String, now: i64) -> R<Self> {
        <Self as VaultApi>::unlock_first_matching(paths, password, secret_key, now)
    }
    pub fn unlock_with_device_key(path: String, device_wrapped_key: Vec<u8>, device: Box<dyn DeviceKeyAgreement>) -> R<Self> {
        <Self as VaultApi>::unlock_with_device_key(path, device_wrapped_key, device)
    }
    pub fn lock(&self) {
        VaultApi::lock(self)
    }
    pub fn is_locked(&self) -> bool {
        VaultApi::is_locked(self)
    }
    pub fn wrap_vault_key_for_device(&self, device_public_key: Vec<u8>) -> R<Vec<u8>> {
        VaultApi::wrap_vault_key_for_device(self, device_public_key)
    }
    pub fn add_item(&self, input: ItemInput, now: i64) -> R<String> {
        VaultApi::add_item(self, input, now)
    }
    pub fn update_item(&self, id: String, input: ItemInput, now: i64) -> R<()> {
        VaultApi::update_item(self, id, input, now)
    }
    pub fn get_item(&self, id: String) -> R<Item> {
        VaultApi::get_item(self, id)
    }
    pub fn search(&self, query: String, folder: Option<String>, tag: Option<String>) -> R<Vec<ItemSummary>> {
        VaultApi::search(self, query, folder, tag)
    }
    pub fn match_domain(&self, url_or_domain: String) -> R<Vec<ItemSummary>> {
        VaultApi::match_domain(self, url_or_domain)
    }
    pub fn item_history(&self, id: String) -> R<Vec<ItemRevision>> {
        VaultApi::item_history(self, id)
    }
    pub fn trash_item(&self, id: String, now: i64) -> R<()> {
        VaultApi::trash_item(self, id, now)
    }
    pub fn restore_item(&self, id: String, now: i64) -> R<()> {
        VaultApi::restore_item(self, id, now)
    }
    pub fn list_trash(&self) -> R<Vec<TrashEntry>> {
        VaultApi::list_trash(self)
    }
    pub fn purge_expired_trash(&self, now: i64) -> R<u32> {
        VaultApi::purge_expired_trash(self, now)
    }
    pub fn list_folders(&self) -> R<Vec<String>> {
        VaultApi::list_folders(self)
    }
    pub fn list_tags(&self) -> R<Vec<String>> {
        VaultApi::list_tags(self)
    }
    pub fn item_totp(&self, id: String, now: i64) -> R<TotpCode> {
        VaultApi::item_totp(self, id, now)
    }
    pub fn password_health(&self, now: i64) -> R<HealthReport> {
        VaultApi::password_health(self, now)
    }
    pub fn set_travel_mode(&self, enabled: bool, now: i64) -> R<()> {
        VaultApi::set_travel_mode(self, enabled, now)
    }
    pub fn travel_mode(&self) -> R<bool> {
        VaultApi::travel_mode(self)
    }
    pub fn export_vtf(&self, password: String, secret_key: String, device_recipients: Vec<Vec<u8>>, now: i64) -> R<Vec<u8>> {
        VaultApi::export_vtf(self, password, secret_key, device_recipients, now)
    }
    pub fn import_vtf(&self, file: Vec<u8>, password: String, secret_key: String, now: i64) -> R<ImportSummary> {
        VaultApi::import_vtf(self, file, password, secret_key, now)
    }
    pub fn import_vtf_with_device_key(&self, file: Vec<u8>, device: Box<dyn DeviceKeyAgreement>, now: i64) -> R<ImportSummary> {
        VaultApi::import_vtf_with_device_key(self, file, device, now)
    }
    pub fn import_csv(&self, source: CsvSource, csv: String, now: i64) -> R<ImportSummary> {
        VaultApi::import_csv(self, source, csv, now)
    }
    pub fn backup_to(&self, path: String) -> R<()> {
        VaultApi::backup_to(self, path)
    }
}
