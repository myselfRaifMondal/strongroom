"""Cryptographic primitives used by VTF1, built on `argon2-cffi` and `cryptography`.

REFERENCE / TEST CODE ONLY. This module is part of the independent Python
reference implementation used to cross-check the Rust `vtf-core` against
docs/SPEC-VTF.md. It is never shipped in any product artifact.

`cryptography` has no XChaCha20-Poly1305, so it is composed here exactly as
draft-irtf-cfrg-xchacha-03 section 2.3 describes: an HChaCha20 subkey from
the key and the first 16 nonce bytes, then the IETF ChaCha20-Poly1305 AEAD
(RFC 8439) with nonce = 4 zero bytes || the last 8 nonce bytes. HChaCha20 is
implemented below in pure Python (reference/test code, not constant-time,
not for production use).
"""

from __future__ import annotations

import hashlib
import hmac as _stdlib_hmac
import struct

from argon2.low_level import Type, hash_secret_raw
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes, hmac
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF, HKDFExpand

KEY_LEN = 32
NONCE_LEN = 24
TAG_LEN = 16

# SPEC-VTF 3.1 / 4.2: the frozen Argon2id cost.
ARGON2_M_KIB = 262_144
ARGON2_T = 3
ARGON2_P = 4
ARGON2_VERSION = 0x13  # 19 == Argon2 v1.3


def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def ct_eq(a: bytes, b: bytes) -> bool:
    """Constant-time comparison (SPEC-VTF 9)."""
    return _stdlib_hmac.compare_digest(a, b)


# --- HKDF-SHA-256 (RFC 5869) -------------------------------------------------


def hkdf(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    """HKDF-SHA-256, extract then expand."""
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(ikm)


def hkdf_extract(salt: bytes, ikm: bytes) -> bytes:
    """HKDF-Extract (RFC 5869 2.2). An empty salt is HMAC keyed with b"",
    which equals HMAC keyed with HashLen zero bytes (HMAC zero-pads keys)."""
    h = hmac.HMAC(salt, hashes.SHA256())
    h.update(ikm)
    return h.finalize()


def hkdf_expand(prk: bytes, info: bytes, length: int) -> bytes:
    """HKDF-Expand (RFC 5869 2.3)."""
    return HKDFExpand(algorithm=hashes.SHA256(), length=length, info=info).derive(prk)


# --- Argon2id ------------------------------------------------------------------


def argon2id(password: bytes, salt: bytes) -> bytes:
    """SPEC-VTF 4.2 pw_key: Argon2id v1.3, m=256 MiB, t=3, p=4, 32-byte tag,
    no secret, no associated data."""
    return hash_secret_raw(
        secret=password,
        salt=salt,
        time_cost=ARGON2_T,
        memory_cost=ARGON2_M_KIB,
        parallelism=ARGON2_P,
        hash_len=32,
        type=Type.ID,
        version=ARGON2_VERSION,
    )


# --- HChaCha20 / XChaCha20-Poly1305 (reference/test code only) -------------------

_MASK = 0xFFFFFFFF
_SIGMA = (0x61707865, 0x3320646E, 0x79622D32, 0x6B206574)  # "expand 32-byte k"


def _rotl(v: int, c: int) -> int:
    return ((v << c) & _MASK) | (v >> (32 - c))


def _qr(s: list[int], a: int, b: int, c: int, d: int) -> None:
    s[a] = (s[a] + s[b]) & _MASK
    s[d] = _rotl(s[d] ^ s[a], 16)
    s[c] = (s[c] + s[d]) & _MASK
    s[b] = _rotl(s[b] ^ s[c], 12)
    s[a] = (s[a] + s[b]) & _MASK
    s[d] = _rotl(s[d] ^ s[a], 8)
    s[c] = (s[c] + s[d]) & _MASK
    s[b] = _rotl(s[b] ^ s[c], 7)


def hchacha20(key: bytes, nonce16: bytes) -> bytes:
    """HChaCha20 (draft-irtf-cfrg-xchacha-03 2.2). REFERENCE/TEST CODE ONLY."""
    if len(key) != 32 or len(nonce16) != 16:
        raise ValueError("hchacha20: bad key/nonce length")
    s = list(_SIGMA) + list(struct.unpack("<8I", key)) + list(struct.unpack("<4I", nonce16))
    for _ in range(10):
        _qr(s, 0, 4, 8, 12)
        _qr(s, 1, 5, 9, 13)
        _qr(s, 2, 6, 10, 14)
        _qr(s, 3, 7, 11, 15)
        _qr(s, 0, 5, 10, 15)
        _qr(s, 1, 6, 11, 12)
        _qr(s, 2, 7, 8, 13)
        _qr(s, 3, 4, 9, 14)
    return struct.pack("<8I", *(s[0:4] + s[12:16]))


def _xchacha_parts(key: bytes, nonce: bytes) -> tuple[ChaCha20Poly1305, bytes]:
    if len(key) != KEY_LEN or len(nonce) != NONCE_LEN:
        raise ValueError("xchacha20poly1305: bad key/nonce length")
    subkey = hchacha20(key, nonce[:16])
    return ChaCha20Poly1305(subkey), b"\x00\x00\x00\x00" + nonce[16:]


def aead_seal(key: bytes, nonce: bytes, aad: bytes, pt: bytes) -> bytes:
    """XChaCha20-Poly1305 encrypt; returns ciphertext || 16-byte tag."""
    aead, n12 = _xchacha_parts(key, nonce)
    return aead.encrypt(n12, pt, aad)


def aead_open(key: bytes, nonce: bytes, aad: bytes, ct: bytes) -> bytes | None:
    """XChaCha20-Poly1305 decrypt; None on authentication failure."""
    aead, n12 = _xchacha_parts(key, nonce)
    try:
        return aead.decrypt(n12, ct, aad)
    except InvalidTag:
        return None
