//! Strongroom FFI crate: the single stable boundary between the Rust security
//! core and the native apps (SwiftUI, Jetpack Compose, WinUI 3).
//!
//! The contract is `src/strongroom.udl`, mirrored by the traits in
//! [`contract`]. The UniFFI-exported objects below are thin wrappers that
//! delegate through those traits.
// `unsafe` here comes only from UniFFI-generated scaffolding; hand-written
// code in this crate must not use it (enforced by `contract` and `types`).

mod bridge;
// Frozen file: kept byte-for-byte as approved, so rustfmt leaves it alone.
#[rustfmt::skip]
pub mod contract;
pub mod types;

use std::fmt;
use std::path::Path;
use std::sync::Mutex;

use bridge::*;
use contract::{StrongroomApi, UnlockGateApi, VaultApi, R};
pub use types::*;
use zeroize::Zeroizing;

/// UniFFI-generated scaffolding, isolated so lints on generated code (e.g.
/// `clippy::large_const_arrays` on newer toolchains) can be allowed narrowly.
#[allow(clippy::large_const_arrays)]
mod scaffolding {
    use super::*;
    uniffi::include_scaffolding!("strongroom");
}
#[allow(unused_imports)]
pub use scaffolding::*;

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

// ---------------------------------------------------------------- namespace

struct Core;

