#!/usr/bin/env python3
"""Outcome report renderer (ADR 0023; OM-07). Report-only — ALWAYS exits 0.

Reads the outcome store and renders a machine-parseable artifact + a markdown digest
(agent-first, ADR 0006). Rules the renderer enforces so a reader (or a VP) can never
be misled:

  - Every metric line prints its HONESTY-CLASS BADGE. A Class-A (agent-graded) row
    renders [agent-graded] and can NEVER render [det] — the H1 anti-laundering guard,
    end to end.
  - A delta is shown un-caveated ONLY when both the baseline and the post window are
    >= the minimum (default 8 weeks); shorter (or window_short) -> 'directional, not
    yet significant'.
  - Every DORA/defect/incident delta carries a named-confounder line (multi-causal
    honesty); the emission share is labeled 'suite-produced, agent-graded', never a
    causal proof.
  - No frozen baseline -> [OUTCOME-NO-BASELINE] + absolute values only (never a
    fabricated 'before').
  - A KNOWN external metric absent from the store -> [OUTCOME-SOURCE-ABSENT: <label>]
    (absence never blocks the report). A non-external metric simply absent is omitted,
    not zero-filled.

Never emits a gating exit code. Exit 0 on every input, including error/degrade.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

MIN_WEEKS = 8

DORA_METRICS = ["deploy_frequency", "lead_time", "change_failure_rate", "mttr_build"]
AGENT_METRICS = ["emission_share"]
EXTERNAL_LABELS = {
    "defect_escape_rate": "defect-escape",
    "incident_count": "incident-system",
    "mttr_incident": "incident-system",
    "paged_share": "alert-config",
}
ORDER = DORA_METRICS + AGENT_METRICS + list(EXTERNAL_LABELS)

# The authoritative name -> honesty-class binding, mirrored from the schema's
# name<->class constraint (H1 anti-laundering, defense-in-depth). For a metric with
# a SINGLE authoritative class the renderer badges by THIS map, never by the stored
# string — so even a hand-crafted store that bypassed the schema can NEVER render a
# Class-A (agent-graded) number as [det]; a stored class that disagrees is surfaced
# as a loud [HONESTY-MISMATCH]. External metrics have two valid classes
# (deterministic | human-annotated), so they are trusted as-stored (the schema
# already constrains them to those two).
AUTHORITATIVE_CLASS = {
    "emission_share": "agent-graded",
    "deploy_frequency": "deterministic",
    "lead_time": "deterministic",
    "change_failure_rate": "deterministic",
    "mttr_build": "deterministic",
}

BADGE = {
    "deterministic": "[det]",
    "agent-graded": "[agent-graded]",
    "human-annotated": "[annotated]",
}
LABEL = {
    "deterministic": "Deterministic",
    "agent-graded": "Agent-graded",
    "human-annotated": "Human-annotated",
}
PRETTY = {
    "deploy_frequency": "Deploy frequency",
    "lead_time": "Lead time",
    "change_failure_rate": "Change-failure rate",
    "mttr_build": "MTTR (build)",
    "emission_share": "Journey emission share (CORE money/auth OBSERVED)",
    "defect_escape_rate": "Defect-escape rate",
    "incident_count": "Incident count",
    "mttr_incident": "MTTR (incident)",
    "paged_share": "Paged share (alert seam)",
}
CONFOUNDERS = ("confounders: team size, release freeze, incident load, seasonal "
               "traffic — correlated with adoption, not proof of cause")


def _flag(argv, name, default=None):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default


def _window_weeks(snap):
    if not isinstance(snap, dict):
        return None
    w = snap.get("window") or {}
    return w.get("weeks")


def _short(snap):
    return bool(isinstance(snap, dict) and snap.get("window_short"))


def _fmt(v):
    if v is None:
        return "n/a"
    if isinstance(v, float):
        return ("%.4f" % v).rstrip("0").rstrip(".")
    return str(v)


def render(store):
    lines = []
    artifact = {"baseline": bool(store.get("baseline")), "metrics": []}

    baseline = store.get("baseline")
    has_baseline = isinstance(baseline, dict) and baseline.get("frozen") is True
    base_metrics = {}
    if has_baseline:
        for m in baseline.get("metrics", []):
            base_metrics[m["name"]] = m

    # after = the most recent run row per metric (append order: later wins), with
    # the run it came from (for window/significance).
    after = {}
    for run in store.get("runs", []):
        for m in run.get("metrics", []):
            after[m["name"]] = (m, run)

    lines.append("# Outcome measurement digest\n")
    if not has_baseline:
        lines.append("**[OUTCOME-NO-BASELINE]** — no frozen baseline captured at "
                     "adoption; showing absolute values only, never a fabricated "
                     "'before'.\n")

    present = [n for n in ORDER if n in after] + \
              [n for n in sorted(after) if n not in ORDER]

    for name in present:
        row, run = after[name]
        stored_hc = row.get("honesty_class", "?")
        # A known metric is badged by its AUTHORITATIVE class, never the stored
        # string — a laundered [det] on an agent-graded metric is structurally
        # impossible in the render, and a disagreement is surfaced, not hidden.
        auth = AUTHORITATIVE_CLASS.get(name)
        hc = auth if auth is not None else stored_hc
        mismatch = auth is not None and stored_hc != auth
        badge = BADGE.get(hc, "[?]")
        val = row.get("value")
        pretty = PRETTY.get(name, name)
        entry = {"metric": name, "value": val, "honesty_class": hc,
                 "stored_honesty_class": stored_hc, "badge": badge,
                 "honesty_mismatch": mismatch, "delta": None, "significant": None}

        line = "- **%s**: %s %s" % (pretty, _fmt(val), badge)
        if mismatch:
            line += (" **[HONESTY-MISMATCH: store says '%s', authoritative is '%s' — "
                     "badged by the authoritative class, never laundered]**"
                     % (stored_hc, hc))

        b = base_metrics.get(name)
        if has_baseline and b is not None and isinstance(b.get("value"), (int, float)) \
                and isinstance(val, (int, float)):
            delta = round(val - b["value"], 4)
            entry["delta"] = delta
            bw = _window_weeks(baseline)
            aw = _window_weeks(run)
            short = _short(baseline) or _short(run)
            too_short = any(w is not None and w < MIN_WEEKS for w in (bw, aw))
            significant = not (short or too_short)
            entry["significant"] = significant
            sign = "+" if delta >= 0 else ""
            if significant:
                line += " (Δ %s%s vs baseline %s)" % (sign, _fmt(delta), _fmt(b["value"]))
            else:
                line += (" (Δ %s%s vs baseline %s — directional, not yet significant; "
                         "window < %dwk)" % (sign, _fmt(delta), _fmt(b["value"]), MIN_WEEKS))
        elif has_baseline and b is not None:
            line += " (baseline present but non-numeric — no delta)"

        # honesty framing
        if hc == "agent-graded":
            line += " · _suite-produced, agent-graded (journeys.json); not a hermetic number_"
        line += " · honesty: %s" % LABEL.get(hc, hc)
        lines.append(line)

        if name in DORA_METRICS or name in EXTERNAL_LABELS:
            if entry["delta"] is not None:
                lines.append("    - _%s_" % CONFOUNDERS)
        artifact["metrics"].append(entry)

    # known external metrics with no source configured -> source-absent
    seen_labels = set()
    for name, label in EXTERNAL_LABELS.items():
        if name not in after and label not in seen_labels:
            lines.append("- **%s**: [OUTCOME-SOURCE-ABSENT: %s] — external fact, no "
                         "source configured; field omitted, never fabricated."
                         % (PRETTY.get(name, name), label))
            artifact["metrics"].append({"metric": name, "value": None,
                                        "source_absent": label})
            seen_labels.add(label)

    if not present:
        lines.append("_No metrics captured yet — first observation._")

    return "\n".join(lines) + "\n", artifact


def main(argv):
    store_path = _flag(argv, "--store")
    json_out = _flag(argv, "--json")
    if not store_path:
        sys.stderr.write("outcome_report: --store PATH required\n")
        return 0  # report-only: never a gating exit
    p = Path(store_path)
    if not p.exists():
        sys.stdout.write("# Outcome measurement digest\n\n"
                         "_No store yet at %s — first observation, no history._\n" % store_path)
        return 0
    try:
        store = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        sys.stdout.write("# Outcome measurement digest\n\n"
                         "**[OUTCOME-STORE-UNREADABLE]** %s — reporting nothing "
                         "(degrade, never fabricate).\n" % exc)
        return 0
    md, artifact = render(store)
    sys.stdout.write(md)
    if json_out:
        try:
            Path(json_out).write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n",
                                      encoding="utf-8")
        except OSError as exc:
            sys.stderr.write("outcome_report: could not write artifact: %s\n" % exc)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
