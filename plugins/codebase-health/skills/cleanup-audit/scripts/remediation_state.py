#!/usr/bin/env python3
"""Deterministic state.json backend for the remediation loop (ADR 0017/0018).

The remediation loop is WIRING, not a checker (ADR 0017): it holds no quality
opinion. This module is its only touch-point on `audit/state.json` — a pure
reader plus the ONE additive mutation the loop is allowed to make (Guard 1, the
`remediation` sub-object). Every judgment lives in the shell routers that call
this; here there is only JSON I/O with the loop-safety invariants baked in:

  * invariant 1 (detection never mutates) — `read`/`already-filed` never write.
  * invariant 4 (broken state → LESS action) — a missing/corrupt/unknown-schema
    state emits NOTHING and never crashes; `stamp` REFUSES to write into it.
  * invariant 8 (idempotent, diffable) — `stamp` is additive and re-runnable;
    it touches ONLY the `remediation` sub-object, never `status`/`severity`/
    `verified_by` (those stay `/audit`- and `/verify`-owned).

Subcommands (each a thin, testable seam; the shell entrypoints wrap these):

  read <state.json> [--from-pr-gate <captured_output>]
      One normalized row per OPEN finding, TAB-separated:
        fingerprint\\tseverity\\tslug\\tpath\\tsymbol\\tstatus\\tremediation_status
      There is deliberately NO `expected_by` column — that field lives only in
      the fixture EXPECTED_FINDINGS.yaml, never in runtime state (HARDENED
      Defect A). Provenance is derived downstream from the slug (RL-02), never
      read as a stored field.

  already-filed <fingerprint> <state.json>
      FILED (skip, Guard 1) when an open remediation record
      (SPEC_OPEN|PR_OPEN|ESCALATED|WONTFIX) OR a human WONTFIX status exists;
      UNFILED otherwise. Unreadable state → FILED (fail-safe toward inaction).

  stamp <state.json> <fingerprint> --status S [--ref R] [--depth N]
        [--opened-at T] [--out O]
      Additively set finding.remediation = {status, ref, opened_at,
      remediation_depth}. schema_version stays 2 (additive fields are not a
      break). Refuses on unreadable state or unknown fingerprint (never guesses).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

SCHEMA_VERSION = 2
# The remediation-record lifecycle (RL-08). WONTFIX here is a loop-side terminal
# that mirrors a human `/verify --wontfix`; the loop also treats a finding whose
# top-level status is WONTFIX as permanently silenced.
OPEN_REMEDIATION = ("SPEC_OPEN", "PR_OPEN", "ESCALATED", "WONTFIX")
ALLOWED_STAMP_STATUS = ("SPEC_OPEN", "PR_OPEN", "ESCALATED", "WONTFIX")


def _note(msg: str) -> None:
    sys.stderr.write("[note] read_findings: %s\n" % msg)


def _load_state(path: Path):
    """Return the parsed state dict, or None if it must be treated as absent.

    A missing / unparseable / wrong-schema state degrades to None (invariant 4)
    — the caller emits nothing and exits 0. We never guess at partial state.
    """
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        _note("state file unreadable (%s) — treating as first run, emitting nothing" % exc)
        return None
    try:
        data = json.loads(raw)
    except (ValueError, json.JSONDecodeError) as exc:
        _note("state file is not valid JSON (%s) — emitting nothing, never a guessed row" % exc)
        return None
    if not isinstance(data, dict):
        _note("state root is not an object — emitting nothing")
        return None
    sv = data.get("schema_version")
    if sv != SCHEMA_VERSION:
        _note("unknown schema_version %r (expected %d) — emitting nothing" % (sv, SCHEMA_VERSION))
        return None
    return data


def _remediation_status(finding: dict) -> str:
    rem = finding.get("remediation")
    if isinstance(rem, dict) and rem.get("status"):
        return str(rem.get("status"))
    return "-"


# ── read ──────────────────────────────────────────────────────────────────────
# A pr_gate / sibling FINDING line, e.g.
#   [FINDING blocking] memory-rot-dangling-ref: 'sym' deleted ... fpsrc=p:s:slug fp=abc123
_PRGATE_RE = re.compile(
    r"\[FINDING[^\]]*\]\s*(?P<slug>[a-z0-9][a-z0-9-]*)\s*:.*?fpsrc=(?P<path>[^:]+):(?P<symbol>[^:]+):(?P<fpslug>[a-z0-9-]+)"
)
_PRGATE_FP_RE = re.compile(r"\bfp=(?P<fp>[0-9a-f]{6,})\b")


def _rows_from_pr_gate(path: Path):
    """Best-effort ingest of a CAPTURED pr_gate/sibling run (RL-01 --from-pr-gate).

    The loop reads the EXISTING finding stream; a captured PR-Gate run is one such
    stream. We parse only its emitted FINDING lines (never re-run the gate). A
    `[FINDING blocking]` line is the ADR-0004 blocking class → HIGH-equivalent.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        _note("--from-pr-gate file unreadable (%s) — emitting nothing from it" % exc)
        return []
    rows = []
    for line in text.splitlines():
        m = _PRGATE_RE.search(line)
        if not m:
            continue
        fpm = _PRGATE_FP_RE.search(line)
        fp = fpm.group("fp")[:12] if fpm else "-"
        sev = "HIGH" if "blocking" in line.lower() else "MED"
        rows.append((fp, sev, m.group("fpslug"), m.group("path"), m.group("symbol"), "OPEN", "-"))
    return rows


