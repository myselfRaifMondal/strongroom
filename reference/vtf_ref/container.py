"""VTF1 container: fixed header, key slots, chunked AEAD (SPEC-VTF 3, 4, 5, 7, 8).

REFERENCE / TEST CODE ONLY. Exports are deterministic: every random value
is supplied by the caller (from vectors/manifest.json).
"""

from __future__ import annotations

import struct
import unicodedata
from dataclasses import dataclass

from . import hpke
from .cbor import CborReject
from .payload import CHUNK_PLAINTEXT, check_plaintext, pad_payload
from .primitives import TAG_LEN, aead_open, aead_seal, argon2id, ct_eq, hkdf, sha256

MAGIC = b"VTF1"
HEADER_LEN = 84
CHUNK_LEN = CHUNK_PLAINTEXT + TAG_LEN
MAX_SLOTS = 16
MAX_CHUNKS = 4096
SLOT_PASSWORD, SLOT_DEVICE = 0x01, 0x02
PASSWORD_SLOT_LEN, DEVICE_SLOT_LEN = 73, 146
FLAG_HAS_DEVICE_SLOTS = 0x0001
KEM_ID = 0x0010
ARGON2 = (262_144, 3, 4)


class Reject(Exception):
    """An import failed the named SPEC-VTF section 7 check."""

    def __init__(self, check: str):
        super().__init__(check)
        self.check = check


# --- Key derivation (SPEC-VTF 4) -----------------------------------------------


def password_bytes(password: str) -> bytes:
    return unicodedata.normalize("NFKC", password).encode("utf-8")


_KEK_CACHE: dict[tuple[bytes, bytes, bytes], bytes] = {}


def derive_kek(pw: bytes, secret_key: bytes, salt: bytes) -> bytes:
    """KEK = HKDF(Argon2id(pw) || HKDF(sk, salt, "VTF1/secret-key"), salt, "VTF1/kek").

    Memoised (pure function) so the vector run does not repeat 256 MiB Argon2id."""
    key = (pw, secret_key, salt)
    if key not in _KEK_CACHE:
        pw_key = argon2id(pw, salt)
        sk_key = hkdf(secret_key, salt, b"VTF1/secret-key", 32)
        _KEK_CACHE[key] = hkdf(pw_key + sk_key, salt, b"VTF1/kek", 32)
    return _KEK_CACHE[key]


def payload_key(vtk: bytes, salt: bytes) -> bytes:
    return hkdf(vtk, salt, b"VTF1/payload", 32)


def key_id(pk: bytes) -> bytes:
    return sha256(pk)[:8]


def hpke_info(fixed_header: bytes) -> bytes:
    return b"VTF1/hpke-info" + sha256(fixed_header)


# --- Export (SPEC-VTF 8), deterministic ------------------------------------------


@dataclass
class Randomness:
    salt: bytes
    chunk_nonce_prefix: bytes
    vtk: bytes
    password_slot_nonce: bytes
    device_slots: list[tuple[bytes, bytes]]  # (ikm_e, nonce) per device recipient


def build_header(flags: int, salt: bytes, prefix: bytes, slot_count: int, chunk_count: int) -> bytes:
    h = (
        MAGIC
        + struct.pack(">HHBBH", 1, flags, 0x01, 0x01, KEM_ID)
        + struct.pack(">III", *ARGON2)
        + salt
        + prefix
        + bytes([slot_count])
        + struct.pack(">I", chunk_count)
        + b"\x00\x00\x00\x00"
    )
    assert len(h) == HEADER_LEN
    return h


def export(
    cbor_payload: bytes,
    password: str | None,
    secret_key: bytes,
    device_recipients: list[bytes],
    rnd: Randomness,
) -> bytes:
    if password is None and not device_recipients:
        raise ValueError("export needs a password slot or a device slot")
    pw = None
    if password is not None:
        pw = password_bytes(password)
        if not pw:
            raise ValueError("empty password")
    plaintext = pad_payload(cbor_payload)
    chunk_count = len(plaintext) // CHUNK_PLAINTEXT
    slot_count = (1 if pw is not None else 0) + len(device_recipients)
    flags = FLAG_HAS_DEVICE_SLOTS if device_recipients else 0
    header = build_header(flags, rnd.salt, rnd.chunk_nonce_prefix, slot_count, chunk_count)

    slots = b""
    if pw is not None:
        kek = derive_kek(pw, secret_key, rnd.salt)
        slots += bytes([SLOT_PASSWORD]) + rnd.password_slot_nonce
        slots += aead_seal(kek, rnd.password_slot_nonce, header + bytes([SLOT_PASSWORD]), rnd.vtk)
    info = hpke_info(header)
    for pkr, (ikm_e, nonce) in zip(device_recipients, rnd.device_slots, strict=False):
        kid = key_id(pkr)
        enc, ctx = hpke.setup_base_s_export_only(pkr, info, ikm_e)
        wrap_key = ctx.export(b"VTF1/device-wrap", 32)
        aad = header + bytes([SLOT_DEVICE]) + kid + enc
        slots += bytes([SLOT_DEVICE]) + kid + enc + nonce + aead_seal(wrap_key, nonce, aad, rnd.vtk)
    if len(rnd.device_slots) < len(device_recipients):
        raise ValueError("not enough device-slot randomness")

    pkey = payload_key(rnd.vtk, rnd.salt)
    header_hash = sha256(header + slots)
    out = [header, slots]
    for i in range(chunk_count):
        nonce = rnd.chunk_nonce_prefix + struct.pack(">I", i) + (b"\x01" if i == chunk_count - 1 else b"\x00")
        out.append(aead_seal(pkey, nonce, header_hash, plaintext[i * CHUNK_PLAINTEXT : (i + 1) * CHUNK_PLAINTEXT]))
    return b"".join(out)


