#!/usr/bin/env python3
"""Hermetic self-test for the Spec Generation tier's deterministic substrate.

The LLM interrogation (S2–S5 judgment) cannot be self-tested; the deterministic
seam can and is (spec-gen §7). Case groups map 1:1 to the deliverable acceptance:

  0. Canonical copies ... validate_manifest.{sh,py} + schema present ONCE in the plugin (SG-3/SG-6, ADR 0025)
  A. Validator reuse .... the canonical (single-copy) validator over the repo fixtures
                          + a rule-8 mutation + the mid-session manifest       (SG-3)
  B. ID allocator ....... §6 grammar: next-id, 999→new-slug, reuse refusal      (SG-4/§7.3)
  C. Resume projection .. validator exit-3 → escalate(1,2,4) / mechanical slots (SG-4/§7.2)
  E. Emission shape ..... one-branch-one-PR, colocation, per-boundary, refs, ADR(SG-4/§7.4)
  F. S4 schema field .... the S4 role prompts REQUIRE dissent + escalation_check (SG-2)
  G. Kill-mid-S4 resume . lossless resume from branch state alone               (SG-5)

No network, no external state. Exits non-zero on any failure.
Run via `scripts/self_test.sh` (bootstraps deps with `uv run`, ADR 0015).
"""
from __future__ import annotations

import copy
import io
import sys
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
PLUGIN = HERE.parent
REPO = PLUGIN.parent.parent
SCRIPTS = PLUGIN / "scripts"
sys.path.insert(0, str(SCRIPTS))

import validate_manifest as V          # noqa: E402  (the canonical copy, ADR 0025)
import id_alloc                         # noqa: E402
import resume_projection                # noqa: E402
import emission_check                   # noqa: E402

passed = 0
failed = 0


def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  ok   - {name}")
    else:
        failed += 1
        print(f"  FAIL - {name} {detail}")


def load(path):
    data, err = V.load_manifest(Path(path))  # the public load API (ADR 0032)
    assert err is None, err
    return data


# ---- 0. Canonical single copies present (SG-3/SG-6, post-ADR-0025) ---------------
# The consolidation collapsed the vendored pairs into ONE canonical copy inside
# the plugin; the byte-identity checks became presence checks (nothing left to
# drift — a MISSING canonical is the failure mode now).
print("== 0. canonical validator + schema single copies (ADR 0025) ==")
singles = [
    ("validate_manifest.sh", SCRIPTS / "validate_manifest.sh"),
    ("validate_manifest.py", SCRIPTS / "validate_manifest.py"),
    ("v1.schema.json", PLUGIN / "schema/verification-manifest/v1.schema.json"),
]
for label, canon in singles:
    check(f"{label} canonical copy present in the plugin (the ONE copy)",
          canon.exists(), f"({canon})")


# ---- A. Validator reuse over the merged repo fixtures (SG-3) ----------------------
print("== A. validate_manifest reuse (repo-root fixtures + rule-8 + mid-session) ==")
RFIX = REPO / "tests/fixtures/manifest"
check("repo valid-complete -> exit 0", V.validate_file(RFIX / "valid-complete.yaml")[0] == 0)
check("repo unsupported-version -> exit 5", V.validate_file(RFIX / "unsupported-version.yaml")[0] == 5)
check("repo norway-enum -> exit 4 (schema-invalid)", V.validate_file(RFIX / "norway-enum.yaml")[0] == 4)

base = load(RFIX / "valid-complete.yaml")
check("base fixture is genuinely complete", V.validate_mapping(base)[0] == 0)

# observability.profile is a tolerated no-op (ADR 0033): present -> still exit 0.
mtol = copy.deepcopy(base)
mtol.setdefault("observability", {})["profile"] = "payments"
check("observability.profile tolerated-and-ignored -> exit 0 (ADR 0033)",
      V.validate_mapping(mtol)[0] == 0)

# rule-8 mutation (CORE confirmed without a resolved_by:human confirmed_by ref).
m8 = copy.deepcopy(base)
m8["journeys"][0].pop("confirmed_by")
code8, lines8 = V.validate_mapping(m8)
check("rule-8 CORE-confirmed-without-DL-ref -> exit 3", code8 == 3)
check("rule-8 token echoed", any("rule-8" in ln for ln in lines8))

# the mid-session (killed-mid-S4) manifest is schema-valid + incomplete (exit 3),
# NOT schema-invalid — proves MS-AMEND-1 (spec_hash optional while incomplete).
mid_path = PLUGIN / "tests/fixtures/resume/killed-mid-s4.manifest.yaml"
code_mid, lines_mid = V.validate_file(mid_path)
check("killed-mid-s4 manifest -> exit 3 (incomplete, not schema-invalid)", code_mid == 3,
      f"(got {code_mid}: {lines_mid[:2]})")


