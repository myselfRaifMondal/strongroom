# VTF1 test vectors

Normative vectors for [docs/SPEC-VTF.md](../docs/SPEC-VTF.md). All keys,
passwords and randomness here are deliberate, public test fixtures.

- `manifest.json` — every input needed to reproduce the files: password and
  NFKC alternates, Secret Key, device key pairs (P-256), and the fixed
  randomness (salt, chunk-nonce prefix, VTK, slot nonces, HPKE `ikmE`).
- `positive/<name>.vtf` — must reproduce byte-for-byte from the inputs and
  `positive/<name>.cbor` (the unpadded deterministic-CBOR payload).
- `negative/<name>.vtf` — must be rejected by the check named in
  `expected_check`, using the credential named in `credential`
  (`password`, `wrong-password`, `wrong-secret-key`, `device-a`, `device-c`).

Device slot `i` of a file uses `randomness.device_slots[i]`.

Regenerate (only when the generator itself changes; the format is frozen):

    cargo run -p vtf-core --release --example gen_vectors

`cargo test -p vtf-core` fails if the committed files drift from the
generator.
