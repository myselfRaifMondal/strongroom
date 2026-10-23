"""Known-answer tests for the hand-composed primitives, taken from the
published documents (not from the Rust code):

- HChaCha20: draft-irtf-cfrg-xchacha-03 section 2.2.1
- XChaCha20-Poly1305: draft-irtf-cfrg-xchacha-03 appendix A.1
- HPKE: RFC 9180 appendix A.3.1, DHKEM(P-256, HKDF-SHA256), HKDF-SHA256,
  AES-128-GCM, base mode (DeriveKeyPair, Encap/Decap, key schedule,
  first encryption, all three exported values)

REFERENCE / TEST CODE ONLY.
"""

from __future__ import annotations

from collections.abc import Callable

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from . import hpke
from .primitives import aead_open, aead_seal, hchacha20

H = bytes.fromhex


def _hchacha20() -> None:
    key = H("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    nonce = H("000000090000004a0000000031415927")
    want = H("82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc")
    assert hchacha20(key, nonce) == want, "HChaCha20 KAT"


def _xchacha_aead() -> None:
    pt = (
        b"Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, "
        b"sunscreen would be it."
    )
    aad = H("50515253c0c1c2c3c4c5c6c7")
    key = H("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
    iv = H("404142434445464748494a4b4c4d4e4f5051525354555657")
    ct = H(
        "bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb"
        "731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b452"
        "2f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff9"
        "21f9664c97637da9768812f615c68b13b52e"
    )
    tag = H("c0875924c1c7987947deafd8780acf49")
    assert aead_seal(key, iv, aad, pt) == ct + tag, "XChaCha20-Poly1305 seal KAT"
    assert aead_open(key, iv, aad, ct + tag) == pt, "XChaCha20-Poly1305 open KAT"
    bad = bytearray(ct + tag)
    bad[-1] ^= 1
    assert aead_open(key, iv, aad, bytes(bad)) is None, "XChaCha20-Poly1305 must reject a bad tag"


def _hpke_a31() -> None:
    info = H("4f6465206f6e2061204772656369616e2055726e")
    ikm_e = H("4270e54ffd08d79d5928020af4686d8f6b7d35dbe470265f1f5aa22816ce860e")
    ikm_r = H("668b37171f1072f3cf12ea8a236a45df23fc13b82af3609ad1e354f6ef817550")
    pk_em = H(
        "04a92719c6195d5085104f469a8b9814d5838ff72b60501e2c4466e5e67b32"
        "5ac98536d7b61a1af4b78e5b7f951c0900be863c403ce65c9bfcb9382657222d18c4"
    )
    sk_em = H("4995788ef4b9d6132b249ce59a77281493eb39af373d236a1fe415cb0c2d7beb")
    pk_rm = H(
        "04fe8c19ce0905191ebc298a9245792531f26f0cece2460639e8bc39cb7f70"
        "6a826a779b4cf969b8a0e539c7f62fb3d30ad6aa8f80e30f1d128aafd68a2ce72ea0"
    )
    sk_rm = H("f3ce7fdae57e1a310d87f1ebbde6f328be0a99cdbcadf4d6589cf29de4b8ffd2")
    shared = H("c0d26aeab536609a572b07695d933b589dcf363ff9d93c93adea537aeabb8cb8")
    ksc = H(
        "00b88d4e6d91759e65e87c470e8b9141113e9ad5f0c8ceefc1e088c82e6980500798"
        "e486f9c9c09c9b5c753ac72d6005de254c607d1b534ed11d493ae1c1d9ac85"
    )
    secret = H("2eb7b6bf138f6b5aff857414a058a3f1750054a9ba1f72c2cf0684a6f20b10e1")
    key = H("868c066ef58aae6dc589b6cfdd18f97e")
    base_nonce = H("4e0bc5018beba4bf004cca59")
    exporter_secret = H("14ad94af484a7ad3ef40e9f3be99ecc6fa9036df9d4920548424df127ee0d99f")

    assert hpke.derive_key_pair(ikm_e) == (sk_em, pk_em), "A.3.1 DeriveKeyPair(ikmE)"
    assert hpke.derive_key_pair(ikm_r) == (sk_rm, pk_rm), "A.3.1 DeriveKeyPair(ikmR)"
    ss, enc = hpke.encap_deterministic(pk_rm, ikm_e)
    assert enc == pk_em, "A.3.1 enc"
    assert ss == shared, "A.3.1 shared_secret (Encap)"
    assert hpke.decap(enc, sk_rm) == shared, "A.3.1 shared_secret (Decap)"
    ctx = hpke.key_schedule_base(ss, info, 0x0001, 16, 12)
    assert ctx.key_schedule_context == ksc, "A.3.1 key_schedule_context"
    assert ctx.secret == secret, "A.3.1 secret"
    assert ctx.key == key, "A.3.1 key"
    assert ctx.base_nonce == base_nonce, "A.3.1 base_nonce"
    assert ctx.exporter_secret == exporter_secret, "A.3.1 exporter_secret"
    pt = H("4265617574792069732074727574682c20747275746820626561757479")
    ct0 = H("5ad590bb8baa577f8619db35a36311226a896e7342a6d836d8b7bcd2f20b6c7f9076ac232e3ab2523f39513434")
    assert AESGCM(key).encrypt(base_nonce, pt, b"Count-0") == ct0, "A.3.1 encryption seq 0"
    exports = [
        (b"", "5e9bc3d236e1911d95e65b576a8a86d478fb827e8bdfe77b741b289890490d4d"),
        (H("00"), "6cff87658931bda83dc857e6353efe4987a201b849658d9b047aab4cf216e796"),
        (H("54657374436f6e74657874"), "d8f1ea7942adbba7412c6d431c62d01371ea476b823eb697e1f6e6cae1dab85a"),
    ]
    for ectx, want in exports:
        assert ctx.export(ectx, 32) == H(want), f"A.3.1 export({ectx.hex()})"


SELFTESTS: list[tuple[str, Callable[[], None]]] = [
    ("hchacha20 (draft-irtf-cfrg-xchacha-03 2.2.1)", _hchacha20),
    ("xchacha20-poly1305 (draft-irtf-cfrg-xchacha-03 A.1)", _xchacha_aead),
    ("hpke dhkem-p256 base (RFC 9180 A.3.1)", _hpke_a31),
]
