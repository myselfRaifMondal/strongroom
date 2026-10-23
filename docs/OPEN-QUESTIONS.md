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

## OQ-7 HPKE receiver with non-exportable hardware keys (approved 2026-10-23)
The `hpke` crate needs the recipient private key, which Secure Enclave, TPM
and Android Keystore never release. Decision (owner-approved): the platform
performs the single P-256 ECDH in hardware (`DeviceKeyAgreement.agree`);
vtf-core composes RFC 9180 `ExtractAndExpand` and the base-mode key schedule
over the `hkdf` crate. The sender side stays on the `hpke` crate. Verified
against RFC 9180 Appendix A.3.1 (shared_secret, exporter_secret, all three
exported values) and against the `hpke` crate for the VTF ciphersuite.

## OQ-8 Dependencies added beyond the original allow-list
- `unicode-normalization` (vtf-core): NFKC for passwords. Owner-approved.
- `p256`, `ciborium` as **dev-dependencies only** of vtf-core: test oracles
  (software ECDH to drive the hardware path; an independent CBOR decoder).
  Not linked into any shipped artifact.
- `uniffi =0.31.0` (strongroom-ffi only, not the security core): pinned to the
  version supported by `uniffi-bindgen-cs` for the Windows C# bindings.
- `ciborium` is not used at runtime: VTF1 needs exact rejection of
  non-canonical encodings and must not leave unzeroized plaintext copies, so
  vtf-core has a small strict decoder/encoder; ciborium cross-checks it.

## OQ-9 Android: per-use biometric for KeyAgreement (Phase 2, android)
`BiometricPrompt.CryptoObject` has no `KeyAgreement` constructor (checked
against android-35), so a Keystore ECDH key cannot be bound to a single
biometric authentication (timeout 0). Default implemented: the P-256
`PURPOSE_AGREE_KEY` key uses `setUserAuthenticationParameters(10,
AUTH_BIOMETRIC_STRONG)` + `setInvalidatedByBiometricEnrollment(true)`, and the
app shows a strong BiometricPrompt immediately before **every** use (unlock,
device-key import). The key is therefore usable for up to 10 s after a
biometric, by this app only. Revisit when `CryptoObject(long operationHandle)`
(API 35) can be obtained for a KeyAgreement operation.

## OQ-10 Android: HIBP check not implemented (TODO)
The opt-in HIBP check (OQ-6) is out of scope for the Phase 2 Android app. The
APK requests no network permission at all, and CI
(`apps/android/scripts/check-no-network.sh`) fails if one appears. Adding the
check means adding `INTERNET` behind the opt-in and doing the SHA-1 range
query with `java.security.MessageDigest` in the platform layer.

## OQ-11 Android: autofill for native apps matches by package name
Autofill passes the page's web domain to `Vault.match_domain`; for native
apps (no web domain) it passes the Android package name (e.g.
`com.example.app`). Whether the core maps package names to domains (Digital
Asset Links are not consulted, as that needs network) is open.
