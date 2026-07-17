#!/usr/bin/env python3
"""Verification Manifest v1 validator (logic; the shell wrapper owns the CLI contract).

Layering (manifest spec §2): the JSON Schema enforces STRUCTURE (types, enums, ID
regexes, required/optional, incomplete_fields-iff-incomplete, spec_hash-iff-complete,
absence-when-null). This module adds the §10 COMPLETENESS rules 0-8. Keeping the two
apart is what lets an incomplete manifest stay schema-valid and resumable.

Exit codes (consumed by validate_manifest.sh): 0 complete · 3 incomplete · 4
schema-invalid · 5 unsupported schema_version.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

SUPPORTED_MAJOR = 1

EXIT_COMPLETE = 0
EXIT_INCOMPLETE = 3
EXIT_SCHEMA_INVALID = 4
EXIT_UNSUPPORTED = 5

_HERE = Path(__file__).resolve().parent
_SCHEMA = _HERE.parent / "schema" / "verification-manifest" / "v1.schema.json"


def load_manifest(path: Path):
    """Public parse API (ADR 0032): THE one manifest/YAML loader for the tree.

    YAML 1.2 core-schema, safe + pure (ADR 0014). Returns (data, error): error is
    None on success; on a parse/read failure data is None and error is a one-line
    string. Every consumer imports this instead of constructing its own parser.
    """
    from ruamel.yaml import YAML
    from ruamel.yaml.error import YAMLError

    yaml = YAML(typ="safe", pure=True)
    yaml.version = (1, 2)  # 1.2 core schema: `no`/`on` stay strings (Norway guard)
    try:
        with path.open("r", encoding="utf-8") as fh:
            return yaml.load(fh), None
    except YAMLError as exc:
        return None, f"YAML parse error: {exc}"
    except OSError as exc:
        return None, f"cannot read {path}: {exc}"


def _schema_errors(data) -> list[str]:
    from jsonschema import Draft202012Validator

    schema = json.loads(_SCHEMA.read_text(encoding="utf-8"))
    v = Draft202012Validator(schema)
    out = []
    for err in sorted(v.iter_errors(data), key=lambda e: list(e.path)):
        loc = "/".join(str(p) for p in err.path) or "<root>"
        out.append(f"{loc}: {err.message}")
    return out


# ---- completeness rules 0-8 (§10) ------------------------------------------------

def _active(items):
    return [x for x in items if isinstance(x, dict) and x.get("lifecycle") == "active"]


def _effective_criticality(behavior, journeys_by_id):
    if behavior.get("criticality"):
        return behavior["criticality"]
    jid = behavior.get("journey")
    if jid and jid in journeys_by_id:
        return journeys_by_id[jid].get("criticality")
    return None


def _nonempty(v):
    return isinstance(v, str) and v.strip() != ""


def completeness_violations(m) -> list[str]:
    """Return violations as `rule-<n>: <path>` strings; empty list == complete."""
    v: list[str] = []
    journeys = m.get("journeys", []) or []
    behaviors = m.get("behaviors", []) or []
    journeys_by_id = {j.get("id"): j for j in journeys if isinstance(j, dict)}
    environments = set(m.get("environments", []) or [])
    log = (m.get("interrogation", {}) or {}).get("log", []) or []
    human_dl = {e.get("id") for e in log if e.get("resolved_by") == "human"}

    active_j = _active(journeys)
    active_b = _active(behaviors)

    # Rule 0 (mechanical): at least one active behavior.
    if not active_b:
        v.append("rule-0: behaviors[] has no active entry")

    # Rules 1 & 2 over active journeys' steps.
    for j in active_j:
        jid = j.get("id", "?")
        for i, step in enumerate(j.get("steps", []) or []):
            vc = step.get("vital_class", "__missing__")
            at = f"journeys[{jid}].steps[{i}]"
            if vc is not None and vc != "__missing__":
                # Rule 1 (escalate): observability intent.
                if not _nonempty(step.get("required_emission")):
                    v.append(f"rule-1: {at}.required_emission")
                if not _nonempty(step.get("event_name")):
                    v.append(f"rule-1: {at}.event_name")
                seam = step.get("alert_seam") or {}
                if not seam.get("default"):
                    v.append(f"rule-1: {at}.alert_seam.default")
            if vc in ("money", "external-side-effect"):
                # Rule 2 (escalate): idempotency + compensation.
                idem = step.get("idempotency")
                if not isinstance(idem, dict) or "required" not in idem:
                    v.append(f"rule-2: {at}.idempotency.required")
                elif idem.get("mechanism") == "not-needed" and not _nonempty(idem.get("justification")):
                    v.append(f"rule-2: {at}.idempotency.justification")
                if not isinstance(step.get("compensation"), dict):
                    v.append(f"rule-2: {at}.compensation")

    # Rule 3 (mechanical): non-empty GWT on active behaviors.
    for b in active_b:
        bid = b.get("id", "?")
        for field in ("given", "when", "then"):
            if not _nonempty(b.get(field)):
                v.append(f"rule-3: behaviors[{bid}].{field}")

    # Rule 4 (escalate): effectively-CORE active entries confirmed.
    for j in active_j:
        if j.get("criticality") == "CORE" and j.get("confirmation") != "confirmed":
            v.append(f"rule-4: journeys[{j.get('id','?')}].confirmation")
    for b in active_b:
        if _effective_criticality(b, journeys_by_id) == "CORE" and b.get("confirmation") != "confirmed":
            v.append(f"rule-4: behaviors[{b.get('id','?')}].confirmation")

    # Rule 5 (mechanical): dangling refs, duplicate IDs, env keys, criticality-when-detached.
    all_ids = [x.get("id") for x in journeys + behaviors if isinstance(x, dict)]
    seen = set()
    for i in all_ids:
        if i in seen:
            v.append(f"rule-5: duplicate id {i}")
        seen.add(i)
    for b in behaviors:
        jid = b.get("journey")
        if jid and jid not in journeys_by_id:
            v.append(f"rule-5: behaviors[{b.get('id','?')}].journey -> unknown {jid}")
        # criticality REQUIRED when journey absent or withdrawn
        if not b.get("criticality"):
            j = journeys_by_id.get(jid) if jid else None
            if jid is None or (j is not None and j.get("lifecycle") == "withdrawn"):
                v.append(f"rule-5: behaviors[{b.get('id','?')}].criticality (required; journey absent/withdrawn)")
    for j in journeys:
        for i, step in enumerate(j.get("steps", []) or []):
            ref = (step.get("compensation") or {}).get("ref")
            if ref and ref not in journeys_by_id:
                v.append(f"rule-5: journeys[{j.get('id','?')}].steps[{i}].compensation.ref -> unknown {ref}")
            for key in (step.get("alert_seam") or {}):
                if key != "default" and key not in environments:
                    v.append(f"rule-5: journeys[{j.get('id','?')}].steps[{i}].alert_seam.{key} (not in environments)")

    # Rule 6 (mechanical): agent-resolved decisions carry dissent.
    for e in log:
        if e.get("resolved_by") == "agent" and not _nonempty(e.get("dissent")):
            v.append(f"rule-6: interrogation.log[{e.get('id','?')}].dissent")

    # Rule 7 (mechanical): withdrawn entries carry a reason.
    for x in journeys + behaviors:
        if x.get("lifecycle") == "withdrawn" and not _nonempty(x.get("withdrawn_reason")):
            kind = "journeys" if x in journeys else "behaviors"
            v.append(f"rule-7: {kind}[{x.get('id','?')}].withdrawn_reason")

    # Rule 8 (mechanical): CORE confirmation references a human interrogation entry.
    def check8(entry, kind, crit):
        if crit == "CORE" and entry.get("confirmation") == "confirmed":
            cb = entry.get("confirmed_by")
            if not cb or cb not in human_dl:
                v.append(f"rule-8: {kind}[{entry.get('id','?')}].confirmed_by (must ref a resolved_by:human DL entry)")

    for j in active_j:
        check8(j, "journeys", j.get("criticality"))
    for b in active_b:
        check8(b, "behaviors", _effective_criticality(b, journeys_by_id))

    return v


# ---- driver ----------------------------------------------------------------------

def validate_file(path: Path):
    """Return (exit_code, lines). Exactly one parse path: load, then validate."""
    data, err = load_manifest(path)
    if err is not None:
        return EXIT_SCHEMA_INVALID, [err]
    return validate_mapping(data)


def validate_mapping(data):
    """Validate an already-parsed manifest mapping. Return (exit_code, lines)."""
    if not isinstance(data, dict):
        return EXIT_SCHEMA_INVALID, ["top-level manifest is not a mapping"]

    # Unsupported major is distinct from schema-invalid (checked before structure).
    sv = data.get("schema_version")
    if isinstance(sv, int) and sv > SUPPORTED_MAJOR:
        return EXIT_UNSUPPORTED, [f"[MANIFEST-UNSUPPORTED: schema_version {sv} > supported {SUPPORTED_MAJOR}]"]

    serrs = _schema_errors(data)
    if serrs:
        return EXIT_SCHEMA_INVALID, ["schema-invalid:"] + serrs

    viol = completeness_violations(data)
    if viol:
        return EXIT_INCOMPLETE, [f"[SPEC-INCOMPLETE: {x}]" for x in viol]
    if data.get("completeness") == "complete":
        return EXIT_COMPLETE, ["complete"]
    return EXIT_INCOMPLETE, ["[SPEC-INCOMPLETE: declared incomplete; no rule violations — finalize to complete]"]


def validate_union(paths: list[Path]):
    """Validate each, then cross-file ID collision + profile/environments match."""
    lines, worst = [], EXIT_COMPLETE
    per_ids, profiles, envs = [], set(), set()
    for p in paths:
        # ONE parse per file (ADR 0032): load once, validate the mapping, and
        # reuse the same data for the cross-file checks below.
        data, err = load_manifest(p)
        if err is not None:
            code, out = EXIT_SCHEMA_INVALID, [err]
        else:
            code, out = validate_mapping(data)
        lines.append(f"== {p.name}: exit {code} ==")
        lines.extend(out)
        worst = max(worst, code) if code != EXIT_COMPLETE else worst
        if isinstance(data, dict):
            ids = {x.get("id") for x in (data.get("journeys", []) + data.get("behaviors", [])) if isinstance(x, dict)}
            for other in per_ids:
                dup = ids & other
                if dup:
                    lines.append(f"[MANIFEST-ID-COLLISION: {', '.join(sorted(dup))}]")
                    worst = max(worst, EXIT_SCHEMA_INVALID)
            per_ids.append(ids)
            profiles.add((data.get("observability") or {}).get("profile"))
            envs.add(tuple(data.get("environments") or []))
    if len(profiles) > 1 or len(envs) > 1:
        lines.append("[MANIFEST-UNION-MISMATCH: observability.profile or environments differ]")
        worst = max(worst, EXIT_SCHEMA_INVALID)
    return worst, lines


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "--union":
        paths = [Path(a) for a in argv[2:]]
        if not paths:
            print("usage: validate_manifest.py --union <file>...", file=sys.stderr)
            return 64
        code, lines = validate_union(paths)
    elif len(argv) == 2:
        code, lines = validate_file(Path(argv[1]))
    else:
        print("usage: validate_manifest.py <manifest.yaml> | --union <file>...", file=sys.stderr)
        return 64
    for ln in lines:
        print(ln)
    return code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
