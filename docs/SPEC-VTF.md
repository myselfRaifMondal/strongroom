# VTF — Vault Transfer Format, version 1

Status: **FROZEN**. Any change to this document that alters a byte on disk,
an algorithm, a parameter, a label or a limit is a new format version (VTF2),
not an edit to VTF1.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## 1. Purpose

A VTF file carries one complete Strongroom vault between devices by manual
file transfer. There is no server. A file is opened either with the user's
master password **and** Secret Key (password slot), or with a paired device's
non-exportable hardware key (device slot).

## 2. Notation

- `||` is byte concatenation.
- `BE16(x)`, `BE32(x)` are big-endian unsigned encodings.
- `SHA256(x)` is SHA-256 (FIPS 180-4).
- `HKDF(ikm, salt, info, L)` is HKDF-SHA-256 (RFC 5869), extract then expand.
- `AEAD(k, n, aad, pt)` is XChaCha20-Poly1305 (draft-irtf-cfrg-xchacha-03):
  256-bit key, 192-bit (24-byte) nonce, 128-bit (16-byte) tag appended to
  the ciphertext.
- All string labels are ASCII, without a terminator. Every HKDF info label
  and every HPKE label defined by this spec begins with `VTF1/`.

## 3. File layout

```
+--------------------+  offset 0
| fixed header       |  84 bytes
+--------------------+  offset 84
| key slot 1         |  73 or 146 bytes
| ...                |
| key slot N         |  1 <= N <= 16
+--------------------+  offset 84 + S   (S = total slot bytes)
| chunk 0            |  65552 bytes
| ...                |
| chunk C-1          |  1 <= C <= 4096
+--------------------+  offset 84 + S + 65552*C  == file length
```

The file length MUST equal exactly `84 + S + 65552 * C`. Nothing may follow
the last chunk.

### 3.1 Fixed header (84 bytes)

| Offset | Size | Field              | Required value                          |
|-------:|-----:|--------------------|-----------------------------------------|
| 0      | 4    | `magic`            | ASCII `VTF1` = `56 54 46 31`            |
| 4      | 2    | `version`          | `BE16(1)`                               |
| 6      | 2    | `flags`            | see 3.2                                 |
| 8      | 1    | `kdf_id`           | `0x01` = Argon2id v1.3 (RFC 9106)       |
| 9      | 1    | `aead_id`          | `0x01` = XChaCha20-Poly1305             |
| 10     | 2    | `kem_id`           | `BE16(0x0010)` = DHKEM(P-256, HKDF-SHA-256) |
| 12     | 4    | `argon2_m_kib`     | `BE32(262144)`                          |
| 16     | 4    | `argon2_t`         | `BE32(3)`                               |
| 20     | 4    | `argon2_p`         | `BE32(4)`                               |
| 24     | 32   | `salt`             | 32 random bytes, fresh per export       |
| 56     | 19   | `chunk_nonce_prefix` | 19 random bytes, fresh per export     |
| 75     | 1    | `slot_count`       | `1..=16`                                |
| 76     | 4    | `chunk_count`      | `BE32(C)`, `1..=4096`                   |
| 80     | 4    | `reserved`         | `00 00 00 00`                           |

`kem_id` is `0x0010` in every VTF1 file, including files with no device
slot, so that the header is a constant shape.

An importer MUST reject any value other than the one in the "Required value"
column. In particular, an importer MUST reject Argon2 parameters that differ
from `m=262144, t=3, p=4` in either direction.

### 3.2 Flags

| Bit (LSB = 0) | Name               | Meaning                                    |
|--------------:|--------------------|--------------------------------------------|
| 0             | `HAS_DEVICE_SLOTS` | Set if and only if at least one slot has type `0x02` |
| 1..15         | reserved           | MUST be zero                               |

An importer MUST reject a file where any reserved bit is set, or where
`HAS_DEVICE_SLOTS` disagrees with the slot table.

### 3.3 Key slots

Slots follow the fixed header back to back, `slot_count` of them. The first
byte of each slot is its type, which determines its length.

**Type `0x01` — password slot (73 bytes)**

| Offset | Size | Field         |
|-------:|-----:|---------------|
| 0      | 1    | `type` = `0x01` |
| 1      | 24   | `nonce`       |
| 25     | 48   | `wrapped_vtk` (32-byte ciphertext + 16-byte tag) |

**Type `0x02` — device slot (146 bytes)**

