<p align="center"><img src="apps/macos/Resources/AppIcon-1024.png" width="128" alt="Strongroom icon"></p>

# Strongroom

A device-first, local-only password manager. Your vault lives encrypted on
your own devices. There is **no server, no account and no cloud sync**:
vaults move between devices only as encrypted files you transfer yourself.

One Rust security core does all the cryptography; each platform has a
native app on top of it.

| Platform | App | Status |
|----------|-----|--------|
| macOS    | SwiftUI (`apps/macos`) | Usable; built with SwiftPM, no Xcode needed |
| Windows  | WinUI 3 (`apps/windows`) | Builds and runs in CI; not yet hand-tested |
| Android  | Jetpack Compose (`apps/android`) | Runs on emulator; not yet hand-tested on devices |
| iOS      | — | Deferred (see [OQ-14](docs/OPEN-QUESTIONS.md)) |

> **Pre-release software.** It has not had an independent security audit.
> Keep a copy of your passwords elsewhere until it has.

## What it does

- Logins, secure notes, cards, identities, API keys, SSH keys, with custom
  fields, folders (as a tree), tags, favourites, search, item history and
  trash.
- Templates for things worth protecting: bank accounts, Wi-Fi, passports
  and IDs, recovery codes, crypto seed phrases, licences, servers and more.
- Several accounts per service, each with its own password and recovery
  codes (for example *Social › Instagram › @personal, @work*).
- Built-in TOTP codes, password and passphrase generator, strength meter.
- Security ranking: every password scored by strength, reuse, age and how
  important the account is, plus reminders to rotate them.
- Organize by service: files logins into a folder tree automatically.
- Touch ID / Windows Hello / Android biometrics via a hardware-held key; the
  master password is still required regularly.
- Import from Apple Passwords, Bitwarden, 1Password, LastPass and Chrome.
- Encrypted export/import between devices (the frozen **VTF** format),
  device pairing by QR code, travel mode and a decoy vault.
- Clipboard auto-clear, screen-capture exclusion, confirmed auto-type and a
  global quick-access overlay on desktop.
- No network access at all (an opt-in breach check is planned and will be
  off by default).

## How it is secured

- Master password **and** a 128-bit Secret Key are both needed to open a
  vault. Argon2id (256 MiB, t=3, p=4) + HKDF-SHA-256, XChaCha20-Poly1305,
  HPKE with P-256 for device-bound files, SQLCipher for the local store.
- No new cryptographic primitives: only audited RustCrypto crates.
- The file format is specified byte-for-byte in
  [docs/SPEC-VTF.md](docs/SPEC-VTF.md), with positive and negative test
  vectors in [vectors/](vectors/) and an independent Python reference
  implementation in [reference/](reference/) that reproduces them.
- Fuzzing, property tests, `cargo-audit` and cross-platform round-trip tests
  run in CI.
- Threat model: [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md).
  Reporting vulnerabilities: [docs/SECURITY.md](docs/SECURITY.md).

**There is no recovery.** If you lose your master password or your Secret
Key, your vault cannot be opened by anyone, including the developers.

## Build the macOS app

Needs the Rust toolchain and the Xcode Command Line Tools (full Xcode is not
required).

```bash
apps/macos/scripts/build-core.sh   # Rust core + Swift bindings (first run ~10 min)
apps/macos/scripts/build-app.sh    # SwiftUI app, ad-hoc signed
open apps/macos/out/Strongroom.app
```

Other platforms: see `apps/windows/` and `apps/android/`, and the CI
workflows in `.github/workflows/`.

## Repository layout

| Path | What |
|------|------|
| `crates/vtf-core` | The VTF transfer format: key hierarchy, chunked AEAD, strict CBOR |
| `crates/vault-core` | Encrypted local store, items, merge, TOTP, generator, audit, CSV import |
| `crates/strongroom-ffi` | The stable FFI contract (UniFFI) used by every app |
| `apps/` | Native apps for macOS, Windows, Android |
| `vectors/` | Normative test vectors for VTF1 |
| `reference/` | Independent Python reference implementation |
| `fuzz/` | cargo-fuzz targets |
| `docs/` | Spec, architecture, threat model, security policy, open questions |

## Contributing

Contributions are welcome, especially security review. Read
[CONTRIBUTING.md](CONTRIBUTING.md) first. Report vulnerabilities privately,
never in a public issue.

## Licence

Strongroom is free software, licensed under the
[GNU General Public License v3.0 or later](LICENSE). If you distribute a
modified version, you must publish its source under the same licence.
Third-party notices: [crates/vault-core/NOTICE](crates/vault-core/NOTICE).
