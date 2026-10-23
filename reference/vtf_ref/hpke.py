"""RFC 9180 HPKE, base mode, DHKEM(P-256, HKDF-SHA256) + HKDF-SHA256.

REFERENCE / TEST CODE ONLY. Written from RFC 9180 sections 4, 4.1, 5.1, 5.3,
7.1.3 directly. Only the P-256 scalar multiplication / ECDH and HMAC/HKDF come
from `cryptography`; DeriveKeyPair, Encap/Decap, ExtractAndExpand, the key
schedule and Export are composed here.

The key schedule is parameterised by (aead_id, Nk, Nn) so that it can be
checked against RFC 9180 Appendix A.3.1 (AES-128-GCM) as well as used with
the VTF1 export-only AEAD (0xFFFF, Nk = Nn = 0).
"""

from __future__ import annotations

from dataclasses import dataclass

from cryptography.hazmat.primitives.asymmetric import ec

from .primitives import hkdf_expand, hkdf_extract

KEM_P256 = 0x0010
KDF_HKDF_SHA256 = 0x0001
AEAD_EXPORT_ONLY = 0xFFFF

N_SECRET = 32  # Nsecret for DHKEM(P-256)
N_H = 32  # Nh for HKDF-SHA256
N_SK = 32
N_PK = 65  # Npk, uncompressed SEC1
P256_ORDER = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

MODE_BASE = 0x00


def i2osp(n: int, w: int) -> bytes:
    return n.to_bytes(w, "big")


KEM_SUITE_ID = b"KEM" + i2osp(KEM_P256, 2)


def hpke_suite_id(aead_id: int) -> bytes:
    return b"HPKE" + i2osp(KEM_P256, 2) + i2osp(KDF_HKDF_SHA256, 2) + i2osp(aead_id, 2)


def labeled_extract(suite_id: bytes, salt: bytes, label: bytes, ikm: bytes) -> bytes:
    return hkdf_extract(salt, b"HPKE-v1" + suite_id + label + ikm)


def labeled_expand(suite_id: bytes, prk: bytes, label: bytes, info: bytes, length: int) -> bytes:
    labeled_info = i2osp(length, 2) + b"HPKE-v1" + suite_id + label + info
    return hkdf_expand(prk, labeled_info, length)


# --- DHKEM(P-256, HKDF-SHA256) ------------------------------------------------


def serialize_public_key(pk: ec.EllipticCurvePublicKey) -> bytes:
    nums = pk.public_numbers()
    return b"\x04" + nums.x.to_bytes(32, "big") + nums.y.to_bytes(32, "big")


def deserialize_public_key(pkm: bytes) -> ec.EllipticCurvePublicKey:
    """Uncompressed SEC1 only; raises ValueError for anything else or an
    invalid point (RFC 9180 7.1.4 validation is done by `cryptography`)."""
    if len(pkm) != N_PK or pkm[0] != 0x04:
        raise ValueError("not an uncompressed P-256 point")
    return ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), pkm)


def private_key_from_bytes(skm: bytes) -> ec.EllipticCurvePrivateKey:
    d = int.from_bytes(skm, "big")
    if not 0 < d < P256_ORDER:
        raise ValueError("invalid P-256 scalar")
    return ec.derive_private_key(d, ec.SECP256R1())


def derive_key_pair(ikm: bytes) -> tuple[bytes, bytes]:
    """RFC 9180 7.1.3 DeriveKeyPair for P-256 (bitmask 0xFF). Returns (skm, pkm)."""
    if len(ikm) < N_SK:
        raise ValueError("ikm too short")
    dkp_prk = labeled_extract(KEM_SUITE_ID, b"", b"dkp_prk", ikm)
    for counter in range(256):
        candidate = bytearray(labeled_expand(KEM_SUITE_ID, dkp_prk, b"candidate", i2osp(counter, 1), N_SK))
        candidate[0] &= 0xFF
        sk = int.from_bytes(candidate, "big")
        if sk != 0 and sk < P256_ORDER:
            skm = bytes(candidate)
            pkm = serialize_public_key(private_key_from_bytes(skm).public_key())
            return skm, pkm
    raise ValueError("DeriveKeyPairError")


def _dh(skm: bytes, pkm: bytes) -> bytes:
    # P-256 ECDH; the shared secret is the 32-byte x-coordinate (RFC 9180 4.1).
    return private_key_from_bytes(skm).exchange(ec.ECDH(), deserialize_public_key(pkm))


def _extract_and_expand(dh: bytes, kem_context: bytes) -> bytes:
    eae_prk = labeled_extract(KEM_SUITE_ID, b"", b"eae_prk", dh)
    return labeled_expand(KEM_SUITE_ID, eae_prk, b"shared_secret", kem_context, N_SECRET)


def encap_deterministic(pkr: bytes, ikm_e: bytes) -> tuple[bytes, bytes]:
    """Encap with the ephemeral key from DeriveKeyPair(ikm_e). Returns (shared_secret, enc)."""
    ske, pke = derive_key_pair(ikm_e)
    dh = _dh(ske, pkr)
    return _extract_and_expand(dh, pke + pkr), pke


def decap(enc: bytes, skr: bytes) -> bytes:
    """Decap. Raises ValueError if enc is not a valid P-256 point."""
    pkr = serialize_public_key(private_key_from_bytes(skr).public_key())
    dh = _dh(skr, enc)
    return _extract_and_expand(dh, enc + pkr)


# --- Key schedule (RFC 9180 5.1), base mode -----------------------------------


@dataclass
class Context:
    suite_id: bytes
    key: bytes
    base_nonce: bytes
    exporter_secret: bytes
    key_schedule_context: bytes
    secret: bytes

    def export(self, exporter_context: bytes, length: int) -> bytes:
        return labeled_expand(self.suite_id, self.exporter_secret, b"sec", exporter_context, length)


def key_schedule_base(shared_secret: bytes, info: bytes, aead_id: int, nk: int, nn: int) -> Context:
    suite_id = hpke_suite_id(aead_id)
    psk = b""
    psk_id = b""
    psk_id_hash = labeled_extract(suite_id, b"", b"psk_id_hash", psk_id)
    info_hash = labeled_extract(suite_id, b"", b"info_hash", info)
    ksc = bytes([MODE_BASE]) + psk_id_hash + info_hash
    secret = labeled_extract(suite_id, shared_secret, b"secret", psk)
    key = labeled_expand(suite_id, secret, b"key", ksc, nk) if nk else b""
    base_nonce = labeled_expand(suite_id, secret, b"base_nonce", ksc, nn) if nn else b""
    exporter_secret = labeled_expand(suite_id, secret, b"exp", ksc, N_H)
    return Context(suite_id, key, base_nonce, exporter_secret, ksc, secret)


def setup_base_s_export_only(pkr: bytes, info: bytes, ikm_e: bytes) -> tuple[bytes, Context]:
    shared_secret, enc = encap_deterministic(pkr, ikm_e)
    return enc, key_schedule_base(shared_secret, info, AEAD_EXPORT_ONLY, 0, 0)


def setup_base_r_export_only(enc: bytes, skr: bytes, info: bytes) -> Context:
    return key_schedule_base(decap(enc, skr), info, AEAD_EXPORT_ONLY, 0, 0)
