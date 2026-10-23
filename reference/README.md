# vtf_ref — independent Python reference for VTF1

Test/assurance code only. Never shipped, not constant-time, does not zeroize.

Written from [`docs/SPEC-VTF.md`](../docs/SPEC-VTF.md), not from the Rust
crate. Dependencies are limited to `argon2-cffi` and `cryptography` (pinned
in `pyproject.toml` / `uv.lock`; `pytest` is a dev-only group).

| Module          | What it implements |
|-----------------|--------------------|
| `primitives.py` | HKDF-SHA-256, Argon2id, HChaCha20 (pure Python) + XChaCha20-Poly1305 composed over `cryptography`'s ChaCha20-Poly1305 |
| `hpke.py`       | RFC 9180 base mode: DHKEM(P-256) DeriveKeyPair / Encap / Decap, key schedule, Export (only ECDH and HMAC from `cryptography`) |
| `cbor.py`       | iterative well-formedness scanner, strict tree builder, deterministic encoder |
| `payload.py`    | SPEC-VTF 6 schema/limits, checks 16–26 applied whole-document in table order |
| `container.py`  | header/slot parsing (checks 1–13), unlock, chunk AEAD, deterministic export |
| `selftest.py`   | KATs: HChaCha20 and XChaCha20-Poly1305 (draft-irtf-cfrg-xchacha-03), HPKE RFC 9180 A.3.1 |
| `verify.py`     | the vector checker |

```sh
cd reference
uv run python -m vtf_ref.verify vectors/      # one line per vector; non-zero exit on mismatch
uv run python -m vtf_ref.verify vectors/ --strict   # also fail on recorded disputes
uv run --group dev pytest -q
```

A negative vector whose `expected_check` this reference disagrees with is
listed in `verify.DISPUTED` with the reason. It must still be rejected, by
exactly the recorded check, or the run fails. Disputes are reported to the
format owner; the frozen vectors are never edited here.
