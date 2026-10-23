#![forbid(unsafe_code)]
//! Conversions between the FFI contract types and vault-core / vtf-core.

use vault_core::{ItemData, ItemKind as CoreKind};
use vtf_core::device::{DeviceKey, PUBLIC_KEY_LEN};
use zeroize::{Zeroize, Zeroizing};

use crate::types::*;
use crate::{DeviceKeyAgreement, StrongroomError};

impl From<vault_core::Error> for StrongroomError {
    fn from(e: vault_core::Error) -> Self {
        use vault_core::Error as E;
        match e {
            E::UnlockFailed => StrongroomError::UnlockFailed,
            E::FormatRejected(c) => StrongroomError::FormatRejected { check: c.to_string() },
            E::InvalidInput(r) => StrongroomError::InvalidInput { reason: r.to_string() },
            E::NotFound => StrongroomError::NotFound,
            E::Unsupported(r) => StrongroomError::Unsupported { reason: r.to_string() },
            E::Storage(r) => StrongroomError::Storage { reason: r },
            E::Internal => StrongroomError::Internal,
        }
    }
}

impl From<vtf_core::Error> for StrongroomError {
    fn from(e: vtf_core::Error) -> Self {
        vault_core::Error::from(e).into()
    }
}

pub fn kind_in(k: ItemKind) -> CoreKind {
    match k {
        ItemKind::Login => CoreKind::Login,
        ItemKind::SecureNote => CoreKind::SecureNote,
        ItemKind::Card => CoreKind::Card,
        ItemKind::Identity => CoreKind::Identity,
        ItemKind::ApiKey => CoreKind::ApiKey,
        ItemKind::SshKey => CoreKind::SshKey,
    }
}

pub fn kind_out(k: CoreKind) -> ItemKind {
    match k {
        CoreKind::Login => ItemKind::Login,
        CoreKind::SecureNote => ItemKind::SecureNote,
        CoreKind::Card => ItemKind::Card,
        CoreKind::Identity => ItemKind::Identity,
        CoreKind::ApiKey => ItemKind::ApiKey,
        CoreKind::SshKey => ItemKind::SshKey,
    }
}

/// Moves the strings (no copies) into the zeroize-on-drop core type.
pub fn item_in(i: ItemInput) -> ItemData {
    ItemData {
        kind: kind_in(i.kind),
        title: i.title,
        username: i.username,
        password: i.password,
        urls: i.urls,
        notes: i.notes,
        totp: i.totp,
        folder: i.folder,
        tags: i.tags,
        fields: i
            .fields
            .into_iter()
            .map(|f| vault_core::Field { name: f.name, value: f.value, concealed: f.concealed })
            .collect(),
        travel_safe: i.travel_safe,
    }
}

/// Moves the strings out of the core type (which then drops empty).
pub fn item_out(mut d: ItemData) -> ItemInput {
    ItemInput {
        kind: kind_out(d.kind),
        title: core::mem::take(&mut d.title),
        username: d.username.take(),
        password: d.password.take(),
        urls: core::mem::take(&mut d.urls),
        notes: d.notes.take(),
        totp: d.totp.take(),
        folder: d.folder.take(),
        tags: core::mem::take(&mut d.tags),
        fields: d
            .fields
            .iter_mut()
            .map(|f| CustomField { name: core::mem::take(&mut f.name), value: core::mem::take(&mut f.value), concealed: f.concealed })
            .collect(),
        travel_safe: d.travel_safe,
    }
}

pub fn summary_out(s: vault_core::Summary) -> ItemSummary {
    ItemSummary {
        id: s.id,
        kind: kind_out(s.kind),
        title: s.title,
        subtitle: s.subtitle,
        folder: s.folder,
        tags: s.tags,
        urls: s.urls,
        modified_at: s.modified_at,
        has_totp: s.has_totp,
    }
}

pub fn import_out(s: vault_core::ImportSummary) -> ImportSummary {
    ImportSummary { added: s.added, updated: s.updated, unchanged: s.unchanged, conflicts: s.conflicts }
}

pub fn health_out(h: vault_core::HealthReport) -> HealthReport {
    HealthReport {
        security_score: h.security_score,
        reused_item_ids: h.reused_item_ids,
        weak_item_ids: h.weak_item_ids,
        old_item_ids: h.old_item_ids,
    }
}

pub fn totp_out(t: vault_core::totp::TotpCode) -> TotpCode {
    TotpCode { code: t.code, period: t.period, seconds_remaining: t.seconds_remaining }
}

pub fn csv_in(s: CsvSource) -> vault_core::CsvSource {
    match s {
        CsvSource::Bitwarden => vault_core::CsvSource::Bitwarden,
        CsvSource::OnePassword => vault_core::CsvSource::OnePassword,
        CsvSource::LastPass => vault_core::CsvSource::LastPass,
        CsvSource::Chrome => vault_core::CsvSource::Chrome,
    }
}

pub fn reason_out(r: vault_core::PasswordRequiredReason) -> PasswordRequiredReason {
    use vault_core::PasswordRequiredReason as C;
    match r {
        C::NotRequired => PasswordRequiredReason::NotRequired,
        C::FirstLaunchAfterReboot => PasswordRequiredReason::FirstLaunchAfterReboot,
        C::TooManyBiometricFailures => PasswordRequiredReason::TooManyBiometricFailures,
        C::PeriodicCheck => PasswordRequiredReason::PeriodicCheck,
        C::BiometricEnrollmentChanged => PasswordRequiredReason::BiometricEnrollmentChanged,
        C::NoBiometricKey => PasswordRequiredReason::NoBiometricKey,
    }
}

/// Moves a zeroizing string out without leaving a copy behind.
pub fn take_string(mut z: Zeroizing<String>) -> String {
    core::mem::take(&mut *z)
}

/// Adapts the platform callback to vtf-core's hardware-key trait. Any
/// callback failure or malformed result becomes the generic unlock failure.
pub struct Hardware<'a>(pub &'a dyn DeviceKeyAgreement);

impl DeviceKey for Hardware<'_> {
    fn public_key(&self) -> [u8; PUBLIC_KEY_LEN] {
        // A wrong-length key yields an all-zero key whose key_id never
        // matches, so the unlock fails generically.
        self.0.public_key().as_slice().try_into().unwrap_or([0u8; PUBLIC_KEY_LEN])
    }

    fn agree(&self, peer: &[u8; PUBLIC_KEY_LEN]) -> Result<Zeroizing<[u8; 32]>, ()> {
        let mut shared = self.0.agree(peer.to_vec()).map_err(|_| ())?;
        let out = <[u8; 32]>::try_from(shared.as_slice()).map(Zeroizing::new).map_err(|_| ());
        shared.zeroize();
        out
    }
}

pub fn lock_err<T>(_: T) -> StrongroomError {
    StrongroomError::Internal
}
