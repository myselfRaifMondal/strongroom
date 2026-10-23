# vault-core: local store rules

Normative description of the behaviour implemented in `crates/vault-core`.

## Files

A vault at `P` is two files:

- `P` — SQLCipher 4 database (rusqlite, `bundled-sqlcipher-vendored-openssl`),
  keyed with the 32-byte random **vault key** as a raw key (`PRAGMA key =
  "x'…'"`, no SQLCipher PBKDF). `secure_delete` is on.
  `cipher_memory_security` is deliberately **off**: it mlock()s every SQLite
  allocation, and once the OS lock quota is exhausted (Windows working-set
  quota, error 1453; small `RLIMIT_MEMLOCK` on Linux/Android) SQLCipher's
  warning logger allocates through the same failing allocator and recurses
  until the stack overflows. SQLCipher still wipes its own key material and
  codec buffers (private heap) on free; general SQLite page-cache memory is
  not wiped.
- `P.hdr` — 138-byte plaintext header that wraps the vault key:

```
"SRV1" | BE16(1) | BE32(262144) | BE32(3) | BE32(4) | vault_id(16) | salt(32) | nonce(24) | wrapped(48)
KEK     = vtf_core::keys::derive_kek(password, secret_key, salt)   (Argon2id m=262144 KiB, t=3, p=4 + HKDF)
wrapped = XChaCha20-Poly1305(KEK, nonce, aad = first 90 header bytes, vault_key)
```

A header whose Argon2 fields differ from the frozen cost in either direction
is rejected. Every unlock failure (missing/garbled header, wrong password,
wrong Secret Key, wrong device key, unreadable database) is the single
`UnlockFailed`.

`backup_to(Q)` writes `Q` (SQLite online backup into a destination keyed with
the same vault key) and `Q.hdr`; it opens with the same credentials and
refuses to overwrite.

## Device (biometric) wrap

`wrap_vault_key_for_device(pk)` returns 146 bytes:
`0x01 | key_id(8) | enc(65) | nonce(24) | wrapped(48)`, where
`(enc, wrap_key) = vtf_core::device::seal_export(pk, "SR1/hpke-info" || vault_id, "SR1/device-wrap")`
and `wrapped = XChaCha20-Poly1305(wrap_key, nonce, "SR1/device-wrap" || vault_id || blob[0..98], vault_key)`.
Unlock compares `key_id` in constant time and performs the one ECDH through
`DeviceKeyAgreement`. The raw vault key never crosses the FFI.

## Decoys

`unlock_first_matching` runs exactly one Argon2id per candidate path (a
placeholder salt for a missing header; placeholder credentials for malformed
input), never exits the loop early, and opens only the first match. At most
8 paths.

## Items, history, trash

- Item ids are 16 random bytes, shown as 32 lowercase hex characters.
- Every edit pushes the previous state onto the history (oldest first, capped
  at 64; VTF limit). An edit that changes nothing is a no-op.
- Trashed items stay 180 days (`purge_at = deleted_at + 180 d`).
  `purge_expired_trash(now)` deletes items with `now - trashed_at >= 180 d`
  and records a tombstone `(id, deleted_at = now, hlc)`. Tombstones are kept
  indefinitely so an old copy can never resurrect a purged item.
- Hybrid logical clock: `hlc = (unix_seconds << 16) | counter`; every local
  change takes `max(now << 16, last + 1)`; imports advance `last` to the
  largest HLC seen.

## Merge on VTF import (per item)

1. Incoming tombstone vs local item: if `local.hlc <= tombstone.hlc` the item
   is deleted and the tombstone stored (`updated`); otherwise the newer local
   edit survives (`conflicts`).
2. Incoming item vs local tombstone: if `tombstone.hlc >= item.hlc` it is
   ignored (`unchanged`); otherwise the item was edited after the deletion and
   is restored (`added` + `conflicts`).
3. Incoming item vs local item: last writer wins by `(hlc, modified_at,
   encoded item)` — a total order, so every device picks the same winner.
   Histories are unioned (deduplicated, oldest first, capped at 64). If the
   loser's current state is neither equal to the winner's nor present in the
   winner's history, the two had diverged: it counts as a conflict and the
   loser's state is added to history so nothing is lost. A remote winner that
   changes content or trash state counts as `updated`, otherwise `unchanged`.
4. While travel mode is on, incoming items not marked `travel_safe` are
   skipped (`unchanged`).

`conflicts` is counted in addition to the other three fields.

## Rollback rule

The vault records the largest `exported_at` among files it has accepted. A
file whose `exported_at` is **older** than that, and whose merge would add,
update or conflict **nothing**, is refused with
`FormatRejected { check: "rollback" }` and the transaction is rolled back.
Rationale: per-item LWW plus permanent tombstones already makes an old file
unable to overwrite newer data; the rule exists so the UI can tell the user
the file is stale. A file that is older but still carries changes this vault
never saw (e.g. from another device that has not synced recently) is merged
normally. Re-importing the same file is not a rollback.

Not detected: replacement of the local database files by an older copy of
the same vault (there is no trusted monotonic storage in the core).

## Travel mode

Enabling deletes every item not marked `travel_safe` (with history, without
tombstones, so the deletion never propagates) and VACUUMs. Disabling clears
the flag only; items come back by importing an export or restoring a backup.

## Autofill domain matching

Matches on registrable domain (eTLD+1). The suffix data is a small embedded
subset, not the Public Suffix List: every single-label TLD is a public suffix
(PSL default rule) plus ~200 listed multi-label suffixes (country second-level
domains and common shared-hosting domains such as `github.io`). No wildcard or
exception rules, no IDNA conversion; IP addresses match exactly. An unlisted
shared-hosting domain can match too broadly.

## Other modules

- TOTP: RFC 6238 over RFC 4226, HMAC-SHA1/256/512 (`hmac`, `sha1`, `sha2`),
  6–10 digits, period 1–3600 s; `otpauth://totp/` URIs (HOTP is refused).
- Generator: unbiased rejection sampling over `vtf_core::keys::fill_random`;
  passwords 4–128 characters (uniform over strings containing every selected
  class); passphrases 3–20 words from the EFF large wordlist (CC BY 3.0 US,
  see `crates/vault-core/NOTICE`).
- Strength: own estimator — cheapest segmentation into brute-force characters
  (union character pool), EFF dictionary words (leet/case aware), repeats,
  sequences, keyboard rows, years; whole-password match against a short
  common-password list. Score thresholds 28/40/56/72 bits → 0..4.
- Health: reused (identical password on ≥ 2 live items), weak (score < 3), old
  (password unchanged > 365 days); score = round(100 × clean / with-password).
- CSV: hand-written RFC 4180 parser; header-name mappings for Bitwarden,
  1Password, LastPass and Chrome exports.
- Pairing: `"SR1PAIR:" + base32(pk65)`; fingerprint = base32 of the first 10
  bytes of SHA-256(pk), shown `XXXX-XXXX-XXXX-XXXX`.
- UnlockGate: plain-text non-secret state file; order of checks: no device
  key, enrollment changed, rebooted, ≥ 5 consecutive biometric failures (only a
  password unlock clears it), no/old (≥ 7 days)/future password unlock.