impl StrongroomApi for Core {
    fn generate_secret_key() -> String {
        // The signature cannot report errors; a failing OS CSPRNG is not
        // recoverable, so this panics (no secret in the message).
        take_string(
            vault_core::generator::generate_secret_key()
                .expect("OS random number generator failed"),
        )
    }
    fn generate_password(policy: PasswordPolicy) -> R<String> {
        let p = vault_core::generator::PasswordPolicy {
            length: policy.length,
            lowercase: policy.lowercase,
            uppercase: policy.uppercase,
            digits: policy.digits,
            symbols: policy.symbols,
            avoid_ambiguous: policy.avoid_ambiguous,
        };
        Ok(take_string(vault_core::generator::generate_password(&p)?))
    }
    fn generate_passphrase(policy: PassphrasePolicy) -> R<String> {
        let p = vault_core::generator::PassphrasePolicy {
            words: policy.words,
            separator: policy.separator,
            capitalize: policy.capitalize,
            include_number: policy.include_number,
        };
        Ok(take_string(vault_core::generator::generate_passphrase(&p)?))
    }
    fn estimate_strength(password: String) -> StrengthReport {
        let password = Zeroizing::new(password);
        let r = vault_core::strength::estimate(&password);
        StrengthReport {
            score: r.score,
            entropy_bits: r.entropy_bits,
            warnings: r.warnings,
        }
    }
    fn totp_code(secret: String, now: i64) -> R<TotpCode> {
        let secret = Zeroizing::new(secret);
        Ok(totp_out(vault_core::totp::totp_code(&secret, now)?))
    }
    fn vtf_inspect(file: Vec<u8>) -> R<VtfInfo> {
        let i = vtf_core::inspect(&file)?;
        Ok(VtfInfo {
            version: i.version,
            password_slots: i.password_slots,
            device_slots: i.device_slots,
            chunk_count: i.chunk_count,
        })
    }
    fn pairing_payload(device_public_key: Vec<u8>) -> String {
        vault_core::pairing::payload(&device_public_key)
    }
    fn parse_pairing_payload(payload: String) -> R<PairedDevice> {
        let (pk, fingerprint) = vault_core::pairing::parse(&payload)?;
        Ok(PairedDevice {
            public_key: pk.to_vec(),
            fingerprint,
        })
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
    inner: vault_core::UnlockGate,
}

impl UnlockGateApi for UnlockGate {
    fn new(state_path: String) -> R<Self> {
        Ok(Self {
            inner: vault_core::UnlockGate::new(state_path)?,
        })
    }
    fn check(&self, now: i64, reboot: bool, enroll: bool, has_key: bool) -> PasswordRequiredReason {
        reason_out(self.inner.check(now, reboot, enroll, has_key))
    }
    fn record_password_unlock(&self, now: i64) -> R<()> {
        Ok(self.inner.record_password_unlock(now)?)
    }
    fn record_biometric_failure(&self) -> R<()> {
        Ok(self.inner.record_biometric_failure()?)
    }
    fn record_biometric_success(&self) -> R<()> {
        Ok(self.inner.record_biometric_success()?)
    }
}

impl UnlockGate {
    pub fn new(state_path: String) -> R<Self> {
        <Self as UnlockGateApi>::new(state_path)
    }
    pub fn check(
        &self,
        now: i64,
        rebooted: bool,
        enrollment_changed: bool,
        has_key: bool,
    ) -> PasswordRequiredReason {
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

/// `None` once locked: locking drops the connection and zeroizes the key.
pub struct Vault {
    inner: Mutex<Option<vault_core::Vault>>,
}

impl Vault {
    fn open(v: vault_core::Vault) -> Self {
        Self {
            inner: Mutex::new(Some(v)),
        }
    }

    fn with<T>(&self, f: impl FnOnce(&mut vault_core::Vault) -> vault_core::Result<T>) -> R<T> {
        let mut guard = self.inner.lock().map_err(lock_err)?;
        let v = guard.as_mut().ok_or(StrongroomError::Locked)?;
        Ok(f(v)?)
    }
}

impl VaultApi for Vault {
    fn create(path: String, password: String, secret_key: String, now: i64) -> R<Self> {
        let (password, secret_key) = (Zeroizing::new(password), Zeroizing::new(secret_key));
        Ok(Self::open(vault_core::Vault::create(
            Path::new(&path),
            &password,
            &secret_key,
            now,
        )?))
    }
    fn unlock_with_password(
        path: String,
        password: String,
        secret_key: String,
        _now: i64,
    ) -> R<Self> {
        let (password, secret_key) = (Zeroizing::new(password), Zeroizing::new(secret_key));
        Ok(Self::open(vault_core::Vault::unlock_with_password(
            Path::new(&path),
            &password,
            &secret_key,
        )?))
    }
    fn unlock_first_matching(
        paths: Vec<String>,
        password: String,
        secret_key: String,
        _now: i64,
    ) -> R<Self> {
        let (password, secret_key) = (Zeroizing::new(password), Zeroizing::new(secret_key));
        let paths: Vec<&Path> = paths.iter().map(Path::new).collect();
        Ok(Self::open(vault_core::Vault::unlock_first_matching(
            &paths,
            &password,
            &secret_key,
        )?))
    }
    fn unlock_with_device_key(
        path: String,
        wrapped: Vec<u8>,
        device: Box<dyn DeviceKeyAgreement>,
    ) -> R<Self> {
        Ok(Self::open(vault_core::Vault::unlock_with_device_key(
            Path::new(&path),
            &wrapped,
            &Hardware(&*device),
        )?))
    }
    fn lock(&self) {
        // Even a poisoned lock must still drop the key.
        let mut guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        *guard = None;
    }
    fn is_locked(&self) -> bool {
        self.inner.lock().map(|g| g.is_none()).unwrap_or(true)
    }
    fn wrap_vault_key_for_device(&self, pk: Vec<u8>) -> R<Vec<u8>> {
        self.with(|v| v.wrap_vault_key_for_device(&pk))
    }
    fn add_item(&self, input: ItemInput, now: i64) -> R<String> {
        let data = item_in(input);
        self.with(|v| v.add_item(data, now))
    }
    fn update_item(&self, id: String, input: ItemInput, now: i64) -> R<()> {
        let data = item_in(input);
        self.with(|v| v.update_item(&id, data, now))
    }
    fn get_item(&self, id: String) -> R<Item> {
        let r = self.with(|v| v.get_item(&id))?;
        Ok(Item {
            id: r.id,
            created_at: r.created_at,
            modified_at: r.modified_at,
            data: item_out(r.data),
        })
    }
    fn search(
        &self,
        q: String,
        folder: Option<String>,
        tag: Option<String>,
    ) -> R<Vec<ItemSummary>> {
        let r = self.with(|v| v.search(&q, folder.as_deref(), tag.as_deref()))?;
        Ok(r.into_iter().map(summary_out).collect())
    }
    fn match_domain(&self, url: String) -> R<Vec<ItemSummary>> {
        let r = self.with(|v| v.match_domain(&url))?;
        Ok(r.into_iter().map(summary_out).collect())
    }
    fn item_history(&self, id: String) -> R<Vec<ItemRevision>> {
        let r = self.with(|v| v.item_history(&id))?;
        Ok(r.into_iter()
            .map(|h| ItemRevision {
                modified_at: h.modified_at,
                data: item_out(h.data),
            })
            .collect())
    }
    fn trash_item(&self, id: String, now: i64) -> R<()> {
        self.with(|v| v.trash_item(&id, now))
    }
    fn restore_item(&self, id: String, now: i64) -> R<()> {
        self.with(|v| v.restore_item(&id, now))
    }
    fn list_trash(&self) -> R<Vec<TrashEntry>> {
        let r = self.with(|v| v.list_trash())?;
        Ok(r.into_iter()
            .map(|t| TrashEntry {
                item: summary_out(t.item),
                deleted_at: t.deleted_at,
                purge_at: t.purge_at,
            })
            .collect())
    }
    fn purge_expired_trash(&self, now: i64) -> R<u32> {
        self.with(|v| v.purge_expired_trash(now))
    }
    fn list_folders(&self) -> R<Vec<String>> {
        self.with(|v| v.list_folders())
    }
    fn list_tags(&self) -> R<Vec<String>> {
        self.with(|v| v.list_tags())
    }
    fn item_totp(&self, id: String, now: i64) -> R<TotpCode> {
        self.with(|v| v.item_totp(&id, now)).map(totp_out)
    }
    fn password_health(&self, now: i64) -> R<HealthReport> {
        self.with(|v| v.password_health(now)).map(health_out)
    }
    fn set_travel_mode(&self, enabled: bool, now: i64) -> R<()> {
        self.with(|v| v.set_travel_mode(enabled, now))
    }
    fn travel_mode(&self) -> R<bool> {
        self.with(|v| v.travel_mode())
    }
    fn export_vtf(&self, pw: String, sk: String, recipients: Vec<Vec<u8>>, now: i64) -> R<Vec<u8>> {
        let (pw, sk) = (Zeroizing::new(pw), Zeroizing::new(sk));
        self.with(|v| v.export_vtf(&pw, &sk, &recipients, now))
    }
    fn import_vtf(&self, file: Vec<u8>, pw: String, sk: String, now: i64) -> R<ImportSummary> {
        let (pw, sk) = (Zeroizing::new(pw), Zeroizing::new(sk));
        self.with(|v| v.import_vtf(&file, &pw, &sk, now))
            .map(import_out)
    }
    fn import_vtf_with_device_key(
        &self,
        file: Vec<u8>,
        device: Box<dyn DeviceKeyAgreement>,
        now: i64,
    ) -> R<ImportSummary> {
        self.with(|v| v.import_vtf_with_device_key(&file, &Hardware(&*device), now))
            .map(import_out)
    }
    fn import_csv(&self, source: CsvSource, csv: String, now: i64) -> R<ImportSummary> {
        let csv = Zeroizing::new(csv);
        self.with(|v| v.import_csv(csv_in(source), &csv, now))
            .map(import_out)
    }
    fn backup_to(&self, path: String) -> R<()> {
        self.with(|v| v.backup_to(Path::new(&path)))
    }
}

impl Vault {
    pub fn create(path: String, password: String, secret_key: String, now: i64) -> R<Self> {
        <Self as VaultApi>::create(path, password, secret_key, now)
    }
    pub fn unlock_with_password(
        path: String,
        password: String,
        secret_key: String,
        now: i64,
    ) -> R<Self> {
        <Self as VaultApi>::unlock_with_password(path, password, secret_key, now)
    }
    pub fn unlock_first_matching(
        paths: Vec<String>,
        password: String,
        secret_key: String,
        now: i64,
    ) -> R<Self> {
        <Self as VaultApi>::unlock_first_matching(paths, password, secret_key, now)
    }
    pub fn unlock_with_device_key(
        path: String,
        device_wrapped_key: Vec<u8>,
        device: Box<dyn DeviceKeyAgreement>,
    ) -> R<Self> {
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
    pub fn search(
        &self,
        query: String,
        folder: Option<String>,
        tag: Option<String>,
    ) -> R<Vec<ItemSummary>> {
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
    pub fn export_vtf(
        &self,
        password: String,
        secret_key: String,
        device_recipients: Vec<Vec<u8>>,
        now: i64,
    ) -> R<Vec<u8>> {
        VaultApi::export_vtf(self, password, secret_key, device_recipients, now)
    }
    pub fn import_vtf(
        &self,
        file: Vec<u8>,
        password: String,
        secret_key: String,
        now: i64,
    ) -> R<ImportSummary> {
        VaultApi::import_vtf(self, file, password, secret_key, now)
    }
    pub fn import_vtf_with_device_key(
        &self,
        file: Vec<u8>,
        device: Box<dyn DeviceKeyAgreement>,
        now: i64,
    ) -> R<ImportSummary> {
        VaultApi::import_vtf_with_device_key(self, file, device, now)
    }
    pub fn import_csv(&self, source: CsvSource, csv: String, now: i64) -> R<ImportSummary> {
        VaultApi::import_csv(self, source, csv, now)
    }
    pub fn backup_to(&self, path: String) -> R<()> {
        VaultApi::backup_to(self, path)
    }
}
