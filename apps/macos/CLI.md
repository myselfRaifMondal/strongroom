# strongroom-mac-cli

A headless harness over the same Swift bindings the macOS app uses. CI and the
Phase 3 cross-platform VTF round-trip drive it; humans can too. Mirrors the
Windows `strongroom-cli` (`apps/windows/src/Strongroom.Cli`).

## Build it

From the repository root:

```bash
# 1. the Rust core (libstrongroom_ffi.a + generated Swift bindings)
apps/macos/scripts/build-core.sh

# 2. the CLI and the app bundle
apps/macos/scripts/build-app.sh
```

The CLI binary lands at `apps/macos/out/strongroom-mac-cli`. Both scripts need
the Xcode Command Line Tools (full Xcode is not required); `build-core.sh`
honours `CARGO_JOBS` and `CARGO_TARGET_DIR`.

The examples below assume the binary is on your `PATH`, for example:

```bash
export PATH="$PWD/apps/macos/out:$PATH"
```

## Secrets

Secrets come **only** from environment variables, never argv (argv is visible
to other processes on the machine):

| Variable | Used for |
| --- | --- |
| `STRONGROOM_PASSWORD` | master password (vault and VTF password slot) |
| `STRONGROOM_SECRET_KEY` | Secret Key for an existing vault or VTF file |
| `STRONGROOM_ITEM_PASSWORD` | optional per-item password for `add` |

Which commands need what:

| Command | `STRONGROOM_PASSWORD` | `STRONGROOM_SECRET_KEY` |
| --- | --- | --- |
| `create` | yes | no (a new key is generated) |
| `add`, `list`, `export`, `organize`, `ranking` | yes | yes |
| `import` | yes | yes (the key of the vault that exported the file) |
| `inspect`, `probe` | no | no |
| `roundtrip`, `hierarchy`, `organize-demo` | yes | no |

Exit codes: `0` ok, `1` failure, `2` usage error (including a missing
variable), `3` the core reported `Unsupported`.

## Commands

Every example below uses made-up test data. Run them in order: the later ones
use the vault and file the earlier ones create.

### create

```bash
export STRONGROOM_PASSWORD='demo-correct-horse-battery'
strongroom-mac-cli create --vault /tmp/demo.vault --secret-key-out /tmp/demo.key
export STRONGROOM_SECRET_KEY="$(cat /tmp/demo.key)"
```

Creates an empty vault and writes its Secret Key to a file. Without
`--secret-key-out` the key is printed instead. Keep the key with the vault when
you move it: losing either the master password or the Secret Key means
permanent data loss.

### add

```bash
export STRONGROOM_ITEM_PASSWORD='demo-item-pin-9931'
strongroom-mac-cli add --vault /tmp/demo.vault \
  --title 'Demo Mail' --username 'demo.user@example.test' \
  --url 'https://mail.example.test' --totp JBSWY3DPEHPK3PXP \
  --notes 'made-up entry for the docs'
```

Adds one login item and prints its ID. Only `--title` is required. `--totp`
takes a base32 secret; `--notes` is free text. The item password comes from
`STRONGROOM_ITEM_PASSWORD`, if set.

### list

```bash
strongroom-mac-cli list --vault /tmp/demo.vault
```

Prints `ITEMS: n` and one `TITLE:` line per item. Passwords are not printed.

### export

```bash
strongroom-mac-cli export --vault /tmp/demo.vault --out /tmp/demo.vtf
```

Writes the vault as a `.vtf` file with one password slot (master password +
Secret Key).

### inspect

```bash
strongroom-mac-cli inspect --in /tmp/demo.vtf
```

Reads only the unencrypted header and prints the format version, the number of
password and device slots, and the chunk count. It does not decrypt anything.

### import

```bash
strongroom-mac-cli import --in /tmp/demo.vtf
```

Decrypts the file with `STRONGROOM_PASSWORD` and `STRONGROOM_SECRET_KEY` (those
of the vault that exported it), imports it into a throwaway vault, prints the
`IMPORTED:` summary and the item titles, then deletes the throwaway vault.

With `--vault PATH` it imports into an existing vault instead. That vault is
opened with the same two variables, so it must already exist and use the same
master password and Secret Key as the file.

### ranking

```bash
strongroom-mac-cli ranking --vault /tmp/demo.vault
```

Prints the Security Ranking, worst first, plus any clusters of reused
passwords. Passwords are not printed.

### organize

```bash
strongroom-mac-cli organize --vault /tmp/demo.vault                          # plan only
strongroom-mac-cli organize --vault /tmp/demo.vault --scope all --apply yes  # apply the plan
```

Plans the Organize by Service re-grouping and, with `--apply yes`, applies it.
By default only items without a folder are considered; `--scope all` includes
items that are already filed.

### probe

```bash
strongroom-mac-cli probe
```

Prints the macOS version, whether the Rust core is linked, whether a Secure
Enclave key can be created, and whether Touch ID is available. A useful first
call when a build misbehaves.

### roundtrip

```bash
strongroom-mac-cli roundtrip --dir /tmp/roundtrip
```

Self-contained scenario (needs only `STRONGROOM_PASSWORD`): creates a vault
with three items, exports it, imports the file into a second vault, checks
that the item titles match, and checks that a wrong Secret Key is rejected.
Prints `ROUNDTRIP OK` on success.

### hierarchy

```bash
strongroom-mac-cli hierarchy --dir /tmp/hierarchy
```

Self-contained scenario (needs only `STRONGROOM_PASSWORD`): nested folders and
recovery codes go through an export/import cycle and are compared on the far
side. Prints `HIERARCHY ROUNDTRIP OK` on success.

### organize-demo

```bash
strongroom-mac-cli organize-demo --dir /tmp/organize-demo
```

Self-contained scenario (needs only `STRONGROOM_PASSWORD`): imports a synthetic
Apple Passwords CSV of fake accounts, organizes and ranks it, then undoes the
changes and checks that the items are identical to before.

## Clean up

```bash
rm -rf /tmp/demo.vault /tmp/demo.vault.hdr /tmp/demo.key /tmp/demo.vtf /tmp/roundtrip /tmp/hierarchy /tmp/organize-demo
unset STRONGROOM_PASSWORD STRONGROOM_SECRET_KEY STRONGROOM_ITEM_PASSWORD
```
