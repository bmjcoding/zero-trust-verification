#!/usr/bin/env python3
"""TR-05 — incident-Spec emitter (the deliverable). NEVER a patch, NEVER a fix.

From a CONFIDENT TR-03 correlation, emit a two-file incident-Spec that plugs into
spec-gen's RESUME path (§10: an incomplete manifest is consumable by nothing except
a resumed spec-tier session):

  <incident-id>.md            prose naming the joined journey + behavior IDs + drift
                              class (+ any unmapped-in-prod events as prose notes)
  <incident-id>.manifest.yaml a partial manifest that is `completeness: incomplete`
                              BY CONSTRUCTION (validator exit 3), referencing EXISTING
                              behavior/journey IDs and MINTING NONE (§6: IDs are never
                              reallocated), with the drifted event_name/vital_class
                              pre-filled and risk/values fields left for interrogation.

Refusals (degrade rule 4 + loop-safety):
  - no confident join (all no_join / manifest-absent) -> REFUSE (exit 2); surface the gap.
  - a prior incident-Spec PR for this incident-key is still open -> SUPPRESS (exit 0),
    log `[note] already-open-incident-spec`, write nothing (TR-loop-guard dedupe).

The incomplete_fields are RECONCILED against the canonical validator's real exit-3
output (a two-pass build) so the file never claims an incompleteness the validator
would not compute — and the emitter REFUSES if its own construction is not actually
incomplete (guards against a vacuous "complete incident-Spec").

  emit_incident_spec.py --correlation <json> --manifest <source.yaml> --out-dir <dir>
      [--config <cfg>] [--host <host.sh>] [--ledger <f>] [--incident-id <id>]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import validate_manifest as V  # the canonical validator (single copy, ADR 0025)
import loop_guard as LG        # sibling

_HERE = Path(__file__).resolve().parent
_VALIDATE_SH = _HERE / "validate_manifest.sh"

REFUSE_NO_JOIN = 2


def _yaml_dump(data) -> str:
    from ruamel.yaml import YAML
    import io
    y = YAML()
    y.default_flow_style = False
    y.width = 4096
    buf = io.StringIO()
    y.dump(data, buf)
    return buf.getvalue()


def _quote(s: str) -> str:
    return json.dumps(str(s))  # JSON string is a valid YAML double-quoted scalar


def _drift_class(corr: dict, event: str, journey: str) -> str:
    for d in corr.get("class_drift", []):
        if d.get("event_name") == event and d.get("journey_id") == journey:
            return "class-drift"
    return "vital-incident"


def _source_journey(m: dict, jid: str):
    for j in m.get("journeys", []) or []:
        if isinstance(j, dict) and j.get("id") == jid:
            return j
    return None


def _source_behavior(m: dict, bid: str):
    for b in m.get("behaviors", []) or []:
        if isinstance(b, dict) and b.get("id") == bid:
            return b
    return None


def _build_manifest(source: dict, corr: dict, primary: dict, incident_id: str) -> dict:
    """Build the partial incident manifest referencing EXISTING IDs, minting none.

    Incompleteness is BY CONSTRUCTION: the joined journey's confirmation is dropped
    to `proposed` (a human has not confirmed this as a Spec) and money/external
    vital steps have idempotency+compensation left unanswered — exactly the
    risk/values residue spec-gen's interrogation owns.
    """
    jid = primary["journey_id"]
    src_j = _source_journey(source, jid)
    if src_j is None:
        raise SystemExit(f"emit: REFUSE: correlated journey {jid} not found in source manifest (cannot reference an ID that is not there)")

    # Journey shell: keep id/name/criticality/steps from source; force confirmation
    # -> proposed (interrogation residue). Strip idempotency/compensation on money/
    # external steps so rule-2 is genuinely open.
    steps = []
    for i, s in enumerate(src_j.get("steps", []) or []):
        st = {"name": s.get("name", f"step-{i}"), "vital_class": s.get("vital_class")}
        if s.get("vital_class") is not None:
            if s.get("required_emission"):
                st["required_emission"] = s["required_emission"]
            if s.get("event_name"):
                st["event_name"] = s["event_name"]
            seam = (s.get("alert_seam") or {})
            if seam.get("default"):
                st["alert_seam"] = {"default": seam["default"]}
        steps.append(st)

    journey = {
        "id": jid,
        "name": src_j.get("name", jid),
        "lifecycle": "active",
        "criticality": src_j.get("criticality", "CORE"),
        "criticality_reason": src_j.get("criticality_reason", "correlated from a production incident"),
        "confirmation": "proposed",
        "steps": steps,
    }

    behaviors = []
    for bid in primary.get("behavior_ids", []):
        src_b = _source_behavior(source, bid)
        if src_b is None:
            continue
        behaviors.append({
            "id": bid,
            "title": src_b.get("title", bid),
            "lifecycle": "active",
            "journey": jid,
            "confirmation": "proposed",
            "given": src_b.get("given", ""),
            "when": src_b.get("when", ""),
            "then": src_b.get("then", ""),
        })
    if not behaviors:  # never mint one; a genuinely undeclared behavior is a prose note
        behaviors = []

    profile = ((source.get("observability") or {}).get("profile")) or "default"
    envs = source.get("environments") or ["prod"]

    manifest = {
        "schema_version": 1,
        "manifest_revision": 1,
        "spec": {
            "path": f"./{incident_id}.md",
            "title": f"Incident: {primary['event_name']} on {jid}",
        },
        "completeness": "incomplete",
        "incomplete_fields": ["rule-0: bootstrap (reconciled below)"],
        "observability": {"profile": profile},
        "environments": list(envs),
        "interrogation": {"log": []},
        "journeys": [journey],
        "behaviors": behaviors,
    }
    return manifest


def _reconcile_incomplete_fields(manifest: dict) -> list[str]:
    """Return the validator's REAL exit-3 rule entries (the honest incomplete_fields)."""
    code, lines = V.validate_mapping(manifest)
    if code != V.EXIT_INCOMPLETE:
        raise SystemExit(
            f"emit: REFUSE: constructed incident manifest is not incomplete-by-construction "
            f"(validator exit {code}: {lines}); an incident-Spec MUST be resumable-incomplete, not complete"
        )
    fields = []
    for ln in lines:
        e = None
        s = ln.strip()
        if s.startswith("[SPEC-INCOMPLETE:") and s.endswith("]"):
            s = s[len("[SPEC-INCOMPLETE:"):-1].strip()
        if s.startswith("rule-"):
            fields.append(s)
    return fields or ["rule-0: incident-Spec is a resumable stub for spec-gen interrogation"]


