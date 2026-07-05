#!/usr/bin/env bash
# audit_commit_shape.sh
#
# DRAIN Step D6.2 — the AP-1 TDD commit-shape audit, extracted as a script so
# the range arithmetic is deterministically testable (AV3-06).
#
# PR-per-Story (ADR 0007 / AV3-06) makes the Story branch `autopilot/<slug>/<story-id>`
# accumulate the WHOLE Story's Subtask commit series. D6.2 must audit ONLY the
# Subtask that just landed — so the range is `in_progress.prev_pushed_sha..HEAD`,
# NOT `origin/<base>..HEAD`. Auditing the whole-branch range would see the prior
# Subtasks' commits and false-flag `tdd-scope-leak`. This script takes the base
# ref explicitly (the caller passes prev_pushed_sha, or origin/<trunk> for the
# first Subtask on the branch) and audits `<base>..HEAD`.
#
# Usage:
#   audit_commit_shape.sh --id <subtask-id> --base <base-ref>
#                         [--kind code|test-only|refactor|docs|config]
#                         [--jira-key <KEY>]
#
# Output: `OK` + exit 0 when the shape is valid; otherwise the FIRST violation as
# a `[BLOCKED: <reason>]` line on stdout + exit 1. Usage error → exit 64.
# Reasons (D6.2 catalog): tdd-no-red · tdd-no-green · tdd-out-of-order ·
# tdd-scope-leak · refactor-shape-wrong · docs-shape-wrong · jira-key-missing.
#
# Portability: bash 3.2 (macOS default) + BSD userland safe. No associative
# arrays, no `grep -P`, no GNU-only sed.

set -u

ID=""
BASE=""
KIND="code"
JIRA=""

usage() {
  echo "usage: audit_commit_shape.sh --id <subtask-id> --base <base-ref> [--kind <k>] [--jira-key <KEY>]" >&2
  exit 64
}

while (( $# )); do
  case "$1" in
    --id)       ID="${2:-}"; shift 2 || usage ;;
    --base)     BASE="${2:-}"; shift 2 || usage ;;
    --kind)     KIND="${2:-}"; shift 2 || usage ;;
    --jira-key) JIRA="${2:-}"; shift 2 || usage ;;
    *) usage ;;
  esac
done

[[ -n "$ID" && -n "$BASE" ]] || usage
case "$KIND" in code|test-only|refactor|docs|config) ;; *) usage ;; esac

# Resolve the range end (HEAD) and start (BASE). Both must be real refs/SHAs.
git rev-parse --verify -q HEAD >/dev/null 2>&1 || { echo "audit_commit_shape: no HEAD" >&2; exit 64; }
git rev-parse --verify -q "$BASE^{commit}" >/dev/null 2>&1 || { echo "audit_commit_shape: base ref not found: $BASE" >&2; exit 64; }

block() { echo "[BLOCKED: $1] $2"; exit 1; }

# Regex-escape the subtask id (only `.` is a metachar in the ids we allow).
IDQ="$(printf '%s' "$ID" | sed 's/\./\\./g')"

# Optional `[JIRA-KEY]` group that D4 injects between the id and the RED/GREEN
# marker under enforce_jira_key. `(\[[^]]+\] )?` — zero-or-one bracketed token.
JGRP='(\[[^]]+\] )?'

RED_RE="^test: ${IDQ}\.([0-9]+) ${JGRP}RED( |$|—)"
GREEN_RE="^feat: ${IDQ}\.([0-9]+) ${JGRP}GREEN( |$|—)"
REFACTOR_RE="^refactor: ${IDQ}( |\.|$|—)"
DOCS_RE="^docs: ${IDQ}( |$|—)"
CONFIG_RE="^chore: ${IDQ}( |$|—)"

# Collect the range's subjects oldest-first. `--no-merges` keeps a stray merge
# commit (a rebased Story branch shouldn't have one, but be defensive) from
# reading as scope leak.
SUBJECTS="$(git log --reverse --no-merges --pretty=format:'%s' "${BASE}..HEAD" 2>/dev/null)"

