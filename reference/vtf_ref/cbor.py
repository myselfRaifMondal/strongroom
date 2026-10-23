"""Hand-written CBOR (RFC 8949) scanner, strict tree builder and deterministic
encoder for VTF1 (SPEC-VTF 6.2).

REFERENCE / TEST CODE ONLY.

Design: SPEC-VTF 7 says the importer stops at the *first failing check in
table order*. This module therefore works in whole-document passes:

1. `scan()` checks RFC 8949 well-formedness of exactly one item (check 16),
   iteratively (no recursion, so adversarial nesting cannot exhaust the
   Python stack), and records facts used by the later generic checks:
   non-shortest heads / indefinite lengths / out-of-order map keys (18),
   duplicate map keys (19), maximum container depth (20), and the presence of
   tags, floats and simple values other than false/true (21).
2. Padding (17) is checked by the caller from `scan().end`.
3. `build()` turns a document that passed 16-21(generic) into a tree; depth is
   then <= 16 so recursion is safe.

Depth: the top-level container has depth 1; each array/map nested inside
another adds 1. Tags are not containers (they are rejected by check 21
anyway). Scalars do not add depth.
"""

from __future__ import annotations

from dataclasses import dataclass, field

WELLFORMED = "cbor-wellformed"


class CborReject(Exception):
    def __init__(self, check: str):
        super().__init__(check)
        self.check = check


# --- Tree node types (booleans are NOT Python bool, so they never alias int) ---


@dataclass(frozen=True)
class NInt:
    """CBOR negative integer, value = -1 - n."""

    n: int


@dataclass(frozen=True)
class Bool:
    v: bool


@dataclass
class Map:
    pairs: list[tuple[object, object]]

    def get(self, k: int):
        for kk, vv in self.pairs:
            if type(kk) is int and kk == k:
                return vv
        return None

    def has(self, k: int) -> bool:
        return any(type(kk) is int and kk == k for kk, _ in self.pairs)


# --- Scanner -------------------------------------------------------------------


@dataclass
class ScanResult:
    end: int
    non_deterministic: bool = False
    duplicate_key: bool = False
    max_depth: int = 0
    has_tag: bool = False
    has_float: bool = False
    has_other_simple: bool = False  # null, undefined, unassigned simple values


@dataclass
class _Frame:
    total: int | None  # number of child items; None = indefinite length
    is_map: bool
    is_tag: bool
    cdepth: int  # container depth of this frame (tags inherit the parent's)
    done: int = 0
    child_start: int = 0
    keys: list[bytes] = field(default_factory=list)


def _wf() -> CborReject:
    return CborReject(WELLFORMED)


def _head(buf: bytes, pos: int) -> tuple[int, int, int | None, int]:
    if pos >= len(buf):
        raise _wf()
    ib = buf[pos]
    mt, ai = ib >> 5, ib & 0x1F
    pos += 1
    if ai < 24:
        return mt, ai, ai, pos
    if ai <= 27:
        n = 1 << (ai - 24)
        if pos + n > len(buf):
            raise _wf()
        return mt, ai, int.from_bytes(buf[pos : pos + n], "big"), pos + n
    if ai == 31:
        return mt, ai, None, pos
    raise _wf()  # 28..30 reserved


_SHORTEST_MIN = {24: 24, 25: 0x100, 26: 0x10000, 27: 0x100000000}


def _non_shortest(ai: int, val: int) -> bool:
    return ai in _SHORTEST_MIN and val < _SHORTEST_MIN[ai]


def _check_text(b: bytes) -> None:
    try:
        b.decode("utf-8", "strict")
    except UnicodeDecodeError:
        raise _wf() from None


