#!/usr/bin/env python3
"""External-source outcome adapters: defect-escape (OM-05) + incident/MTTR/paged
(OM-06). ADR 0023 / ADR 0002 / ADR 0006.

These are EXTERNAL facts: a defect reaching production, an incident, whether an
alert paged — none is observable from the repo (alert seams live OUTSIDE the repo,
ADR 0006). v1 ships the adapter INTERFACE (one contract, swappable backend — the
host.sh pattern): when a source is CONFIGURED (an external-tracker / incident-system
export file), the number is derived DETERMINISTICALLY (honesty_class: deterministic);
when NO source is configured, the adapter derives NOTHING and reports the field
`[OUTCOME-SOURCE-ABSENT: <label>]` — absence never blocks the report, and a number
is NEVER fabricated or model-estimated. The concrete production backend (PagerDuty /
Opsgenie / ServiceNow / a host label API) is NAMED by human escalation, then built
behind this same contract.

Output (stdout, JSON): {"ok": bool, "source_absent": [labels...], "metrics": [row,...]}.
Exit 0 always (report-only).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

VITAL_CORE = {"money", "auth"}


def _flag(argv, name, default=None):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default


def _median(vals):
    if not vals:
        return None
    s = sorted(vals)
    n = len(s)
    mid = n // 2
    return s[mid] if n % 2 else (s[mid - 1] + s[mid]) / 2.0


def cmd_defect_escape(argv):
    source = _flag(argv, "--source-file")
    if not source:
        return {"ok": False, "source_absent": ["defect-escape"], "metrics": []}
    try:
        p = Path(source)
        # source format: one escaped-defect record per non-empty, non-# line
        # (a hotfix merge sha / a tracker ticket id). The count is the numerator.
        escapes = 0
        for line in p.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                escapes += 1
    except OSError as exc:
        sys.stderr.write("outcome_external: defect-escape source unreadable: %s\n" % exc)
        return {"ok": False, "source_absent": ["defect-escape"], "metrics": []}
    deploys = _flag(argv, "--deploys")
    try:
        deploys = int(deploys) if deploys is not None else None
    except ValueError:
        deploys = None
    if not deploys:
        # escapes known but no deploy denominator: report the raw count, not a rate.
        value = None
        detail = {"escapes": escapes, "deploys": None}
    else:
        value = round(escapes / deploys, 4)
        detail = {"escapes": escapes, "deploys": deploys}
    return {"ok": True, "source_absent": [], "metrics": [{
        "name": "defect_escape_rate",
        "value": value,
        "unit": "ratio",
        "honesty_class": "deterministic",
        "provenance": "external-tracker:%s" % p.name,
        "detail": detail,
    }]}


def _journey_darkness(journeys_path):
    """Map journey name -> 'DARK'|'OBSERVED'|None from CORE money/auth steps."""
    out = {}
    try:
        data = json.loads(Path(journeys_path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return out
    for j in (data.get("journeys") or []):
        if not isinstance(j, dict) or j.get("criticality") != "CORE":
            continue
        grades = [s.get("emission_grade") for s in (j.get("steps") or [])
                  if isinstance(s, dict) and s.get("vital_class") in VITAL_CORE]
        if not grades:
            continue
        # a journey is DARK if any CORE money/auth step is not OBSERVED
        out[j.get("name")] = "OBSERVED" if all(g == "OBSERVED" for g in grades) else "DARK"
    return out


def cmd_incident(argv):
    source = _flag(argv, "--source-file")
    journeys = _flag(argv, "--journeys")
    if not source:
        return {"ok": False,
                "source_absent": ["incident-system", "alert-config"], "metrics": []}
    try:
        src = json.loads(Path(source).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        sys.stderr.write("outcome_external: incident source unreadable: %s\n" % exc)
        return {"ok": False,
                "source_absent": ["incident-system", "alert-config"], "metrics": []}

    incidents = src.get("incidents") or []
    alerts = src.get("alerts") or []
    darkness = _journey_darkness(journeys) if journeys else {}

    # incidents concentrated on DARK vs OBSERVED journeys (join by name)
    dark_hits = sum(1 for i in incidents if darkness.get(i.get("journey")) == "DARK")
    obs_hits = sum(1 for i in incidents if darkness.get(i.get("journey")) == "OBSERVED")
    mttrs = [i["mttr_minutes"] / 60.0 for i in incidents
             if isinstance(i.get("mttr_minutes"), (int, float))]

    seamed = [a for a in alerts if a.get("seam") in ("paged", "dashboard-only")]
    paged = [a for a in seamed if a.get("seam") == "paged"]
    paged_share = round(len(paged) / len(seamed), 4) if seamed else None

    prov = "incident-system export"
    metrics = [
        {"name": "incident_count", "value": len(incidents), "unit": "count",
         "honesty_class": "deterministic", "provenance": prov,
         "detail": {"on_dark_journeys": dark_hits, "on_observed_journeys": obs_hits}},
        {"name": "mttr_incident", "value": round(_median(mttrs), 4) if mttrs else None,
         "unit": "hours", "honesty_class": "deterministic", "provenance": prov},
        {"name": "paged_share", "value": paged_share, "unit": "ratio",
         "honesty_class": "deterministic", "provenance": "alert-config export",
         "detail": {"paged": len(paged), "seamed": len(seamed)}},
    ]
    return {"ok": True, "source_absent": [], "metrics": metrics}


def main(argv):
    if not argv:
        sys.stderr.write("outcome_external: {defect-escape|incident} [...]\n")
        return 64
    sub, rest = argv[0], argv[1:]
    if sub == "defect-escape":
        result = cmd_defect_escape(rest)
    elif sub == "incident":
        result = cmd_incident(rest)
    else:
        sys.stderr.write("outcome_external: unknown subcommand: %s\n" % sub)
        return 64
    sys.stdout.write(json.dumps(result, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
