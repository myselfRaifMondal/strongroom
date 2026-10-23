"""Unit tests for the reference's own CBOR/payload checks and KATs (no Argon2)."""

import pytest

from vtf_ref import cbor
from vtf_ref.payload import check_plaintext, pad_payload
from vtf_ref.selftest import SELFTESTS

H = bytes.fromhex
VALID = H("a30101020003 80".replace(" ", ""))  # {1:1, 2:0, 3:[]}


def check(cbor_bytes: bytes, pad: bool = True) -> str:
    try:
        check_plaintext(pad_payload(cbor_bytes) if pad else cbor_bytes)
        return "ok"
    except cbor.CborReject as e:
        return e.check


@pytest.mark.parametrize(("name", "fn"), SELFTESTS)
def test_kat(name, fn):
    fn()


@pytest.mark.parametrize(
    ("hexstr", "want"),
    [
        ("a3010102000380", "ok"),
        ("a301010200038 1a0".replace(" ", ""), "cbor-missing-key"),
        ("a30101020003817a00010000", "cbor-wellformed"),  # text runs past the plaintext
        ("a3010102000381ff", "cbor-wellformed"),  # stray break
        ("a30101021f0380", "cbor-wellformed"),  # major 0 with ai 31
        ("a3010102df000380", "cbor-wellformed"),  # tag with ai 31
        ("a3010102f8100380", "cbor-wellformed"),  # two-byte simple < 32
        ("a3010102fc0380", "cbor-wellformed"),  # reserved ai 28
        ("a3010102627f800380", "cbor-wellformed"),  # invalid UTF-8 (lone 0x80)
        ("a301010218000380", "cbor-deterministic"),  # non-shortest uint
        ("a301010200039fff", "cbor-deterministic"),  # indefinite array
        ("a30201010003 80".replace(" ", ""), "cbor-deterministic"),  # unsorted keys
        ("a40101010102000380", "cbor-duplicate-key"),
        ("a3010102f93c000380", "cbor-type"),  # half float
        ("a3010102c1000380", "cbor-type"),  # tag
        ("a3010102f60380", "cbor-type"),  # null
        ("a3010102f70380", "cbor-type"),  # undefined
        ("a3010102f00380", "cbor-type"),  # simple(16)
        ("a3010102200380", "cbor-type"),  # negative int where uint required
        ("a301010200036161", "cbor-type"),  # items is text
        ("a40101020003800520", "cbor-unknown-key"),  # nint under unknown key is not itself a fault
        ("a4010102000380616b00", "cbor-unknown-key"),  # text map key
        ("a2010102 00".replace(" ", ""), "cbor-missing-key"),
        ("a4010102000380 0480".replace(" ", ""), "cbor-empty-optional"),
        ("a3010202000380", "payload-version"),
    ],
)
def test_payload_checks(hexstr, want):
    assert check(H(hexstr)) == want


def _item(extra: bytes = b"", n_extra: int = 0) -> bytes:
    # {1: id16, 2: 0, 3: "t", 4: 0, 5: 0, 6: 0, ...extra}
    head = bytes([0xA0 + 6 + n_extra])
    return head + b"\x01\x50" + b"\x00" * 16 + b"\x02\x00\x03\x61t\x04\x00\x05\x00\x06\x00" + extra


def _payload_with(item: bytes) -> bytes:
    return H("a3010102000381") + item


def test_item_valid_and_flags():
    assert check(_payload_with(_item())) == "ok"
    assert check(_payload_with(_item(b"\x0f\xf5", 1))) == "ok"  # travel_safe true
    assert check(_payload_with(_item(b"\x0f\xf4", 1))) == "cbor-empty-optional"  # false encoded
    assert check(_payload_with(_item(b"\x09\x80", 1))) == "cbor-empty-optional"  # empty urls
    bad_kind = _item().replace(b"\x02\x00\x03", b"\x02\x06\x03")
    assert check(_payload_with(bad_kind)) == "cbor-type"  # kind 6 is not defined


def test_limits():
    big = b"\x7a\x00\x01\x00\x01" + b"a" * 65537
    assert check(_payload_with(_item(b"\x0a" + big, 1))) == "cbor-limit"  # notes too long
    ok = b"\x7a\x00\x01\x00\x00" + b"a" * 65536
    assert check(_payload_with(_item(b"\x0a" + ok, 1))) == "ok"
    urls = b"\x09\x98\x41" + b"\x61u" * 65
    assert check(_payload_with(_item(urls, 1))) == "cbor-limit"
    short_id = _item().replace(b"\x01\x50" + b"\x00" * 16, b"\x01\x4f" + b"\x00" * 15)
    assert check(_payload_with(short_id)) == "cbor-type"


def test_depth():
    nested16 = H("a3010102000381") + b"\x81" * 14 + b"\x00"  # top map depth 1, items 2, +14 = 16
    nested17 = H("a3010102000381") + b"\x81" * 15 + b"\x00"
    # depth 16 passes the generic depth check and then fails typing; 17 fails depth
    assert check(nested16) == "cbor-type"
    assert check(nested17) == "cbor-depth"


def test_padding():
    assert check(VALID + b"\x00" * (65536 - len(VALID)), pad=False) == "ok"
    p = bytearray(pad_payload(VALID))
    p[-1] = 1
    assert check(bytes(p), pad=False) == "padding"
    assert check(pad_payload(VALID) + b"\x00" * 65536, pad=False) == "padding"


def test_scanner_is_iterative():
    # a million nested arrays must not exhaust the Python stack
    deep = H("a3010102000381") + b"\x81" * 1_000_000 + b"\x00"
    assert check(deep) == "cbor-depth"
