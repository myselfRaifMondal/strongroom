use core::fmt;

/// Errors of the vault core. No variant ever carries secret material: SQLite
/// messages (which can quote SQL text) are reduced to a fixed operation name
/// and the numeric result code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// Wrong password, Secret Key or device key, or an unreadable vault
    /// header. Deliberately carries no detail.
    UnlockFailed,
    /// A file failed a structural or authentication check (VTF check name,
    /// or `rollback` for a stale import).
    FormatRejected(&'static str),
    InvalidInput(&'static str),
    NotFound,
    Unsupported(&'static str),
    Storage(String),
    Internal,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::UnlockFailed => f.write_str("unlock failed"),
            Error::FormatRejected(c) => write!(f, "file rejected: {c}"),
            Error::InvalidInput(r) => write!(f, "invalid input: {r}"),
            Error::NotFound => f.write_str("not found"),
            Error::Unsupported(r) => write!(f, "unsupported: {r}"),
            Error::Storage(r) => write!(f, "storage error: {r}"),
            Error::Internal => f.write_str("internal error"),
        }
    }
}

impl std::error::Error for Error {}

pub type Result<T> = core::result::Result<T, Error>;

impl From<vtf_core::Error> for Error {
    fn from(e: vtf_core::Error) -> Self {
        match e {
            vtf_core::Error::Rejected(vtf_core::Check::SlotUnwrap) => Error::UnlockFailed,
            vtf_core::Error::Rejected(c) => Error::FormatRejected(c.name()),
            vtf_core::Error::InvalidInput(r) => Error::InvalidInput(r),
            vtf_core::Error::Entropy => Error::Internal,
        }
    }
}

/// Maps a SQLite error to a detail-free storage error. The SQLite message is
/// dropped on purpose: it can quote SQL text.
pub(crate) fn db(op: &'static str) -> impl FnOnce(rusqlite::Error) -> Error {
    move |e| {
        let code = match &e {
            rusqlite::Error::SqliteFailure(f, _) => f.extended_code,
            _ => -1,
        };
        Error::Storage(format!("{op} failed (sqlite {code})"))
    }
}

pub(crate) fn io(op: &'static str) -> impl FnOnce(std::io::Error) -> Error {
    move |e| Error::Storage(format!("{op} failed ({:?})", e.kind()))
}
