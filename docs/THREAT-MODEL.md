# Threat model

Scope: the Strongroom apps (macOS, iOS, Android, Windows), the Rust core
(`vtf-core`, `vault-core`, `strongroom-ffi`) and the VTF1 transfer format.
There is no server, so there is no server-side attacker, account takeover or
breach of a hosted vault. Every threat below is against a device, a file, or
the person.

## 1. Assets

| Asset | Where it exists | Sensitivity |
|---|---|---|
| Vault contents (passwords, TOTP secrets, notes, cards, identities, keys, history, trash) | SQLCipher store on disk; decrypted in core memory while unlocked; shown in UI, clipboard, autofill | critical |
| Master password | user's memory; transiently in UI text fields and FFI strings | critical |
| Secret Key (128-bit, `SR1-…`) | printout / user's records; transiently in UI and FFI strings; never in a VTF file | critical (second factor) |
| Vault key, KEK, VTK, payload key, HPKE secrets | Rust core memory only, zeroized after use; never cross FFI | critical |
| Hardware device key (P-256) | Secure Enclave / TPM / Android Keystore, non-exportable | high: enables biometric unlock and device-bound imports |
| ECDH shared secret from `DeviceKeyAgreement.agree` | returned across FFI from platform to core | high: with the matching wrapped key or slot it unwraps that one key |
| VTF export files | wherever the user puts them (USB, AirDrop, cloud drive, email) | encrypted; confidentiality rests on password + Secret Key or device key |
| Device-wrapped vault key (`wrap_vault_key_for_device`) | platform keychain / credential store | encrypted to the hardware key |
| UnlockGate state (failed-biometric counter, last-password time) | plain file at `state_path`, sealed by the platform layer (residual risk 3) | low confidentiality, but it carries policy integrity |
| Metadata: item count, export time, file size | VTF file length (chunked to 64 KiB); `exported_at` is inside the ciphertext | low |

## 2. Adversaries

Mitigations in the Rust core and the VTF format are implemented and tested.
Mitigations credited to the platform apps (clipboard handling, capture
exclusion, masking, secure flags, biometric gating UI) are **requirements**
on those apps from `docs/ARCHITECTURE.md` and the FFI contract. This
document does not verify them.

### A1. Device thief (device powered off or locked)
Has the device and its storage, not the master password or Secret Key.
- The vault is encrypted at rest (SQLCipher). Opening it needs the
  password **and** the Secret Key (Argon2id 256 MiB, t=3, p=4, then HKDF),
  or the hardware key through a biometric prompt.
- Biometric unlock is gated by `UnlockGate`: the password is required on
  first launch after reboot, after 5 failed biometric attempts, every 7 days,
  and whenever the OS biometric enrollment changes. Hardware keys are
  non-exportable, so offline attacks need the password and the Secret Key.
- Residual: an attacker who can also read the user's Secret Key record
  (printed sheet, photo) is reduced to guessing the password at the frozen
  Argon2id cost.

### A2. Malware on an unlocked device
Runs as the user, or with accessibility / input-method / screen-reading
privileges, while the vault is unlocked.
- **Largely out of scope.** It can read what the app shows, the clipboard,
  keystrokes and process memory.
- Mitigations reduce exposure only: clipboard auto-clear (20–30 s) with
  OS clipboard-history exclusion, screen-capture exclusion on desktop,
  auto-type only after confirmation, secrets zeroized in the core.
- The raw vault key never crosses FFI, so malware that hooks the FFI layer
  gets item data it asks for, not the key. It does see passwords and Secret
  Keys typed into the UI.

### A3. File interceptor
Copies, modifies, truncates, reorders or replays a VTF file in transit.
- Confidentiality: AEAD under keys from password + Secret Key (password
  slot) or HPKE to a paired device's hardware key (device slot).
- Integrity: every chunk's AAD is `SHA256(fixed header ‖ slot table)`; the
  chunk nonce binds the index and a last-chunk flag. Any header, slot or
  chunk edit, chunk reorder, deletion, duplication or truncation fails
  authentication (checked by vectors, property tests and fuzzing).
