# strongroom-mac-cli

A headless harness over the same Swift bindings the macOS app uses. CI and the
Phase 3 cross-platform VTF round-trip drive it; humans can too. Mirrors the
Windows `strongroom-cli`.

## Build it

```bash
# 1. the Rust core (libstrongroom_ffi.a + generated Swift bindings)
scripts/build-core.sh

# 2. the CLI and the app bundle
apps/macos/scripts/build-app.sh
```

The CLI binary lands at `apps/macos/scripts/out/strongroom-mac-cli`. Both
scripts need a Mac with the Xcode toolchain; `build-core.sh` honours
`CARGO_JOBS` and `CARGO_TARGET_DIR`.

## Secrets

Secrets come **only** from environment variables, never argv (argv is visible
to other processes on the machine):

| Variable | Used for |
| --- | --- |
| `STRONGROOM_PASSWORD` | master password (vault and VTF password slot) |
| `STRONGROOM_SECRET_KEY` | Secret Key for an existing vault or VTF file |
| `STRONGROOM_ITEM_PASSWORD` | optional per-item password for `add` |

## Commands

Every example below uses made-up test data. `export`/`import`/`inspect`
operate on the `.vtf` interchange file; `roundtrip`, `hierarchy` and
`organize-demo` are self-contained scenarios that need nothing but a scratch
directory.

### create

```bash
export STRONGROOM_PASSWORD='demo-correct-horse-battery'
strongroom-mac-cli create --vault /tmp/demo.vault --secret-key-out /tmp/demo.key
```

Creates an empty vault and writes its Secret Key to a file. Keep the key with
the vault when you move it.

### add

```bash
export STRONGROOM_PASSWORD='demo-correct-horse-battery'
export STRONGROOM_ITEM_PASSWORD='demo-item-pin-9931'
strongroom-mac-cli add --vault /tmp/demo.vault \
  --title 'Demo Mail' --username 'demo.user@example.test' \
  --url 'https://mail.example.test' --totp JBSWY3DPEHPK3PXP \
  --notes 'made-up entry for the docs'
```

Adds one item. `--totp` takes a base32 secret; `--notes` is free text.

### list

```bash
strongroom-mac-cli list --vault /tmp/demo.vault
```

Prints the item titles in the vault. Passwords are not printed.

### export

```bash
export STRONGROOM_PASSWORD='demo-correct-horse-battery'
strongroom-mac-cli export --vault /tmp/demo.vault --out /tmp/demo.vtf
```

Writes the vault as a `.vtf` interchange file.

### import

```bash
export STRONGROOM_PASSWORD='demo-correct-horse-battery'
export STRONGROOM_SECRET_KEY="$(cat /tmp/demo.key)"
strongroom-mac-cli import --in /tmp/demo.vtf --vault /tmp/copy.vault
```

Reads a `.vtf` file into a vault and prints the imported item titles.

### inspect

```bash
strongroom-mac-cli inspect --in /tmp/demo.vtf
```

Prints the structure of a `.vtf` file (slots, counts, hierarchy) without
decrypting it into a vault.

### roundtrip

```bash
strongroom-mac-cli roundtrip --dir /tmp/roundtrip
```

Self-contained scenario: creates two vaults, adds items, exports from one and
imports into the other, then verifies the data survived byte-for-byte.

### hierarchy

```bash
strongroom-mac-cli hierarchy --dir /tmp/hierarchy
```

Self-contained scenario: nested folders and recovery codes go through an
export/import cycle and are checked on the far side.

### probe

```bash
strongroom-mac-cli probe
```

Prints whether the FFI links and whether Secure Enclave / Touch ID are
available on this machine. Handy first call when a build "mysteriously" fails.

### organize

```bash
export STRONGROOM_PASSWORD='demo-correct-horse-battery'
strongroom-mac-cli organize --vault /tmp/demo.vault              # plan only
strongroom-mac-cli organize --vault /tmp/demo.vault --apply yes  # apply the plan
```

Plans (and optionally applies) the Organize by Service re-grouping.

### ranking

```bash
strongroom-mac-cli ranking --vault /tmp/demo.vault
```

Prints the Security Ranking, worst first. Passwords are not printed.

### organize-demo

```bash
strongroom-mac-cli organize-demo --dir /tmp/organize-demo
```

Self-contained end-to-end: generates a synthetic Apple Passwords CSV,
organizes it, ranks it, then undoes everything and verifies the inputs are
identical to before.
