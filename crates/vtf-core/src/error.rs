use core::fmt;

/// The named import checks of SPEC-VTF section 7, in specification order.
///
/// Every rejection of a file names exactly one of these. None of them carries
/// secret material.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Check {
    LengthMin,
    Magic,
    Version,
    FlagsReserved,
    KdfId,
    AeadId,
    KemId,
    Argon2Params,
    Reserved,
    SlotCount,
    SlotTable,
    FlagsDeviceSlots,
    Length,
    SlotUnwrap,
    ChunkAuth,
    CborWellformed,
    Padding,
    CborDeterministic,
    CborDuplicateKey,
    CborDepth,
    CborType,
    CborUnknownKey,
    CborMissingKey,
    CborEmptyOptional,
    CborLimit,
    PayloadVersion,
}

impl Check {
    pub const ALL: [Check; 26] = [
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
        Check::SlotUnwrap,
        Check::ChunkAuth,
        Check::CborWellformed,
        Check::Padding,
        Check::CborDeterministic,
        Check::CborDuplicateKey,
        Check::CborDepth,
        Check::CborType,
        Check::CborUnknownKey,
        Check::CborMissingKey,
        Check::CborEmptyOptional,
        Check::CborLimit,
        Check::PayloadVersion,
    ];

    /// The check name used in SPEC-VTF section 7 and in vector manifests.
    pub const fn name(self) -> &'static str {
        match self {
            Check::LengthMin => "length-min",
            Check::Magic => "magic",
            Check::Version => "version",
            Check::FlagsReserved => "flags-reserved",
            Check::KdfId => "kdf-id",
            Check::AeadId => "aead-id",
            Check::KemId => "kem-id",
            Check::Argon2Params => "argon2-params",
            Check::Reserved => "reserved",
            Check::SlotCount => "slot-count",
            Check::SlotTable => "slot-table",
            Check::FlagsDeviceSlots => "flags-device-slots",
            Check::Length => "length",
            Check::SlotUnwrap => "slot-unwrap",
            Check::ChunkAuth => "chunk-auth",
            Check::CborWellformed => "cbor-wellformed",
            Check::Padding => "padding",
            Check::CborDeterministic => "cbor-deterministic",
            Check::CborDuplicateKey => "cbor-duplicate-key",
            Check::CborDepth => "cbor-depth",
            Check::CborType => "cbor-type",
            Check::CborUnknownKey => "cbor-unknown-key",
            Check::CborMissingKey => "cbor-missing-key",
            Check::CborEmptyOptional => "cbor-empty-optional",
            Check::CborLimit => "cbor-limit",
            Check::PayloadVersion => "payload-version",
        }
    }

    pub fn from_name(name: &str) -> Option<Check> {
        Check::ALL.into_iter().find(|c| c.name() == name)
    }
}

impl fmt::Display for Check {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    /// The file failed the named check.
    Rejected(Check),
    /// The caller supplied invalid input to an export or key operation.
    InvalidInput(&'static str),
    /// The OS random number generator failed.
    Entropy,
}

impl Error {
    /// True for the one failure that the UI must show as a generic unlock
    /// failure (wrong password, Secret Key or device key).
    pub fn is_unlock_failure(&self) -> bool {
        matches!(self, Error::Rejected(Check::SlotUnwrap))
    }
}

impl From<Check> for Error {
    fn from(c: Check) -> Self {
        Error::Rejected(c)
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Rejected(c) => write!(f, "rejected by check `{c}`"),
            Error::InvalidInput(why) => write!(f, "invalid input: {why}"),
            Error::Entropy => f.write_str("system random number generator failed"),
        }
    }
}

impl std::error::Error for Error {}

pub type Result<T> = core::result::Result<T, Error>;
