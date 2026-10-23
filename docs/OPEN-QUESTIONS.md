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

## OQ-M1 macOS: HIBP breach check not implemented
Default: out of scope for the macOS app in Phase 2. The app makes no network
calls at all. When it is added it follows OQ-6: opt-in, off by default, SHA-1
from CryptoKit (`Insecure.SHA1`) in the platform layer, k-anonymity range API.

## OQ-M2 macOS: built without Xcode, ad-hoc signed
Default: `apps/macos` is a SwiftPM package built with the Command Line Tools;
`scripts/build-app.sh` assembles `Strongroom.app` and signs it ad hoc
(hardened runtime, no entitlements). No certificate, no notarization, so on
another Mac Gatekeeper blocks it until the user allows it. The Secure Enclave
key needs no keychain entitlement: it is stored as its SE-encrypted
`dataRepresentation` in a 0600 file under ~/Library/Application Support/Strongroom.
With only the CLT, `swift test` needs extra flags (`scripts/test.sh`).

## OQ-M3 macOS: Touch ID enrollment change detection
Default: two signals feed `UnlockGate`'s `enrollment_changed`: the LocalAuthentication
domain-state hash stored at enrollment, and the Secure Enclave refusing the
`.biometryCurrentSet` key after a successful Touch ID check. After the next
password unlock the device key is recreated automatically. Not verified with a
real fingerprint change (manual test pending).

## OQ-M4 macOS: Secret Key not stored on the Mac
Default: password unlock asks for the master password and the Secret Key every
time; the Secret Key is never written to disk by the app. Touch ID unlock
avoids typing both. Storing the Secret Key locally (as 1Password does) would
be a deliberate product decision.

## OQ-M5 macOS: screen-capture exclusion
Default: every window (main, sheets, alerts, panels, quick-access overlay) gets
`NSWindow.sharingType = .none`. Verified as window-server sharing state 0 via
`CGWindowListCopyWindowInfo` (`scripts/window-sharing.swift`, also run in CI)
for every on-screen window. Exception: on the CI runner AppKit's off-screen
menu-bar backing windows (not in `NSApp.windows`, no app content) report
sharing state 1; the app cannot reach them. Whether a given capture API
honours `.none` is up to macOS.
