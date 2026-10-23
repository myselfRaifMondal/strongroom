"""Decrypt the payload-level vectors and write their plaintexts (trailing zero
padding stripped) as fuzz seeds for the `payload_decode` target.

    uv run python -m vtf_ref.dump_plaintexts vectors/ ../fuzz/seeds/payload_decode

Only vectors that get past chunk authentication are dumped. REFERENCE /
TEST CODE ONLY; the vectors are public test fixtures.
"""

from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

from . import container
from .primitives import aead_open, sha256
from .verify import _resolve


def _plaintext(data: bytes, pw: str, sk: bytes) -> bytes | None:
    try:
        p = container.parse(data)
        vtk = container._unwrap_password(p, pw, sk)
    except container.Reject:
        return None
    key = container.payload_key(vtk, p.salt)
    hh = sha256(p.header + p.slot_table)
    base = container.HEADER_LEN + len(p.slot_table)
    out = []
    for i in range(p.chunk_count):
        n = p.prefix + struct.pack(">I", i) + (b"\x01" if i == p.chunk_count - 1 else b"\x00")
        pt = aead_open(key, n, hh, data[base + i * container.CHUNK_LEN : base + (i + 1) * container.CHUNK_LEN])
        if pt is None:
            return None
        out.append(pt)
    return b"".join(out)


def main(argv: list[str]) -> int:
    root = _resolve(argv[1])
    out = Path(argv[2])
    out.mkdir(parents=True, exist_ok=True)
    m = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    sk = bytes.fromhex(m["secret_key_hex"])
    pw = next(v["password"] for v in m["positive"] if v["name"] == "unbound")
    for v in m["negative"]:
        if v["credential"] != "password":
            continue
        pt = _plaintext((root / v["file"]).read_bytes(), pw, sk)
        if pt is not None:
            (out / f"{v['name']}.bin").write_bytes(pt.rstrip(b"\x00") or b"\x00")
            print(v["name"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