# --- Import (SPEC-VTF 7) ----------------------------------------------------------


@dataclass
class Parsed:
    header: bytes
    slot_table: bytes
    slots: list[bytes]
    chunk_count: int
    salt: bytes
    prefix: bytes


def parse(file: bytes) -> Parsed:
    """Checks 1..13 (everything before key derivation)."""
    if len(file) < HEADER_LEN:
        raise Reject("length-min")
    h = file[:HEADER_LEN]
    if h[0:4] != MAGIC:
        raise Reject("magic")
    version, flags, kdf_id, aead_id, kem_id = struct.unpack(">HHBBH", h[4:12])
    if version != 1:
        raise Reject("version")
    if flags & ~FLAG_HAS_DEVICE_SLOTS & 0xFFFF:
        raise Reject("flags-reserved")
    if kdf_id != 0x01:
        raise Reject("kdf-id")
    if aead_id != 0x01:
        raise Reject("aead-id")
    if kem_id != KEM_ID:
        raise Reject("kem-id")
    if struct.unpack(">III", h[12:24]) != ARGON2:
        raise Reject("argon2-params")
    if h[80:84] != b"\x00\x00\x00\x00":
        raise Reject("reserved")
    slot_count = h[75]
    if slot_count == 0 or slot_count > MAX_SLOTS:
        raise Reject("slot-count")
    pos = HEADER_LEN
    slots: list[bytes] = []
    seen_password = False
    seen_ids: list[bytes] = []
    for _ in range(slot_count):
        if pos >= len(file):
            raise Reject("slot-table")
        t = file[pos]
        if t == SLOT_PASSWORD:
            ln = PASSWORD_SLOT_LEN
        elif t == SLOT_DEVICE:
            ln = DEVICE_SLOT_LEN
        else:
            raise Reject("slot-table")
        if pos + ln > len(file):
            raise Reject("slot-table")
        s = file[pos : pos + ln]
        if t == SLOT_PASSWORD:
            if seen_password:
                raise Reject("slot-table")
            seen_password = True
        else:
            kid = s[1:9]
            if kid in seen_ids:
                raise Reject("slot-table")
            seen_ids.append(kid)
        slots.append(s)
        pos += ln
    if bool(flags & FLAG_HAS_DEVICE_SLOTS) != bool(seen_ids):
        raise Reject("flags-device-slots")
    chunk_count = struct.unpack(">I", h[76:80])[0]
    if chunk_count == 0 or chunk_count > MAX_CHUNKS or len(file) != pos + CHUNK_LEN * chunk_count:
        raise Reject("length")
    return Parsed(h, file[HEADER_LEN:pos], slots, chunk_count, h[24:56], h[56:75])


def _unwrap_password(p: Parsed, password: str, secret_key: bytes) -> bytes:
    pw = password_bytes(password)
    slot = next((s for s in p.slots if s[0] == SLOT_PASSWORD), None)
    if slot is None or not pw or len(secret_key) != 16:
        raise Reject("slot-unwrap")
    kek = derive_kek(pw, secret_key, p.salt)
    vtk = aead_open(kek, slot[1:25], p.header + bytes([SLOT_PASSWORD]), slot[25:73])
    if vtk is None:
        raise Reject("slot-unwrap")
    return vtk


def _unwrap_device(p: Parsed, device_sk: bytes) -> bytes:
    pk = hpke.serialize_public_key(hpke.private_key_from_bytes(device_sk).public_key())
    kid = key_id(pk)
    slot = None
    for s in p.slots:  # scan every slot; constant-time key_id comparison
        if s[0] == SLOT_DEVICE and ct_eq(s[1:9], kid):
            slot = s
    if slot is None:
        raise Reject("slot-unwrap")
    enc, nonce, wrapped = slot[9:74], slot[74:98], slot[98:146]
    try:
        ctx = hpke.setup_base_r_export_only(enc, device_sk, hpke_info(p.header))
    except ValueError:
        raise Reject("slot-unwrap") from None
    wrap_key = ctx.export(b"VTF1/device-wrap", 32)
    vtk = aead_open(wrap_key, nonce, p.header + bytes([SLOT_DEVICE]) + slot[1:9] + enc, wrapped)
    if vtk is None:
        raise Reject("slot-unwrap")
    return vtk


def decrypt(file: bytes, *, password: str | None = None, secret_key: bytes | None = None, device_sk: bytes | None = None):
    """Full import. Returns (cbor_payload, padded_plaintext, tree) or raises Reject."""
    p = parse(file)
    if device_sk is not None:
        vtk = _unwrap_device(p, device_sk)
    else:
        vtk = _unwrap_password(p, password or "", secret_key or b"")
    pkey = payload_key(vtk, p.salt)
    header_hash = sha256(p.header + p.slot_table)
    base = HEADER_LEN + len(p.slot_table)
    parts = []
    for i in range(p.chunk_count):
        nonce = p.prefix + struct.pack(">I", i) + (b"\x01" if i == p.chunk_count - 1 else b"\x00")
        ct = file[base + i * CHUNK_LEN : base + (i + 1) * CHUNK_LEN]
        pt = aead_open(pkey, nonce, header_hash, ct)
        if pt is None:
            raise Reject("chunk-auth")
        parts.append(pt)
    plaintext = b"".join(parts)
    try:
        body, tree = check_plaintext(plaintext)
    except CborReject as e:
        raise Reject(e.check) from None
    return body, plaintext, tree
