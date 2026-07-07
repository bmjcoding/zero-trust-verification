#!/usr/bin/env python3
"""CH-03 — §12 intended↔discovered comparator (logic; the shell wrapper owns the CLI).

Joins a Verification Manifest (intent) to `audit/journeys.json` v2 (discovered)
per verification-manifest-v1.md §12, EVERY row, and emits one greppable verdict
line per row. This is a REPORTER (loop-safety invariant 1): it reads two files,
compares, and prints — it never mutates the manifest, the journeys file, or the
target, and it never blocks (the shell wrapper always exits 0).

Join keys and comparison rules are §12 verbatim:

  journeys[].id            <- manifest_journey_id   exact backref; else exact name; fuzzy = NO-JOIN
  steps[].event_name       <- steps[].event_name    exact string on a real discovered field (CH-02)
  required_emission        <- emission_grade         OBSERVED-only / LOG-ONLY-or-better lattice
  alert_seam (env map)     <- alert_seam (scalar)    paged<-paged; dash<-paged|dash; none<-any;
                                                     discovered unknown satisfies only intent none
  idempotency.required     <- duplicate_guard        present PASS; absent FAIL (escalate on money);
                                                     n/a NEEDS-VERIFICATION
  compensation             <- compensation_note      informational NOTE (no pass/fail)
  criticality (declared)   <- criticality (derived)  mismatch = MED needs-verification drift

Fingerprints — two scopes (CH-AMEND-A):
  * step-scoped rows (emission/seam/idempotency): path:symbol:slug
  * journey-scoped rows (criticality/backref):    <source-without-line>:<name>:slug

Severity obeys the severity-rubric.md 1.4.0 amendment: an emission/idempotency
absence reaches HIGH ONLY on a traced CORE money/auth path; everything else
hard-caps at MED (needs-verification when untraced). A config profile (CH-08)
never lifts that ceiling — it only decides which steps are money/auth-class.
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

# Profile names this deterministic layer recognizes. The profile PAYLOAD (vitals
# taxonomy, event vocabulary, alert seams) is data, not vendored here (ADR 0006);
# the deterministic layer only reads the NAME and degrades unknown -> default.
KNOWN_PROFILES = {"default", "payments"}

SLUG_EMISSION = "manifest-emission-drift"
SLUG_SEAM = "manifest-seam-drift"
SLUG_IDEMPOTENCY = "manifest-idempotency-drift"
SLUG_CRITICALITY = "manifest-criticality-drift"

# ── System-Design Coverage rows (SD-03..SD-10; ADR 0021/0022) ─────────────────
# vendored:sd-locus-guard:begin
# SD-00 (the honesty spine, ADR 0021/0022): the manifest DECLARES a control
# `locus`; this engine VERIFIES ONLY `locus: app` — the sole locus whose evidence
# is in the repo — and reports EVERY other locus as out-of-scope-by-declaration.
# That informational line is NEVER a finding, NEVER a violation, NEVER counted,
# NEVER blocking (ADR 0022). A raw "missing X" finding for a non-app/absent locus
# is the CENTRAL PROHIBITION this tier exists to prevent (unfalsifiable against an
# out-of-repo control); this engine emits no such line. Every app-locus SD finding
# caps at comment-only because the discovered side is agent-derived (MT-06), so no
# SD row is ever a blocking severity — only the mechanical JOIN is [det].
SLUG_ABUSE = "abuse-controls-drift"
SLUG_RESILIENCE = "resilience-posture-drift"
SLUG_ISOLATION = "isolation-drift"
SLUG_TIMEOUT = "timeout-budget-drift"
CLASS_ABUSE = "abuse-controls"
CLASS_RESILIENCE = "resilience-posture"
CLASS_ISOLATION = "isolation"


def sd_locus(decl):
    """The declared locus string for an SD field object, or None when the field or
    its locus is absent (nothing declared -> no row emitted, additive-safe)."""
    if not isinstance(decl, dict):
        return None
    loc = decl.get("locus")
    return loc if isinstance(loc, str) and loc else None


def sd_out_of_scope(class_name: str, locus: str, extra: str = "") -> None:
    """Emit THE one informational out-of-scope-by-declaration line (ADR 0022). It
    names the class + declared locus and is NEVER a finding/violation/blocking/
    counted line — the mechanical embodiment of SD-00's silence, the opposite of a
    raw missing-X finding. A declared out-of-repo locus (gateway/mesh/…) is verified
    elsewhere by declaration; `none-declared` is honestly UNdeclared (not verified
    elsewhere — just no in-repo control to assess), so it gets the truthful wording."""
    tail = f" — {extra}" if extra else ""
    if locus == "none-declared":
        body = ("no locus declared — no in-repo control to verify, and none declared "
                "elsewhere (honest silence, not a finding)")
    else:
        body = "verified elsewhere by declaration — not assessed in-repo"
    emit(f"[out-of-scope-by-declaration] {class_name} (locus={locus}): {body}{tail}")
# vendored:sd-locus-guard:end


def fingerprint(path: str, symbol: str, slug: str) -> str:
    """audit-state-and-verify.md: first 12 hex of sha1('<path>:<symbol>:<slug>')."""
    return hashlib.sha1(f"{path}:{symbol}:{slug}".encode()).hexdigest()[:12]


def strip_line(source: str) -> str:
    """Journey source is `file:line`; fingerprints carry NO line numbers, so the
    line suffix is stripped (CH-AMEND-A). `app/x.py:12` -> `app/x.py`."""
    if not source:
        return "<unknown-source>"
    # rsplit once: a path may itself contain no colon; a trailing :<int> is the line.
    head, sep, tail = source.rpartition(":")
    if sep and tail.isdigit():
        return head
    return source


def load_manifest(path: Path):
    from ruamel.yaml import YAML

    yaml = YAML(typ="safe", pure=True)
    yaml.version = (1, 2)  # 1.2 core schema — same Norway guard as the validator
    with path.open("r", encoding="utf-8") as fh:
        return yaml.load(fh)


# ── comparison lattices (§12) ─────────────────────────────────────────────────

def emission_verdict(intent: str, grade: str) -> str:
    """intent OBSERVED: only OBSERVED satisfies. intent LOG-ONLY: OBSERVED or
    LOG-ONLY; DARK never satisfies either."""
    if intent == "OBSERVED":
        return "PASS" if grade == "OBSERVED" else "FAIL"
    if intent == "LOG-ONLY":
        return "PASS" if grade in ("OBSERVED", "LOG-ONLY") else "FAIL"
    return "PASS"  # no emission intent -> nothing to satisfy


def seam_verdict(intent: str, discovered) -> str:
    """paged<-paged; dashboard-only<-paged|dashboard-only; none<-anything.
    A discovered `unknown`/`null` seam can only CONFIRM intent none; against a
    paged/dashboard-only intent it is needs-verification, never a violation."""
    if intent == "none":
        return "PASS"  # none <- anything (including unknown/null)
    if discovered in (None, "unknown", "null"):
        return "NEEDS-VERIFICATION"  # cannot confirm the required seam; not a violation
    if intent == "paged":
        return "PASS" if discovered == "paged" else "FAIL"
    if intent == "dashboard-only":
        return "PASS" if discovered in ("paged", "dashboard-only") else "FAIL"
    return "NEEDS-VERIFICATION"


def idempotency_verdict(required: bool, guard) -> str:
    if not required:
        return "PASS"  # not required -> nothing to satisfy
    if guard == "present":
        return "PASS"
    if guard == "absent":
        return "FAIL"
    return "NEEDS-VERIFICATION"  # n/a or unknown


def emission_severity(journey_crit, vital_class, grade) -> str:
    """HIGH only for DARK on a traced CORE money/auth path (the wire-transfer
    exemplar). LOG-ONLY vital even on CORE caps at MED (HIGH is DARK-only).
    Everything else caps at MED. A profile cannot lift this ceiling (CH-08)."""
    traced_core = journey_crit == "CORE" and vital_class in ("money", "auth")
    if traced_core and grade == "DARK":
        return "HIGH"
    return "MED"


def idempotency_severity(journey_crit, vital_class) -> str:
    """Missing idempotency on a traced CORE money-path write is the ADR-0004
    blocking class -> HIGH; otherwise MED needs-verification."""
    if journey_crit == "CORE" and vital_class == "money":
        return "HIGH"
    return "MED"


# ── driver ────────────────────────────────────────────────────────────────────

def emit(line: str) -> None:
    print(line)


def resolve_seam_intent(seam_map, audited_env: str):
    """Collapse the env-keyed intent map to the audited-environment key, else
    `default` (§12 seam row). journeys.json records one env-agnostic scalar, so
    the map must be reduced before the lattice compares."""
    if not isinstance(seam_map, dict):
        return None
    if audited_env in seam_map:
        return seam_map[audited_env]
    return seam_map.get("default")


def run(manifest_path: Path, journeys_path: Path, audited_env: str) -> int:
    manifest = load_manifest(manifest_path)
    if not isinstance(manifest, dict):
        emit("ERROR manifest is not a mapping")
        return 0
    journeys_doc = json.loads(journeys_path.read_text(encoding="utf-8"))

    # CH-08: read the profile NAME; degrade unknown -> default with a loud note.
    profile = ((manifest.get("observability") or {}).get("profile")) or "default"
    if profile in KNOWN_PROFILES:
        emit(f"PROFILE {profile} recognized")
    else:
        emit(f"PROFILE {profile} unknown->default")
        emit(f"[note] observability.profile '{profile}' not recognized — proceeding with default profile (CH-08; MS §11 unknown-profile row)")
        profile = "default"

    # audited env: the profile's env under audit, else default (seam collapse key).
    emit(f"ENV {audited_env}")

    m_journeys = manifest.get("journeys", []) or []
    d_journeys = journeys_doc.get("journeys", []) or []
    d_by_id = {j.get("manifest_journey_id"): j for j in d_journeys if j.get("manifest_journey_id")}
    d_by_name = {j.get("name"): j for j in d_journeys if j.get("name")}

    for mj in m_journeys:
        mid = mj.get("id", "?")
        mname = mj.get("name", "")
        # ── row 1: journey backref (exact id -> exact name -> NO-JOIN) ──────────
        disc = d_by_id.get(mid)
        how = "EXACT"
        if disc is None:
            disc = d_by_name.get(mname)
            how = "NAME" if disc is not None else "NONE"
        src = strip_line(disc.get("source", "")) if disc else "<no-discovered>"
        dname = disc.get("name", "") if disc else ""
        fp_journey = fingerprint(src, dname, SLUG_CRITICALITY)
        emit(f"JOURNEY {mid} backref={how} discovered={dname or 'NONE'}")

        if disc is None:
            emit(f"ROW journey-backref NO-JOIN fpsrc={src}:{mname}:{SLUG_CRITICALITY} fp={fingerprint(src, mname, SLUG_CRITICALITY)} :: no confident discovered match")
            emit(f"[not-covered] journey '{mid}' ({mname}): backref absent and name no-match — NOT a drift finding (invariant 6)")
            continue
        emit(f"ROW journey-backref PASS fpsrc={src}:{dname}:{SLUG_CRITICALITY} fp={fp_journey} :: matched via {how}")

        # ── row 8: criticality declared vs derived (journey-scoped) ────────────
        declared = mj.get("criticality")
        derived = disc.get("criticality")
        if declared == derived:
            emit(f"ROW criticality PASS fpsrc={src}:{dname}:{SLUG_CRITICALITY} fp={fp_journey} :: declared={declared} derived={derived}")
        else:
            emit(f"ROW criticality FAIL sev=MED fpsrc={src}:{dname}:{SLUG_CRITICALITY} fp={fp_journey} :: declared={declared} derived={derived} (intent-vs-derived drift, needs-verification)")

        derived_crit = derived  # per-journey criticality drives step severity

        # ── SD-05: abuse controls (rate limiting), journey-scoped, VERIFY app-only ──
        # locus:app -> verify the discovered (agent-traced) limiter, comment-only
        # (MT-06). Any other locus -> out-of-scope-by-declaration, NEVER a raw
        # "missing rate limit" finding (SD-00). Field absent -> no row (additive).
        abuse_loc = sd_locus(mj.get("abuse_controls"))
        if abuse_loc is not None:
            fp_ab = fingerprint(src, dname, SLUG_ABUSE)
            if abuse_loc == "app":
                discovered_ab = disc.get("abuse_control")
                if discovered_ab == "present":
                    emit(f"ROW {SLUG_ABUSE} PASS comment-only fpsrc={src}:{dname}:{SLUG_ABUSE} fp={fp_ab} :: locus=app discovered=present")
                elif discovered_ab == "absent":
                    emit(f"ROW {SLUG_ABUSE} FAIL comment-only fpsrc={src}:{dname}:{SLUG_ABUSE} fp={fp_ab} :: locus=app discovered=absent (app-declared limiter not discovered on the traced journey — candidate, agent-traced, MT-06)")
                else:
                    emit(f"ROW {SLUG_ABUSE} NEEDS-VERIFICATION comment-only fpsrc={src}:{dname}:{SLUG_ABUSE} fp={fp_ab} :: locus=app discovered={discovered_ab or 'unknown'} (limiter presence not determined — agent)")
            else:
                sd_out_of_scope(CLASS_ABUSE, abuse_loc)

        # ── per-step rows keyed by event_name (row 2) ──────────────────────────
        d_steps = disc.get("steps", []) or []
        d_step_by_event = {s.get("event_name"): s for s in d_steps if s.get("event_name")}
        for ms in mj.get("steps", []) or []:
            ev = ms.get("event_name")
            if not ev:
                continue  # non-vital manifest step (vital_class null) — nothing to join
            ds = d_step_by_event.get(ev)
            if ds is None:
                emit(f"STEP {ev} match=NONE")
                emit(f"[not-covered] step event_name '{ev}' on journey '{mid}': no discovered step emits it — NOT a drift finding (invariant 6)")
                continue
            path = ds.get("path", "<unknown-path>")
            symbol = ds.get("symbol", "<unknown-symbol>")
            vital = ds.get("vital_class")
            emit(f"STEP {ev} match=MATCH path={path} symbol={symbol}")

            # row 3/4: emission
            intent_em = ms.get("required_emission")
            if intent_em:
                grade = ds.get("emission_grade")
                v = emission_verdict(intent_em, grade)
                fp = fingerprint(path, symbol, SLUG_EMISSION)
                if v == "PASS":
                    emit(f"ROW emission PASS fpsrc={path}:{symbol}:{SLUG_EMISSION} fp={fp} :: intent={intent_em} grade={grade}")
                else:
                    sev = emission_severity(derived_crit, vital, grade)
                    # needs-verification rides on every UNconfirmed absence
                    # (severity-rubric.md 1.4.0 amendment): a finding on a traced
                    # CORE money/auth path is confirmed (HIGH if DARK, else a
                    # confirmed MED) and carries NO mark; anything off that traced
                    # path is capped MED and IS needs-verification.
                    traced_core = derived_crit == "CORE" and vital in ("money", "auth")
                    nv = "" if traced_core else " needs-verification"
                    emit(f"ROW emission FAIL sev={sev} fpsrc={path}:{symbol}:{SLUG_EMISSION} fp={fp} :: intent={intent_em} grade={grade}{nv}")

            # row 5: seam
            intent_seam = resolve_seam_intent(ms.get("alert_seam"), audited_env)
            if intent_seam is not None:
                disc_seam = ds.get("alert_seam")
                v = seam_verdict(intent_seam, disc_seam)
                fp = fingerprint(path, symbol, SLUG_SEAM)
                detail = f"intent={intent_seam}@{audited_env} discovered={disc_seam}"
                if v == "PASS":
                    emit(f"ROW seam PASS fpsrc={path}:{symbol}:{SLUG_SEAM} fp={fp} :: {detail}")
                elif v == "NEEDS-VERIFICATION":
                    emit(f"ROW seam NEEDS-VERIFICATION sev=MED fpsrc={path}:{symbol}:{SLUG_SEAM} fp={fp} :: {detail}")
                else:
                    emit(f"ROW seam FAIL sev=MED fpsrc={path}:{symbol}:{SLUG_SEAM} fp={fp} :: {detail}")

            # row 6: idempotency
            idem = ms.get("idempotency") or {}
            if isinstance(idem, dict) and idem.get("required"):
                guard = ds.get("duplicate_guard")
                v = idempotency_verdict(True, guard)
                fp = fingerprint(path, symbol, SLUG_IDEMPOTENCY)
                detail = f"required=true guard={guard}"
                if v == "PASS":
                    emit(f"ROW idempotency PASS fpsrc={path}:{symbol}:{SLUG_IDEMPOTENCY} fp={fp} :: {detail}")
                elif v == "NEEDS-VERIFICATION":
                    emit(f"ROW idempotency NEEDS-VERIFICATION sev=MED fpsrc={path}:{symbol}:{SLUG_IDEMPOTENCY} fp={fp} :: {detail}")
                else:
                    sev = idempotency_severity(derived_crit, vital)
                    emit(f"ROW idempotency FAIL sev={sev} fpsrc={path}:{symbol}:{SLUG_IDEMPOTENCY} fp={fp} :: {detail}")

            # row 7: compensation (informational NOTE)
            comp = ms.get("compensation")
            if isinstance(comp, dict):
                intent_comp = comp.get("ref") or comp.get("none_reason") or "unspecified"
                emit(f"ROW compensation NOTE :: intent={intent_comp} discovered={ds.get('compensation_note')}")

            # ── SD-06: resilience posture (breakers/shed/bulkheads), VERIFY app-only ──
            # locus:app -> verify the discovered (agent-traced) breaker/mechanism,
            # comment-only. shed-priority is DERIVED from criticality (agent) -> a
            # comment-only NOTE always. Other locus -> out-of-scope (sidecar/mesh);
            # NEVER a raw "missing circuit breaker" finding (SD-00).
            res_loc = sd_locus(ms.get("resilience_posture"))
            if res_loc is not None:
                fp_r = fingerprint(path, symbol, SLUG_RESILIENCE)
                if res_loc == "app":
                    mech = (ms.get("resilience_posture") or {}).get("mechanism", "unspecified")
                    disc_mech = ds.get("resilience_mechanism")
                    if disc_mech and disc_mech not in ("none", "unknown"):
                        emit(f"ROW {SLUG_RESILIENCE} PASS comment-only fpsrc={path}:{symbol}:{SLUG_RESILIENCE} fp={fp_r} :: locus=app mechanism={mech} discovered={disc_mech}")
                    else:
                        emit(f"ROW {SLUG_RESILIENCE} FAIL comment-only fpsrc={path}:{symbol}:{SLUG_RESILIENCE} fp={fp_r} :: locus=app mechanism={mech} discovered={disc_mech or 'none'} (app-declared {mech} not discovered on the traced step — candidate, agent-traced, MT-06)")
                    # shed-priority: derived from the criticality ladder (agent) -> comment-only NOTE, never [det]
                    emit(f"ROW {SLUG_RESILIENCE} NOTE shed-priority=derived({derived_crit}) comment-only :: shed-priority derived from criticality (agent, MT-06) — never [det]")
                else:
                    sd_out_of_scope(CLASS_RESILIENCE, res_loc)

            # ── SD-07: transaction isolation, app verifies a CANDIDATE (never a verdict) ──
            # locus:app + discovered explicit-lock -> a NOTE candidate (comment-only):
            # isolation-correctness needs runtime, so no PASS/FAIL verdict is minted.
            # db-config/none-declared -> out-of-scope + the honest degrade line.
            iso_loc = sd_locus(ms.get("isolation_requirement"))
            if iso_loc is not None:
                fp_i = fingerprint(path, symbol, SLUG_ISOLATION)
                if iso_loc == "app":
                    disc_iso = ds.get("isolation")
                    if disc_iso and disc_iso not in ("none", "unknown"):
                        emit(f"ROW {SLUG_ISOLATION} NOTE comment-only fpsrc={path}:{symbol}:{SLUG_ISOLATION} fp={fp_i} :: locus=app discovered={disc_iso} (explicit-lock CANDIDATE, not a verdict — isolation-correctness needs runtime; unknown, agent)")
                    else:
                        emit(f"ROW {SLUG_ISOLATION} NOTE comment-only fpsrc={path}:{symbol}:{SLUG_ISOLATION} fp={fp_i} :: locus=app discovered={disc_iso or 'none'} (no explicit-lock candidate discovered — unknown, agent; NOT a verdict)")
                else:
                    # `none-declared` already reads "no in-repo control to verify"; the
                    # DB/session-config degrade only clarifies a declared-elsewhere locus.
                    iso_extra = "" if iso_loc == "none-declared" else "unknown — isolation configured outside repo"
                    sd_out_of_scope(CLASS_ISOLATION, iso_loc, iso_extra)

            # ── SD-10: timeout budget composition, DETERMINISTIC-in-the-join ─────
            # timeout_budget_ms carries no locus: per-call timeouts are greppable and
            # in-repo, so a discovered configured timeout > declared budget is a real
            # [det] join finding — but it STILL ships comment-only through the ADR-0004
            # soak (ADR 0022). Cross-hop composition needs topology -> agent/unknown.
            budget = ms.get("timeout_budget_ms")
            if isinstance(budget, int):
                fp_t = fingerprint(path, symbol, SLUG_TIMEOUT)
                disc_to = ds.get("timeout_ms")
                if isinstance(disc_to, int):
                    if disc_to > budget:
                        emit(f"ROW {SLUG_TIMEOUT} FAIL comment-only fpsrc={path}:{symbol}:{SLUG_TIMEOUT} fp={fp_t} :: discovered={disc_to}ms > budget={budget}ms (deterministic-in-join; comment-only in the ADR-0004 soak, ADR 0022)")
                    else:
                        emit(f"ROW {SLUG_TIMEOUT} PASS comment-only fpsrc={path}:{symbol}:{SLUG_TIMEOUT} fp={fp_t} :: discovered={disc_to}ms <= budget={budget}ms")
                else:
                    emit(f"ROW {SLUG_TIMEOUT} NOTE comment-only fpsrc={path}:{symbol}:{SLUG_TIMEOUT} fp={fp_t} :: no discovered per-call timeout — per-call candidate only; cross-hop composition unknown (agent/topology)")

    return 0


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if a and not a.startswith("--")]
    audited_env = "default"
    for a in argv[1:]:
        if a.startswith("--env="):
            audited_env = a.split("=", 1)[1]
    if len(args) != 2:
        print("usage: manifest_join.py <manifest.yaml> <journeys.json> [--env=NAME]", file=sys.stderr)
        return 64
    return run(Path(args[0]), Path(args[1]), audited_env)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
