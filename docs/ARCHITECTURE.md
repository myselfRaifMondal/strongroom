# Architecture

Strongroom is a device-first, local-only password manager. There is no
server, no cloud sync and no backend. Vaults move between devices only as
manually transferred VTF files (`docs/SPEC-VTF.md`).

## Layers

```
 SwiftUI (macOS, iOS)   Jetpack Compose (Android)   WinUI 3 (Windows)
          \                      |                       /
           \        UniFFI bindings (Swift / Kotlin / C#)
            \                    |                     /
             +------------ strongroom-ffi -------------+   stable contract
                                 |
                  +--------------+--------------+
                  |                             |
             vault-core                      vtf-core
   SQLCipher store, items, history,   frozen transfer format:
   trash, HLC merge, TOTP, generator, header, slots, KDF,
   strength, audit, CSV import        chunked AEAD, CBOR
```

- **vtf-core** — pure, I/O-free implementation of VTF v1. Owns every
  cryptographic operation of the transfer format.
- **vault-core** — the encrypted local store (rusqlite + SQLCipher) and all
  item logic. Uses vtf-core for export/import.
- **strongroom-ffi** — the only crate the apps link. Its surface is
  `crates/strongroom-ffi/src/strongroom.udl`, mirrored by Rust traits in
  `src/contract.rs`. Frozen after Phase 1.

## Platform responsibilities

The Rust core never touches the OS. Each app provides:

- secure-hardware P-256 key (Secure Enclave / TPM via Windows Hello /
  Android Keystore, StrongBox where present) behind the `DeviceKeyAgreement`
  callback; biometric prompt gating each use;
- reboot and biometric-enrollment-change signals for `UnlockGate`;
- clipboard with auto-clear (20–30 s) and OS clipboard-history exclusion;
- desktop: global hotkey overlay, screen-capture exclusion, confirmed
  auto-type; mobile: Android Autofill Service, iOS Credential Provider
  Extension;
- the optional, off-by-default HIBP k-anonymity breach check (the only
  outbound network call in the product).

## Key flow

Master password + Secret Key -> KEK (Argon2id + HKDF) -> unwraps the vault
key. Biometric unlock: the vault key is HPKE-sealed to the device's hardware
public key; unlocking performs one hardware ECDH via `DeviceKeyAgreement`.
The raw vault key never crosses the FFI boundary.