# ---- B. ID allocator table tests (SG-4, §6/§7.3) ---------------------------------
print("== B. ID allocator (§6 grammar) ==")

# next-id: monotonic max+1 for the (prefix, slug) pair.
check("next J-pay after 001 -> 002",
      id_alloc.next_id("J", "pay", ["J-pay-001"]) == "J-pay-002")
check("first B-pay in empty set -> 001",
      id_alloc.next_id("B", "pay", []) == "B-pay-001")
check("gap from tombstone is NOT refilled (max+1, never reuse)",
      id_alloc.next_id("J", "pay", ["J-pay-001", "J-pay-003"]) == "J-pay-004")
# a withdrawn/tombstoned id still counts as reserved (manifest §6).
check("multi-slug isolation: J-fee unaffected by J-pay",
      id_alloc.next_id("J", "fee", ["J-pay-007"]) == "J-fee-001")

# 999 overflow -> IdOverflow, and allocate() falls to the supplied new slug.
full = [f"J-pay-{n:03d}" for n in range(1, 1000)]  # 001..999
try:
    id_alloc.next_id("J", "pay", full)
    check("next_id raises IdOverflow at 999", False, "(no exception)")
except id_alloc.IdOverflow:
    check("next_id raises IdOverflow at 999", True)
oid, overflowed = id_alloc.allocate("J", "pay", full, overflow_slug="pay-b")
check("allocate() overflows 999 -> new slug", oid == "J-pay-b-001" and overflowed is True, f"(got {oid})")

# reuse refusal: reserved set spans MAIN lineage + an OPEN branch (HC7).
main_lineage = ["J-wire-001", "B-wire-001"]
open_branch = ["J-wire-002"]          # allocated by an overlapping session (ADR 0009)
reserved = set(main_lineage) | set(open_branch)
check("allocation skips both main-lineage and open-branch ids",
      id_alloc.next_id("J", "wire", reserved) == "J-wire-003")
try:
    id_alloc.claim("J-wire-002", reserved)   # explicitly claiming an open-branch id
    check("claim() refuses an id reserved on an open branch", False, "(no refusal)")
except id_alloc.IdError:
    check("claim() refuses an id reserved on an open branch", True)
check("claim() accepts a fresh well-formed id", id_alloc.claim("J-wire-009", reserved) == "J-wire-009")

# grammar: every emitted id matches the canonical schema regex; malformed rejected.
check("emitted ids are §6-valid", id_alloc.valid("J-pay-002") and id_alloc.valid("B-fee-x-001"))
check("uppercase slug rejected (schema regex)", not id_alloc.valid("J-Pay-001"))
check("2-digit suffix rejected", not id_alloc.valid("J-pay-01"))
check("DL grammar has no slug", id_alloc.valid("DL-001") and not id_alloc.valid("DL-pay-001"))
try:
    id_alloc.next_id("DL", "", ["DL-001"])
    check("next_id refuses DL allocation (per-manifest, not slug-based)", False)
except id_alloc.IdError:
    check("next_id refuses DL allocation (per-manifest, not slug-based)", True)


# ---- C. Resume projection (SG-4, §7.2) -------------------------------------------
print("== C. resume projection (validator exit-3 -> S-step slots) ==")
proj = resume_projection.project_manifest(mid_path)
check("projection ran off validator exit-3", proj.get("validator_exit") == 3)
esc_rules = {s["rule"] for s in proj["escalate"]}
mech_rules = {s["rule"] for s in proj["mechanical"]}
check("escalate slots carry ONLY rules 1,2,4", esc_rules <= {1, 2, 4} and esc_rules, f"(got {sorted(esc_rules)})")
check("mechanical slots carry ONLY rules 0,3,5,6,7,8", mech_rules <= {0, 3, 5, 6, 7, 8} and mech_rules,
      f"(got {sorted(mech_rules)})")
