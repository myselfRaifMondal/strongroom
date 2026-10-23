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

## OQ-W1 Windows Hello gating of the TPM device key
Windows Hello's own key store (Microsoft Passport KSP / `KeyCredentialManager`)
creates RSA signing keys only, so it cannot host the P-256 ECDH key that
`DeviceKeyAgreement` needs. Default: the device key is created in the
Microsoft Platform Crypto Provider (TPM) as `ECDH_P256`, export policy 0
(non-exportable), usage `NCRYPT_ALLOW_KEY_AGREEMENT_FLAG` only, and every
`agree()` is preceded by a Windows Hello verification
(`UserConsentVerifierInterop.RequestVerificationForWindowAsync`). The Hello
gate is therefore enforced by the Strongroom process, not by the TPM.
`CngDeviceKey.Create` can additionally set `NCRYPT_UI_POLICY`
(`NCRYPT_UI_PROTECT_KEY_FLAG`), but on the PCP that adds a separate
TPM-key password/consent prompt rather than Hello, so it is off by default.
Owner decision needed if TPM-enforced gating is required.
`NCryptDeriveKey(BCRYPT_KDF_RAW_SECRET)` returns the x-coordinate
little-endian; it is reversed to big-endian before returning to the core.

## OQ-W2 No TPM on CI; hardware path unverified
There is no Windows dev machine; the app is built and run only on GitHub
Actions `windows-latest`. See the `probe` step of the windows workflow for
what the runner offers. Where the PCP cannot create a P-256 key, Windows
Hello unlock and device-bound export are disabled and the UI says so;
password unlock is unaffected. The NCrypt code path is exercised on CI with
the Microsoft Software KSP (identical calls, checked against .NET's ECDH),
but the TPM-backed path and the Hello prompt have not run on real hardware.

## OQ-W3 Hello enrollment-change signal on Windows
Desktop apps have no API to observe changes to the Windows Hello enrollment
set. Default: `enrollment_changed` is passed as `false`; the reboot,
5-failure and 7-day password checks still apply. Reboot is detected by
comparing the boot time recorded at the last password unlock.

## OQ-W4 HIBP opt-in on Windows
Out of scope for Phase 2 on Windows. The Windows app and CLI make no
network calls.

## OQ-W5 Auto-type limits
Auto-type uses `SendInput` (Unicode key events) only after the user has
seen the previously focused window's title and process and confirmed;
each confirmation is single-use and typing aborts if that exact window
cannot be brought back to the foreground. Windows UIPI blocks input into
elevated windows; the user is told when this happens.