# `kind: refactor` — exactly one refactor commit for this id, no test/feat.
# jira-key presence (only when enforced): EVERY in-range commit must carry
# [<JIRA-KEY>], regardless of kind (AP-22 covers TDD-cycle, final, refactor, docs,
# config, and bookkeeping commits). Checked once here so no kind branch can bypass it.
if [[ -n "$JIRA" ]]; then
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    case "$s" in *"[$JIRA]"*) : ;; *) block jira-key-missing "commit missing [$JIRA]: $s" ;; esac
  done <<EOF
$SUBJECTS
EOF
fi

if [[ "$KIND" == "refactor" ]]; then
  n_ref=0; n_other=0
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    if [[ "$s" =~ $REFACTOR_RE ]]; then n_ref=$((n_ref+1)); else n_other=$((n_other+1)); fi
  done <<EOF
$SUBJECTS
EOF
  { [[ "$n_ref" == "1" && "$n_other" == "0" ]]; } || block refactor-shape-wrong "expected exactly one 'refactor: ${ID}' commit and no test/feat commits (saw ref=${n_ref} other=${n_other})"
  echo OK; exit 0
fi

# `kind: docs | config` — exactly one commit of the matching type.
if [[ "$KIND" == "docs" || "$KIND" == "config" ]]; then
  want_re="$DOCS_RE"; want_label="docs: ${ID}"
  [[ "$KIND" == "config" ]] && { want_re="$CONFIG_RE"; want_label="chore: ${ID}"; }
  n_ok=0; n_other=0
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    if [[ "$s" =~ $want_re ]]; then n_ok=$((n_ok+1)); else n_other=$((n_other+1)); fi
  done <<EOF
$SUBJECTS
EOF
  { [[ "$n_ok" == "1" && "$n_other" == "0" ]]; } || block docs-shape-wrong "expected exactly one '${want_label}' commit (saw ok=${n_ok} other=${n_other})"
  echo OK; exit 0
fi

# kind: code | test-only — full TDD vertical-slice audit over the range.
# reds / greens hold the space-separated behavior numbers seen so far, in order.
reds=""
greens=""
refactor_started=0

# helper: is <n> already present in the space-list <list>?
contains() {  # <n> <list>
  case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

while IFS= read -r s; do
  [[ -z "$s" ]] && continue

  if [[ "$s" =~ $RED_RE ]]; then
    n="${BASH_REMATCH[1]}"
    (( refactor_started )) && block tdd-out-of-order "RED for behavior ${n} after a refactor commit: $s"
    contains "$n" "$reds" && block tdd-out-of-order "duplicate RED for behavior ${n}: $s"
    reds="$reds $n"
    continue
  fi

  if [[ "$s" =~ $GREEN_RE ]]; then
    n="${BASH_REMATCH[1]}"
    (( refactor_started )) && block tdd-out-of-order "GREEN for behavior ${n} after a refactor commit: $s"
    contains "$n" "$reds" || block tdd-out-of-order "GREEN precedes RED for behavior ${n}: $s"
    contains "$n" "$greens" && block tdd-out-of-order "duplicate GREEN for behavior ${n}: $s"
    greens="$greens $n"
    continue
  fi

  if [[ "$s" =~ $REFACTOR_RE ]]; then
    refactor_started=1
    continue
  fi

  # Anything else in range is a foreign commit: a foreign Subtask's commit (the
  # symptom the D6.2 range fix prevents) or a foreign type (chore/fix/docs mixed
  # into a code Subtask).
  block tdd-scope-leak "foreign commit in ${ID}'s audit range: $s"
done <<EOF
$SUBJECTS
EOF

# Every RED must have its GREEN and vice-versa.
for n in $reds; do
  contains "$n" "$greens" || block tdd-no-green "behavior ${n} has RED but no GREEN"
done
for n in $greens; do
  contains "$n" "$reds" || block tdd-no-red "behavior ${n} has GREEN but no RED"
done

# A code Subtask that produced no cycles at all is a no-op, not a valid slice.
if [[ -z "$reds$greens" ]]; then
  block tdd-no-red "no TDD cycles for ${ID} in range ${BASE}..HEAD"
fi

echo OK
exit 0
