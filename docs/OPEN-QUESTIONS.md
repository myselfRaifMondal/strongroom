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
Status: **deferred.** The owner removed iOS from v1 on 2026-10-23, so the
iOS app and its Credential Provider Extension are not built and the memory
measurement has not been made. When iOS returns, the measurement comes
first; if 256 MiB does not fit, work stops and is reported. The cost is
never lowered.

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
- vault-core (Phase 2): `rusqlite` with `bundled-sqlcipher-vendored-openssl`
  and `backup` (owner-approved; pulls `libsqlite3-sys`, `openssl-src` at build
  time), `hmac` + `sha1` (TOTP only, owner-approved), `sha2`, `zeroize`,
  `subtle`; `p256` as a dev-dependency only. strongroom-ffi adds `zeroize`
  and a `p256` dev-dependency.
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
biometric, by this app only. Observed on the API 34 emulator: after a new
fingerprint is enrolled, Keystore2 reports `UserNotAuthenticated` (not
`KeyPermanentlyInvalidated`) even right after a successful BiometricPrompt;
the app treats that combination as "enrollment changed", deletes the key and
the wrapped vault key, and the gate then demands the password. Revisit when `CryptoObject(long operationHandle)`
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
Actions `windows-latest`. Observed on the runner (Windows 10.0.26100):
`Get-Tpm` reports TpmPresent False, and opening the Platform Crypto
Provider fails with 0x80090030 (NTE_DEVICE_NOT_READY). Where the PCP cannot create a P-256 key, Windows
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

## OQ-W6 Vault store overflowed the stack on Windows (resolved)
Resolved on phase2/core-vault (65b249b): the overflow was SQLCipher's
`cipher_memory_security` recursing after VirtualLock hit the working-set
quota. The setting is now off on all platforms; see OQ-12. Original report:
With phase2/core-vault merged (throwaway branch phase2/windows-with-core),
`Vault.create` crashes with a stack overflow on the windows-latest runner:
- from .NET, inside `uniffi_strongroom_ffi_fn_constructor_vault_create`,
  on a 1 MB thread-pool thread, on a 16 MB thread, and (experiment) on a
  512 MB thread, so it is not simply a large-but-bounded frame;
- in pure Rust, `cargo test --workspace` on Windows/MSVC:
  `vault_round_trip_through_vtf_and_device_unlock` (strongroom-ffi) and
  `decoy_first_matching` (vault-core) "overflowed its stack", while all
  vtf-core tests (including Argon2id at full cost) pass.
The Windows app cannot create or unlock a vault until this is fixed in the
core. The app, CLI and tests call the core on a 16 MB-stack thread
(`CoreThread`) as a precaution; that alone does not fix this crash.
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

## OQ-M6 macOS: folder hierarchy and sensitive sections without a format change
Default: a folder is the item's `folder` string read as a path ("Social/Instagram",
"Social / Instagram"); the app writes "A/B". Folders exist only through their
items, so a new empty folder lasts until the vault locks. Rename/move is
`update_item` on every live item in the subtree (each keeps the old folder in
its history; trashed items keep theirs). Favourites are the tag `favourite`,
templates the tag `template:<id>`. Recovery codes, security questions, 2FA
notes, PINs and seed words are custom fields named by the convention in
`apps/macos/Sources/StrongroomKit/SensitiveFields.swift`; a used recovery code
gets the name prefix `[used] ` (the value is never changed). Other clients show
these as ordinary tags and fields.

## OQ-M7 macOS: additional (decoy) vault
Default: the second vault is `vault-2.srdb` in the app data directory. Password
unlock always calls `unlock_first_matching([vault.srdb, vault-2.srdb])`, whether
or not the second file exists. The UI never names the open vault; the "create"
button is hidden for both vaults once the file exists. Not hidden from someone
who can list the data directory. Touch ID unlock opens the vault that was open
when Touch ID was turned on, recorded in `device-unlock-target.txt` ("1"/"2");
which vault that is gets found by wrapping the vault key to a throwaway
in-memory P-256 key and opening each file with it (no Argon2id, no prompt).