- Downgrade: the importer requires the exact frozen algorithm IDs and Argon2
  parameters (raising or lowering either is rejected).
- Wrong-credential failures are one generic error, so the interceptor
  cannot learn which factor was wrong.
- Residual: **replay** of an older, validly encrypted export is not
  detected by the format; the vault's HLC merge decides what wins. The file
  size reveals the payload size to within 64 KiB.

### A4. Malicious import file
A crafted `.vtf` or CSV file aimed at crashing or exploiting the importer.
- Checks 1–13 (sizes, IDs, slot table, exact length) run before any key
  derivation or allocation proportional to attacker-declared sizes. A
  hostile file cannot make the importer run a stronger Argon2 (memory DoS)
  than the frozen 256 MiB.
- Decrypt-then-parse: no plaintext is parsed until every chunk has
  authenticated, so an attacker without the credentials cannot reach the
  CBOR decoder at all. With the credentials (or for CSV, which is not
  authenticated), the strict decoder enforces depth ≤ 16, length and count
  limits, and canonical encoding; `vtf-core` has `#![forbid(unsafe_code)]`.
- Fuzzed with libFuzzer + ASan: the VTF header and slot parser, chunk
  path and payload decoder, plus the CSV parser and column mapping, the
  pairing payload, TOTP / `otpauth://` URIs and the vault header and
  device wrap blob (`fuzz/`). CSV has no size or row limit; the whole
  file is held in memory.
- Residual: a 4096-chunk file means up to 256 MiB of plaintext in memory
  during import. That is a bounded but large allocation.

### A5. Shoulder-surfer / screen capture
- Passwords are masked by default and revealed only on request. The Secret
  Key is shown once at creation with a warning.
- Desktop: screen-capture exclusion for vault windows; mobile: OS secure
  flags where available (Android `FLAG_SECURE`, iOS app-switcher snapshot
  obscuring).
- Residual: a camera aimed at the screen or keyboard, and anything revealed
  on purpose.

### A6. Coerced unlock (border crossing, duress)
- **Travel mode** removes every item not marked `travel_safe` from the
  device's store; the full set stays only in exported/backup files kept
  elsewhere. Unlocking under coercion then reveals only travel-safe items.
- **Decoy vaults**: `unlock_first_matching` tries several vault paths with
  the same credentials, with identical error and comparable timing whether
  zero, one or several match. A decoy password can open a decoy vault.
- Residual: neither defeats a determined adversary. The existence of
  several vault files, or of travel mode, is visible to someone examining
  the device; travel-mode deletion is only as good as the storage's secure
  deletion (flash wear levelling may retain old pages, SQLCipher pages are
  encrypted); the user can be coerced into revealing the real password.

## 3. Trust boundaries

```
 user ── UI (Swift / Kotlin / C#) ──FFI── Rust core ──► storage (SQLCipher file, VTF files)
              │                              ▲
              │  DeviceKeyAgreement callback │ one ECDH result
              ▼                              │
        secure hardware (SE / TPM / Keystore) ┘
 platform ── HTTPS (opt-in only) ──► HIBP range API
```

| Boundary | What crosses | Rule |
|---|---|---|
| UI ↔ core (UniFFI, `strongroom.udl`, frozen) | passwords, Secret Keys, item fields as managed strings; summaries, errors | Raw keys never cross. Unlock failures are a single `UnlockFailed` with no detail. Errors carry no secrets. |
| Core ↔ secure hardware (`DeviceKeyAgreement`) | 65-byte public keys out; 32-byte ECDH x-coordinate back | The private key never leaves hardware. The core validates `enc` before the hardware sees it. Each use can require biometrics. |
| Core ↔ storage | SQLCipher pages, VTF bytes | Everything on disk is encrypted, except UnlockGate state, which is sealed by the platform layer. Imports are untrusted input (A4). |
| Device ↔ device | VTF file, user-carried | Untrusted channel (A3). Pairing compares a short fingerprint of the device public key on both screens. |
| App ↔ network | only the opt-in HIBP request: a 5-hex-char SHA-1 prefix | Product code makes no other network call. SHA-1 runs in the platform layer, never in the core. |
| Core ↔ OS clock / RNG | timestamps passed in by the caller; OS CSPRNG | The core never reads the clock. |

