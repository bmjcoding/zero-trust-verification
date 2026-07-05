#!/usr/bin/env bash
# lint_consistency.sh
#
# Deterministic cross-file contract lint for the autopilot skill (GAPS M2).
# The orchestrator is an LLM that loads SKILL.md + references/ as ground
# truth; a contradiction between two files is a coin-flip at runtime. Each
# rule below pins one canonical contract and greps for known drift.
#
# Scope: SKILL.md, README.md, references/*.md, scripts/*.sh headers.
# CHANGELOG.md is exempt from content rules (it legitimately describes
# historical, now-forbidden states) but supplies the canonical version (L12).
#
# Exit 0 = all rules pass. Exit 1 = at least one violation (each printed).
#
# Adding a rule: append an `L<n>` block, cite it from docs/GAPS_SPEC.md, and
# reference the rule id in the CHANGELOG entry that motivated it.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

FAIL=0
violation() {
  echo "LINT-FAIL [$1] $2" >&2
  FAIL=1
}
ok() {
  echo "lint ok   [$1]"
}

# Doc set under lint (CHANGELOG deliberately excluded).
DOCS=("$ROOT/SKILL.md" "$ROOT/README.md")
while IFS= read -r f; do DOCS+=("$f"); done < <(find "$ROOT/references" -name '*.md' | sort)
SCRIPTS=()
while IFS= read -r f; do
  # This linter necessarily contains its own forbidden tokens; exclude it.
  [[ "$(basename "$f")" == "lint_consistency.sh" ]] && continue
  SCRIPTS+=("$f")
done < <(find "$ROOT/scripts" -name '*.sh' | sort)

grep_docs() { grep -l -E "$1" "${DOCS[@]}" 2>/dev/null; }

# --- L1: one artifact-path scheme -------------------------------------------
# Canonical: .autopilot/runbooks/<slug>.md + <slug>.tracker.md.
if hits=$(grep_docs 'docs/design/AUTOPILOT-'); then
  violation L1 "legacy docs/design/AUTOPILOT-* path referenced in: $(tr '\n' ' ' <<<"$hits")"
else
  ok L1
fi

# --- L2: one tracker frontmatter schema --------------------------------------
# Canonical: session_lock / session_lock_expires_at / STATUS / in_progress.
legacy_fields='lock_acquired_at|current_step:|spec_hash|paused_count'
if hits=$(grep_docs "$legacy_fields"); then
  violation L2 "legacy tracker schema field in: $(tr '\n' ' ' <<<"$hits")"
else
  ok L2
fi
if hits=$(grep -l -E "$legacy_fields" "${SCRIPTS[@]}" 2>/dev/null); then
  violation L2 "legacy tracker schema field in script: $(tr '\n' ' ' <<<"$hits")"
fi

# --- L3: one step graph -------------------------------------------------------
# Legacy D0..D7.5 graph tokens must not reappear.
legacy_steps='D0 \(init\)|D0\.\.D7\.5|D1\.D3\.0|\bD2\.1\b'
if hits=$(grep_docs "$legacy_steps"); then
  violation L3 "legacy step-graph reference in: $(tr '\n' ' ' <<<"$hits")"
else
  ok L3
fi
if hits=$(grep -l -E "$legacy_steps" "${SCRIPTS[@]}" 2>/dev/null); then
  violation L3 "legacy step-graph reference in script header: $(tr '\n' ' ' <<<"$hits")"
fi

# --- L4: unique step ids ------------------------------------------------------
d75_defs=$(grep -c -E '^#+ +(Step +)?D7\.5\b' "$ROOT/references/drain-lifecycle.md" 2>/dev/null || echo 0)
if [[ "$d75_defs" != "1" ]]; then
  violation L4 "expected exactly one D7.5 heading in drain-lifecycle.md, found $d75_defs"
else
  ok L4
fi

# --- L5: one validator catalog ------------------------------------------------
# integration/design/quality (+security, sre). The phantom catalog used
# correctness/performance/style as validator names.
if hits=$(grep_docs 'validators:.*correctness|- correctness|\[correctness'); then
  violation L5 "phantom validator name 'correctness' in: $(tr '\n' ' ' <<<"$hits")"
else
  ok L5
fi

