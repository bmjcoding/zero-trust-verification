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

# --- L16: the host adapter is the single PR/build surface (ADR 0013, AV3-16b) --
# The v2.4.0 "Bitbucket DC is the source-of-truth host / gh is NOT a dependency"
# framing is retired: PR/build ops route through scripts/host.sh, which
# dispatches to per-host backends. Any doc reasserting the single-host framing,
# or calling a backend script as THE surface, is a runtime coin-flip.
l16_bad=0
# (a) Retired single-host framing must not reappear in the doc set.
if hits=$(grep_docs 'source-of-truth host|CLI is NOT a dependency'); then
  violation L16 "retired single-host framing (host adapter is the surface now): $(tr '\n' ' ' <<<"$hits")"
  l16_bad=1
fi
# (b) SKILL.md must name host.sh as the PR/build surface and carry the rewritten
#     Hard Contract 11 wording.
grep -q 'scripts/host.sh' "$ROOT/SKILL.md" || { violation L16 "SKILL.md does not reference scripts/host.sh as the PR/build surface"; l16_bad=1; }
grep -q 'host adapter is the single PR/build surface' "$ROOT/SKILL.md" || { violation L16 "Hard Contract 11 does not carry the host-adapter wording"; l16_bad=1; }
# (c) Operational PR/build invocations ANYWHERE in the doc set must go through
#     host.sh, never a backend script directly (Hard Contract 11). Scans the full
#     DOCS array (SKILL + README + all references) — the whole corpus, not just
#     the lifecycle files — so a direct call cannot hide in a prompt or the
#     README. Matches `<backend>.sh <verb>` (invocation form); the reference-index
#     rows that merely NAME a backend and list its verbs use backticks/colons,
#     not this form, so they are not false-positived.
verbs='pr-open|pr-ready|pr-state|pr-comment|pr-merge-strategies|pr-merge|pr-approve|pr-decline|build-status'
if hits=$(grep -l -E "(bitbucket|github)\.sh ($verbs)" "${DOCS[@]}" 2>/dev/null); then
  violation L16 "doc calls a backend script directly (use host.sh): $(tr '\n' ' ' <<<"$hits")"
  l16_bad=1
fi
(( l16_bad == 0 )) && ok L16

# --- L17: PR-per-Story, not PR-per-Subtask (AV3-06 / ADR 0007) ----------------
# v3 collapses the drain onto Story branches: one Story = one branch = one PR
# (draft until the Story's Subtasks are all Done). Subtasks are the commit series
# on the Story branch, NOT separate PRs. Any doc reasserting the retired
# per-Subtask-PR granularity is a runtime coin-flip — the orchestrator would open
# a PR every fire. Scans the whole DOCS corpus (CHANGELOG exempt: it records the
# historical per-Subtask state). The bookkeeping-fold phrasing ("the next Subtask
# PR" for the AP-23 delta fold) is out of scope here — AV3-08 re-scopes it to the
# Runbook PR — so this rule matches only the PR-*granularity* claim.
l17_bad=0
per_subtask_pr='PR per [Ss]ubtask|per-[Ss]ubtask PR|one-PR-per-[Ss]ubtask|one [Ss]ubtask,? one PR|stacked PR per [Ss]ubtask'
if hits=$(grep_docs "$per_subtask_pr"); then
  violation L17 "retired PR-per-Subtask framing (v3 is PR-per-Story): $(tr '\n' ' ' <<<"$hits")"
  l17_bad=1
fi
# SKILL.md must carry the PR-per-Story wording and the Story-branch shape.
grep -q 'PR-per-Story' "$ROOT/SKILL.md" || { violation L17 "SKILL.md does not carry the PR-per-Story contract wording"; l17_bad=1; }
grep -q 'autopilot/<slug>/<story-id>' "$ROOT/references/drain-lifecycle.md" || { violation L17 "drain-lifecycle.md does not name the Story branch autopilot/<slug>/<story-id>"; l17_bad=1; }
(( l17_bad == 0 )) && ok L17