## 4. Residual risks (accepted, documented)

1. **No recovery: lost password or Secret Key means permanent data loss.**
   There is no recovery slot in VTF1 (OQ-2), no escrow, no server. The UI
   must say so at vault creation and when the Secret Key is shown.
2. **Swift / Kotlin / C# strings are not zeroizable.** Passwords, Secret
   Keys and item values cross FFI as managed strings and may persist in heap
   memory, swap or crash dumps until collected and overwritten. The same goes
   for the ECDH shared secret returned as `bytes` by `DeviceKeyAgreement`.
   The Rust side zeroizes its copies.
3. **UnlockGate state can be replayed, not edited.** The core file has no
   integrity protection of its own (format and FFI unchanged). Each platform
   keeps a seal next to it, made with a key that needs no user presence:
   a Secure Enclave P-256 signature on macOS, a Keystore HMAC-SHA256 key on
   Android, DPAPI (current user) on Windows. The seal covers the state file's
   name and bytes. A state file with a missing or wrong seal is deleted
   before the gate reads it, and the core treats a missing file as "password
   required", so editing the counter or the 7-day timer now forces the
   master password (issue #29). Existing installs ask for the password once
   after the update, because their state has no seal yet.
   Residual: an attacker who saved an earlier state file **and** its seal
   can put both back and so reset the failure counter to that earlier value
   (none of the platforms gives us a cheap monotonic counter). That only
   works within 7 days of the saved password unlock. The reboot and
   enrollment signals (`last-password-boot`, biometry state) are separate
   plain files and are not sealed. Malware running as the user on an unlocked
   device (A2) can make valid seals. Hardware-enforced biometric rate limits
   (Secure Enclave / Keystore / Windows Hello) still apply, and the vault key
   still needs the hardware ECDH. Replay protection and sealing the signal
   files are tracked in issue #45.
4. **HIBP breach check makes a network call** when the user turns it on.
   It sends a 5-character SHA-1 prefix (k-anonymity), and the timing and
   destination reveal that the user runs a breach check. Off by default.
5. **Clipboard exposure** between copy and auto-clear, to any app that can
   read the clipboard.
6. **Replay of old exports** (A3) and **size leakage** to 64 KiB.
7. **Device-bound imports trust the pairing step.** If a user pairs an
   attacker's public key (fingerprint not compared), later exports with that
   device slot are readable by the attacker.
8. **Unicode normalization drift**: NFKC runs in the Rust core
   (`unicode-normalization`), so every platform normalizes the same way. A
   future upgrade to a newer Unicode version could change the NFKC form of
   code points that were unassigned before. That would only affect passwords
   containing such code points.
9. **Argon2id memory on iOS extensions** (OQ-5): iOS is out of scope for
   v1 (owner decision, 2026-10-23), so this is unmeasured and deferred. If a
   future Credential Provider Extension cannot afford 256 MiB, that is a
   functional limit, not a reason to lower the cost.
10. **Check-name precedence in the payload decoder**: resolved. SPEC-VTF 7
    now states the precedence (encoding faults in stream order, then schema),
    vtf-core follows RFC 8949 for malformed heads, and the Python reference
    agrees on every vector in strict mode.
11. **SQLite memory is not wiped on free** (OQ-12). SQLCipher's
    `cipher_memory_security` is off on every platform: with it on, SQLCipher
    mlocks every allocation and, once the OS lock quota is exhausted,
    recurses until the stack overflows (seen on Windows). SQLCipher still
    wipes its own key material. Decrypted database pages in SQLite's page
    cache may remain in freed memory of an unlocked app until reused.
    Owner-accepted for v1.
12. **macOS stays unlocked in the background** (OQ-M10). With its windows
    closed the app keeps running in the menu bar, and the vault stays open
    in process memory until the Mac sleeps, the screen locks, the user
    switches or logs out, the user locks it, or the optional idle lock
    fires. This lengthens the time A2 applies.