def cmd_read(args) -> int:
    rows = []
    data = _load_state(Path(args.state))
    if data is not None:
        findings = data.get("findings")
        if isinstance(findings, dict):
            for fp, f in findings.items():
                if not isinstance(f, dict):
                    continue
                if f.get("status") != "OPEN":
                    continue  # WONTFIX/FIXED/STALE/PARTIAL are not loop work
                rows.append((
                    str(fp),
                    str(f.get("severity", "-")),
                    str(f.get("slug", "-")),
                    str(f.get("path", "-")),
                    str(f.get("symbol", "-")),
                    str(f.get("status", "-")),
                    _remediation_status(f),
                ))
    if args.from_pr_gate:
        rows.extend(_rows_from_pr_gate(Path(args.from_pr_gate)))
    for r in rows:
        sys.stdout.write("\t".join(r) + "\n")
    return 0


# ── already-filed ───────────────────────────────────────────────────────────
def cmd_already_filed(args) -> int:
    data = _load_state(Path(args.state))
    if data is None:
        # Cannot idempotency-check → the loop must not file. Fail SAFE (skip).
        print("FILED reason=state-unreadable")
        return 0
    findings = data.get("findings") or {}
    f = findings.get(args.fingerprint) if isinstance(findings, dict) else None
    if not isinstance(f, dict):
        print("UNFILED reason=no-such-finding")
        return 0
    if f.get("status") == "WONTFIX":
        print("FILED reason=human-wontfix")
        return 0
    rem = f.get("remediation")
    if isinstance(rem, dict) and rem.get("status") in OPEN_REMEDIATION:
        print("FILED reason=remediation-%s ref=%s" % (rem.get("status"), rem.get("ref", "-")))
        return 0
    print("UNFILED reason=open")
    return 0


# ── stamp (the ONE additive mutation) ─────────────────────────────────────────
def cmd_stamp(args) -> int:
    path = Path(args.state)
    data = _load_state(path)
    if data is None:
        sys.stderr.write("[refuse] stamp: state unreadable/unknown-schema — never write into broken state (invariant 4)\n")
        return 1
    if args.status not in ALLOWED_STAMP_STATUS:
        sys.stderr.write("[refuse] stamp: unknown remediation status %r (allowed: %s)\n"
                         % (args.status, ", ".join(ALLOWED_STAMP_STATUS)))
        return 64
    findings = data.get("findings")
    if not isinstance(findings, dict) or args.fingerprint not in findings:
        sys.stderr.write("[refuse] stamp: fingerprint %s not in state — never invent a record\n" % args.fingerprint)
        return 1
    f = findings[args.fingerprint]
    if not isinstance(f, dict):
        sys.stderr.write("[refuse] stamp: finding %s is not an object\n" % args.fingerprint)
        return 1

    prev = f.get("remediation") if isinstance(f.get("remediation"), dict) else {}
    # Idempotent: preserve the original opened_at across re-stamps unless caller
    # forces a value; only the remediation sub-object is ever touched.
    opened_at = args.opened_at or prev.get("opened_at") or "unset"
    f["remediation"] = {
        "status": args.status,
        "ref": args.ref if args.ref is not None else prev.get("ref", ""),
        "opened_at": opened_at,
        "remediation_depth": args.depth if args.depth is not None else int(prev.get("remediation_depth", 0)),
    }
    # schema_version is untouched (stays 2); additive field is not a break.
    out = Path(args.out) if args.out else path
    out.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print("stamped %s remediation.status=%s ref=%s depth=%s (additive; schema_version=%s)"
          % (args.fingerprint, args.status, f["remediation"]["ref"],
             f["remediation"]["remediation_depth"], data.get("schema_version")))
    return 0


def main(argv) -> int:
    p = argparse.ArgumentParser(prog="remediation_state.py")
    sub = p.add_subparsers(dest="cmd", required=True)

    pr = sub.add_parser("read")
    pr.add_argument("state")
    pr.add_argument("--from-pr-gate", dest="from_pr_gate", default=None)
    pr.set_defaults(func=cmd_read)

    pa = sub.add_parser("already-filed")
    pa.add_argument("fingerprint")
    pa.add_argument("state")
    pa.set_defaults(func=cmd_already_filed)

    ps = sub.add_parser("stamp")
    ps.add_argument("state")
    ps.add_argument("fingerprint")
    ps.add_argument("--status", required=True)
    ps.add_argument("--ref", default=None)
    ps.add_argument("--depth", type=int, default=None)
    ps.add_argument("--opened-at", dest="opened_at", default=None)
    ps.add_argument("--out", default=None)
    ps.set_defaults(func=cmd_stamp)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
