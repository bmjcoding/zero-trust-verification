#!/usr/bin/env python3
"""wave_gate.py — deterministic wave-advance gate for /health-loop (ADR 0024).

The health-loop never re-grades a finding: `/verify` is the only verifier, and
`audit/state.json` is already the machine-readable record of its judgment. This
gate is a pure READER of that record — it decides ADVANCE vs stop for one wave
by looking at (a) the wave's fingerprint statuses, (b) REGRESSED anywhere in
state (a loop that regressed the codebase must stop, wave-scoped or not), and
(c) the ratchet counts of the latest verify run vs the audit baseline.

It never writes state.json, never runs a detector, never rounds a verdict up
(loop-safety invariants 1/7). A consumer that re-grades a verdict is a defect.

Exit contract (consumed verbatim by /health-loop):
  0  ADVANCE      every listed fingerprint FIXED or WONTFIX; no REGRESSED
                  anywhere; no ratchet increase between the latest kind:"verify"
                  run and its same-target kind:"audit" baseline.
  2  INCOMPLETE   >=1 listed fingerprint OPEN / PARTIAL / STALE.
  3  REGRESSION   >=1 REGRESSED finding anywhere in state, OR a ratchet count
                  increased. (Outranks INCOMPLETE: regressions stop the loop.)
  4  UNREADABLE   state missing / corrupt / unknown schema, or a listed
                  fingerprint absent from state (spec<->state desync — the join
                  is broken; fail closed, never guess).
  64 usage error (bad args, empty fingerprint list).

Ratchet notes (mirrors /verify's own rules — see commands/verify.md):
  * counts are compared only when present in BOTH runs (absent is never 0);
  * `stdout_logging_count` is report-only and NEVER gates, even here;
  * no comparable baseline -> reported as a note, statuses alone govern.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

SCHEMA_VERSION = 2
PASS_STATUSES = ("FIXED", "WONTFIX")
INCOMPLETE_STATUSES = ("OPEN", "PARTIAL", "STALE")
# The eight ratcheted counts (audit-state-and-verify.md), minus the one that is
# report-only by contract everywhere, including under /verify --strict.
RATCHET_COUNTS = (
    "marker_count",
    "suppression_count",
    "flaky_count",
    "test_vacuity_count",
    "test_skip_count",
    "giant_file_count",
    "commented_code_count",
)
REPORT_ONLY_COUNTS = ("stdout_logging_count",)


def _say(line: str) -> None:
    sys.stdout.write(line + "\n")


def _load_state(path: Path):
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        _say("UNREADABLE reason=state-unreadable detail=%s" % exc)
        return None
    try:
        data = json.loads(raw)
    except ValueError as exc:
        _say("UNREADABLE reason=state-not-json detail=%s" % exc)
        return None
    if not isinstance(data, dict) or data.get("schema_version") != SCHEMA_VERSION:
        _say("UNREADABLE reason=unknown-schema schema_version=%r" % (
            data.get("schema_version") if isinstance(data, dict) else None))
        return None
    return data


def _load_fingerprints(path: Path):
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        sys.stderr.write("wave_gate: fingerprint list unreadable: %s\n" % exc)
        return None
    fps = []
    for line in raw.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            fps.append(line)
    return fps


def _ratchet(data) -> tuple[bool, list[str]]:
    """Return (increased?, notes). Baseline = most recent kind:'audit' run with
    the same target as the most recent kind:'verify' run."""
    runs = data.get("runs")
    if not isinstance(runs, list):
        return False, ["ratchet: no runs[] — not comparable"]
    vidx = next((i for i in range(len(runs) - 1, -1, -1)
                 if isinstance(runs[i], dict) and runs[i].get("kind") == "verify"), None)
    if vidx is None:
        return False, ["ratchet: no kind=verify run — not comparable (statuses alone govern)"]
    verify = runs[vidx]
    target = verify.get("target")
    # Baseline rule mirrors /verify (audit-state-and-verify.md): the most recent
    # PRIOR same-target run, preferring the last kind:"audit" — falling back to
    # a prior verify run so a target that was only ever verified still ratchets.
    prior = [r for r in runs[:vidx] if isinstance(r, dict) and r.get("target") == target]
    audit = next((r for r in reversed(prior) if r.get("kind") == "audit"), None)
    notes = []
    if audit is None and prior:
        audit = prior[-1]
        notes.append("ratchet: no same-target kind=audit run — baseline is the prior same-target %s run" % audit.get("kind"))
    if audit is None:
        return False, ["ratchet: no same-target baseline run (target=%r) — not comparable" % target]
    increased = []
    for count in RATCHET_COUNTS:
        before, after = audit.get(count), verify.get(count)
        if not isinstance(before, int) or not isinstance(after, int):
            notes.append("ratchet: %s absent in one run — not comparable (absent is never 0)" % count)
            continue
        if after > before:
            increased.append("%s %d->%d" % (count, before, after))
    for count in REPORT_ONLY_COUNTS:
        before, after = audit.get(count), verify.get(count)
        if isinstance(before, int) and isinstance(after, int) and after > before:
            notes.append("ratchet: %s %d->%d (report-only, never gates)" % (count, before, after))
    return bool(increased), (["ratchet-increase %s" % " ".join(increased)] if increased else []) + notes


def main(argv) -> int:
    if len(argv) != 2:
        sys.stderr.write("usage: wave_gate.py <state.json> <fingerprint-list-file>\n")
        return 64
    data = _load_state(Path(argv[0]))
    if data is None:
        return 4
    fps = _load_fingerprints(Path(argv[1]))
    if fps is None:
        return 64
    if not fps:
        sys.stderr.write("wave_gate: empty fingerprint list — nothing to gate (refusing; an empty wave never reaches the gate)\n")
        return 64

    findings = data.get("findings")
    if not isinstance(findings, dict):
        _say("UNREADABLE reason=no-findings-object")
        return 4

    incomplete, unknown = [], []
    for fp in fps:
        f = findings.get(fp)
        if not isinstance(f, dict):
            unknown.append(fp)
            continue
        status = str(f.get("status", ""))
        if status in PASS_STATUSES:
            continue
        if status == "REGRESSED":
            continue  # covered by the global scan below
        if status in INCOMPLETE_STATUSES:
            incomplete.append("%s %s (%s)" % (fp, status, f.get("tag", "-")))
        else:
            unknown.append("%s status=%r" % (fp, status))

    # Global REGRESSED scan — never wave-scoped. A previously-FIXED finding that
    # is broken again means the drain damaged the codebase; the wave in front of
    # us is irrelevant until a human looks.
    regressed = ["%s (%s)" % (fp, f.get("tag", "-"))
                 for fp, f in findings.items()
                 if isinstance(f, dict) and f.get("status") == "REGRESSED"]

    ratchet_up, ratchet_notes = _ratchet(data)

    if unknown:
        _say("UNREADABLE reason=unknown-fingerprint %s" % "; ".join(unknown))
        _say("note: SPEC.md and state.json disagree — the join is broken; re-derive the spec, never guess")
        return 4
    for note in ratchet_notes:
        _say("note: %s" % note)
    if regressed or ratchet_up:
        for r in regressed:
            _say("REGRESSED %s" % r)
        _say("VERDICT=REGRESSION")
        return 3
    if incomplete:
        for i in incomplete:
            _say("INCOMPLETE %s" % i)
        _say("VERDICT=INCOMPLETE")
        return 2
    _say("VERDICT=ADVANCE fingerprints=%d" % len(fps))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
