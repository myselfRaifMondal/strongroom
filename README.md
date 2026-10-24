<p align="center"><img src="apps/macos/Resources/AppIcon-1024.png" width="128" alt="Strongroom icon"></p>

# Strongroom

[![rust](https://github.com/myselfRaifMondal/strongroom/actions/workflows/rust.yml/badge.svg)](https://github.com/myselfRaifMondal/strongroom/actions/workflows/rust.yml)
[![macos](https://github.com/myselfRaifMondal/strongroom/actions/workflows/macos.yml/badge.svg)](https://github.com/myselfRaifMondal/strongroom/actions/workflows/macos.yml)
[![windows](https://github.com/myselfRaifMondal/strongroom/actions/workflows/windows.yml/badge.svg)](https://github.com/myselfRaifMondal/strongroom/actions/workflows/windows.yml)
[![android](https://github.com/myselfRaifMondal/strongroom/actions/workflows/android.yml/badge.svg)](https://github.com/myselfRaifMondal/strongroom/actions/workflows/android.yml)
[![crossplatform](https://github.com/myselfRaifMondal/strongroom/actions/workflows/crossplatform.yml/badge.svg)](https://github.com/myselfRaifMondal/strongroom/actions/workflows/crossplatform.yml)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)

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
> Publishing the source code lets people review it; it does not by itself
> make the software secure. Keep a copy of your passwords elsewhere until it
> has been audited.

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

## Security design

These are design goals and the checks that test them, not a guarantee.

- Master password **and** a 128-bit Secret Key are both needed to open a
  vault. Argon2id (256 MiB, t=3, p=4) + HKDF-SHA-256, XChaCha20-Poly1305,
  HPKE with P-256 for device-bound files, SQLCipher for the local store.
- No new cryptographic primitives: it composes existing, widely used
  RustCrypto crates (not all of which have had third-party audits).
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

## Known limitations

- **No independent security audit** yet.
- **macOS:** the app is ad-hoc signed and not notarized, so other Macs show
  a Gatekeeper warning on first launch, and weekly reminder notifications are
  unavailable (reminders appear as a banner on unlock instead). Built for
  macOS 14+, but only run on macOS 26.
- **Windows:** built and tested only on GitHub Actions runners. Windows Hello
  and the TPM-backed key have not been tested on real hardware, and the app
  enforces the Hello prompt rather than the TPM ([OQ-W1](docs/OPEN-QUESTIONS.md)).
- **Android:** tested on an emulator only. Autofill on real forms is
  untested, and biometric unlock uses a 10-second authorisation window rather
  than per-use binding ([OQ-9](docs/OPEN-QUESTIONS.md)). Device-key features
  need Android 12 (API 31) or later.
- **iOS:** not available.
- **Memory:** passwords passing through Swift, Kotlin or C# strings cannot be
  reliably wiped, and SQLite's page cache is not wiped on free
  ([OQ-12](docs/OPEN-QUESTIONS.md)).
- **Rollback:** replacing the local vault files with an older copy is not
  detected.
- **Breach checking** (Have I Been Pwned) is not implemented yet.
- Full list of open design questions: [docs/OPEN-QUESTIONS.md](docs/OPEN-QUESTIONS.md).

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

The headless CLI (`strongroom-mac-cli`) is documented in [apps/macos/CLI.md](apps/macos/CLI.md): build steps, the environment variables it reads, and one made-up-data example per command.

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

Contributions are welcome. The most valuable help right now:

- **Security review** of the format spec, the Rust core and the FFI
  boundary. Report findings privately (see below).
- **Testing on real hardware**: Windows Hello / TPM, Android devices and
  autofill, older macOS versions.
- **Independent implementations** of [SPEC-VTF](docs/SPEC-VTF.md) checked
  against [vectors/](vectors/). Disagreements with the spec are bugs worth
  reporting.
- **Fuzzing** for longer than the 60-second CI smoke runs.
- Issues labelled
  [good first issue](https://github.com/myselfRaifMondal/strongroom/labels/good%20first%20issue).

Start with [CONTRIBUTING.md](CONTRIBUTING.md): setup for each platform, the
project rules and the pull request checklist.

**Report vulnerabilities privately** with
[Report a vulnerability](https://github.com/myselfRaifMondal/strongroom/security/advisories/new),
never in a public issue.

## Licence

Strongroom is free software, licensed under the
[GNU General Public License v3.0 or later](LICENSE). If you distribute a
modified version, you must publish its source under the same licence.
Third-party notices: [crates/vault-core/NOTICE](crates/vault-core/NOTICE).