## OQ-M8 macOS: transfer key for pairing
Default: a separate Secure Enclave P-256 key (`transfer-key.se`) with
`.userPresence` (Touch ID or the login password), not the Touch ID unlock key:
it must survive fingerprint changes and Touch ID being turned off, or files
sealed to this Mac become unopenable. Its public key is the pairing payload;
paired devices' public keys live in `paired-devices.json` (0600, not secret).

## OQ-M9 macOS: organize by service, security ranking, rotation reminders
Default, all app-side (no FFI, UDL or format change):
- Organize by Service classifies a login by the registrable domain of its first
  URL against a built-in, generic map of well-known services
  (`StrongroomKit/ServiceCatalog.swift`; a small built-in list of multi-label
  suffixes such as .co.uk/.co.in, no public-suffix download). More than one
  account for a service: "<Category>/<Service>", title = username (careers/LMS
  portals keep the employer: "acme (user)"). One account: "<Category>",
  title "<Service> (<username>)". Unknown sites use "Other" and the domain
  ("Other/<domain>" once there are two accounts); no URL: "Other", title kept.
  Only `folder` and `title` change, via `update_item`, after a preview; undo
  holds the previous values in memory until lock. New logins get the same
  suggestion in the editor (editable; a second account offers to move the
  first into the service folder), and imports offer the preview for the new
  items. Setting: "Suggest folders for new items" (on).
- Risk score 0-100 (formula in `StrongroomKit/SecurityRanking.swift`):
  strength 40/30/18/8/0, reuse 0/25/30/35, age 0/5/10/15 (180/365/730 days),
  no TOTP 5, times 1.5 critical / 1.0 / 0.6 low; Critical >= 70, High >= 45,
  Medium >= 20. Critical = Email & Identity, Finance, Developer & Cloud (by
  folder, template, kind or URL) or tag `priority:critical`; `priority:low`
  lowers it. Reuse is found by comparing passwords in memory while unlocked;
  no hash or password is kept, and the result is dropped on lock. Age is
  counted from the last revision that changed the password (item history),
  not `modified_at`, because organizing changes `modified_at`.
- Due = age >= policy (critical 90 days, others 365; 30/60/90/180/365/never)
  OR reused OR strength <= 1. Banner after unlock; one repeating weekly
  local notification whose text is only a count ("Strongroom: 12 passwords
  are due for a change."), rescheduled on unlock and lock. Settings live in
  UserDefaults. Tested on the dev Mac (macOS 26, 2026-10-24) with an ad-hoc
  signed copy under a separate bundle id, launched directly and via `open`:
  `requestAuthorization` fails at once with UNErrorDomain code 1
  (notificationsNotAllowed) and no prompt appears. So for ad-hoc builds the
  unlock banner is the only reminder and Settings says so; a Developer ID
  signed build is expected to get the normal prompt (not verified).

## OQ-12 SQLCipher `cipher_memory_security` off on all platforms (owner-accepted)
Decision (owner, 2026-10-23): off everywhere for v1, documented as a residual
risk (THREAT-MODEL 4.11). With it on, SQLCipher mlocks every SQLite
allocation; when the OS lock quota runs out (Windows working-set quota;
small RLIMIT_MEMLOCK on Linux/Android) its own warning path allocates
through the same allocator and recurses until the stack overflows.
SQLCipher still wipes its key material on free; SQLite's page cache and
other general allocations are not wiped.

## OQ-13 Payload check precedence
The Python reference found inputs where vtf-core's reported check name
differed from SPEC-VTF 7's table order or RFC 8949. Resolution: SPEC-VTF 7
now states the precedence explicitly (encoding faults in stream order, then
schema checks, `payload-version` first among schema checks); vtf-core now
reports a stray break, ai=31 on majors 0/1/6 and a two-byte simple value
below 32 as `cbor-wellformed`; the `cbor-limit` vector was regenerated so
it carries a single fault (a valid item with a 65537-byte title). No byte
of the format and no positive vector changed.

## OQ-14 iOS out of scope for v1
Owner decision, 2026-10-23: iOS (app and Credential Provider Extension) is
removed from v1. macOS is built with SwiftPM and the Command Line Tools,
without Xcode (OQ-M2). The cross-platform round-trip covers macOS, Windows
and Android.
