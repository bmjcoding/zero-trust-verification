#!/usr/bin/env python3
"""Resume projection for the Spec Generation tier (SG-4, spec-gen §7.2).

On `--resume`/`--amend`, S1 runs the canonical `validate_manifest.sh` FIRST and
trusts its exit-3 output over the stored `incomplete_fields` (the file may be
stale after a crash). This module is the DETERMINISTIC mapping that turns that
exit-3 output into the S-step work queue:

  validator `[SPEC-INCOMPLETE: rule-<n>: <path>]`  (or raw incomplete_fields)
        │
        ├── rules 1, 2, 4  →  ESCALATE-class question SLOTS (S5)
        └── rules 0,3,5,6,7,8 →  MECHANICAL-class fix queue (S3/S4, silent)

The two classes are the manifest §10 / ADR 0002 split: **(b) unanswered
MUST-escalate fields** (values/risk appetite, observability intent, confirmation)
vs **(a) mechanical validity** an agent fixes itself before finalizing. Only the
escalate class becomes a human question.

What this module produces are SLOTS ONLY — `{rule, path, klass, kind}`. The
recommendation and dissent attached to each S5 question come from the MANDATORY
S4 re-run over the resumed entries (spec-gen §3 S5, §7.2) and are deliberately
excluded here so the projection stays deterministic and testable.

CLI:
  resume_projection.py <manifest.yaml>     # runs the canonical validator, projects exit-3
  resume_projection.py --fields -          # reads incomplete_fields lines on stdin
Both print a JSON {escalate:[...], mechanical:[...]} projection.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

# manifest §10 rule classes. Rule 0 is mechanical (empty manifest). Rules 1,2,4
# are the escalate class (the ADR 0002 MUST-escalate residue). 3,5,6,7,8 mechanical.
ESCALATE_RULES = frozenset({1, 2, 4})
MECHANICAL_RULES = frozenset({0, 3, 5, 6, 7, 8})

# The S5 question kind each escalate rule maps to (spec-gen §3 S5, manifest §10).
ESCALATE_KIND = {
    1: "observability-intent",   # required_emission / event_name / alert_seam.default
    2: "risk-appetite",          # idempotency answered + compensation (money / external-write)
    4: "confirmation",           # effectively-CORE entry confirmed by a human
}

_ENTRY_RE = re.compile(r"rule-(\d+):\s*(.*)")
_WRAPPED_RE = re.compile(r"\[SPEC-INCOMPLETE:\s*(rule-\d+:.*?)\]\s*$")


def parse_entry(line: str):
    """Parse one `rule-<n>: <path>` (optionally `[SPEC-INCOMPLETE: ...]`-wrapped).

    Returns {rule:int, path:str} or None for lines that are not rule entries
    (e.g. the validator's `complete` or the declared-incomplete note).
    """
    if not isinstance(line, str):
        return None
    s = line.strip()
    m = _WRAPPED_RE.search(s)
    if m:
        s = m.group(1)
    m = _ENTRY_RE.match(s)
    if not m:
        return None
    return {"rule": int(m.group(1)), "path": m.group(2).strip()}


def classify(rule: int) -> str:
    if rule in ESCALATE_RULES:
        return "escalate"
    if rule in MECHANICAL_RULES:
        return "mechanical"
    # Unknown rule number: fail safe toward escalate so nothing is silently
    # auto-fixed that we don't understand (never widen the agent's authority).
    return "escalate"


def project(fields) -> dict:
    """Project incomplete_fields / validator lines into S-step work slots.

    Order-preserving and deduplicated (same rule+path collapses). One-at-a-time
    escalation ordering (Hard Contract 4) is the skill's concern; this returns
    the full slot set in stable order.
    """
    escalate, mechanical = [], []
    seen = set()
    for line in fields or []:
        e = parse_entry(line)
        if e is None:
            continue
        key = (e["rule"], e["path"])
        if key in seen:
            continue
        seen.add(key)
        klass = classify(e["rule"])
        slot = {"rule": e["rule"], "path": e["path"], "klass": klass}
        if klass == "escalate":
            slot["kind"] = ESCALATE_KIND.get(e["rule"], "unknown")
            escalate.append(slot)
        else:
            mechanical.append(slot)
    return {"escalate": escalate, "mechanical": mechanical}


def project_manifest(path: Path) -> dict:
    """Run the canonical validator on `path`; project its exit-3 output.

    exit 3  -> project the `[SPEC-INCOMPLETE: ...]` lines.
    exit 0  -> complete, nothing to resume (empty projection).
    exit 4/5 -> caller must handle (schema-invalid / unsupported); we surface it.
    """
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import validate_manifest as V  # the canonical validator (single copy, ADR 0025)

    code, lines = V.validate_file(path)
    if code == V.EXIT_INCOMPLETE:
        out = project(lines)
        out["validator_exit"] = code
        return out
    return {"escalate": [], "mechanical": [], "validator_exit": code, "validator_lines": lines}


def _main(argv) -> int:
    if len(argv) == 3 and argv[1] == "--fields":
        src = sys.stdin if argv[2] == "-" else open(argv[2], encoding="utf-8")
        with src:
            fields = [ln.rstrip("\n") for ln in src]
        print(json.dumps(project(fields), indent=2))
        return 0
    if len(argv) == 2 and not argv[1].startswith("-"):
        out = project_manifest(Path(argv[1]))
        print(json.dumps(out, indent=2))
        # Always exit 0: a resumable incomplete manifest is the NORMAL case, so we
        # never signal it as a process failure (that would trip `set -e` callers).
        # The caller branches on the JSON `validator_exit` field, not $?.
        return 0
    print("usage: resume_projection.py <manifest.yaml> | --fields <file|->", file=sys.stderr)
    return 64


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
