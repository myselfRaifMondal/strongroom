## What and why

<!-- What does this change, and why is it needed? Link the issue: "Fixes #123". -->

## How I tested it

<!-- Commands you ran and what you checked by hand. Name the platforms. -->

- [ ] `cargo fmt --all --check` and `cargo clippy --workspace --all-targets -- -D warnings`
- [ ] `cargo test --workspace`
- [ ] Platform build / tests for any app I touched (say which)

## Security checklist

- [ ] No change to the VTF format, the FFI contract (`strongroom.udl`) or the Argon2id cost — or this was agreed in an issue first.
- [ ] No new dependency in `vtf-core`, `vault-core` or `strongroom-ffi` — or a maintainer agreed in an issue first.
- [ ] No secret can reach a log, panic, error value, notification or crash report.
- [ ] No new network call.
- [ ] No real passwords, keys or vault data in code, tests, screenshots or this description.

By opening this pull request I agree that my contribution is licensed under GPL-3.0-or-later.
