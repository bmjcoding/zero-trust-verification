#!/usr/bin/env bash
# lint_spec_gen.sh — cross-file contract lint for the spec-gen domain of the
# zero-trust plugin (SG-6; single plugin since ADR 0025).
#
# The /spec orchestrator is an LLM that loads SKILL.md + references/ as ground
# truth; a contradiction between two files is a coin-flip at runtime. Each rule
# below pins one canonical contract and greps for drift, following the autopilot
# lint pattern (ADR 0001: "extends the existing lint_consistency.sh pattern").
#
# Rules:
#   L1  S-step ids ............ SKILL.md defines exactly S1..S7, no phantom steps
#   L2  hard-contract refs .... all SEVEN §4 hard contracts named in SKILL.md
#   L3  canonical schema ...... the ONE v1.schema.json present in the plugin (SG-3, ADR 0025)
#   L4  canonical validator ... the ONE validate_manifest.{sh,py} present (SG-3, ADR 0025)
#   L5  ADR grammar pin ....... ADR 0002 canonical `rule-<n>: <path>` + two-class
#                               echo; ADR 0001 `amended-by: 0011` (SG-7)
#   L6  escalation checklist .. both S4 prompts REQUIRE dissent + escalation_check
#                               over the ADR 0002 trilist (SG-2)
#   L7  GWT, no Gherkin ....... no Cucumber/behave/.feature runtime (ADR 0005)
#   L8  vanilla agents ........ S4 attackers are general-purpose, role-via-prompt (HC6)
#
# Roots are overridable (SPEC_GEN_PLUGIN_ROOT / SPEC_GEN_REPO_ROOT) so self_test.sh
# can point the lint at a tampered sandbox copy and assert it goes red.
#
# Exit 0 = all rules pass. Exit 1 = at least one violation (each printed).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="${SPEC_GEN_PLUGIN_ROOT:-$(cd "$HERE/.." && pwd)}"
REPO="${SPEC_GEN_REPO_ROOT:-$(cd "$PLUGIN/../.." && pwd)}"

SKILL="$PLUGIN/skills/spec/SKILL.md"
REFS="$PLUGIN/skills/spec/references"

FAIL=0
violation() { echo "LINT-FAIL [$1] $2" >&2; FAIL=1; }
ok() { echo "lint ok   [$1]"; }

# --- L1: S-step ids — exactly S1..S7, no phantom S0/S8 -----------------------------
l1_bad=0
for n in 1 2 3 4 5 6 7; do
  grep -qE "\bS${n}\b" "$SKILL" || { violation L1 "SKILL.md is missing lifecycle step S${n}"; l1_bad=1; }
done
if grep -qE '\bS0\b|\bS8\b|\bS9\b' "$SKILL"; then
  violation L1 "SKILL.md references a phantom S-step (S0/S8/S9)"; l1_bad=1
fi
(( l1_bad == 0 )) && ok L1

# --- L2: all SEVEN §4 hard contracts are named in SKILL.md -------------------------
# SKILL.md is the orchestrator's runtime ground truth; a silent deletion of any
# hard-contract statement is exactly the drift this rule exists to catch, so it
# pins all seven (HC1-HC7), not just the "headline" four.
l2_bad=0
grep -qiE 'refuse[- ]to[- ]finalize' "$SKILL" || { violation L2 "SKILL.md omits HC1 refuse-to-finalize"; l2_bad=1; }
grep -qiE 'no agent path to confirmed-CORE|confirmed-CORE .*(human|S5)' "$SKILL" || { violation L2 "SKILL.md omits HC2 no-agent-path-to-confirmed-CORE"; l2_bad=1; }
grep -qiE 'one writer|only writer' "$SKILL" || { violation L2 "SKILL.md omits HC3 one-writer"; l2_bad=1; }
grep -qiE 'one[- ]at[- ]a[- ]time' "$SKILL" || { violation L2 "SKILL.md omits HC4 one-at-a-time escalation"; l2_bad=1; }
grep -qiE 'session death is safe|every S-step boundary.*commit' "$SKILL" || { violation L2 "SKILL.md omits HC5 session-death-safe (per-boundary commits)"; l2_bad=1; }
grep -qiE 'vanilla agents only' "$SKILL" || { violation L2 "SKILL.md omits HC6 vanilla-agents-only, role-via-prompt"; l2_bad=1; }
grep -qiE 'ID allocation.*monotonic|never reuses? IDs' "$SKILL" || { violation L2 "SKILL.md omits HC7 monotonic ID allocation (reuse refusal)"; l2_bad=1; }
(( l2_bad == 0 )) && ok L2

