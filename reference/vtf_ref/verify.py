"""Check every VTF1 test vector against this independent reference.

    uv run python -m vtf_ref.verify vectors/

(run from `reference/`; a relative path that does not exist there is also
tried relative to the repository root). Prints one line per vector and exits
non-zero on any mismatch.

For each positive vector:
  (a) re-export from manifest inputs (every password form, every device
      recipient) and compare byte-for-byte, plus the manifest sha256;
      re-encode the decoded payload with this reference's deterministic
      encoder and compare with positive/<name>.cbor;
  (b) decrypt with every credential and compare the plaintext with
      positive/<name>.cbor || zero padding.
For each negative vector:
  (c) import with the named credential and require rejection by exactly the
      `expected_check`.

REFERENCE / TEST CODE ONLY.
"""

from __future__ import annotations

import base64
import hashlib
import json
import sys
import traceback
from pathlib import Path

from . import container
from .payload import encode_model, model_from_tree, pad_payload
from .selftest import SELFTESTS

H = bytes.fromhex

# The manifest names these credentials but does not fix their values; any
# value different from the real one must fail with slot-unwrap.
WRONG_PASSWORD = "not the password"
WRONG_SECRET_KEY = b"\xff" * 16

# Negative vectors whose `expected_check` this reference disputes, with the
# check this reference reports and why. A disputed vector still has to be
# REJECTED, and rejected by exactly the check recorded here; any other
# outcome fails. `--strict` makes every dispute a failure. The vectors are
# frozen and owned elsewhere; disputes are reported, never "fixed" here.
DISPUTED: dict[str, tuple[str, str]] = {
    "cbor-limit": (
        "cbor-type",
        "payload is {1:1, 2:0, 3:[tstr(65537)]}: the items array holds a text string where an Item "
        "map is required, so the vector carries two faults (21 cbor-type and 25 cbor-limit). "
        "SPEC-VTF 7 numbers cbor-type before cbor-limit; vtf-core reports cbor-limit only because "
        "its generic decoder enforces the 6.4 text limit before schema typing.",
    ),
}


def parse_secret_key_display(s: str) -> bytes:
    """SPEC-VTF Appendix A."""
    s = "".join(s.split()).upper()
    if not s.startswith("SR1-"):
        raise ValueError("prefix")
    groups = s[4:].split("-")
    if [len(g) for g in groups] != [5, 5, 5, 5, 6]:
        raise ValueError("grouping")
    b32 = "".join(groups)
    if b32[-1] not in "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"[::4]:  # low two bits zero
        raise ValueError("non-zero trailing bits")
    return base64.b32decode(b32 + "======")


def _resolve(arg: str) -> Path:
    p = Path(arg)
    if p.exists():
        return p
    alt = Path(__file__).resolve().parents[2] / arg
    if alt.exists():
        return alt
    raise SystemExit(f"vectors directory not found: {arg}")