def _prose(incident_id, primary, corr, drift, source) -> str:
    jid = primary["journey_id"]
    bids = ", ".join(primary.get("behavior_ids", [])) or "(none declared)"
    unmapped = sorted({e.get("event_name") for e in corr.get("no_join", []) if e.get("reason") == "unmapped-in-prod" and e.get("event_name")})
    dark = sum(1 for e in corr.get("no_join", []) if e.get("reason") == "dark-in-prod")
    lines = [
        f"# Incident-Spec: {primary['event_name']} — {drift} on {jid}",
        "",
        "> Produced by the production-telemetry triage tier (read-only, bounded-window).",
        "> This is a **Spec, not a patch**: it re-enters the ADLC at the LEFT edge via",
        "> spec-gen's RESUME path (`/spec @" + incident_id + ".md`), never a hotfix bypass,",
        "> never an auto-merge. The manifest below is `completeness: incomplete` BY",
        "> CONSTRUCTION — spec-gen interrogates the risk/values residue; the drain (never",
        "> this tier) authors any fix.",
        "",
        "## What the join found (journey DERIVED from the event_name match; backref agreement in correlation.backref_cross_check)",
        "",
        f"- Runtime event `{primary['event_name']}` correlates to journey **{jid}**, step "
        f"{primary['step_index']} (§12 event_name key, exact string).",
        f"- Affected behavior IDs (EXISTING; none minted): **{bids}**.",
        f"- Drift class: **{drift}**"
        + (f" (runtime vital_class `{primary.get('runtime_vital_class')}` vs manifest "
           f"`{primary.get('manifest_vital_class')}`)." if drift == "class-drift" else "."),
        "",
    ]
    if unmapped:
        lines += [
            "## Unmapped-in-prod (surfaced, not dropped — no ID minted here)",
            "",
            "These runtime events fired but no manifest step declares them. spec-gen may",
            "allocate a new behavior during interrogation; the triage tier mints nothing:",
            "",
        ] + [f"- `{e}`" for e in unmapped] + [""]
    if dark:
        lines += [
            "## DARK-in-prod",
            "",
            f"- {dark} record(s) carried no `event_name` (unjoinable). Bucketed, never dropped.",
            "",
        ]
    lines += [
        "## Invariants this artifact honors (grep-provable)",
        "",
        "- read-only on prod and on the repo target (queries telemetry; writes one",
        "  artifact class + a DRAFT PR proposal).",
        "- Spec-not-patch: the deliverable is a resumable incomplete manifest.",
        "- bounded-window-only ingestion (never a full-retention / whole-fleet scan).",
        "- no-self-ingestion loop guard (self-emitted events excluded; open incidents deduped).",
        "",
    ]
    return "\n".join(lines) + "\n"