# --- L3: canonical schema present (SG-3; ADR 0025 — one copy, nothing to drift) ----
if [ -f "$PLUGIN/schema/verification-manifest/v1.schema.json" ]; then
  ok L3
else
  violation L3 "canonical v1.schema.json missing from the plugin (schema/verification-manifest/)"
fi

# --- L4: canonical validator present (shell + python; ADR 0025 single copy) --------
l4_bad=0
[ -f "$PLUGIN/scripts/validate_manifest.sh" ] \
  || { violation L4 "canonical validate_manifest.sh missing from the plugin"; l4_bad=1; }
[ -f "$PLUGIN/scripts/validate_manifest.py" ] \
  || { violation L4 "canonical validate_manifest.py missing from the plugin"; l4_bad=1; }
(( l4_bad == 0 )) && ok L4

# --- L5: ADR grammar pin (SG-7) ---------------------------------------------------
ADR1="$REPO/docs/adr/0001-three-tier-suite-verification-manifest.md"
ADR2="$REPO/docs/adr/0002-agent-escalation-criterion.md"
l5_bad=0
grep -qE 'amended-by:\s*0011' "$ADR1" || { violation L5 "ADR 0001 lacks 'amended-by: 0011' annotation"; l5_bad=1; }
grep -qE 'rule-<n>: <path>' "$ADR2" || { violation L5 "ADR 0002 erratum lacks the canonical 'rule-<n>: <path>' grammar"; l5_bad=1; }
grep -qiE 'mechanical|two[- ]class|class \(b\)' "$ADR2" || { violation L5 "ADR 0002 erratum lacks the two-class echo"; l5_bad=1; }
(( l5_bad == 0 )) && ok L5

# --- L6: S4 escalation checklist (SG-2) -------------------------------------------
l6_bad=0
for ref in s4-decomposition-refuter.md s4-consumer-simulator.md; do
  f="$REFS/$ref"
  grep -q 'escalation_check:' "$f" || { violation L6 "$ref: output schema lacks escalation_check"; l6_bad=1; }
  grep -q 'dissent:' "$f" || { violation L6 "$ref: output schema lacks dissent"; l6_bad=1; }
  for axis in 'flagged:values' 'flagged:external-fact' 'flagged:irreversible'; do
    grep -q "$axis" "$f" || { violation L6 "$ref: escalation_check missing axis '$axis'"; l6_bad=1; }
  done
  grep -q 'REQUIRED' "$f" || { violation L6 "$ref: does not mark its fields REQUIRED"; l6_bad=1; }
done
(( l6_bad == 0 )) && ok L6

# --- L7: GWT, no Gherkin runtime (ADR 0005) ---------------------------------------
l7_bad=0
if grep -rilE 'cucumber|behave|specflow|\.feature\b' "$SKILL" "$REFS" 2>/dev/null; then
  violation L7 "a Gherkin/Cucumber runtime is referenced (ADR 0005 forbids one)"; l7_bad=1
fi
grep -qiE 'given/when/then|GWT' "$SKILL" || { violation L7 "SKILL.md does not use GWT behaviors (ADR 0005)"; l7_bad=1; }
(( l7_bad == 0 )) && ok L7

# --- L8: vanilla agents, role-via-prompt (HC6) ------------------------------------
l8_bad=0
for ref in s4-decomposition-refuter.md s4-consumer-simulator.md; do
  grep -q 'general-purpose' "$REFS/$ref" || { violation L8 "$ref: does not name the vanilla general-purpose agent (HC6)"; l8_bad=1; }
done
if grep -rqE 'subagent_type|custom agent type' "$REFS" 2>/dev/null; then
  violation L8 "a reference relies on a custom subagent_type (HC6 forbids it — role-via-prompt only)"; l8_bad=1
fi
(( l8_bad == 0 )) && ok L8

if (( FAIL == 1 )); then
  echo "lint_spec_gen: FAIL" >&2
  exit 1
fi
echo "lint_spec_gen: PASS (8 rules)"
exit 0
