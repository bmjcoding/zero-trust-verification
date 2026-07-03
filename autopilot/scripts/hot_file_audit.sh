#!/usr/bin/env bash
# hot_file_audit.sh
#
# Two modes (v2.4.0 — GAPS A8; previously only the overlap mode existed, so
# the G4 "30-day churn" contract was unimplemented and the hot-file DAG
# feature could never trigger at GENERATE time):
#
#   --churn [--days N] [--top N]
#       GENERATE Step G4 mode. Surfaces the most-churned files over the
#       trailing window (default: 30 days, top 20) from origin-trunk history.
#       Output: TSV "<commit-count>\t<path>", descending.
#
#   --subtasks <slug> [--threshold N]
#       DRAIN Step D7.0 mode. Surfaces files touched by multiple subtask
#       branches of an in-flight drain (refs/heads/autopilot/<slug>/*,
#       excluding setup/tracker), i.e. likely rebase-conflict hotspots.
#       Output: TSV "<distinct-subtask-count>\t<path>", count >= threshold
#       (default 2), descending.
#
# Usage:
#   hot_file_audit.sh --churn [--days 30] [--top 20]
#   hot_file_audit.sh --subtasks <slug> [--threshold 2]

set -euo pipefail

MODE=""
SLUG=""
DAYS=30
TOP=20
THRESHOLD=2

usage() {
  echo "usage: hot_file_audit.sh --churn [--days N] [--top N] | --subtasks <slug> [--threshold N]" >&2
  exit 64
}

while (( $# > 0 )); do
  case "$1" in
    --churn) MODE="churn"; shift ;;
    --subtasks) MODE="subtasks"; SLUG="${2:?--subtasks requires a slug}"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --top) TOP="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$MODE" ]] || usage

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "not a git repo" >&2
  exit 65
fi

churn_mode() {
  # Prefer origin trunk history so local WIP branches don't skew the counts;
  # fall back to HEAD when origin/HEAD is unset (fresh clone).
  local ref
  ref=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@origin/@' || true)
  [[ -n "$ref" ]] && git rev-parse --verify -q "$ref" >/dev/null 2>&1 || ref="HEAD"
  # awk does the empty-line filter and the top-N cut: under pipefail, a
  # `grep` with no matches (quiet repo, empty churn window) or a `head`
  # that closes the pipe early (SIGPIPE 141 on big repos) would turn a
  # legitimate empty/large result into script exit 1/141.
  git log "$ref" --since="${DAYS}.days" --name-only --pretty=format: 2>/dev/null \
    | awk 'NF' \
    | sort \
    | uniq -c \
    | sort -rn \
    | awk -v top="$TOP" 'NR<=top {count=$1; $1=""; sub(/^ /,""); print count "\t" $0}'
}

subtasks_mode() {
  # List branches matching autopilot/<slug>/<subtask-id>.
  local branches
  branches=$(git for-each-ref --format='%(refname:short)' "refs/heads/autopilot/${SLUG}/*" \
    | grep -v -E "/(setup|tracker)$" || true)

  if [[ -z "$branches" ]]; then
    exit 0
  fi

  # For each subtask branch, list files it touches relative to its merge-base
  # with the runbook's setup branch (or trunk if setup doesn't exist).
  local base_ref
  base_ref="autopilot/${SLUG}/setup"
  if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    base_ref=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo main)
  fi

  # Not `local`: the EXIT trap fires at script scope, where a function-local
  # would be unbound under set -u.
  HFA_TMP=$(mktemp)
  trap 'rm -f "$HFA_TMP"' EXIT

  local branch subtask_id mb
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    subtask_id="${branch##*/}"
    mb=$(git merge-base "$base_ref" "$branch" 2>/dev/null) || continue
    git diff --name-only "$mb" "$branch" 2>/dev/null \
      | awk -v sid="$subtask_id" '{print sid "\t" $0}' >> "$HFA_TMP"
  done <<< "$branches"

  # Group: count distinct subtask IDs per file.
  awk -F'\t' '{ key=$2; if (!(key SUBSEP $1 in seen)) { seen[key SUBSEP $1]=1; count[key]++ } } END { for (k in count) print count[k] "\t" k }' "$HFA_TMP" \
    | awk -v t="$THRESHOLD" -F'\t' '$1 >= t' \
    | sort -rn -k1,1
}

case "$MODE" in
  churn)    churn_mode ;;
  subtasks) subtasks_mode ;;
esac
