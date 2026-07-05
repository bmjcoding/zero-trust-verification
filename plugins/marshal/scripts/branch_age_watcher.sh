#!/usr/bin/env bash
# branch_age_watcher.sh
#
# The staleness / branch-age watcher (ADR 0012, with ADR 0009's decay framing).
# Trunk-based development caps a Story branch at 48 hours wall-clock; a branch
# older than that is a PLANNING FAILURE — exactly how D7.0 treats an oversized
# rebase (ADR 0012). ADR 0009 states the same clock from the claim side: a
# binding claim with no commits in ~2 business days demotes to advisory and the
# watcher comments. Both reduce to one deterministic question: is the branch's
# last activity older than the ceiling? Age is measured from the LAST COMMIT
# (the observable "activity" signal), not from branch creation — a branch that
# is still being pushed to is not stale.
#
# The Marshal runs this on the cron loop (ADR 0010) over in-flight branches and
# comments on / flags the stale ones. Like claim_overlap.sh this is a pure,
# git/API-provable function (ADR 0011): its verdict is a timestamp comparison,
# no agent judgment.
#
# Input, two interchangeable sources (pick one):
#   (stdin, default)  lines "<id>\t<last-commit-epoch>", one branch per line.
#                     Blank / malformed lines are ignored. This is the pure,
#                     fixture-friendly form the caller feeds after deriving
#                     timestamps however it likes.
#   --refs <glob>     Derive the pairs from local git refs matching <glob>
#                     (git for-each-ref pattern, e.g. 'refs/heads/story/*'),
#                     using each ref's last-commit committer date. Requires a
#                     git repo in CWD.
#
# Options:
#   --max-age-hours N (default 48) the trunk-based ceiling.
#   --now <epoch>     override "now" (default: date -u +%s). Makes the verdict
#                     reproducible in tests and lets the caller pin a single
#                     clock across a whole sweep.
#
# Output: "<age-hours>\t<id>" for every branch whose age >= max, sorted by age
# desc then id asc. age-hours is integer-truncated. Empty output = nothing stale
# (a valid answer, not an error).
#
# Exit: 0 on a clean sweep (stale or not). 64 usage. 65 --refs outside a git repo.
#
# Portability: bash 3.2 (macOS default) + BSD userland safe. Integer math only;
# no bc, no GNU date, no associative arrays.

set -u
set +x

export LC_ALL=C

usage() {
  echo "usage: branch_age_watcher.sh [--max-age-hours N] [--now EPOCH] [--refs GLOB]  [< pairs.tsv]" >&2
  echo "  pairs.tsv: lines '<id>\\t<last-commit-epoch>'" >&2
  exit 64
}

MAX_AGE_HOURS=48
NOW=""
REFS_GLOB=""
while (( $# > 0 )); do
  case "$1" in
    --max-age-hours) MAX_AGE_HOURS="${2:-}"; shift 2 || usage ;;
    --now)           NOW="${2:-}"; shift 2 || usage ;;
    --refs)          REFS_GLOB="${2:-}"; shift 2 || usage ;;
    -h|--help)       usage ;;
    *) echo "branch_age_watcher.sh: unknown arg: $1" >&2; usage ;;
  esac
done

case "$MAX_AGE_HOURS" in
  ''|*[!0-9]*) echo "branch_age_watcher.sh: --max-age-hours must be a non-negative integer" >&2; usage ;;
esac
if [[ -n "$NOW" ]]; then
  case "$NOW" in
    ''|*[!0-9]*) echo "branch_age_watcher.sh: --now must be an epoch integer" >&2; usage ;;
  esac
else
  NOW="$(date -u +%s)"
fi

MAX_AGE_SECONDS=$(( MAX_AGE_HOURS * 3600 ))

emit_pairs() {
  if [[ -n "$REFS_GLOB" ]]; then
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "branch_age_watcher.sh: --refs needs a git repo" >&2; exit 65; }
    # %(refname:short) TAB last-commit committer epoch. --sort keeps it stable;
    # the awk below re-sorts by age anyway, so ordering here is not load-bearing.
    git for-each-ref --format='%(refname:short)%09%(committerdate:unix)' "$REFS_GLOB" 2>/dev/null
  else
    cat
  fi
}

emit_pairs \
  | awk -F'\t' -v now="$NOW" -v maxsec="$MAX_AGE_SECONDS" '
      NF >= 2 && $1 != "" && $2 ~ /^[0-9]+$/ {
        age = now - $2
        if (age < 0) age = 0          # a future commit date is not "stale"
        if (age >= maxsec) print int(age / 3600) "\t" $1
      }
    ' \
  | sort -t"$(printf '\t')" -k1,1nr -k2,2
