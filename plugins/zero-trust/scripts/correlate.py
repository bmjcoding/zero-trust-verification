#!/usr/bin/env python3
"""TR-03 — incident<->manifest correlation via the §12 event_name key (runtime source).

Consumes (a) the incident window (TR-02 NDJSON, POST loop-guard) and (b) the
Verification Manifest, validated through the VENDORED validate_manifest (exit
0/3/4/5, §11 — reused verbatim, never reimplemented). It joins runtime emission to
design-time intent on `event_name` (the §12 key) and DERIVES the journey from that
match — NOT from a backref: journeys.json's v2 `manifest_journey_id` backref lives
in codebase-health CH-02, which is UNBUILT, so any cross-check against it is a
[det-cond] SKIP, never a silent assumption.

Honesty invariants:
  - schema-invalid(4)/unsupported(5) manifest -> REFUSE (degrade §11 never to
    manifest-less on a broken manifest); manifest ABSENT -> degrade to all-DARK-
    context + a loud note.
  - event_name with no manifest step        -> unmapped-in-prod (surfaced, not dropped)
  - record with no event_name               -> dark-in-prod (bucketed, not dropped)
  - runtime vital_class != manifest step's   -> class-drift finding
  - manifest CORE step absent from the window -> informational ONLY (degrade rule 4;
    absence-in-a-bounded-window is not absence-in-prod, never a violation)
  - correlation.json is schema-versioned + idempotent (sorted keys; detection never mutates).

  correlate.py --window <ndjson|-> --manifest <yaml> [--out <correlation.json>]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import validate_manifest as V  # vendored, byte-identical to repo root (V1/V3 pinned)

SCHEMA_VERSION = 1


def _load_window(src: str) -> list[dict]:
    fh = sys.stdin if src == "-" else open(src, encoding="utf-8")
    out = []
    with fh:
        for ln in fh:
            ln = ln.strip()
            if not ln:
                continue
            try:
                out.append(json.loads(ln))
            except ValueError:
                continue
    return out


def _index_manifest(m: dict):
    """event_name -> (journey_id, step_index, manifest_vital_class); plus behaviors-by-journey."""
    by_event = {}
    behaviors_by_journey: dict[str, list[str]] = {}
    core_steps = []  # (journey_id, step_index, event_name) for effectively-CORE active journeys
    journeys = m.get("journeys", []) or []
    behaviors = m.get("behaviors", []) or []
    for b in behaviors:
        if not isinstance(b, dict) or b.get("lifecycle") == "withdrawn":
            continue
        jid = b.get("journey")
        if jid:
            behaviors_by_journey.setdefault(jid, []).append(b.get("id"))
    for j in journeys:
        if not isinstance(j, dict):
            continue
        jid = j.get("id")
        active = j.get("lifecycle") == "active"
        is_core = j.get("criticality") == "CORE"
        for i, step in enumerate(j.get("steps", []) or []):
            en = step.get("event_name")
            if en:
                by_event.setdefault(en, (jid, i, step.get("vital_class")))
            if active and is_core:
                core_steps.append((jid, i, en))
    return by_event, behaviors_by_journey, core_steps


def correlate(window: list[dict], manifest_path: Path) -> dict:
    result = {
        "schema_version": SCHEMA_VERSION,
        "manifest_status": "absent",
        "correlated": [],
        "no_join": [],
        "class_drift": [],
        "core_steps_absent_in_window": [],
        "backref_cross_check": {
            "status": "skipped",
            "note": "backref-unavailable (CH-02 unbuilt): the journeys.json v2 manifest_journey_id "
                    "backref does not exist in the built suite; journey is DERIVED from the event_name "
                    "match. Cross-check is a triage-owned fixture check, NOT end-to-end suite proof.",
        },
        "notes": [],
    }

    if not manifest_path.exists():
        result["manifest_status"] = "absent"
        result["notes"].append("[note] manifest absent — no join possible; all records DARK-context (degrade rule 4)")
        for rec in window:
            result["no_join"].append({"event_name": rec.get("event_name"), "reason": "manifest-absent"})
        return result

    data, err = V._load_yaml_12(manifest_path)
    if err is not None:
        raise SystemExit(f"correlate.py: REFUSE: manifest unreadable/parse error: {err}")
    code, lines = V.validate_mapping(data)
    if code == V.EXIT_SCHEMA_INVALID:
        raise SystemExit("correlate.py: REFUSE: manifest schema-invalid (exit 4) — never degrade to manifest-less on a broken manifest (§11)")
    if code == V.EXIT_UNSUPPORTED:
        raise SystemExit("correlate.py: REFUSE: manifest schema_version unsupported (exit 5) — refuse (§11)")
    result["manifest_status"] = "complete" if code == V.EXIT_COMPLETE else "incomplete"

    by_event, behaviors_by_journey, core_steps = _index_manifest(data)
    seen_events = set()

    for rec in window:
        en = rec.get("event_name")
        if not en:
            result["no_join"].append({"event_name": None, "reason": "dark-in-prod"})
            continue
        seen_events.add(en)
        hit = by_event.get(en)
        if hit is None:
            result["no_join"].append({"event_name": en, "reason": "unmapped-in-prod"})
            continue
        jid, idx, m_vc = hit
        r_vc = rec.get("vital_class")
        entry = {
            "event_name": en,
            "journey_id": jid,
            "step_index": idx,
            "behavior_ids": sorted([b for b in behaviors_by_journey.get(jid, []) if b]),
            "runtime_vital_class": r_vc,
            "manifest_vital_class": m_vc,
        }
        result["correlated"].append(entry)
        # class-drift: both sides known and disagreeing.
        if r_vc is not None and m_vc is not None and r_vc != m_vc:
            result["class_drift"].append({
                "event_name": en, "journey_id": jid,
                "runtime_vital_class": r_vc, "manifest_vital_class": m_vc,
            })

    # CORE step absent from the bounded window — informational ONLY (degrade rule 4).
    for jid, idx, en in core_steps:
        if en and en not in seen_events:
            result["core_steps_absent_in_window"].append({
                "journey_id": jid, "step_index": idx, "event_name": en,
                "note": "CORE step not emitted in this bounded window — informational only; "
                        "absence-in-a-window is not absence-in-prod (never a violation).",
            })

    # de-duplicate correlated entries deterministically (idempotent output).
    def _dedup(seq, keyfn):
        seen, out = set(), []
        for x in seq:
            k = keyfn(x)
            if k in seen:
                continue
            seen.add(k)
            out.append(x)
        return out

    result["correlated"] = _dedup(result["correlated"], lambda e: (e["event_name"], e["journey_id"], e["step_index"]))
    result["class_drift"] = _dedup(result["class_drift"], lambda e: (e["event_name"], e["journey_id"], e["runtime_vital_class"], e["manifest_vital_class"]))
    result["correlated"].sort(key=lambda e: (e["event_name"], e["journey_id"], e["step_index"]))
    result["no_join"].sort(key=lambda e: (e.get("event_name") or "", e["reason"]))
    result["class_drift"].sort(key=lambda e: (e["event_name"], e["journey_id"]))
    result["core_steps_absent_in_window"].sort(key=lambda e: (e["journey_id"], e["step_index"]))
    return result


def main(argv) -> int:
    ap = argparse.ArgumentParser(prog="correlate.py")
    ap.add_argument("--window", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--out", default=None)
    args = ap.parse_args(argv[1:])

    window = _load_window(args.window)
    result = correlate(window, Path(args.manifest))
    blob = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.out:
        Path(args.out).write_text(blob, encoding="utf-8")
    else:
        sys.stdout.write(blob)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
