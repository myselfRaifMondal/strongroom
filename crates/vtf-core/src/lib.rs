//! Vault Transfer Format (VTF) v1.
//!
//! The format is frozen; `docs/SPEC-VTF.md` is the normative byte-exact
//! specification. This crate is pure: no file system, network or clock.
#![forbid(unsafe_code)]

mod cbor;
pub mod container;
pub mod device;
pub mod error;
pub mod keys;
pub mod payload;

pub use container::{
    export, import_with_device, import_with_password, inspect, Info, PasswordCredentials,
};
pub use device::DeviceKey;
pub use error::{Check, Error, Result};
pub use keys::{Password, SecretKey};
pub use payload::{Field, Item, ItemData, ItemKind, Payload, Revision, Tombstone};

/// Fuzzing hook: SPEC-VTF checks 16-26 on an already-decrypted plaintext
/// (CBOR item || padding). Exists only when built with `--cfg fuzzing`
/// (cargo-fuzz sets it); never part of the shipped API.
#[cfg(fuzzing)]
#[doc(hidden)]
pub fn fuzz_decode_plaintext(plaintext: &[u8]) -> Result<Payload> {
    payload::decode_plaintext(plaintext)
}
