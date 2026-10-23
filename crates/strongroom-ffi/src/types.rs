#![forbid(unsafe_code)]
//! Plain data types of the FFI contract. Field-for-field mirrors of the UDL
//! dictionaries and enums.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ItemKind {
    Login,
    SecureNote,
    Card,
    Identity,
    ApiKey,
    SshKey,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CsvSource {
    Bitwarden,
    OnePassword,
    LastPass,
    Chrome,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PasswordRequiredReason {
    NotRequired,
    FirstLaunchAfterReboot,
    TooManyBiometricFailures,
    PeriodicCheck,
    BiometricEnrollmentChanged,
    NoBiometricKey,
}

#[derive(Clone, PartialEq, Eq)]
pub struct CustomField {
    pub name: String,
    pub value: String,
    pub concealed: bool,
}

#[derive(Clone, PartialEq, Eq)]
pub struct ItemInput {
    pub kind: ItemKind,
    pub title: String,
    pub username: Option<String>,
    pub password: Option<String>,
    pub urls: Vec<String>,
    pub notes: Option<String>,
    pub totp: Option<String>,
    pub folder: Option<String>,
    pub tags: Vec<String>,
    pub fields: Vec<CustomField>,
    pub travel_safe: bool,
}

#[derive(Clone, PartialEq, Eq)]
pub struct Item {
    pub id: String,
    pub data: ItemInput,
    pub created_at: i64,
    pub modified_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ItemSummary {
    pub id: String,
    pub kind: ItemKind,
    pub title: String,
    pub subtitle: Option<String>,
    pub folder: Option<String>,
    pub tags: Vec<String>,
    pub urls: Vec<String>,
    pub modified_at: i64,
    pub has_totp: bool,
}

#[derive(Clone, PartialEq, Eq)]
pub struct ItemRevision {
    pub modified_at: i64,
    pub data: ItemInput,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrashEntry {
    pub item: ItemSummary,
    pub deleted_at: i64,
    pub purge_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PasswordPolicy {
    pub length: u8,
    pub lowercase: bool,
    pub uppercase: bool,
    pub digits: bool,
    pub symbols: bool,
    pub avoid_ambiguous: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PassphrasePolicy {
    pub words: u8,
    pub separator: String,
    pub capitalize: bool,
    pub include_number: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct StrengthReport {
    pub score: u8,
    pub entropy_bits: f64,
    pub warnings: Vec<String>,
}

#[derive(Clone, PartialEq, Eq)]
pub struct TotpCode {
    pub code: String,
    pub period: u32,
    pub seconds_remaining: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HealthReport {
    pub security_score: u8,
    pub reused_item_ids: Vec<String>,
    pub weak_item_ids: Vec<String>,
    pub old_item_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VtfInfo {
    pub version: u16,
    pub password_slots: u8,
    pub device_slots: u8,
    pub chunk_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportSummary {
    pub added: u32,
    pub updated: u32,
    pub unchanged: u32,
    pub conflicts: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairedDevice {
    pub public_key: Vec<u8>,
    pub fingerprint: String,
}