def main(argv) -> int:
    ap = argparse.ArgumentParser(prog="emit_incident_spec.py")
    ap.add_argument("--correlation", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--out-dir", dest="out_dir", required=True)
    ap.add_argument("--config", default=str(_HERE.parent / "triage.config.yaml"))
    ap.add_argument("--host", default=None)
    ap.add_argument("--ledger", default=None)
    ap.add_argument("--incident-id", dest="incident_id", default=None)
    args = ap.parse_args(argv[1:])

    corr = json.loads(Path(args.correlation).read_text(encoding="utf-8"))
    correlated = corr.get("correlated") or []
    if not correlated:
        print("emit: REFUSE: no confident join (no correlated record) — no Spec; surface the gap (degrade rule 4).", file=sys.stderr)
        return REFUSE_NO_JOIN

    primary = sorted(correlated, key=lambda e: (e["event_name"], e["journey_id"], e["step_index"]))[0]
    drift = _drift_class(corr, primary["event_name"], primary["journey_id"])
    key = LG.incident_key(primary["event_name"], primary["journey_id"], drift)
    incident_id = args.incident_id or f"incident-{key}"

    # ── loop-safety dedupe: refuse a duplicate for an already-open incident-Spec ──
    lg_cmd = [sys.executable, str(_HERE / "loop_guard.py"), "is-open", "--key", key, "--config", args.config]
    if args.host:
        lg_cmd += ["--host", args.host]
    if args.ledger:
        lg_cmd += ["--ledger", args.ledger]
    isopen = subprocess.run(lg_cmd, capture_output=True, text=True)
    if isopen.returncode == 0 and isopen.stdout.strip() == "open":
        sys.stderr.write(isopen.stderr)
        print(f"[note] already-open-incident-spec (key={key}) — suppressing duplicate incident-Spec (TR-loop-guard).", file=sys.stderr)
        return 0  # suppression is the correct, safe outcome — not an error

    source, err = V._load_yaml_12(Path(args.manifest))
    if err is not None:
        print(f"emit: REFUSE: source manifest unreadable: {err}", file=sys.stderr)
        return REFUSE_NO_JOIN

    manifest = _build_manifest(source, corr, primary, incident_id)
    manifest["incomplete_fields"] = _reconcile_incomplete_fields(manifest)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    man_path = out_dir / f"{incident_id}.manifest.yaml"
    md_path = out_dir / f"{incident_id}.md"
    man_path.write_text(_yaml_dump(manifest), encoding="utf-8")
    md_path.write_text(_prose(incident_id, primary, corr, drift, source), encoding="utf-8")

    # ── prove it is resumable-incomplete through the CANONICAL validator (exit 3) ──
    res = subprocess.run(["bash", str(_VALIDATE_SH), str(man_path)], capture_output=True, text=True)
    if res.returncode != V.EXIT_INCOMPLETE:
        print(f"emit: REFUSE: emitted manifest did not validate as incomplete (exit {res.returncode}): {res.stdout}{res.stderr}", file=sys.stderr)
        return 1

    print(json.dumps({
        "incident_id": incident_id,
        "incident_key": key,
        "drift_class": drift,
        "manifest": str(man_path),
        "prose": str(md_path),
        "validator_exit": res.returncode,
        "references": {"journey": primary["journey_id"], "behaviors": primary.get("behavior_ids", [])},
    }, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
