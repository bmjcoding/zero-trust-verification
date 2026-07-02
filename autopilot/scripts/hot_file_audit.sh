#!/usr/bin/env bash
# hot_file_audit.sh
#
# Surfaces files that have been touched by multiple subtasks during this
# runbook's execution. The planner calls this at D2 (plan) to detect
# ownership conflicts before emitting the plan, and the dispatcher calls
# it at D7.0 (rebase) to flag files that are likely conflict hotspots.
#
# Mechanism: read the tracker's commit history for the runbook branches
# (everything under refs/heads/autopilot/<slug>/*) and count distinct
# subtask IDs that touched each file.
#
# Output: TSV "<count>\t<path>" sorted descending by count, files with
# count >= 2 only.
#
# Usage: hot_file_audit.sh <slug> [--threshold N]
# Default threshold is 2.

set -euo pipefail

SLUG="${1:?usage: hot_file_audit.sh <slug> [--threshold N]}"
shift
THRESHOLD=2
while (( $# > 0 )); do
  case "$1" in
    --threshold) THRESHOLD="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "not a git repo" >&2
  exit 65
fi

# List branches matching autopilot/<slug>/<subtask-id>.
BRANCHES=$(git for-each-ref --format='%(refname:short)' "refs/heads/autopilot/${SLUG}/*" \
  | grep -v -E "/(setup|tracker)$" || true)

if [[ -z "$BRANCHES" ]]; then
  exit 0
fi

# For each subtask branch, list files it touches relative to its merge-base
# with the runbook's setup branch (or main if setup doesn't exist).
BASE_REF="autopilot/${SLUG}/setup"
if ! git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
  BASE_REF=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo main)
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

while IFS= read -r BRANCH; do
  [[ -z "$BRANCH" ]] && continue
  SUBTASK_ID="${BRANCH##*/}"
  MB=$(git merge-base "$BASE_REF" "$BRANCH" 2>/dev/null || continue)
  git diff --name-only "$MB" "$BRANCH" 2>/dev/null \
    | awk -v sid="$SUBTASK_ID" '{print sid "\t" $0}' >> "$TMP"
done <<< "$BRANCHES"

# Group: count distinct subtask IDs per file.
awk -F'\t' '{ key=$2; if (!(key SUBSEP $1 in seen)) { seen[key SUBSEP $1]=1; count[key]++ } } END { for (k in count) print count[k] "\t" k }' "$TMP" \
  | awk -v t="$THRESHOLD" -F'\t' '$1 >= t' \
  | sort -rn -k1,1
