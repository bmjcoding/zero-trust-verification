#!/usr/bin/env python3
"""Emission-shape gate for the Spec Generation tier (spec-gen §7.4).

S7 emits one Spec + one manifest + S4 draft ADRs + S2 glossary edits on ONE
session branch and opens ONE PR. This module is the DETERMINISTIC check that the
emission bundle has the right shape before the PR is opened — the testable half
of S7 (the prose/behavior half is not machine-checkable).

It validates a bundle description (YAML/JSON) with these fields:

  branch:           spec/<slug>              # the one session branch
  session_slug:     <slug>
  spec_path:        docs/specs/<name>.md
  manifest_path:    docs/specs/<name>.manifest.yaml
  adrs:             [docs/adr/DRAFT-<slug>-<title>.md, ...]   # S4 provisional ADRs
  commits:          [{boundary: S1, ...}, ...]                # per S-boundary (HC5)
  pr:               {count: 1, body_anchors: [...]}
  interrogation_log:[{id: DL-001, resolved_by: human, exchange_ref: "#..."}]

Checks (each a spec-gen contract):
  E1 one-branch-one-PR .............. pr.count == 1                    (§7, HC)
  E2 manifest colocation ............ <name>.manifest.yaml beside <name>.md (§2)
  E3 per-boundary commits ........... a commit at every S-boundary     (HC5)
  E4 exchange_ref resolvability ..... every human DL exchange_ref is a PR anchor (S5/§7)
  E5 provisional-ADR filename shape . docs/adr/DRAFT-<session_slug>-<title>.md (§3 S4)

Returns a list of `Ennn: <detail>` violation strings; empty == emission is well-shaped.
This is a SHAPE gate; manifest content (completeness rules, rule-8 no-agent-path-
to-confirmed-CORE) is the canonical validator's job and runs at S6, not here.

CLI: emission_check.py <bundle.yaml>   # exit 0 clean, exit 3 with violations printed
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import validate_manifest as _VM  # noqa: E402  the public load API (ADR 0032)

# HC5: every S-step boundary commits. A completed session commits at each of S1..S7.
REQUIRED_BOUNDARIES = ["S1", "S2", "S3", "S4", "S5", "S6", "S7"]

# A DRAFT ADR title is a non-empty slug-shaped tail. The session-slug and the
# title both contain hyphens, so `DRAFT-<slug>-<title>` cannot be split by regex
# alone — E5 anchors on the KNOWN session_slug (see check_emission).
_TITLE_RE = re.compile(r"[a-z0-9]+(-[a-z0-9]+)*")
_ADR_GENERIC_RE = re.compile(r"^docs/adr/DRAFT-[a-z0-9]+(-[a-z0-9]+)*\.md$")


def _basename_noext(p: str) -> str:
    return Path(p).name.rsplit(".", 1)[0]


def check_emission(bundle: dict, required_boundaries=REQUIRED_BOUNDARIES) -> list[str]:
    v: list[str] = []
    slug = bundle.get("session_slug")
    spec_path = bundle.get("spec_path")
    manifest_path = bundle.get("manifest_path")

    # E1 — one branch, one PR.
    pr = bundle.get("pr") or {}
    if pr.get("count") != 1:
        v.append(f"E1: expected exactly one PR (pr.count == 1), got {pr.get('count')!r}")
    branch = bundle.get("branch")
    if not isinstance(branch, str) or not branch:
        v.append("E1: bundle names no session branch")

    # E2 — manifest colocated with its Spec as <spec-basename>.manifest.yaml.
    if not spec_path or not manifest_path:
        v.append("E2: spec_path and manifest_path are both required")
    else:
        sp, mp = Path(spec_path), Path(manifest_path)
        if sp.parent != mp.parent:
            v.append(f"E2: manifest not colocated with spec ({mp.parent} != {sp.parent})")
        expect = f"{_basename_noext(spec_path)}.manifest.yaml"
        if mp.name != expect:
            v.append(f"E2: manifest name {mp.name!r} != expected {expect!r}")

    # E3 — a commit at every S-boundary (HC5, session-death safety).
    boundaries = {c.get("boundary") for c in (bundle.get("commits") or []) if isinstance(c, dict)}
    missing = [b for b in required_boundaries if b not in boundaries]
    if missing:
        v.append(f"E3: missing per-boundary commit(s): {', '.join(missing)} (HC5)")

    # E4 — every human-resolved entry carries an exchange_ref that resolves to an
    # anchor in the PR body. At S7 (final emit) a human answer with a MISSING or
    # blank exchange_ref is a shape defect: the S5-presenter contract records one
    # per human answer, and §7.4 acceptance is "exchange_ref resolvability". (The
    # manifest schema keeps exchange_ref optional for mid-session resumability;
    # this stricter check is an S7-emit-time gate, not a schema rule.)
    anchors = set(pr.get("body_anchors") or [])
    for e in bundle.get("interrogation_log") or []:
        if not isinstance(e, dict):
            continue
        if e.get("resolved_by") == "human":
            ref = e.get("exchange_ref")
            if not (isinstance(ref, str) and ref.strip()):
                v.append(
                    f"E4: interrogation.log[{e.get('id','?')}] is resolved_by:human but "
                    "carries no exchange_ref (S7 must record the human exchange)"
                )
            elif ref not in anchors:
                v.append(
                    f"E4: interrogation.log[{e.get('id','?')}].exchange_ref {ref!r} "
                    "not resolvable in PR body anchors"
                )

    # E5 — provisional ADR filename shape docs/adr/DRAFT-<session_slug>-<title>.md.
    # Anchor on the known session_slug: `DRAFT-<slug>-<title>` is unsplittable by
    # regex when both parts carry hyphens, so we match the exact slug prefix and
    # require a non-empty slug-shaped title tail.
    for adr in bundle.get("adrs") or []:
        if not isinstance(adr, str):
            v.append(f"E5: ADR entry {adr!r} is not a string path")
            continue
        if slug:
            prefix = f"docs/adr/DRAFT-{slug}-"
            title = adr[len(prefix):-3] if adr.startswith(prefix) and adr.endswith(".md") else None
            if title is None or not _TITLE_RE.fullmatch(title):
                v.append(f"E5: ADR {adr!r} is not docs/adr/DRAFT-{slug}-<title>.md")
        elif not _ADR_GENERIC_RE.match(adr):
            v.append(f"E5: ADR path {adr!r} is not docs/adr/DRAFT-<slug-title>.md")
    return v


def _load(path: Path):
    """Bundle YAML through the canonical loader (ADR 0032); a parse failure is
    re-raised as ValueError so `_main` renders `{"error": ...}` + exit 4."""
    data, err = _VM.load_manifest(path)
    if err is not None:
        # read-errors already embed the path; only parse-errors need the prefix
        raise ValueError(err if str(path) in err else f"{path}: {err}")
    return data


def _main(argv) -> int:
    if len(argv) != 2:
        print("usage: emission_check.py <bundle.yaml>", file=sys.stderr)
        return 64
    try:
        bundle = _load(Path(argv[1]))
    except (ValueError, OSError) as exc:
        print(json.dumps({"error": str(exc)}))
        return 4
    if not isinstance(bundle, dict):
        print(json.dumps({"error": "bundle is not a mapping"}))
        return 4
    viol = check_emission(bundle)
    if viol:
        for x in viol:
            print(f"[EMISSION-MALFORMED: {x}]")
        return 3
    print("emission ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