# --- L18: AP-3 projection allow-list tracks the AV3 planner schema (AV3-02/07) -
# The reviewer projection (AP-3) is what plan review judges from; a planner-schema
# field the projection omits is invisible to the reviewer. Pin the AV3 additions —
# behavior_ids (AV3-02) and predicted_hours (AV3-07) — in BOTH the planner schema
# and the projection allow-list so they cannot drift apart.
l18_bad=0
l18_proj="$ROOT/references/plan-reviewer-projection.md"
l18_plan="$ROOT/references/planner-prompt.md"
for field in behavior_ids predicted_hours; do
  grep -q "${field}:" "$l18_proj" || { violation L18 "AP-3 allow-list missing '${field}:' (plan review can't see it)"; l18_bad=1; }
  grep -q "${field}:" "$l18_plan" || { violation L18 "planner schema missing '${field}:'"; l18_bad=1; }
done
(( l18_bad == 0 )) && ok L18

# --- L19: Runbook PR is the bookkeeping home; file-surface block format (AV3-08) --
# The rolling tracker PR is retired: bookkeeping lands on the Runbook PR
# (autopilot/<slug>/runbook) under both no_force_push settings, and G7 emits a
# grep-able predicted-file-surface block delimited by literal marker comments.
l19_bad=0
# (a) the file-surface block markers are pinned where they are emitted/documented.
grep -q 'autopilot:file-surface:begin' "$ROOT/references/runbook-template.md" || { violation L19 "runbook-template.md missing the file-surface block markers"; l19_bad=1; }
grep -q 'autopilot:file-surface:begin' "$ROOT/references/generate-lifecycle.md" || { violation L19 "generate-lifecycle.md G7 missing the file-surface block markers"; l19_bad=1; }
# (b) the Runbook PR branch is named as the bookkeeping home.
grep -q 'autopilot/<slug>/runbook' "$ROOT/references/drain-lifecycle.md" || { violation L19 "drain-lifecycle.md does not name the Runbook PR branch autopilot/<slug>/runbook"; l19_bad=1; }
# (c) no doc reasserts the retired rolling-tracker-PR framing as active — any
#     surviving mention must be flagged 'retired' on the same line.
if hits=$(grep -nE 'rolling tracker PR' "${DOCS[@]}" 2>/dev/null | grep -vi 'retired'); then
  violation L19 "active 'rolling tracker PR' framing (retired by AV3-08): $(tr '\n' ' ' <<<"$hits")"
  l19_bad=1
fi
(( l19_bad == 0 )) && ok L19

# --- L20: Behavior coverage PR-body section format (MS §13.9 / AV3-05) ---------
# D7.3 publishes the D6.3-verified Behavior-ID -> test-node-ID mapping in a
# grep-able, marker-delimited `## Behavior coverage` block the PR Gate parses
# (MS §13.11). Pin the heading + marker so the format cannot silently drift.
l20_bad=0
dlc="$ROOT/references/drain-lifecycle.md"
grep -q '## Behavior coverage' "$dlc" || { violation L20 "drain-lifecycle.md does not define the '## Behavior coverage' PR-body section"; l20_bad=1; }
grep -q 'autopilot:behavior-coverage' "$dlc" || { violation L20 "the Behavior coverage block is missing its grep-able marker (autopilot:behavior-coverage)"; l20_bad=1; }
(( l20_bad == 0 )) && ok L20

# --- L21: implementer anti-flakiness contract + design-validator routing (AV3-11) --
# The five anti-flakiness rules live in the implementer prompt; the design
# validator routes violations (test quality is design's remit). Pin both so a
# rule can't be dropped from the prompt or silently un-routed.
l21_bad=0
l21_imp="$ROOT/references/implementer-prompt.md"
l21_val="$ROOT/references/validator-prompts.md"
for phrase in 'ANTI-FLAKINESS' 'sleeps for synchronization' 'Seeded randomness' 'Injected clock' 'Faked transport' 'Order-independent'; do
  grep -qF "$phrase" "$l21_imp" || { violation L21 "implementer-prompt.md missing anti-flakiness rule: $phrase"; l21_bad=1; }
done
grep -qF 'Anti-flakiness contract' "$l21_val" || { violation L21 "design validator does not route the anti-flakiness contract"; l21_bad=1; }
(( l21_bad == 0 )) && ok L21

if (( FAIL == 1 )); then
  echo "lint_consistency: FAIL" >&2
  exit 1
fi
echo "lint_consistency: PASS (21 rules)"
exit 0