# --- L6: caps come from budget, not hardcoded threes --------------------------
if ! grep -q 'budget.max_impl_blocks' "$ROOT/references/drain-lifecycle.md"; then
  violation L6 "drain-lifecycle.md does not source escalation caps from budget.max_impl_blocks"
elif grep -qE 'consecutive_(impl|ci)_blocks >= 3' "$ROOT/references/drain-lifecycle.md"; then
  violation L6 "drain-lifecycle.md still hardcodes a >= 3 cap"
else
  ok L6
fi

# --- L7: batching doc matches drain-lifecycle ----------------------------------
b="$ROOT/references/tracker-delta-batching.md"
l7_bad=0
grep -q 'D1\.0\.6' "$b" && { violation L7 "tracker-delta-batching.md references nonexistent step D1.0.6"; l7_bad=1; }
grep -q -- '--force-rolling-tracker' "$b" && { violation L7 "tracker-delta-batching.md references unregistered flag --force-rolling-tracker"; l7_bad=1; }
grep -q 'D7\.2 tracker-PR cadence check' "$b" && { violation L7 "tracker-delta-batching.md describes the pre-v2.4 flush point"; l7_bad=1; }
grep -q 'D7\.1a' "$b" || { violation L7 "tracker-delta-batching.md does not reference the D7.1a fold"; l7_bad=1; }
(( l7_bad == 0 )) && ok L7

# --- L8: one TDD commit format -------------------------------------------------
if hits=$(grep_docs '\[RED\]|\[GREEN\]'); then
  violation L8 "legacy '[RED]/[GREEN]' commit format in: $(tr '\n' ' ' <<<"$hits")"
else
  ok L8
fi

# --- L9: branch_pattern field removed ------------------------------------------
if hits=$(grep_docs 'branch_pattern:'); then
  violation L9 "removed schema field 'branch_pattern:' in: $(tr '\n' ' ' <<<"$hits")"
else
  ok L9
fi

# --- L10: one estimated_size vocabulary ----------------------------------------
if grep -qE '`xs`|`s\+s`|`s` or `m`|→ `m`' "$ROOT/references/generate-lifecycle.md"; then
  violation L10 "generate-lifecycle.md uses out-of-vocabulary lowercase sizes (planner emits S|M|L)"
else
  ok L10
fi

# --- L11: cron prompts carry the drain invocation -------------------------------
l11_bad=0
while IFS= read -r line; do
  if ! grep -q '/autopilot --drain' <<<"$line"; then
    violation L11 "CronCreate prompt without '/autopilot --drain': $line"
    l11_bad=1
  fi
done < <(grep -h "prompt='" "${DOCS[@]}" 2>/dev/null)
(( l11_bad == 0 )) && ok L11

# --- L12: version references pinned to CHANGELOG top entry ----------------------
V=$(sed -n 's/^## \[\([0-9.]*\)\].*/\1/p' "$ROOT/CHANGELOG.md" | head -1)
l12_bad=0
if [[ -z "$V" ]]; then
  violation L12 "cannot parse current version from CHANGELOG.md"
  l12_bad=1
else
  grep -q "v${V}" "$ROOT/README.md" || { violation L12 "README.md Status does not cite v${V}"; l12_bad=1; }
  grep -q "v${V}" "$ROOT/references/runbook-template.md" || { violation L12 "runbook-template.md title does not cite v${V}"; l12_bad=1; }
  # Stale "in vX.Y.Z"-scoped claims about the CURRENT state must use "since".
  if grep -qE 'path in v2\.0\.0|ships Bitbucket DC only\. v2' "$ROOT/README.md" "$ROOT/references/cadence-dispatch.md"; then
    violation L12 "stale version-scoped claim (use 'since vX.Y.Z')"
    l12_bad=1
  fi
fi
(( l12_bad == 0 )) && ok L12

# --- L13: flag registry ----------------------------------------------------------
# Three sub-checks:
#  (a) required dispatcher flags present in SKILL.md;
#  (b) ghost flags absent everywhere;
#  (c) EVERY --flag token used in an `/autopilot ...` invocation anywhere in
#      the docs must appear in SKILL.md — new flags cannot be introduced in a
#      reference without registration. (Script-level flags like --dry-run are
#      out of scope: they belong to their script's usage header, not the
#      dispatcher registry.)
l13_bad=0
for flag in --generate --drain --resume --yolo --merge --overwrite --jira --consolidate=auto --slug --force --reprobe --no-probe --no-auto-seed; do
  grep -q -- "$flag" "$ROOT/SKILL.md" || { violation L13 "dispatcher flag $flag missing from SKILL.md registry"; l13_bad=1; }
