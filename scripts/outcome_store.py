#!/usr/bin/env python3
"""Outcome store reader/writer (logic; the shell wrapper owns the CLI contract).

The single shared writer path for BOTH outcome producers (the Marshal
`outcome-capture` mode and the codebase-health audit `outcome-emit` step). ADR
0023: outcome measurement is report-only wiring — this module reads history and
appends rows, it never gates, never posts, never mutates a target repo.

The store (`outcome/outcomes.json`) is append-only `runs[]` + one frozen
`baseline`. `schema/outcome/v1.schema.json` is the single structural source of
truth, validated with the SAME jsonschema Draft202012Validator toolchain as the
manifest (ADR 0014) — no hand-rolled checks. EVERY metric row MUST carry an
`honesty_class` + `provenance`; a row without them is schema-invalid, so no
unlabeled number can enter the store (the H1 anti-laundering guard).

Degrade rules (loop-safety invariant 4, mirrors state.json):
  - absent store        -> first run creates it.
  - corrupt / unknown schema_version -> REFUSE to write; report the read error;
    NEVER overwrite (the file is left byte-identical).
  - frozen baseline present -> write-baseline is REFUSED (byte-identical).

Exit codes (consumed by outcome_store.sh):
  0  ok
  4  schema-invalid (the input snapshot, or the resulting store, fails the schema)
  5  store unreadable / corrupt / unknown schema_version (refuse; byte-untouched)
  6  refuse-second (a frozen baseline already exists; byte-untouched)
  64 usage
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

SCHEMA_VERSION = 1

EXIT_OK = 0
EXIT_SCHEMA_INVALID = 4
EXIT_STORE_CORRUPT = 5
EXIT_REFUSE_SECOND = 6
EXIT_USAGE = 64

_HERE = Path(__file__).resolve().parent
# the canonical outcome-store schema lives inside the single plugin (ADR 0025)
_SCHEMA = _HERE.parent / "plugins" / "zero-trust" / "schema" / "outcome" / "v1.schema.json"


def _err(msg: str) -> None:
    sys.stderr.write("outcome_store: %s\n" % msg)


def _schema_errors(data) -> list[str]:
    from jsonschema import Draft202012Validator

    schema = json.loads(_SCHEMA.read_text(encoding="utf-8"))
    v = Draft202012Validator(schema)
    out = []
    for err in sorted(v.iter_errors(data), key=lambda e: list(e.path)):
        loc = "/".join(str(p) for p in err.path) or "<root>"
        out.append("%s: %s" % (loc, err.message))
    return out


def _read_store(path: Path):
    """Returns (store_or_None, exit_code, reason). exit_code 0 iff a usable store
    (or a clean absent -> empty skeleton). A corrupt / unknown-version store is
    NOT usable and must never be overwritten (exit 5)."""
    if not path.exists():
        return {"schema_version": SCHEMA_VERSION, "runs": []}, EXIT_OK, "absent"
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        return None, EXIT_STORE_CORRUPT, "cannot read %s: %s" % (path, exc)
    try:
        store = json.loads(raw)
    except ValueError as exc:
        return None, EXIT_STORE_CORRUPT, "corrupt store (not JSON): %s" % exc
    if not isinstance(store, dict):
        return None, EXIT_STORE_CORRUPT, "corrupt store (top-level is not an object)"
    ver = store.get("schema_version")
    if ver != SCHEMA_VERSION:
        return None, EXIT_STORE_CORRUPT, "unknown schema_version %r (this reader supports %d)" % (ver, SCHEMA_VERSION)
    return store, EXIT_OK, "present"


def _load_snapshot(snapshot_path: str | None):
    """Read the incoming snapshot JSON from a file or stdin. Returns (obj, err)."""
    try:
        if snapshot_path in (None, "-"):
            text = sys.stdin.read()
        else:
            text = Path(snapshot_path).read_text(encoding="utf-8")
    except OSError as exc:
        return None, "cannot read snapshot: %s" % exc
    if not text.strip():
        return None, "empty snapshot input"
    try:
        return json.loads(text), None
    except ValueError as exc:
        return None, "snapshot is not JSON: %s" % exc


def _write_store(path: Path, store) -> None:
    """Atomic write: validate is the caller's job; this only replaces after a full
    serialize so a partial write can never corrupt the store."""
    tmp = path.with_name(path.name + ".tmp")
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_text(json.dumps(store, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


# ---- subcommands -----------------------------------------------------------------

def cmd_validate(store_path: str) -> int:
    p = Path(store_path)
    if not p.exists():
        _err("validate: no such store: %s" % store_path)
        return EXIT_STORE_CORRUPT
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        _err("validate: unreadable store: %s" % exc)
        return EXIT_STORE_CORRUPT
    errs = _schema_errors(data)
    if errs:
        for e in errs:
            _err("schema: %s" % e)
        return EXIT_SCHEMA_INVALID
    sys.stdout.write("outcome-store OK (schema_version %d, %d run(s), baseline=%s)\n"
                     % (SCHEMA_VERSION, len(data.get("runs", [])), "yes" if data.get("baseline") else "no"))
    return EXIT_OK


def cmd_read(store_path: str) -> int:
    store, code, reason = _read_store(Path(store_path))
    if code != EXIT_OK:
        _err("read: %s" % reason)
        return code
    sys.stdout.write(json.dumps(store, indent=2, sort_keys=True) + "\n")
    return EXIT_OK


def _validate_snapshot_in_store(store, snapshot, *, as_baseline: bool):
    """Splice the snapshot into a copy of the store and validate the WHOLE store,
    so a malformed row (e.g. missing honesty_class) is rejected exactly as it would
    be on read. Returns (candidate_store, errors)."""
    candidate = dict(store)
    candidate.setdefault("schema_version", SCHEMA_VERSION)
    candidate.setdefault("runs", list(store.get("runs", [])))
    if as_baseline:
        snap = dict(snapshot)
        snap["frozen"] = True
        candidate["baseline"] = snap
    else:
        candidate["runs"] = list(store.get("runs", [])) + [snapshot]
    return candidate, _schema_errors(candidate)


def cmd_append_run(store_path: str, snapshot_path: str | None) -> int:
    p = Path(store_path)
    store, code, reason = _read_store(p)
    if code != EXIT_OK:
        _err("append-run refused: %s (store left byte-identical)" % reason)
        return code
    snapshot, serr = _load_snapshot(snapshot_path)
    if serr:
        _err("append-run: %s" % serr)
        return EXIT_USAGE
    candidate, errs = _validate_snapshot_in_store(store, snapshot, as_baseline=False)
    if errs:
        for e in errs:
            _err("schema: %s" % e)
        return EXIT_SCHEMA_INVALID
    _write_store(p, candidate)
    sys.stdout.write("appended run (%d total)\n" % len(candidate["runs"]))
    return EXIT_OK


def cmd_write_baseline(store_path: str, snapshot_path: str | None) -> int:
    p = Path(store_path)
    store, code, reason = _read_store(p)
    if code != EXIT_OK:
        _err("write-baseline refused: %s (store left byte-identical)" % reason)
        return code
    existing = store.get("baseline")
    if isinstance(existing, dict) and existing.get("frozen") is True:
        _err("write-baseline REFUSED: a frozen baseline already exists (captured_at=%s); "
             "the baseline is captured once at adoption and never re-captured (ADR 0023). "
             "Store left byte-identical." % existing.get("captured_at"))
        return EXIT_REFUSE_SECOND
    snapshot, serr = _load_snapshot(snapshot_path)
    if serr:
        _err("write-baseline: %s" % serr)
        return EXIT_USAGE
    candidate, errs = _validate_snapshot_in_store(store, snapshot, as_baseline=True)
    if errs:
        for e in errs:
            _err("schema: %s" % e)
        return EXIT_SCHEMA_INVALID
    _write_store(p, candidate)
    sys.stdout.write("wrote frozen baseline (captured_at=%s)\n" % candidate["baseline"].get("captured_at"))
    return EXIT_OK


def _flag(argv, name, default=None):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default


def main(argv) -> int:
    if not argv:
        _err("usage: outcome_store.py {read|validate|append-run|write-baseline} --store PATH [--snapshot-file F]")
        return EXIT_USAGE
    sub = argv[0]
    rest = argv[1:]
    store_path = _flag(rest, "--store")
    if not store_path:
        _err("%s: --store PATH required" % sub)
        return EXIT_USAGE
    snap = _flag(rest, "--snapshot-file")
    if sub == "read":
        return cmd_read(store_path)
    if sub == "validate":
        return cmd_validate(store_path)
    if sub == "append-run":
        return cmd_append_run(store_path, snap)
    if sub == "write-baseline":
        return cmd_write_baseline(store_path, snap)
    _err("unknown subcommand: %s" % sub)
    return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