def main(argv: list[str]) -> int:
    strict = "--strict" in argv
    args = [a for a in argv[1:] if a != "--strict"]
    root = _resolve(args[0] if args else "vectors")
    m = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    failures = 0
    disputes = 0

    def line(ok: bool, what: str, detail: str, tag: str | None = None) -> None:
        nonlocal failures
        if not ok:
            failures += 1
        print(f"{tag or ('PASS' if ok else 'FAIL'):<8}{what:<42} {detail}", flush=True)

    for name, fn in SELFTESTS:
        try:
            fn()
            line(True, f"selftest/{name.split(' ')[0]}", name)
        except AssertionError as e:
            line(False, f"selftest/{name.split(' ')[0]}", f"{name}: {e}")

    sk = H(m["secret_key_hex"])
    try:
        ok = parse_secret_key_display(m["secret_key_display"]) == sk
        line(ok, "manifest/secret_key_display", "Appendix A display encoding decodes to secret_key_hex")
    except ValueError as e:
        line(False, "manifest/secret_key_display", str(e))

    devices = {k: (H(v["private_key_hex"]), H(v["public_key_hex"])) for k, v in m["devices"].items()}
    from . import hpke

    for k, (skd, pkd) in devices.items():
        derived = hpke.serialize_public_key(hpke.private_key_from_bytes(skd).public_key())
        line(derived == pkd, f"manifest/device-{k}", "public key matches private key")

    r = m["randomness"]
    rnd = container.Randomness(
        salt=H(r["salt"]),
        chunk_nonce_prefix=H(r["chunk_nonce_prefix"]),
        vtk=H(r["vtk"]),
        password_slot_nonce=H(r["password_slot_nonce"]),
        device_slots=[(H(d["ikm_e"]), H(d["nonce"])) for d in r["device_slots"]],
    )

    n_pos_ok = 0
    for v in m["positive"]:
        what = f"positive/{v['name']}"
        try:
            want = (root / v["file"]).read_bytes()
            cb = (root / v["payload"]).read_bytes()
            errs: list[str] = []
            if hashlib.sha256(want).hexdigest() != v["sha256"]:
                errs.append("manifest sha256 mismatch")
            recips = [devices[d][1] for d in v["device_recipients"]]
            passwords = []
            if v["password"] is not None:
                passwords = [v["password"]] + list(v["password_alternates"])
            # (a) reproduce
            n_repro = 0
            for pw in passwords or [None]:
                got = container.export(cb, pw, sk, recips, rnd)
                if got != want:
                    errs.append(f"export differs (password form {pw!r})")
                n_repro += 1
            # (b) decrypt with each credential
            creds = [("password", {"password": pw, "secret_key": sk}) for pw in passwords]
            creds += [(f"device-{d}", {"device_sk": devices[d][0]}) for d in v["device_recipients"]]
            for cname, kw in creds:
                body, plaintext, tree = container.decrypt(want, **kw)
                if body != cb or plaintext != pad_payload(cb):
                    errs.append(f"plaintext mismatch ({cname})")
                if encode_model(model_from_tree(tree)) != cb:
                    errs.append("reference encoder does not reproduce payload")
            ok = not errs
            n_pos_ok += ok
            line(
                ok,
                what,
                "; ".join(errs)
                or f"reproduced x{n_repro}, decrypted x{len(creds)} ({', '.join(c for c, _ in creds)})",
            )
        except container.Reject as e:
            line(False, what, f"rejected by {e.check}")
        except Exception as e:  # noqa: BLE001
            line(False, what, f"error: {e!r}")
            traceback.print_exc()

    n_neg_ok = 0
    pw_main = next(v["password"] for v in m["positive"] if v["name"] == "unbound")
    for v in m["negative"]:
        what = f"negative/{v['name']}"
        cred = v["credential"]
        kw = {
            "password": {"password": pw_main, "secret_key": sk},
            "wrong-password": {"password": WRONG_PASSWORD, "secret_key": sk},
            "wrong-secret-key": {"password": pw_main, "secret_key": WRONG_SECRET_KEY},
            "device-a": {"device_sk": devices["a"][0]},
            "device-c": {"device_sk": devices["c"][0]},
        }.get(cred)
        if kw is None:
            line(False, what, f"unknown credential {cred!r}")
            continue
        data = (root / v["file"]).read_bytes()
        try:
            container.decrypt(data, **kw)
            line(False, what, f"ACCEPTED (expected {v['expected_check']})")
        except container.Reject as e:
            ok = e.check == v["expected_check"]
            n_neg_ok += ok
            if not ok and v["name"] in DISPUTED:
                ref_check, why = DISPUTED[v["name"]]
                disputes += 1
                line(
                    e.check == ref_check and not strict,
                    what,
                    f"rejected by {e.check}; manifest expects {v['expected_check']}. {why}",
                    tag="DISPUTE" if e.check == ref_check else "FAIL",
                )
                continue
            line(ok, what, f"rejected by {e.check} (expected {v['expected_check']})")
        except Exception as e:  # noqa: BLE001
            line(False, what, f"error: {e!r}")
            traceback.print_exc()

    print(
        f"\npositive: {n_pos_ok}/{len(m['positive'])} reproduced and decrypted; "
        f"negative: {n_neg_ok}/{len(m['negative'])} rejected with the expected check "
        f"({disputes} disputed, still rejected); failures: {failures}"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