done
for ghost in --force-rolling-tracker --external-scheduler; do
  if hits=$(grep -l -- "$ghost" "${DOCS[@]}" 2>/dev/null); then
    # --external-scheduler is allowed in the rationale doc's AP-19 history.
    hits=$(grep -v 'role-prompts-rationale.md' <<<"$hits" || true)
    [[ -n "$hits" ]] && { violation L13 "ghost flag $ghost referenced in: $(tr '\n' ' ' <<<"$hits")"; l13_bad=1; }
  fi
done
while IFS= read -r flag; do
  grep -q -- "$flag" "$ROOT/SKILL.md" || { violation L13 "flag $flag used in an /autopilot invocation but not registered in SKILL.md"; l13_bad=1; }
done < <(grep -h '/autopilot' "${DOCS[@]}" 2>/dev/null | grep -oE -- '--[a-z][a-z0-9-]*(=auto)?' | sort -u)
(( l13_bad == 0 )) && ok L13

# --- L14: no consumer-repo leakage -----------------------------------------------
# (the generic install-path mention of the skills root in README is fine;
# what's banned is depending on specific user-local skills or origin-repo files)
leak='internal_sdk|internal\.yml|mcp/server\.py|owasp-reference|observability-patterns'
l14_bad=0
if hits=$(grep_docs "$leak"); then
  violation L14 "consumer-repo leakage in: $(tr '\n' ' ' <<<"$hits")"
  l14_bad=1
fi
if hits=$(grep -l -E "$leak" "${SCRIPTS[@]}" 2>/dev/null); then
  violation L14 "consumer-repo leakage in script: $(tr '\n' ' ' <<<"$hits")"
  l14_bad=1
fi
# Real internal-corporate FQDNs: any host with an `.internal.` segment that is NOT the
# sanctioned `*.internal.example.<tld>` placeholder. Catches a hostname leak (e.g. the
# former origin-repo domain) without naming any company. Portable (no grep -P/-qv).
if hits=$(grep -En '[a-z0-9-]+\.internal\.[a-z0-9.-]+' "${DOCS[@]}" "${SCRIPTS[@]}" 2>/dev/null \
          | grep -v 'internal\.example\.'); then
  violation L14 "internal-corporate hostname leak in: $(tr '\n' ' ' <<<"$hits")"
  l14_bad=1
fi
(( l14_bad == 0 )) && ok L14

# --- L15: gates are runbook-sourced, not hardcoded --------------------------------
l15_bad=0
if hits=$(grep_docs 'ruff check \.'); then
  violation L15 "repo-wide 'ruff check .' in: $(tr '\n' ' ' <<<"$hits")"
  l15_bad=1
fi
if hits=$(grep_docs 'pytest -m unit'); then
  violation L15 "hardcoded 'pytest -m unit' gate in: $(tr '\n' ' ' <<<"$hits")"
  l15_bad=1
fi
# Bare-runner phrasing outside "(Python default: ...)" annotations — the
# stray class the v2.4.0 adversarial round caught seven of.
if hits=$(grep_docs '(scoped|runs?|running) pytest'); then
  violation L15 "bare 'pytest' phrasing (use gates.* with a Python-default annotation) in: $(tr '\n' ' ' <<<"$hits")"
  l15_bad=1
fi
grep -q 'gates.test_scoped' "$ROOT/references/drain-lifecycle.md" || { violation L15 "drain-lifecycle D6.1 does not reference gates.test_scoped"; l15_bad=1; }
grep -q '^gates:' "$ROOT/references/runbook-template.md" || { violation L15 "runbook-template.md does not define the gates: block"; l15_bad=1; }
(( l15_bad == 0 )) && ok L15

if (( FAIL == 1 )); then
  echo "lint_consistency: FAIL" >&2
  exit 1
fi
echo "lint_consistency: PASS (15 rules)"
exit 0