def scan(buf: bytes, start: int = 0) -> ScanResult:
    """Validate that `buf[start:]` begins with exactly one well-formed CBOR item."""
    r = ScanResult(end=start)
    stack: list[_Frame] = []
    pos = start
    n = len(buf)
    while True:
        item_start = pos
        completed = False
        if stack and stack[-1].total is None and pos < n and buf[pos] == 0xFF and not stack[-1].is_tag:
            f = stack.pop()
            if f.is_map and f.done % 2 == 1:
                raise _wf()  # indefinite map with a key and no value
            pos += 1
            _finish_map(f, r)
            completed = True
        else:
            if stack:
                stack[-1].child_start = item_start
            mt, ai, val, pos = _head(buf, pos)
            parent_depth = stack[-1].cdepth if stack else 0
            if mt in (0, 1):
                if val is None:
                    raise _wf()
                if _non_shortest(ai, val):
                    r.non_deterministic = True
                completed = True
            elif mt in (2, 3):
                if val is None:
                    r.non_deterministic = True
                    while True:  # indefinite string: definite chunks of the same type, then break
                        if pos >= n:
                            raise _wf()
                        if buf[pos] == 0xFF:
                            pos += 1
                            break
                        cmt, cai, clen, pos = _head(buf, pos)
                        if cmt != mt or clen is None:
                            raise _wf()
                        if _non_shortest(cai, clen):
                            r.non_deterministic = True
                        if clen > n - pos:
                            raise _wf()
                        if mt == 3:
                            _check_text(buf[pos : pos + clen])
                        pos += clen
                else:
                    if _non_shortest(ai, val):
                        r.non_deterministic = True
                    if val > n - pos:
                        raise _wf()
                    if mt == 3:
                        _check_text(buf[pos : pos + val])
                    pos += val
                completed = True
            elif mt in (4, 5):
                depth = parent_depth + 1
                r.max_depth = max(r.max_depth, depth)
                if val is None:
                    r.non_deterministic = True
                    stack.append(_Frame(None, mt == 5, False, depth))
                else:
                    if _non_shortest(ai, val):
                        r.non_deterministic = True
                    total = val * (2 if mt == 5 else 1)
                    if total > n - pos:  # every child needs at least one byte
                        raise _wf()
                    if total == 0:
                        completed = True
                    else:
                        stack.append(_Frame(total, mt == 5, False, depth))
            elif mt == 6:
                if val is None:
                    raise _wf()
                if _non_shortest(ai, val):
                    r.non_deterministic = True
                r.has_tag = True
                stack.append(_Frame(1, False, True, parent_depth))
            else:  # mt == 7
                if ai == 31:
                    raise _wf()  # break outside an indefinite container
                if ai in (25, 26, 27):
                    r.has_float = True
                elif ai == 24:
                    if val < 32:
                        raise _wf()  # RFC 8949 3.3: not well-formed
                    r.has_other_simple = True
                elif ai not in (20, 21):
                    r.has_other_simple = True
                completed = True
        while completed:
            if not stack:
                r.end = pos
                return r
            f = stack[-1]
            if f.is_map and f.done % 2 == 0:
                f.keys.append(bytes(buf[f.child_start : pos]))
            f.done += 1
            if f.total is not None and f.done == f.total:
                # The closed container is itself a completed child of the next
                # frame, whose child_start still points at this container's head.
                stack.pop()
                _finish_map(f, r)
            else:
                completed = False


def _finish_map(f: _Frame, r: ScanResult) -> None:
    if not f.is_map:
        return
    for a, b in zip(f.keys, f.keys[1:]):
        if a > b:
            r.non_deterministic = True
        elif a == b:
            r.duplicate_key = True


# --- Tree builder (only after checks 16..21-generic pass) ----------------------


def build(buf: bytes) -> object:
    """Decode a deterministic, definite-length, tag/float-free item."""
    v, pos = _build(buf, 0)
    assert pos == len(buf)
    return v


def _build(buf: bytes, pos: int):
    mt, ai, val, pos = _head(buf, pos)
    assert val is not None or mt == 7
    if mt == 0:
        return val, pos
    if mt == 1:
        return NInt(val), pos
    if mt == 2:
        return bytes(buf[pos : pos + val]), pos + val
    if mt == 3:
        return buf[pos : pos + val].decode("utf-8"), pos + val
    if mt == 4:
        out = []
        for _ in range(val):
            v, pos = _build(buf, pos)
            out.append(v)
        return out, pos
    if mt == 5:
        pairs = []
        for _ in range(val):
            k, pos = _build(buf, pos)
            v, pos = _build(buf, pos)
            pairs.append((k, v))
        return Map(pairs), pos
    if mt == 7 and ai in (20, 21):
        return Bool(ai == 21), pos
    raise AssertionError("build() called on a document that failed a generic check")


# --- Deterministic encoder -------------------------------------------------------


def _enc_head(mt: int, val: int) -> bytes:
    if val < 24:
        return bytes([(mt << 5) | val])
    if val < 0x100:
        return bytes([(mt << 5) | 24, val])
    if val < 0x10000:
        return bytes([(mt << 5) | 25]) + val.to_bytes(2, "big")
    if val < 0x100000000:
        return bytes([(mt << 5) | 26]) + val.to_bytes(4, "big")
    if val < 1 << 64:
        return bytes([(mt << 5) | 27]) + val.to_bytes(8, "big")
    raise ValueError("integer out of CBOR range")


def encode(v: object) -> bytes:
    """RFC 8949 4.2.1 core deterministic encoding of a tree value."""
    if isinstance(v, Bool):
        return b"\xf5" if v.v else b"\xf4"
    if isinstance(v, bool):
        raise TypeError("use cbor.Bool, not Python bool")
    if isinstance(v, int):
        if v < 0:
            raise ValueError("negative int: use NInt")
        return _enc_head(0, v)
    if isinstance(v, NInt):
        return _enc_head(1, v.n)
    if isinstance(v, bytes):
        return _enc_head(2, len(v)) + v
    if isinstance(v, str):
        b = v.encode("utf-8")
        return _enc_head(3, len(b)) + b
    if isinstance(v, list):
        return _enc_head(4, len(v)) + b"".join(encode(x) for x in v)
    if isinstance(v, Map):
        items = sorted(((encode(k), encode(x)) for k, x in v.pairs), key=lambda kv: kv[0])
        for (a, _), (b, _) in zip(items, items[1:]):
            if a == b:
                raise ValueError("duplicate map key")
        return _enc_head(5, len(items)) + b"".join(k + x for k, x in items)
    raise TypeError(f"cannot encode {type(v).__name__}")