| Offset | Size | Field         |
|-------:|-----:|---------------|
| 0      | 1    | `type` = `0x02` |
| 1      | 8    | `key_id` = first 8 bytes of `SHA256(pkR)` |
| 9      | 65   | `enc` — HPKE encapsulated key, uncompressed SEC1 P-256 point |
| 74     | 24   | `nonce`       |
| 98     | 48   | `wrapped_vtk` |

`pkR` is the recipient device's public key as a 65-byte uncompressed SEC1
point (`0x04 || X || Y`).

Slot table rules. An importer MUST reject the file if:

- `slot_count` is 0 or greater than 16;
- any slot type is not `0x01` or `0x02` (types `0x03`+ are reserved; `0x03`
  is earmarked for a future recovery-code slot and is **not** valid in VTF1);
- more than one password slot is present;
- two device slots carry the same `key_id`;
- the file ends inside the slot table.

### 3.4 Chunks

Each chunk is exactly 65552 bytes: 65536 bytes of ciphertext followed by a
16-byte Poly1305 tag. There is no short final chunk; the payload is padded
(section 6) so every chunk is full.

## 4. Key hierarchy

### 4.1 Password and Secret Key inputs

- `password_bytes = UTF-8(NFKC(password))` (Unicode Normalization Form KC,
  Unicode Standard Annex #15). An empty `password_bytes` MUST be refused at
  export and causes unlock failure at import.
- `secret_key` is exactly 16 bytes (128 bits) of uniformly random data. It is
  never written to a VTF file. Its human display encoding is in Appendix A.

### 4.2 Derivation

```
pw_key  = Argon2id(version = 0x13, m = 262144 KiB, t = 3, p = 4,
                   password = password_bytes, salt = salt,
                   secret = empty, associated_data = empty,
                   tag_length = 32)
sk_key  = HKDF(secret_key,        salt, "VTF1/secret-key", 32)
KEK     = HKDF(pw_key || sk_key,  salt, "VTF1/kek",        32)
```

### 4.3 Vault Transfer Key and payload key

- `VTK` is 32 fresh random bytes per export.
- `payload_key = HKDF(VTK, salt, "VTF1/payload", 32)`.

The VTK is wrapped once per slot. The payload is encrypted under
`payload_key` only.

### 4.4 Password slot wrapping

```
nonce        = 24 random bytes
wrapped_vtk  = AEAD(KEK, nonce, aad = fixed_header || 0x01, VTK)
```

`fixed_header` is the 84 bytes of section 3.1, exactly as written.

### 4.5 Device slot wrapping (HPKE)

HPKE (RFC 9180), **base mode**, ciphersuite:

- KEM `0x0010` DHKEM(P-256, HKDF-SHA256)
- KDF `0x0001` HKDF-SHA256
- AEAD `0xFFFF` export-only

```
info              = "VTF1/hpke-info" || SHA256(fixed_header)
(enc, ctx)        = SetupBaseS(pkR, info)
wrap_key          = ctx.Export("VTF1/device-wrap", 32)
nonce             = 24 random bytes
wrapped_vtk       = AEAD(wrap_key, nonce,
                         aad = fixed_header || 0x02 || key_id || enc,
                         VTK)
```

The recipient computes `ctx = SetupBaseR(enc, skR, info)` and the same
`wrap_key`. Because device private keys live in secure hardware and are not
exportable, the recipient side is defined purely in terms of RFC 9180
`Decap` (one ECDH with `skR`) followed by the standard key schedule; an
implementation MAY perform the ECDH in hardware and the rest in software,
provided the result is bit-identical to RFC 9180.

P-256 (not X25519) is mandated because Secure Enclave, TPM 2.0 and Android
Keystore keys are P-256 and non-exportable.

### 4.6 Unlock procedure

To open a file with a password: derive `KEK` (4.2) and try the password slot.
To open with a device key: compute `key_id` of the local public key, find the
device slot with that `key_id` (constant-time comparison), and unwrap it.

If no slot unwraps, the importer MUST report a single, generic unlock failure.
It MUST NOT reveal whether the password, the Secret Key or the device key was
wrong, nor which slot was tried.

## 5. Chunk encryption

```
header_hash = SHA256(fixed_header || slot_table)
for i in 0 .. C-1:
    last  = 0x01 if i == C-1 else 0x00
    nonce = chunk_nonce_prefix || BE32(i) || last          (19+4+1 = 24 bytes)
    chunk_i = AEAD(payload_key, nonce, aad = header_hash, plaintext[i*65536 .. (i+1)*65536])
```

`slot_table` is the bytes of all key slots in file order. "The entire header"
for AAD purposes is therefore the fixed header **and** the slot table, so
adding, removing, reordering or editing any slot invalidates every chunk.

The index and last-flag in the nonce make chunk reordering, chunk deletion,
truncation at a chunk boundary and chunk duplication detectable as
authentication failures.

## 6. Payload

### 6.1 Plaintext framing

```
plaintext = cbor_payload || zero_padding
```

`cbor_payload` is exactly one CBOR data item (section 6.2).
`zero_padding` is 0..65535 zero bytes, chosen so that `len(plaintext)` is the
smallest positive multiple of 65536 that is `>= len(cbor_payload)`. If
`cbor_payload` is already a multiple of 65536, no padding is added.

An importer MUST reject the file if any padding byte is non-zero, or if the
padding is 65536 bytes or longer (an entire all-padding chunk).

**There is no compression, ever.** A VTF1 payload is never compressed.

### 6.2 Deterministic CBOR

`cbor_payload` MUST be encoded with RFC 8949 section 4.2.1 "Core Deterministic
Encoding": preferred (shortest) argument encoding, definite lengths only, and
map keys sorted by the bytewise lexicographic order of their encodings.

Additional VTF1 restrictions. An importer MUST reject a payload that:

- is not exactly one well-formed CBOR item followed by valid padding;
- uses non-shortest argument encoding, indefinite-length items, tags,
  floating-point values, `null`, `undefined` or any simple value other than
  `false`/`true`;
- has map keys out of deterministic order, or any duplicate map key;
- has nesting depth greater than 16 (the top-level map is depth 1);
- has any map key that is not an unsigned integer listed in 6.3, or a known
  key with a value of the wrong type;
- omits a required key;
- contains an optional array or map key whose value is empty (encoders MUST
  omit empty optional arrays);
- exceeds any limit in 6.4;
- has a text string that is not valid UTF-8.

### 6.3 Schema

All keys are unsigned integers. `R` = required, `O` = optional.

**Top-level map (`Payload`)**

| Key | R/O | Type                  | Meaning |
|----:|:---:|-----------------------|---------|
| 1   | R   | uint                  | `payload_version`, MUST be 1 |
| 2   | R   | uint                  | `exported_at`, Unix seconds |
| 3   | R   | array of `Item`       | live and trashed items (may be empty) |
| 4   | O   | array of `Tombstone`  | permanently deleted items |

**`Item` map**

| Key | R/O | Type                   | Meaning |
|----:|:---:|------------------------|---------|
| 1   | R   | bstr, 16 bytes         | item id |
| 2   | R   | uint 0..=5             | kind: 0 Login, 1 SecureNote, 2 Card, 3 Identity, 4 ApiKey, 5 SshKey |
| 3   | R   | tstr                   | title |
| 4   | R   | uint                   | created_at |
| 5   | R   | uint                   | modified_at |
| 6   | R   | uint (64-bit)          | hybrid logical clock of last change |
| 7   | O   | tstr                   | username |
| 8   | O   | tstr                   | password |
| 9   | O   | array of tstr          | urls |
| 10  | O   | tstr                   | notes |
| 11  | O   | tstr                   | totp (base32 secret or otpauth URI) |
| 12  | O   | tstr                   | folder |
| 13  | O   | array of tstr          | tags |
| 14  | O   | array of `Field`       | custom fields |
| 15  | O   | `true`                 | travel_safe (absent means false; `false` MUST NOT be encoded) |
| 16  | O   | array of `Revision`    | history, oldest first |
| 17  | O   | uint                   | trashed_at (present = item is in trash) |

**`Field` map**: `1` R tstr name; `2` R tstr value; `3` O `true` concealed
(absent means false).

**`Revision` map**: `1` R uint modified_at; `2` R `RevisionData`.

**`RevisionData` map**: the `Item` keys `2, 3, 7, 8, 9, 10, 11, 12, 13, 14,
15` with the same types and rules. No other keys are permitted.

**`Tombstone` map**: `1` R bstr(16) item id; `2` R uint deleted_at; `3` R
uint hybrid logical clock.

### 6.4 Limits

| Limit                                  | Value |
|----------------------------------------|------:|
| Chunks per file                        | 4096 (256 MiB plaintext) |
| Nesting depth                          | 16 |
| Items per payload                      | 100 000 |
| Tombstones per payload                 | 100 000 |
| Revisions per item                     | 64 |
| Custom fields per item / revision      | 128 |
| URLs per item / revision               | 64 |
| Tags per item / revision               | 64 |
| Text string length (bytes)             | 65 536 |
| Byte string length                     | 16 (only item ids exist) |

## 7. Import algorithm and check names

An importer MUST perform these checks and MUST stop at the first failure.
Each failure is identified by the check name in the left column; tests and
logs refer to these names. Checks 1–13 run before any key derivation.

| #  | Check name           | Rejects when |
|---:|----------------------|--------------|
| 1  | `length-min`         | file shorter than 84 bytes |
| 2  | `magic`              | bytes 0..4 are not `VTF1` |
| 3  | `version`            | version is not 1 |
| 4  | `flags-reserved`     | any reserved flag bit set |
| 5  | `kdf-id`             | kdf_id is not 0x01 |
| 6  | `aead-id`            | aead_id is not 0x01 |
| 7  | `kem-id`             | kem_id is not 0x0010 |
| 8  | `argon2-params`      | m, t or p differs from the frozen values |
| 9  | `reserved`           | reserved bytes are not zero |
| 10 | `slot-count`         | slot_count is 0 or > 16 |
| 11 | `slot-table`         | unknown slot type, truncated slot table, duplicate password slot, duplicate device key_id |
| 12 | `flags-device-slots` | `HAS_DEVICE_SLOTS` disagrees with slot table |
| 13 | `length`             | chunk_count is 0 or > 4096, or file length is not exactly `84 + S + 65552*C` |
| 14 | `slot-unwrap`        | no slot can be unwrapped (reported to the UI as the generic unlock failure) |
| 15 | `chunk-auth`         | any chunk fails AEAD verification |
| 16 | `cbor-wellformed`    | malformed or truncated CBOR, invalid UTF-8 |
| 17 | `padding`            | a byte after the CBOR item is non-zero, or padding >= 65536 bytes |
| 18 | `cbor-deterministic` | non-shortest encoding, indefinite length, unsorted keys |
| 19 | `cbor-duplicate-key` | a map contains a key twice |
| 20 | `cbor-depth`         | nesting depth > 16 |
| 21 | `cbor-type`          | tag, float, null/undefined/other simple value, or wrong value type for a key |
| 22 | `cbor-unknown-key`   | a map key not defined in 6.3 |
| 23 | `cbor-missing-key`   | a required key is absent |
| 24 | `cbor-empty-optional`| an optional array is present but empty, or `false` encoded for a flag |
| 25 | `cbor-limit`         | a limit in 6.4 is exceeded |
| 26 | `payload-version`    | payload_version is not 1 |

An importer MUST NOT release any plaintext to the caller unless every chunk
has authenticated and every payload check has passed. Decryption into
memory, verification, and only then parsing, is the required order.

## 8. Export

1. Serialize the payload with deterministic CBOR (6.2), enforce 6.4.
2. Pad to a multiple of 65536 (6.1).
3. Draw fresh `salt`, `chunk_nonce_prefix`, `VTK` and per-slot nonces from the
   OS CSPRNG.
4. Write the fixed header.
5. Write the password slot (if the export uses one) followed by device slots
   in the order the recipients were supplied.
6. Encrypt chunks (section 5).

A file MAY contain only device slots ("device-bound file"). An export that
has neither a password slot nor any device slot is invalid.

## 9. Security requirements on implementations

- Tag and `key_id` comparisons MUST be constant-time.
- `pw_key`, `sk_key`, `KEK`, `VTK`, `payload_key`, `wrap_key`, HPKE secrets,
  `password_bytes`, `secret_key` and decrypted plaintext MUST be zeroized when
  no longer needed.
- No secret may appear in a log message, panic message, error value or crash
  report.

## Appendix A. Secret Key display encoding

The 16-byte Secret Key is shown to users as:

```
SR1-AAAAA-BBBBB-CCCCC-DDDDD-EEEEEE
```

- prefix `SR1-` (format version 1);
- the 16 bytes encoded in RFC 4648 base32 (alphabet `A–Z2–7`), no padding:
  26 characters, the final character carrying 3 data bits and 2 zero bits;
- grouped 5-5-5-5-6 with `-`.

Parsers MUST accept lowercase and MUST ignore whitespace, MUST reject a final
character whose two low bits are non-zero, and MUST reject any other length.

## Appendix B. Test vectors

Normative test vectors live in `vectors/`. Every positive vector MUST
reproduce byte-for-byte; every negative vector MUST be rejected by the check
named in its metadata.
