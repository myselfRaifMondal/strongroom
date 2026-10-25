# Contributing to Strongroom

Thanks for helping. Everyone taking part agrees to the
[Code of Conduct](CODE_OF_CONDUCT.md). Strongroom stores people's most
sensitive data, so the bar for changes is high and the rules below are
strict on purpose.

## Security issues

**Never** open a public issue or pull request for a vulnerability. Use
GitHub's private **Security → Report a vulnerability** form. See
[docs/SECURITY.md](docs/SECURITY.md).

## Getting started

You need Rust (installed with [rustup](https://rustup.rs); the repository
pins the exact version in `rust-toolchain.toml` and rustup installs it on
first use) and
[uv](https://docs.astral.sh/uv/) for the Python reference implementation.

```bash
git clone https://github.com/myselfRaifMondal/strongroom.git
cd strongroom
cargo test --workspace          # Rust core, FFI and all format test vectors
```

The first build compiles SQLCipher and OpenSSL from source and takes several
minutes. Each password-based test runs Argon2id at the real cost (256 MiB of
memory), so the full suite needs a few minutes and about 1 GB of free RAM.

### Platform apps

| Platform | Needs | Build and test |
|----------|-------|----------------|
| macOS | Xcode Command Line Tools (full Xcode not required) | `apps/macos/scripts/build-core.sh`, then `build-app.sh` and `test.sh` |
| Android | JDK 17, Android SDK + NDK 27, `cargo install cargo-ndk` | `apps/android/scripts/build-rust.sh`, then `./gradlew assembleDebug testDebugUnitTest` in `apps/android` |
| Windows | Windows 10/11, Rust MSVC toolchain, .NET 8 SDK, `uniffi-bindgen-cs` | `apps/windows/scripts/build-native.ps1`, then `gen-bindings.ps1`, then `dotnet build` |

The workflows in `.github/workflows/` show the exact, tested commands for
each platform. The Windows installers (Inno Setup, x64 and ARM64) are built
and smoke-tested by `windows-installer.yml` from `apps/windows/installer/`;
the end-user guide is [apps/windows/INSTALL.md](apps/windows/INSTALL.md).
Releases (all platforms, signing secrets) are described in
[docs/RELEASING.md](docs/RELEASING.md).

### Where things are

- `crates/vtf-core`: the transfer format. Start with `container.rs` and
  [docs/SPEC-VTF.md](docs/SPEC-VTF.md).
- `crates/vault-core`: the local store and item logic.
- `crates/strongroom-ffi`: `strongroom.udl` is the contract every app uses.
- `apps/<platform>`: the native apps.
- `vectors/`, `reference/`, `fuzz/`: format test vectors, the independent
  Python implementation and fuzz targets. [fuzz/README.md](fuzz/README.md)
  explains how to run long fuzzing locally.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
  [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md) and
  [docs/OPEN-QUESTIONS.md](docs/OPEN-QUESTIONS.md) explain the design and
  its known gaps.

## Finding something to work on

- Issues labelled **good first issue** are small and self-contained.
- Issues labelled **help wanted** need someone with a specific skill or
  device (for example a Windows machine with a TPM).
- The open questions in [docs/OPEN-QUESTIONS.md](docs/OPEN-QUESTIONS.md)
  and the "Known limitations" in the README are good sources of larger
  work. Comment on or open an issue before you start, so nobody duplicates
  effort.

### Your first contribution

You do not need to build every platform to help. Some starting points that
need only one toolchain:

| You know | Try | You need |
|----------|-----|----------|
| Rust | A CSV importer fix or a new importer in `crates/vault-core` (see [#53](https://github.com/myselfRaifMondal/strongroom/issues/53)), or a new fuzz target ([#49](https://github.com/myselfRaifMondal/strongroom/issues/49)) | `cargo test -p vault-core` |
| Swift | More services for Organize by Service in `apps/macos/Sources/StrongroomKit/ServiceCatalog.swift`, or accessibility ([#24](https://github.com/myselfRaifMondal/strongroom/issues/24)) | macOS with the Command Line Tools |
| Kotlin | Android parity features ([#21](https://github.com/myselfRaifMondal/strongroom/issues/21)) or accessibility ([#54](https://github.com/myselfRaifMondal/strongroom/issues/54)) | Android SDK + an emulator |
| C# | Windows lock triggers ([#51](https://github.com/myselfRaifMondal/strongroom/issues/51)) or Trash and history ([#52](https://github.com/myselfRaifMondal/strongroom/issues/52)) | Windows 10/11 |
| Python | A second check of the format against [docs/SPEC-VTF.md](docs/SPEC-VTF.md) in `reference/` | `uv` |
| CI / YAML | [#47](https://github.com/myselfRaifMondal/strongroom/issues/47), [#48](https://github.com/myselfRaifMondal/strongroom/issues/48) | a GitHub fork |
| A real device | Test reports for [#16](https://github.com/myselfRaifMondal/strongroom/issues/16), [#17](https://github.com/myselfRaifMondal/strongroom/issues/17) or [#32](https://github.com/myselfRaifMondal/strongroom/issues/32) | no coding at all |

Docs fixes, clearer error messages and better tests are always welcome too.
Comment "I'd like to take this" on an issue and it is yours.

On your first pull request, GitHub waits for a maintainer to approve the CI
run. That is a GitHub safety setting for first-time contributors, not a sign
that something is wrong.

Questions are welcome in
[Discussions](https://github.com/myselfRaifMondal/strongroom/discussions).

## Ground rules

- **The VTF1 file format is frozen.** Anything that changes a byte on disk,
  an algorithm, a parameter, a label or a limit needs a new format version.
  Open an issue to discuss it first.
- **The FFI contract is stable.** Changes to
  `crates/strongroom-ffi/src/strongroom.udl` affect every app; propose them
  in an issue before writing code.
- **No new cryptographic primitives.** Compose existing, widely used crates
  (see the inventory in [docs/SECURITY.md](docs/SECURITY.md)). Adding
  any dependency to `vtf-core`, `vault-core` or `strongroom-ffi` needs a
  maintainer's agreement in the issue first.
- **Never lower the Argon2id cost** (m=262144 KiB, t=3, p=4).
- **Secrets never reach logs, panic messages, error values or crash
  reports.** Keys, passwords and plaintext are zeroized on drop; tag and key
  ID comparisons are constant-time.
- **Every unlock failure is the same error.** Never reveal which of the
  password, Secret Key or device key was wrong.
- **No network calls**, except the planned opt-in breach check.
- **No real vault data, passwords or keys** in issues, tests or commits. Use
  the public fixtures in `vectors/manifest.json`.

## Before you open a pull request

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
(cd reference && uv run python -m vtf_ref.verify ../vectors/ --strict)
```

For app changes, build and test the platform you touched (for macOS:
`apps/macos/scripts/build-core.sh`, `build-app.sh`, `test.sh`) and say in
the pull request what you checked by hand.

Keep pull requests focused, explain *why* in the description, and add tests:
a negative test for every new rejection path, a vector for every format
behaviour.

### Bumping the Rust toolchain

Every build uses the exact compiler in `rust-toolchain.toml`, and the fuzz
targets use the dated nightly in `fuzz/rust-toolchain.toml`. Workflows and
the platform build scripts read these files; no workflow names a Rust
version. Dependabot is not set up to bump them. To move to a new compiler:

1. Set `channel` in `rust-toolchain.toml` to the new stable release, for
   example `"1.100.0"`. Set `channel` in `fuzz/rust-toolchain.toml` to a
   recent nightly, `"nightly-YYYY-MM-DD"`.
2. Run the checks above with the new compiler and fix any new clippy or
   rustfmt findings in the same pull request.
3. Open a pull request with only the bump and those fixes. Changing
   `rust-toolchain.toml` runs the app workflows (macOS, Windows, Android and
   the cross-platform round-trip); changing `fuzz/rust-toolchain.toml` runs
   a short `fuzz-long.yml`.

The platform build scripts pass `--locked`, so they build exactly the crate
versions in `Cargo.lock`. Update `Cargo.lock` with `cargo update` in its own
commit, never as a side effect of a build.

## Pull request process

1. Fork the repository and create a branch from `main`.
2. Make your change with tests, and run the checks above.
3. Open a pull request and fill in the template, including the security
   checklist.
4. CI runs on every pull request: Rust tests and vectors, fuzz smoke runs,
   `cargo audit`, and builds for each platform. All checks must pass.
5. A maintainer reviews it. Changes to `crates/`, `docs/SPEC-VTF.md` or
   `vectors/` get extra scrutiny and may take longer. Strongroom has one
   maintainer today, so please be patient.

Write commit messages in the imperative mood ("Add …", "Fix …") with a
short first line and the reason in the body.

## Licence

By contributing you agree that your contribution is licensed under the
[GPL-3.0-or-later](LICENSE), the same licence as the project.
