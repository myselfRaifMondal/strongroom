# Security policy

Strongroom is a local-only password manager: no server, no account, no
sync service. Vaults live encrypted on the device and move between devices
only as user-transferred VTF files ([SPEC-VTF.md](SPEC-VTF.md)). The threat
model is in [THREAT-MODEL.md](THREAT-MODEL.md).

## Reporting a vulnerability

- Report privately through GitHub's **Security → Report a vulnerability**
  (private security advisory) on this repository. Do not open a public issue,
  pull request or discussion for a suspected vulnerability.
- Include the affected component (Rust core, FFI, a platform app, the file
  format), the version or commit, reproduction steps, and the impact you
  expect. A crafted `.vtf` file or CBOR payload that reproduces the problem
  is the most useful attachment.
- Never include real vault data, master passwords or Secret Keys. The public
  test fixtures in `vectors/manifest.json` are enough to build a test file.
- The maintainer acknowledges the report and agrees a disclosure date with
  you. Format-level issues (anything that would need a VTF2) are disclosed
  together with the new format version.

## Supported versions

Strongroom is pre-release. Only the `main` branch receives security fixes.

| Component                     | Supported |
|-------------------------------|-----------|
| `main` (Rust core + apps)     | yes       |
| Any other branch or old build | no        |
| VTF1 file format              | yes. Frozen; flaws are fixed in a new format version, and VTF1 import keeps working |

## Cryptographic inventory

All cryptography is in the Rust core (`crates/vtf-core`, `crates/vault-core`).
Platform code calls it through `strongroom-ffi` and never implements
cryptography itself, with two exceptions: secure-hardware ECDH and the
opt-in HIBP SHA-1 (both listed below).

| Purpose | Primitive and parameters | Implementation |
|---|---|---|
| Password stretching | Argon2id v1.3, m = 262144 KiB (256 MiB), t = 3, p = 4, 32-byte output; parameters fixed and enforced on import in both directions | `argon2` 0.6 |
| Key derivation | HKDF-SHA-256 (RFC 5869), labels `VTF1/secret-key`, `VTF1/kek`, `VTF1/payload` | `hkdf` 0.13, `sha2` 0.11 |
| Second factor | 128-bit random Secret Key, combined with the password-derived key via HKDF, never written to any file | OS CSPRNG |
| Password normalization | Unicode NFKC, then UTF-8 | `unicode-normalization` 0.1 |
| Authenticated encryption | XChaCha20-Poly1305 (draft-irtf-cfrg-xchacha-03), 256-bit key, 192-bit nonce | `chacha20poly1305` 0.11 |
| Device-slot key wrapping | HPKE (RFC 9180) base mode, DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, export-only AEAD; exporter label `VTF1/device-wrap` | sender: `hpke` 0.14; receiver: RFC 9180 key schedule composed over `hkdf` with one hardware ECDH (OQ-7) |
| Hardware key agreement | P-256 ECDH with a non-exportable key: Secure Enclave, TPM 2.0 via Windows Hello/CNG, Android Keystore (StrongBox where present) | platform, behind the `DeviceKeyAgreement` callback |
| Hashing | SHA-256: chunk AAD (`SHA256(header ‖ slots)`), HPKE info, device `key_id` | `sha2` 0.11 |
| Randomness | OS CSPRNG for salt, VTK, nonces, HPKE ephemeral `ikmE`, Secret Key | `getrandom` (via the crates above) |
| Constant-time compares | AEAD tags; device `key_id` selection | `chacha20poly1305`, `subtle` 2.6 |
| Secret hygiene | zeroize-on-drop for keys, VTK, decrypted plaintext and payload structures | `zeroize` 1.8 |
| Breach check (opt-in, off by default) | SHA-1 k-anonymity range query to HIBP (first 5 hex chars of the hash leave the device) | platform OS SHA-1 (CryptoKit / `java.security` / CNG), never the core (OQ-6) |
| Local vault store | SQLCipher (rusqlite), key wrapped as above | `vault-core`: planned, not yet in tree |

There is no compression anywhere in VTF1. No new primitive may be added to
shipped code without owner approval; new crates in `vtf-core`, `vault-core`
or `strongroom-ffi` need the same approval (see `docs/OPEN-QUESTIONS.md`
OQ-8 for the current exceptions).

## Assurance

| Activity | Where | Runs in CI (`.github/workflows/rust.yml`) |
|---|---|---|
| Normative vectors: 4 positive (byte-for-byte), 55 negative (each named check) | `vectors/`, `crates/vtf-core/tests/vectors.rs` | `cargo test --workspace` |
| Independent Python reference written from the spec (`argon2-cffi` + `cryptography` only); reproduces and opens every positive vector, rejects every negative one; KATs for HChaCha20, XChaCha20-Poly1305 and RFC 9180 A.3.1 | `reference/` | yes |
| Property tests (deterministic generator): payload round trips, single-byte mutation rejection, chunk reorder/duplicate/delete/truncate rejection | `crates/vtf-core/tests/properties.rs` | yes |
| Fuzzing (cargo-fuzz/libFuzzer + ASan): header/slot parser and device unlock, tampered-chunk decryption, CBOR/payload decoder | `fuzz/` | 60 s smoke per target |
| Dependency advisories | `cargo audit` on `Cargo.lock` and `fuzz/Cargo.lock` | yes, warnings fail |
| Lints | `cargo fmt --check`, `cargo clippy -D warnings` | yes |

## Out of scope

- An attacker with code execution, root or a debugger on an **unlocked**
  device, or a compromised OS, keyboard, accessibility service or IME:
  they can read whatever the app displays or holds in memory.
- Physical or invasive attacks on the secure element, TPM or StrongBox
  itself, and vendor flaws in them.
- Forensic recovery of passwords or Secret Keys from managed-runtime memory
  (Swift, Kotlin, C# strings cannot be reliably zeroized). See residual
  risks in the threat model.
- Weak master passwords chosen despite the strength meter, and loss of the
  master password or Secret Key. There is deliberately no recovery path.
- The HIBP service's own security and availability (the check is opt-in and
  sends only a 5-character hash prefix).
- Denial of service by deleting or corrupting vault or export files. The
  format detects tampering; it cannot prevent destruction.
- Social engineering, phishing of the master password, and shoulder-surfing
  of the Secret Key printout.
- Findings that apply only to the reference implementation in `reference/`
  or the fuzz harnesses (test code, never shipped), unless they show a
  defect in the spec, the vectors or the Rust core.