check("no rule leaks across the class boundary", esc_rules.isdisjoint(mech_rules))
# the planted gaps land in the right class:
check("rule-1 (alert_seam) escalated", 1 in esc_rules)
check("rule-2 (idempotency/compensation) escalated", 2 in esc_rules)
check("rule-4 (CORE confirmation) escalated", 4 in esc_rules)
check("rule-3 (empty then) is mechanical (S3/S4 queue), NOT a question", 3 in mech_rules and 3 not in esc_rules)
check("rule-6 (agent dissent) is mechanical, NOT a question", 6 in mech_rules and 6 not in esc_rules)
# each escalate slot carries its S5 question kind (recommendation/dissent excluded — §7.2).
kinds = {s["rule"]: s.get("kind") for s in proj["escalate"]}
check("rule-1 slot kind = observability-intent", kinds.get(1) == "observability-intent")
check("rule-2 slot kind = risk-appetite", kinds.get(2) == "risk-appetite")
check("rule-4 slot kind = confirmation", kinds.get(4) == "confirmation")
check("slots carry NO recommendation/dissent (comes from the S4 re-run, §7.2)",
      all("recommendation" not in s and "dissent" not in s for s in proj["escalate"]))

# pure-fields projection (parses the wrapped validator lines too).
p2 = resume_projection.project([
    "[SPEC-INCOMPLETE: rule-2: journeys[J-x-001].steps[0].idempotency.required]",
    "rule-3: behaviors[B-x-001].then",
    "complete",                        # non-rule lines ignored
])
check("wrapped [SPEC-INCOMPLETE:] line parsed", any(s["rule"] == 2 for s in p2["escalate"]))
check("bare rule line parsed", any(s["rule"] == 3 for s in p2["mechanical"]))
check("non-rule lines dropped", len(p2["escalate"]) + len(p2["mechanical"]) == 2)


# ---- E. Emission shape (SG-4, §7.4) ----------------------------------------------
print("== E. emission-shape gate ==")
good = load(PLUGIN / "tests/fixtures/emission/session-good.yaml")
check("good session bundle passes clean", emission_check.check_emission(good) == [],
      f"({emission_check.check_emission(good)})")

def mutate_emit(fn):
    d = copy.deepcopy(good)
    fn(d)
    return emission_check.check_emission(d)

def has(viol, code):
    return any(x.startswith(code) for x in viol)

check("E1 two PRs -> violation", has(mutate_emit(lambda d: d["pr"].__setitem__("count", 2)), "E1"))
check("E2 non-colocated manifest -> violation",
      has(mutate_emit(lambda d: d.__setitem__("manifest_path", "docs/other/wire-transfer.manifest.yaml")), "E2"))
check("E2 wrong manifest basename -> violation",
      has(mutate_emit(lambda d: d.__setitem__("manifest_path", "docs/specs/wrong.manifest.yaml")), "E2"))
check("E3 dropping the S4 boundary commit -> violation (HC5)",
      has(mutate_emit(lambda d: d.__setitem__("commits", [c for c in d["commits"] if c["boundary"] != "S4"])), "E3"))
check("E4 human exchange_ref with no PR anchor -> violation",
      has(mutate_emit(lambda d: d["interrogation_log"].append(
          {"id": "DL-004", "resolved_by": "human", "exchange_ref": "#missing"})), "E4"))
check("E4 human entry with BLANK exchange_ref -> violation (S7 must record it)",
      has(mutate_emit(lambda d: d["interrogation_log"].append(
          {"id": "DL-005", "resolved_by": "human", "exchange_ref": ""})), "E4"))
check("E4 human entry with MISSING exchange_ref key -> violation",
      has(mutate_emit(lambda d: d["interrogation_log"].append(
          {"id": "DL-006", "resolved_by": "human"})), "E4"))
check("E4 does NOT fire on an agent entry with no exchange_ref (only human answers gate)",
      not has(mutate_emit(lambda d: d["interrogation_log"].append(
          {"id": "DL-007", "resolved_by": "agent", "dissent": "x"})), "E4"))
check("E5 ADR filename with wrong session slug -> violation",
      has(mutate_emit(lambda d: d.__setitem__("adrs", ["docs/adr/DRAFT-other-slug-title.md"])), "E5"))
check("E5 ADR not under DRAFT- prefix -> violation",
      has(mutate_emit(lambda d: d.__setitem__("adrs", ["docs/adr/0099-wire-transfer-title.md"])), "E5"))


# ---- F. S4 output-schema checklist field (SG-2) ----------------------------------
print("== F. S4 role-prompt output schema REQUIRES dissent + escalation_check ==")
REFS = PLUGIN / "skills/spec/references"
for ref in ("s4-decomposition-refuter.md", "s4-consumer-simulator.md"):
    text = (REFS / ref).read_text()
    # prompt-projection: the fenced OUTPUT SCHEMA must name both required fields.
    check(f"{ref}: schema declares escalation_check", "escalation_check:" in text)
    check(f"{ref}: schema declares dissent", "dissent:" in text)
    # the ADR 0002 trilist is present as an explicit checklist (not vibes).
    for axis in ("clear", "flagged:values", "flagged:external-fact", "flagged:irreversible"):
        check(f"{ref}: escalation_check offers '{axis}'", axis in text)
    # dissent is marked REQUIRED/non-empty (manifest rule 6).
    check(f"{ref}: dissent marked REQUIRED", "REQUIRED" in text and "dissent" in text)
    # vanilla-agent contract (HC6) is stated.
    check(f"{ref}: names the vanilla general-purpose agent (HC6)", "general-purpose" in text)
