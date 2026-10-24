# Contributing to Strongroom

Thanks for helping. Strongroom stores people's most sensitive data, so the
bar for changes is high and the rules below are strict on purpose.

## Security issues

**Never** open a public issue or pull request for a vulnerability. Use
GitHub's private **Security → Report a vulnerability** form. See
[docs/SECURITY.md](docs/SECURITY.md).

## Ground rules

- **The VTF1 file format is frozen.** Anything that changes a byte on disk,
  an algorithm, a parameter, a label or a limit needs a new format version.
  Open an issue to discuss it first.
- **The FFI contract is stable.** Changes to
  `crates/strongroom-ffi/src/strongroom.udl` affect every app; propose them
  in an issue before writing code.
- **No new cryptographic primitives.** Compose audited crates only. Adding
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
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
(cd reference && uv run python -m vtf_ref.verify ../vectors/ --strict)
```

For app changes, build and test the platform you touched (for macOS:
`apps/macos/scripts/build-core.sh`, `build-app.sh`, `test.sh`) and say in
the pull request what you checked by hand.

Keep pull requests focused, explain *why* in the description, and add tests:
a negative test for every new rejection path, a vector for every format
behaviour.

## Licence

By contributing you agree that your contribution is licensed under the
[GPL-3.0-or-later](LICENSE), the same licence as the project.
