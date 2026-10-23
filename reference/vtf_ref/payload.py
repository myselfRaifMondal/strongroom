"""VTF1 payload: plaintext framing (SPEC-VTF 6.1), schema (6.3), limits (6.4)
and the payload checks 16..26 of section 7, in table order.

REFERENCE / TEST CODE ONLY.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from . import cbor
from .cbor import Bool, CborReject, Map

CHUNK_PLAINTEXT = 65_536
MAX_DEPTH = 16
MAX_TEXT = 65_536
MAX_BYTES = 16

# --- Schema (SPEC-VTF 6.3) ---------------------------------------------------------
# A type is one of the strings below, ("array", elem_type, limit) or ("map", schema).
UINT, KIND, TSTR, BSTR16, FLAG = "uint", "kind", "tstr", "bstr16", "flag"
R, O = True, False


def _arr(elem, limit):
    return ("array", elem, limit)


FIELD = {1: (R, TSTR), 2: (R, TSTR), 3: (O, FLAG)}

_DATA_KEYS = {
    2: (R, KIND),
    3: (R, TSTR),
    7: (O, TSTR),
    8: (O, TSTR),
    9: (O, _arr(TSTR, 64)),
    10: (O, TSTR),
    11: (O, TSTR),
    12: (O, TSTR),
    13: (O, _arr(TSTR, 64)),
    14: (O, _arr(("map", FIELD), 128)),
    15: (O, FLAG),
}
REVISION_DATA = dict(_DATA_KEYS)
REVISION = {1: (R, UINT), 2: (R, ("map", REVISION_DATA))}
ITEM = {
    1: (R, BSTR16),
    **{k: v for k, v in _DATA_KEYS.items()},
    4: (R, UINT),
    5: (R, UINT),
    6: (R, UINT),
    16: (O, _arr(("map", REVISION), 64)),
    17: (O, UINT),
}
TOMBSTONE = {1: (R, BSTR16), 2: (R, UINT), 3: (R, UINT)}
TOP = {1: (R, UINT), 2: (R, UINT), 3: (R, _arr(("map", ITEM), 100_000)), 4: (O, _arr(("map", TOMBSTONE), 100_000))}


def _is_uint(v) -> bool:
    return type(v) is int


def _type_ok(t, v) -> bool:
    if t == UINT:
        return _is_uint(v)
    if t == KIND:
        return _is_uint(v) and 0 <= v <= 5
    if t == TSTR:
        return isinstance(v, str)
    if t == BSTR16:
        # A byte string longer than 16 is a limit violation (6.4), checked by 25.
        return isinstance(v, bytes) and len(v) >= 16
    if t == FLAG:
        return isinstance(v, Bool)
    if t[0] == "array":
        return isinstance(v, list) and all(_type_ok(t[1], x) for x in v)
    if t[0] == "map":
        return isinstance(v, Map) and _types_in_map(t[1], v)
    raise AssertionError(t)


def _types_in_map(schema, m: Map) -> bool:
    for k, v in m.pairs:
        if _is_uint(k) and k in schema and not _type_ok(schema[k][1], v):
            return False
    return True


def _children(schema, m: Map):
    """Yield (child_schema, child_map) for every nested schema map below m."""
    for k, v in m.pairs:
        if not (_is_uint(k) and k in schema):
            continue
        t = schema[k][1]
        if isinstance(t, tuple) and t[0] == "map":
            yield t[1], v
        elif isinstance(t, tuple) and t[0] == "array" and isinstance(t[1], tuple):
            for x in v:
                yield t[1][1], x


def _walk(schema, m: Map):
    yield schema, m
    for s, c in _children(schema, m):
        yield from _walk(s, c)


def _texts_and_bytes(v):
    if isinstance(v, (str, bytes)):
        yield v
    elif isinstance(v, list):
        for x in v:
            yield from _texts_and_bytes(x)
    elif isinstance(v, Map):
        for k, x in v.pairs:
            yield from _texts_and_bytes(k)
            yield from _texts_and_bytes(x)


def check_plaintext(plaintext: bytes) -> tuple[bytes, Map]:
    """Run checks 16..26 over the concatenated chunk plaintext.

    Returns (cbor_payload_bytes, tree) or raises CborReject(check_name)."""
    # 16 cbor-wellformed
    sr = cbor.scan(plaintext)
    # 17 padding
    pad = plaintext[sr.end :]
    if len(pad) >= CHUNK_PLAINTEXT or any(pad):
        raise CborReject("padding")
    # 18..20 generic
    if sr.non_deterministic:
        raise CborReject("cbor-deterministic")
    if sr.duplicate_key:
        raise CborReject("cbor-duplicate-key")
    if sr.max_depth > MAX_DEPTH:
        raise CborReject("cbor-depth")
    # 21 cbor-type: generic part
    if sr.has_tag or sr.has_float or sr.has_other_simple:
        raise CborReject("cbor-type")
    body = plaintext[: sr.end]
    tree = cbor.build(body)
    # 21 cbor-type: schema part
    if not isinstance(tree, Map) or not _types_in_map(TOP, tree):
        raise CborReject("cbor-type")
    maps = list(_walk(TOP, tree))
    # 22 cbor-unknown-key
    for schema, m in maps:
        for k, _ in m.pairs:
            if not (_is_uint(k) and k in schema):
                raise CborReject("cbor-unknown-key")
    # 23 cbor-missing-key
    for schema, m in maps:
        for k, (req, _) in schema.items():
            if req and not m.has(k):
                raise CborReject("cbor-missing-key")
    # 24 cbor-empty-optional
    for schema, m in maps:
        for k, v in m.pairs:
            req, t = schema[k]
            if req:
                continue
            if t == FLAG and not v.v:
                raise CborReject("cbor-empty-optional")
            if isinstance(t, tuple) and t[0] == "array" and len(v) == 0:
                raise CborReject("cbor-empty-optional")
    # 25 cbor-limit
    for schema, m in maps:
        for k, v in m.pairs:
            t = schema[k][1]
            if isinstance(t, tuple) and t[0] == "array" and len(v) > t[2]:
                raise CborReject("cbor-limit")
    for s in _texts_and_bytes(tree):
        if isinstance(s, str) and len(s.encode("utf-8")) > MAX_TEXT:
            raise CborReject("cbor-limit")
        if isinstance(s, bytes) and len(s) > MAX_BYTES:
            raise CborReject("cbor-limit")
    # 26 payload-version
    if tree.get(1) != 1:
        raise CborReject("payload-version")
    return body, tree


def pad_payload(cbor_payload: bytes) -> bytes:
    """SPEC-VTF 6.1: zero-pad to the smallest positive multiple of 65536."""
    n = len(cbor_payload)
    total = max(1, -(-n // CHUNK_PLAINTEXT)) * CHUNK_PLAINTEXT
    return cbor_payload + b"\x00" * (total - n)


# --- Typed model + deterministic encoder (exercises the omit-empty rules) ---------


@dataclass
class FieldV:
    name: str
    value: str
    concealed: bool = False


@dataclass
class Data:
    kind: int
    title: str
    username: str | None = None
    password: str | None = None
    urls: list[str] = field(default_factory=list)
    notes: str | None = None
    totp: str | None = None
    folder: str | None = None
    tags: list[str] = field(default_factory=list)
    fields: list[FieldV] = field(default_factory=list)
    travel_safe: bool = False


@dataclass
class RevisionV:
    modified_at: int
    data: Data


@dataclass
class ItemV:
    id: bytes
    created_at: int
    modified_at: int
    hlc: int
    data: Data
    history: list[RevisionV] = field(default_factory=list)
    trashed_at: int | None = None


@dataclass
class TombstoneV:
    id: bytes
    deleted_at: int
    hlc: int


@dataclass
class PayloadV:
    exported_at: int
    items: list[ItemV]
    tombstones: list[TombstoneV] = field(default_factory=list)


def _data_from(m: Map) -> Data:
    g = m.get
    return Data(
        kind=g(2),
        title=g(3),
        username=g(7),
        password=g(8),
        urls=list(g(9) or []),
        notes=g(10),
        totp=g(11),
        folder=g(12),
        tags=list(g(13) or []),
        fields=[FieldV(f.get(1), f.get(2), f.has(3)) for f in (g(14) or [])],
        travel_safe=m.has(15),
    )


def model_from_tree(t: Map) -> PayloadV:
    items = []
    for it in t.get(3):
        items.append(
            ItemV(
                id=it.get(1),
                created_at=it.get(4),
                modified_at=it.get(5),
                hlc=it.get(6),
                data=_data_from(it),
                history=[RevisionV(r.get(1), _data_from(r.get(2))) for r in (it.get(16) or [])],
                trashed_at=it.get(17),
            )
        )
    tombs = [TombstoneV(x.get(1), x.get(2), x.get(3)) for x in (t.get(4) or [])]
    return PayloadV(exported_at=t.get(2), items=items, tombstones=tombs)


def _data_pairs(d: Data) -> list:
    p: list = [(2, d.kind), (3, d.title)]
    for k, v in ((7, d.username), (8, d.password), (10, d.notes), (11, d.totp), (12, d.folder)):
        if v is not None:
            p.append((k, v))
    if d.urls:
        p.append((9, list(d.urls)))
    if d.tags:
        p.append((13, list(d.tags)))
    if d.fields:
        p.append(
            (14, [Map([(1, f.name), (2, f.value)] + ([(3, Bool(True))] if f.concealed else [])) for f in d.fields])
        )
    if d.travel_safe:
        p.append((15, Bool(True)))
    return p


def encode_model(pl: PayloadV) -> bytes:
    items = []
    for it in pl.items:
        p = [(1, it.id), (4, it.created_at), (5, it.modified_at), (6, it.hlc)] + _data_pairs(it.data)
        if it.history:
            p.append((16, [Map([(1, r.modified_at), (2, Map(_data_pairs(r.data)))]) for r in it.history]))
        if it.trashed_at is not None:
            p.append((17, it.trashed_at))
        items.append(Map(p))
    top = [(1, 1), (2, pl.exported_at), (3, items)]
    if pl.tombstones:
        top.append((4, [Map([(1, t.id), (2, t.deleted_at), (3, t.hlc)]) for t in pl.tombstones]))
    return cbor.encode(Map(top))