# the other two role prompts exist and state a schema.
for ref in ("s3-proposer.md", "s5-presenter.md"):
    text = (REFS / ref).read_text()
    check(f"{ref}: states an OUTPUT SCHEMA", "OUTPUT SCHEMA" in text)
check("S5 presenter forbids agent path to confirmed-CORE",
      "human" in (REFS / "s5-presenter.md").read_text() and "confirmed-CORE" in (REFS / "s5-presenter.md").read_text().replace("confirmed CORE", "confirmed-CORE"))


# ---- G. Kill-mid-S4 resumes losslessly from branch state (SG-5) -------------------
print("== G. kill-mid-S4 lossless resume (branch state only) ==")
# The mid-session manifest IS the branch state (nothing in context memory — HC5).
# Resuming = re-validate + project. The full escalate residue must reconstruct
# purely from the committed file, independent of the stale incomplete_fields.
stale = load(mid_path).get("incomplete_fields", [])
check("stored incomplete_fields is stale/partial (only 1 entry)", len(stale) == 1)
resumed = resume_projection.project_manifest(mid_path)
check("resume reconstructs MORE gaps than the stale field named (validator recompute wins)",
      len(resumed["escalate"]) + len(resumed["mechanical"]) > len(stale))
# content, not just count: the one gap the stale field DID name must survive the
# recompute (a projection that dropped it while finding others would still grow).
stale_paths = {resume_projection.parse_entry(s)["path"] for s in stale}
resumed_paths = {s["path"] for s in resumed["escalate"] + resumed["mechanical"]}
check("resume PRESERVES the gap the stale incomplete_fields named",
      stale_paths <= resumed_paths, f"(stale {stale_paths} not in {sorted(resumed_paths)})")
check("resume yields the full S5 residue (rules 1,2,4 all present)",
      {1, 2, 4} <= {s["rule"] for s in resumed["escalate"]})
check("resume yields the S3/S4 fix queue (mechanical rules present)",
      len(resumed["mechanical"]) >= 1)
# and the branch-state emission that a completed session would produce is well-shaped
# (per-boundary commits S1..S7 present -> the kill point had S1..S3 already committed).
check("a completed session's emission bundle is well-shaped (per-boundary commits, HC5)",
      emission_check.check_emission(good) == [])


# ---- H. Malformed-input robustness (hand-editable files degrade cleanly) ----------
print("== H. malformed-input robustness ==")
import subprocess  # noqa: E402
import tempfile  # noqa: E402

def run_cli(mod, args, stdin=None):
    """Run a helper's CLI under uv and return (exit_code, stdout, stderr)."""
    cmd = ["uv", "run", "--project", str(PLUGIN), "python", str(SCRIPTS / mod), *args]
    p = subprocess.run(cmd, input=stdin, capture_output=True, text=True, cwd=str(PLUGIN))
    return p.returncode, p.stdout, p.stderr

with tempfile.TemporaryDirectory() as td:
    bad_bundle = Path(td) / "bundle.yaml"
    bad_bundle.write_text("branch: [unclosed\n")
    rc, out, err = run_cli("emission_check.py", [str(bad_bundle)])
    check("emission_check on malformed YAML: clean exit 4, no traceback",
          rc == 4 and '"error"' in out and "Traceback" not in err, f"(rc={rc}, err={err[:80]})")

# id_alloc: a bare string for `existing` is refused, not silently iterated to a reuse.
try:
    id_alloc.next_id("J", "pay", "J-pay-005")   # a str, not a list
    check("id_alloc refuses a bare-string `existing` (would silently reuse)", False, "(no error)")
except id_alloc.IdError:
    check("id_alloc refuses a bare-string `existing` (would silently reuse)", True)

# The helper CLIs are wired and return their documented JSON on good input, too.
rc, out, err = run_cli("id_alloc.py", ["alloc"], stdin='{"prefix":"J","slug":"pay","existing":["J-pay-001"]}')
check("id_alloc.py alloc CLI returns the next id", rc == 0 and '"J-pay-002"' in out, f"(rc={rc}, out={out[:80]})")


print(f"\n== spec-gen run_spec_gen_cases: {passed} passed, {failed} failed ==")
sys.exit(1 if failed else 0)
