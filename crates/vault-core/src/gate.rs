//! Unlock policy gate: non-secret state, readable while the vault is locked.
//!
//! Password is required (instead of biometrics) when:
//! - there is no device-wrapped key (`NoBiometricKey`);
//! - the OS biometric enrollment set changed (`BiometricEnrollmentChanged`);
//! - this is the first launch since a reboot (`FirstLaunchAfterReboot`);
//! - 5 or more consecutive biometric failures (`TooManyBiometricFailures`);
//! - no password unlock was ever recorded, the last one is 7 days old or
//!   more, or the clock went backwards (`PeriodicCheck`).
//!
//! Checks are evaluated in that order. A missing state file means "never
//! unlocked with the password"; an unreadable or malformed one fails safe
//! (password required). The file is plain text:
//! `SRGATE1\n<last password unlock, Unix s, or ->\n<failure count>\n`.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::error::{io, Error, Result};

pub const MAX_BIOMETRIC_FAILURES: u32 = 5;
pub const PASSWORD_INTERVAL_SECS: i64 = 7 * 24 * 60 * 60;
const MAGIC: &str = "SRGATE1";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PasswordRequiredReason {
    NotRequired,
    FirstLaunchAfterReboot,
    TooManyBiometricFailures,
    PeriodicCheck,
    BiometricEnrollmentChanged,
    NoBiometricKey,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct State {
    last_password_unlock: Option<i64>,
    failures: u32,
}

pub struct UnlockGate {
    path: PathBuf,
}

/// A sibling of `path` with a name unique to this process and call:
/// `<path>.<pid>.<n>.<suffix>`. Leftovers of crashed writers are never
/// reused, and two writers never share one.
pub(crate) fn unique_sibling(path: &Path, suffix: &str) -> PathBuf {
    static N: AtomicU64 = AtomicU64::new(0);
    let mut s = path.as_os_str().to_owned();
    s.push(format!(
        ".{}.{}.{suffix}",
        std::process::id(),
        N.fetch_add(1, Ordering::Relaxed)
    ));
    PathBuf::from(s)
}

/// Makes completed renames and file creations in `path`'s directory
/// durable. Unix only: std cannot open a directory for syncing on Windows,
/// so there this is a no-op. A file system that cannot sync a directory
/// (`EINVAL`) is accepted.
pub(crate) fn sync_parent_dir(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        let dir = match path.parent() {
            Some(d) if !d.as_os_str().is_empty() => d,
            _ => Path::new("."),
        };
        let d = fs::File::open(dir).map_err(io("open dir"))?;
        match d.sync_all() {
            Err(e) if e.kind() != std::io::ErrorKind::InvalidInput => {
                return Err(io("sync dir")(e))
            }
            _ => {}
        }
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

/// Writes `bytes` to `path` durably: a uniquely named temporary file is
/// written and synced, renamed over `path`, then the directory is synced.
/// On failure `path` keeps its old content and the temporary file is
/// removed.
pub(crate) fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut attempt = 0;
    let (tmp, mut f) = loop {
        let tmp = unique_sibling(path, "tmp");
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)
        {
            Ok(f) => break (tmp, f),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists && attempt < 8 => attempt += 1,
            Err(e) => return Err(io("write")(e)),
        }
    };
    let written = f
        .write_all(bytes)
        .map_err(io("write"))
        .and_then(|_| f.sync_all().map_err(io("sync")));
    drop(f);
    if let Err(e) = written.and_then(|_| fs::rename(&tmp, path).map_err(io("rename"))) {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    sync_parent_dir(path)
}

impl UnlockGate {
    pub fn new(state_path: impl Into<PathBuf>) -> Result<Self> {
        let path = state_path.into();
        if path.as_os_str().is_empty() {
            return Err(Error::InvalidInput("empty state path"));
        }
        Ok(UnlockGate { path })
    }

    /// `None` = unreadable or malformed (fail safe).
    fn read(&self) -> Option<State> {
        let text = match fs::read_to_string(&self.path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Some(State {
                    last_password_unlock: None,
                    failures: 0,
                })
            }
            Err(_) => return None,
        };
        let mut lines = text.lines();
        if lines.next()? != MAGIC {
            return None;
        }
        let last = match lines.next()? {
            "-" => None,
            v => Some(v.parse().ok()?),
        };
        let failures = lines.next()?.parse().ok()?;
        if lines.next().is_some() {
            return None;
        }
        Some(State {
            last_password_unlock: last,
            failures,
        })
    }

    fn write(&self, s: State) -> Result<()> {
        let last = s
            .last_password_unlock
            .map_or_else(|| "-".to_string(), |v| v.to_string());
        write_atomic(
            &self.path,
            format!("{MAGIC}\n{last}\n{}\n", s.failures).as_bytes(),
        )
    }

    pub fn check(
        &self,
        now: i64,
        rebooted_since_last_password: bool,
        enrollment_changed: bool,
        has_device_key: bool,
    ) -> PasswordRequiredReason {
        use PasswordRequiredReason::*;
        if !has_device_key {
            return NoBiometricKey;
        }
        if enrollment_changed {
            return BiometricEnrollmentChanged;
        }
        if rebooted_since_last_password {
            return FirstLaunchAfterReboot;
        }
        let Some(s) = self.read() else {
            return PeriodicCheck;
        };
        if s.failures >= MAX_BIOMETRIC_FAILURES {
            return TooManyBiometricFailures;
        }
        match s.last_password_unlock {
            Some(t) if now >= t && now - t < PASSWORD_INTERVAL_SECS => NotRequired,
            _ => PeriodicCheck,
        }
    }

    /// A successful password unlock resets the failure count.
    pub fn record_password_unlock(&self, now: i64) -> Result<()> {
        self.write(State {
            last_password_unlock: Some(now),
            failures: 0,
        })
    }

    pub fn record_biometric_failure(&self) -> Result<()> {
        let s = self.read().unwrap_or(State {
            last_password_unlock: None,
            failures: MAX_BIOMETRIC_FAILURES,
        });
        self.write(State {
            failures: s.failures.saturating_add(1),
            ..s
        })
    }

    /// A biometric success resets the consecutive-failure count, unless the
    /// limit was already reached (only a password unlock clears that).
    pub fn record_biometric_success(&self) -> Result<()> {
        let s = self.read().unwrap_or(State {
            last_password_unlock: None,
            failures: MAX_BIOMETRIC_FAILURES,
        });
        if s.failures >= MAX_BIOMETRIC_FAILURES || s.failures == 0 {
            return Ok(());
        }
        self.write(State { failures: 0, ..s })
    }
}
