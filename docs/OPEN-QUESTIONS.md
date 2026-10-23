# Open questions

Each entry records the default that is implemented, so work does not stall.

## OQ-1 Android hardware key agreement requires API 31+
Default: device-bound export/import and biometric unlock via
`DeviceKeyAgreement` are gated on Android API 31+. Below 31 the features are
disabled and the UI says so; password unlock works everywhere.

## OQ-2 Recovery-code key slot (type 0x03) deferred
Default: not in VTF1. **A lost master password or Secret Key means permanent,
unrecoverable data loss.** The UI must say this plainly at vault creation and
when showing the Secret Key.

## OQ-3 Export passphrase
Default: export reuses the master password + Secret Key (password slot). No
separate export passphrase.

## OQ-4 "Entire header" for chunk AAD
The brief fixes "SHA-256 of the entire header" as chunk AAD and also fixes an
84-byte fixed header followed by slots. Default (SPEC-VTF §5): the AAD hash
covers the fixed header **and** the slot table, so slots are authenticated by
every chunk.

## OQ-5 iOS Credential Provider Extension memory budget vs Argon2id 256 MiB
Status: **not yet measured.** To be measured early in Phase 2 on a real
extension process; figure to be recorded here. If it does not fit, work stops
and is reported; the cost is not lowered.

## OQ-6 HIBP breach check
SHA-1 is required by the HIBP range API and is not in the security-core
crate allow-list. Default: the opt-in check is implemented in the platform
layer with the OS SHA-1 (CryptoKit / java.security / CNG), never in the core.
