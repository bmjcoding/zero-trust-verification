#!/usr/bin/env python3
"""Journey EMISSION-share projection for outcome measurement (ADR 0023; Class-A).

The suite-unique repo metric: on CORE journeys, the share of money/auth vital
steps graded OBSERVED (vs LOG-ONLY / DARK). Its input is `audit/journeys.json`,
written by the journey-walker AGENT, so the metric is **agent-graded** (Class-A),
NOT deterministic — the projection ARITHMETIC over a fixed fixture is [det], but
the number on a real repo is [audit-run] (the H1 honesty residual). Every emitted
row is stamped `honesty_class: agent-graded` and cannot be laundered as [det].

Shared by OM-02 (baseline emission-share field) and OM-04 (the audit outcome-emit
step). It is a projection of grades already recorded — it does NOT re-walk, does
NOT trigger a fresh audit (H6), reads only the file it is given, and (H2) emits NO
alert_seam / paged-share (alert seams live outside the repo, ADR 0006 — paged-share
is the OM-06 external adapter's job).

Degrade (loop-safety, journey-trace.md verbatim): a missing / corrupt / unknown-
schema (> 2) journeys.json emits NO share row and a loud note — NEVER a guessed
share. A v1 file (missing the v2 optional fields) is NOT corrupt; it still projects.

Output (stdout, JSON): {"ok": bool, "note": str, "metrics": [row,...]}. Exit 0
always (report-only, ADR 0004).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

SUPPORTED_SCHEMA = {1, 2}
VITAL_CORE = {"money", "auth"}
EMISSION_GRADES = {"OBSERVED", "LOG-ONLY", "DARK"}


def _flag(argv, name, default=None):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default


def _degrade(note):
    return {"ok": False, "note": note, "metrics": []}


def project(path: Path):
    if not path.exists():
        return _degrade("[note] journeys.json absent (%s) — no emission share emitted "
                        "(degrade, never guess)" % path)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return _degrade("[note] journeys.json corrupt (%s) — no emission share emitted" % exc)
    if not isinstance(data, dict):
        return _degrade("[note] journeys.json is not an object — no emission share emitted")
    ver = data.get("schema_version")
    if ver not in SUPPORTED_SCHEMA:
        return _degrade("[note] journeys.json unknown schema_version %r (supported: 1,2) — "
                        "no emission share emitted" % ver)

    journeys = data.get("journeys")
    if not isinstance(journeys, list):
        return _degrade("[note] journeys.json has no journeys[] array — no emission share emitted")

    observed = 0
    total = 0
    for j in journeys:
        if not isinstance(j, dict) or j.get("criticality") != "CORE":
            continue
        for step in (j.get("steps") or []):
            if not isinstance(step, dict):
                continue
            if step.get("vital_class") not in VITAL_CORE:
                continue
            grade = step.get("emission_grade")
            if grade not in EMISSION_GRADES:
                continue
            total += 1
            if grade == "OBSERVED":
                observed += 1

    git_sha = "unknown"
    sr = data.get("source_run")
    if isinstance(sr, dict) and sr.get("git_sha"):
        git_sha = str(sr["git_sha"])
    provenance = "journeys.json@%s" % git_sha

    if total == 0:
        # A parseable trace with no CORE money/auth vital steps: honest zero-denominator,
        # not a corrupt file. Emit the row with value null (absent != 0) so the renderer
        # says "no CORE money/auth vitals traced", never fabricates a share.
        row = {
            "name": "emission_share",
            "value": None,
            "unit": "ratio",
            "honesty_class": "agent-graded",
            "provenance": provenance,
            "detail": {"observed": 0, "core_money_auth_steps": 0},
            "note": "no CORE money/auth vital steps in the trace",
        }
        return {"ok": True, "note": "[note] no CORE money/auth vital steps traced", "metrics": [row]}

    row = {
        "name": "emission_share",
        "value": round(observed / total, 4),
        "unit": "ratio",
        "honesty_class": "agent-graded",
        "provenance": provenance,
        "detail": {"observed": observed, "core_money_auth_steps": total},
    }
    return {"ok": True, "note": "", "metrics": [row]}


def main(argv):
    jpath = _flag(argv, "--journeys")
    if not jpath:
        sys.stderr.write("outcome_emission: --journeys PATH required\n")
        # report-only: still exit 0, but emit a degrade object
        sys.stdout.write(json.dumps(_degrade("[note] no --journeys path given")) + "\n")
        return 0
    result = project(Path(jpath))
    sys.stdout.write(json.dumps(result, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
