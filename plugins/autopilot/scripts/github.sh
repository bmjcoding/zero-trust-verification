#!/usr/bin/env bash
# github.sh
#
# GitHub backend for the host adapter (host.sh). Implements the SAME PR/build
# subcommand contract as bitbucket.sh (the Bitbucket DC backend), so callers
# never branch on host — see ADR 0013 (host-agnostic autopilot) and
# references/loop-safety.md. Selected by host.sh when `origin` is a GitHub
# remote; run it directly only for backend-scoped testing.
#
# Subcommands. The T01-class matrix (pr-state vocabulary, pr-open, pr-comment,
# pr-merge exit, pr-approve/decline, build-status, draft round-trip) is
# byte-identical with bitbucket.sh; pr-merge-strategies reports host-native
# capability in the shared operator vocabulary (see its note below).
#   pr-open           --title <t> --src <branch> --dest <branch> [--body-file <path>] [--draft]
#                       -> prints PR number on stdout
#   pr-ready          --num <N>
#                       -> flips a draft PR to ready-for-review; exits 0
#   pr-state          (--num <N> | --branch <src-branch>)
#                       -> prints one of: OPEN, DRAFT, MERGED, DECLINED, NONE (--branch only)
#   pr-comment        --num <N> --body-file <path>
#                       -> exits 0 on success
#   pr-approve        --num <N>
#                       -> approves the PR (gh pr review --approve)
#   pr-decline        --num <N>
#                       -> closes the PR without merging (state -> DECLINED)
#   pr-merge          --num <N> [--strategy merge-commit|squash|ff-only|no-ff|rebase|semi-linear]
#                       -> defaults to merge-commit (AP-10); maps operator intent
#                          onto gh's three native strategies (merge|squash|rebase)
#   pr-merge-strategies
#                       -> prints repo-permitted OPERATOR strategy tokens (one
#                          per line; each consumable by pr-merge --strategy). The
#                          set reflects host capability (not byte-identical across
#                          backends); the tokens are the shared vocabulary.
#   build-status      --sha <sha>
#                       -> prints aggregated state: SUCCESSFUL | FAILED | INPROGRESS | UNKNOWN
#                          (aggregates BOTH the commit-status API and check-runs)
#   pr-list-ready     [--base <trunk>]
#                       -> enumerate the merge queue as TSV, one ready PR per line:
#                            <ready_ts>\t<pr_num>\t<src_branch>\t<head_sha>\t<approval>
#                          ready_ts is INTEGER EPOCH SECONDS of the ready-for-review
#                          transition (most-recent ReadyForReviewEvent, else the PR's
#                          createdAt for PRs opened non-draft). approval is APPROVED
#                          (reviewDecision == APPROVED) | PENDING. Selection: OPEN,
#                          non-draft PRs targeting the trunk; drafts/merged/closed
#                          omitted. Empty queue -> no output, exit 0. Order is
#                          unspecified (the Marshal sorts). Trunk resolution:
#                          --base > $AUTOPILOT_TRUNK > the repo's default branch.
#                          (The Merge Marshal's queue primitive — see
#                           plugins/marshal/reference/host-contract.md.)
#
# Repo coords (OWNER/REPO) are derived from `git remote get-url origin`.
# Expected origin shapes: https://github.com/<owner>/<repo>(.git)
#                         git@github.com:<owner>/<repo>(.git)
#
# Auth / secrets (per-backend property behind the host surface — ADR 0013,
# Hard Contract 12): the `gh` CLI owns credential resolution (GH_TOKEN /
# GITHUB_TOKEN in the environment, or a prior `gh auth login`). This backend
# never reads, echoes, or places a token on argv — the token never enters
# Claude's context. `gh` is REQUIRED for the GitHub backend (it is NOT a
# dependency of the Bitbucket DC backend; each backend owns its own deps).
#
# State mapping to the shared contract vocabulary:
#   gh state OPEN + isDraft=true  -> DRAFT   (draft is a first-class GitHub PR flag)
#   gh state OPEN + isDraft=false -> OPEN
#   gh state MERGED               -> MERGED
#   gh state CLOSED               -> DECLINED (closed-not-merged == Bitbucket DECLINED)
#
# Portability: written for bash 3.2 (the macOS default) and BSD userland —
# empty arrays are expanded through the ${arr[@]+"${arr[@]}"} guard (a bare
# "${empty[@]}" is an unbound-variable error under `set -u` on bash 3.2).

set -u
set +x

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<EOF
usage: github.sh <subcommand> [args]
subcommands: pr-open pr-ready pr-state pr-comment pr-approve pr-decline pr-merge pr-merge-strategies build-status pr-list-ready
EOF
  exit 64
}

# Emit LAST_STATE=<value> on stderr then die rc=1 — identical failure-
# classification contract to bitbucket.sh (callers grep LAST_STATE=).
die_state() {
  local state="$1"; shift
  echo "LAST_STATE=${state}" >&2
  echo "github.sh: $*" >&2
  exit 1
}
die() { die_state "generic-failure" "$*"; }

require_gh() {
  command -v gh >/dev/null 2>&1 || die_state "missing-dep" "gh CLI is required for the GitHub backend"
}
require_jq() {
  command -v jq >/dev/null 2>&1 || die_state "missing-dep" "jq is required"
}

# --- Repo coords --------------------------------------------------------------

ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
[[ -n "$ORIGIN_URL" ]] || die_state "no-origin" "no origin remote configured"
# Strip a trailing slash so `https://github.com/owner/repo/` parses (host.sh's
# `*github.com/*` heuristic routes it here, so the backend must accept it).
ORIGIN_URL="${ORIGIN_URL%/}"

if [[ "$ORIGIN_URL" =~ github\.com[:/]([^/]+)/([^/]+)$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]%.git}"
else
  die_state "origin-parse" "cannot parse GitHub owner/repo from origin URL: $ORIGIN_URL"
fi
REPO_NWO="${OWNER}/${REPO}"

# Every gh invocation is pinned to --repo so the backend is independent of the
# process CWD (host.sh may run from anywhere). Assembled once as an array.
GH_REPO=(--repo "$REPO_NWO")

# Map a GitHub PR (state,isDraft) to the shared contract vocabulary.
map_state() {  # <gh-state> <isDraft: true|false>
  local st="$1" draft="$2"
  case "$st" in
    OPEN)   [[ "$draft" == "true" ]] && echo "DRAFT" || echo "OPEN" ;;
    MERGED) echo "MERGED" ;;
    CLOSED) echo "DECLINED" ;;
    *)      echo "UNKNOWN" ;;
  esac
}

# --- Subcommands --------------------------------------------------------------

cmd_pr_open() {
  require_gh
  local title="" src="" dest="" body_file="" draft=0
  while (( $# > 0 )); do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --src) src="$2"; shift 2 ;;
      --dest) dest="$2"; shift 2 ;;
      --body-file) body_file="$2"; shift 2 ;;
      --draft) draft=1; shift ;;
      *) die_state "arg-parse" "pr-open: unknown arg $1" ;;
    esac
  done
  [[ -n "$title" && -n "$src" && -n "$dest" ]] || die_state "arg-parse" "pr-open: --title --src --dest required"

  local -a args=(pr create "${GH_REPO[@]}" --title "$title" --base "$dest" --head "$src")
  if [[ -n "$body_file" ]]; then
    [[ -f "$body_file" ]] || die_state "arg-parse" "pr-open: body-file not found: $body_file"
    args+=(--body-file "$body_file")
  else
    args+=(--body "")
  fi
  (( draft == 1 )) && args+=(--draft)

  local url rc=0
  url="$(gh "${args[@]}" 2>/dev/null)" || rc=$?
  if (( rc != 0 )); then
    die_state "pr-open-failed" "gh pr create failed (rc=$rc)"
  fi
  # gh prints the PR URL (…/pull/<N>) as its final stdout line.
  local num
  num="$(printf '%s\n' "$url" | sed -n 's#.*/pull/\([0-9][0-9]*\).*#\1#p' | tail -1)"
  [[ -n "$num" ]] || die_state "pr-open-no-id" "no PR number in gh output: $url"
  echo "$num"
}

cmd_pr_ready() {
  require_gh
  local num=""
  while (( $# > 0 )); do
    case "$1" in
      --num) num="$2"; shift 2 ;;
      *) die_state "arg-parse" "pr-ready: unknown arg $1" ;;
    esac
  done
  [[ -n "$num" ]] || die_state "arg-parse" "pr-ready: --num required"
  gh pr ready "$num" "${GH_REPO[@]}" >/dev/null 2>&1 || die_state "pr-ready-failed" "gh pr ready $num failed"
}

cmd_pr_state() {
  require_gh; require_jq
  local num="" branch=""
  while (( $# > 0 )); do
    case "$1" in
      --num) num="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      *) die_state "arg-parse" "pr-state: unknown arg $1" ;;
    esac
  done
  [[ -n "$num" || -n "$branch" ]] || die_state "arg-parse" "pr-state: --num or --branch required"

  local json rc=0
  if [[ -n "$num" ]]; then
    json="$(gh pr view "$num" "${GH_REPO[@]}" --json state,isDraft 2>/dev/null)" || rc=$?
    (( rc == 0 )) || die_state "pr-state-failed" "gh pr view $num failed"
    local st draft
    st="$(jq -r '.state // "UNKNOWN"' <<<"$json")"
    draft="$(jq -r '.isDraft // false' <<<"$json")"
    map_state "$st" "$draft"
  else
    # Most-recent PR whose head ref is <branch>; NONE when absent. Mirrors
    # bitbucket.sh pr-state --branch (used by tracker-PR availability checks).
    json="$(gh pr list "${GH_REPO[@]}" --head "$branch" --state all --json state,isDraft --limit 1 2>/dev/null)" || rc=$?
    (( rc == 0 )) || die_state "pr-state-failed" "gh pr list --head $branch failed"
    if [[ "$(jq -r 'length' <<<"$json")" == "0" ]]; then
      echo "NONE"
    else
      local st draft
      st="$(jq -r '.[0].state // "UNKNOWN"' <<<"$json")"
      draft="$(jq -r '.[0].isDraft // false' <<<"$json")"
      map_state "$st" "$draft"
    fi
  fi
}

cmd_pr_comment() {
  require_gh
  local num="" body_file=""
  while (( $# > 0 )); do
    case "$1" in
      --num) num="$2"; shift 2 ;;
      --body-file) body_file="$2"; shift 2 ;;
      *) die_state "arg-parse" "pr-comment: unknown arg $1" ;;
    esac
  done
  [[ -n "$num" && -n "$body_file" ]] || die_state "arg-parse" "pr-comment: --num --body-file required"
  [[ -f "$body_file" ]] || die_state "arg-parse" "pr-comment: body-file not found"
  gh pr comment "$num" "${GH_REPO[@]}" --body-file "$body_file" >/dev/null 2>&1 \
    || die_state "pr-comment-failed" "gh pr comment $num failed"
}

cmd_pr_approve() {
  require_gh
  local num=""
  while (( $# > 0 )); do
    case "$1" in
      --num) num="$2"; shift 2 ;;
      *) die_state "arg-parse" "pr-approve: unknown arg $1" ;;
    esac
  done
  [[ -n "$num" ]] || die_state "arg-parse" "pr-approve: --num required"
  gh pr review "$num" "${GH_REPO[@]}" --approve >/dev/null 2>&1 \
    || die_state "pr-approve-failed" "gh pr review --approve $num failed"
}

cmd_pr_decline() {
  require_gh
  local num=""
  while (( $# > 0 )); do
    case "$1" in
      --num) num="$2"; shift 2 ;;
      *) die_state "arg-parse" "pr-decline: unknown arg $1" ;;
    esac
  done
  [[ -n "$num" ]] || die_state "arg-parse" "pr-decline: --num required"
  gh pr close "$num" "${GH_REPO[@]}" >/dev/null 2>&1 \
    || die_state "pr-decline-failed" "gh pr close $num failed"
}

# Map operator intent onto GitHub's three native merge methods. GitHub has no
# separate no-ff / ff-only / semi-linear knobs; the closest faithful mapping:
#   merge-commit, no-ff        -> --merge   (preserves TDD cycle history, AP-10 default)
#   squash                     -> --squash
#   rebase, ff-only, semi-linear -> --rebase (linear history)
gh_merge_flag() {  # <operator-strategy> -> echoes the gh flag
  case "$1" in
    merge-commit|no-ff)          echo "--merge" ;;
    squash)                      echo "--squash" ;;
    rebase|ff-only|semi-linear)  echo "--rebase" ;;
    *) return 1 ;;
  esac
}

cmd_pr_merge() {
  require_gh
  local num="" strategy="merge-commit"
  while (( $# > 0 )); do
    case "$1" in
      --num) num="$2"; shift 2 ;;
      --strategy) strategy="$2"; shift 2 ;;
      *) die_state "arg-parse" "pr-merge: unknown arg $1" ;;
    esac
  done
  [[ -n "$num" ]] || die_state "arg-parse" "pr-merge: --num required"
  local flag
  flag="$(gh_merge_flag "$strategy")" || die_state "arg-parse" "pr-merge: unknown strategy: $strategy"
  gh pr merge "$num" "${GH_REPO[@]}" "$flag" >/dev/null 2>&1 \
    || die_state "pr-merge-failed" "gh pr merge $num $flag failed"
}

cmd_pr_merge_strategies() {
  require_gh; require_jq
  # Discover which methods the repo permits; print the operator-facing tokens
  # pr-merge accepts. Falls back to the AP-10 default on any discovery failure.
  local json rc=0
  json="$(gh api "repos/${REPO_NWO}" 2>/dev/null)" || rc=$?
  if (( rc != 0 )) || [[ -z "$json" ]]; then
    echo "merge-commit"
    return 0
  fi
  local out
  out="$(jq -r '
    [ (if .allow_merge_commit then "merge-commit" else empty end),
      (if .allow_squash_merge then "squash" else empty end),
      (if .allow_rebase_merge then "rebase" else empty end) ]
    | if length == 0 then ["merge-commit"] else . end
    | .[]' <<<"$json" 2>/dev/null)" || out=""
  [[ -n "$out" ]] || out="merge-commit"
  printf '%s\n' "$out"
}

cmd_build_status() {
  require_gh; require_jq
  local sha=""
  while (( $# > 0 )); do
    case "$1" in
      --sha) sha="$2"; shift 2 ;;
      *) die_state "arg-parse" "build-status: unknown arg $1" ;;
    esac
  done
  [[ -n "$sha" ]] || die_state "arg-parse" "build-status: --sha required"

  # GitHub exposes CI health through TWO independent surfaces: the legacy
  # commit-status API and the check-runs (GitHub Actions / Apps) API. Aggregate
  # BOTH into the shared 4-value vocabulary so neither a statuses-only repo nor
  # an Actions-only repo silently reports UNKNOWN.
  local status_json checks_json
  status_json="$(gh api "repos/${REPO_NWO}/commits/${sha}/status" 2>/dev/null)" || status_json=""
  checks_json="$(gh api "repos/${REPO_NWO}/commits/${sha}/check-runs" 2>/dev/null)" || checks_json=""
  [[ -n "$status_json" ]] || status_json='{}'
  [[ -n "$checks_json" ]] || checks_json='{}'

  # Aggregation rules:
  #  - Statuses: use the AUTHORITATIVE server-computed combined `.state` (it is
  #    page-independent), gated on `.total_count` so "no statuses" != "pending".
  #  - Check-runs: classify the returned page; both APIs paginate at 30 items, so
  #    if `.total_count` exceeds what we can see, add a RUN signal — FAIL-SAFE:
  #    never claim all-green from a partial view (a page-2 failure would then
  #    read INPROGRESS, keeping ci_check polling, never a false GREEN).
  #  - Unknown/`stale` conclusions are dropped (neutral), not poisoned to UNKNOWN.
  jq -rn --argjson s "$status_json" --argjson c "$checks_json" '
    ( (($s.total_count // (($s.statuses // []) | length)) // 0) as $sc
      | if $sc == 0 then []
        elif $s.state == "success" then ["OK"]
        elif ($s.state == "failure" or $s.state == "error") then ["BAD"]
        else ["RUN"] end ) as $sts
    | ( ($c.check_runs // []) | map(
        if .status != "completed" then "RUN"
        elif (.conclusion == "success" or .conclusion == "neutral" or .conclusion == "skipped") then "OK"
        elif (.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out"
              or .conclusion == "action_required" or .conclusion == "startup_failure") then "BAD"
        else "SKIP" end) ) as $chk
    | ( if (($c.total_count // 0) > (($c.check_runs // []) | length)) then ["RUN"] else [] end ) as $more
    | ( ($sts + $chk + $more) | map(select(. != "SKIP")) ) as $all
    | if ($all | length) == 0 then "UNKNOWN"
      elif ($all | any(. == "BAD")) then "FAILED"
      elif ($all | any(. == "RUN")) then "INPROGRESS"
      elif ($all | all(. == "OK")) then "SUCCESSFUL"
      else "UNKNOWN" end
  ' 2>/dev/null || { echo "UNKNOWN"; return 0; }
}

# resolve_trunk: the base branch the merge queue targets. Precedence:
#   1. --base <b> (explicit)  2. $AUTOPILOT_TRUNK  3. the repo's default branch
#   4. "main" (last-resort). Symmetric with bitbucket.sh so the adapter is
#   host-agnostic: the caller (the Marshal) never has to pass the trunk, but MAY
#   ($AUTOPILOT_TRUNK / --base) when the merge trunk is not the default branch.
resolve_trunk() {  # <explicit-base-or-empty> -> echoes the trunk branch name
  local explicit="$1"
  if [[ -n "$explicit" ]]; then printf '%s' "$explicit"; return 0; fi
  if [[ -n "${AUTOPILOT_TRUNK:-}" ]]; then printf '%s' "$AUTOPILOT_TRUNK"; return 0; fi
  # Repo default branch. Mirror cmd_pr_merge_strategies: fetch the repo object,
  # then filter with jq separately (no reliance on `gh api --jq`).
  local json db
  json="$(gh api "repos/${REPO_NWO}" 2>/dev/null || true)"
  db="$(jq -r '.default_branch // empty' <<<"$json" 2>/dev/null || true)"
  [[ -n "$db" ]] || db="main"
  printf '%s' "$db"
}

# iso_to_epoch: ISO-8601 Zulu (2026-07-05T17:15:00Z) -> integer epoch SECONDS.
# Done in jq (strptime+mktime are UTC) so there is NO BSD-vs-GNU `date` variance —
# the FIFO key must be a stable integer across macOS and Linux.
iso_to_epoch() {  # <iso8601-or-empty> -> epoch seconds (0 on empty/parse-miss)
  local iso="$1"
  [[ -n "$iso" && "$iso" != "null" ]] || { printf '0'; return 0; }
  # Tolerate fractional seconds (…SS.mmmZ): gh emits whole-second Zulu today, but a
  # fractional (or otherwise-degraded) timestamp must NOT be a hard failure — strip
  # a `.NNN` fraction before strptime, and fall back to 0 on any parse miss. This is
  # per-row (see cmd_pr_list_ready), so a single bad timestamp degrades one row, it
  # does not abort the whole enumeration.
  jq -rn --arg t "$iso" '($t | sub("\\.[0-9]+Z$";"Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)' 2>/dev/null || printf '0'
}

# gh_ready_for_review_iso: createdAt of the PR's most-recent ReadyForReviewEvent
# (the draft->ready transition — the contract's FIFO key). Empty for a PR opened
# non-draft (no such event) or on any GraphQL failure; the caller then falls back
# to the PR's createdAt. timelineItems is GraphQL-only (not exposed by `gh pr
# list --json`), so this is a per-PR query; a merge queue is small.
gh_ready_for_review_iso() {  # <pr_num> -> ISO-8601 or ""
  local num="$1" q gj
  q='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){timelineItems(last:1,itemTypes:[READY_FOR_REVIEW_EVENT]){nodes{__typename ... on ReadyForReviewEvent{createdAt}}}}}}'
  gj="$(gh api graphql -f query="$q" -f o="$OWNER" -f r="$REPO" -F n="$num" 2>/dev/null)" || { printf ''; return 0; }
  jq -r '.data.repository.pullRequest.timelineItems.nodes[-1].createdAt // ""' <<<"$gj" 2>/dev/null || printf ''
}

# pr-list-ready: enumerate the merge queue as the marshal-consumable 5-column TSV
#   <ready_ts>\t<pr_num>\t<src_branch>\t<head_sha>\t<approval>
# See the header block and plugins/marshal/reference/host-contract.md.
cmd_pr_list_ready() {
  require_gh; require_jq
  local base=""
  while (( $# > 0 )); do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      *) die_state "arg-parse" "pr-list-ready: unknown arg $1" ;;
    esac
  done
  local trunk
  trunk="$(resolve_trunk "$base")"

  # OPEN PRs targeting the trunk. Draft exclusion is client-side on isDraft (gh's
  # --draft filters to drafts-ONLY, not the inverse), so it is version-independent.
  local limit=200 list_json rc=0
  list_json="$(gh pr list "${GH_REPO[@]}" --state open --base "$trunk" --limit "$limit" \
      --json number,headRefName,headRefOid,reviewDecision,createdAt,isDraft 2>/dev/null)" || rc=$?
  (( rc == 0 )) || die_state "pr-list-ready-failed" "gh pr list failed (rc=$rc)"
  [[ -n "$list_json" ]] || return 0

  # A full page could mean the queue was truncated — never claim completeness
  # silently (a dropped tail PR would break strict FIFO).
  local n
  n="$(jq 'length' <<<"$list_json" 2>/dev/null || echo 0)"
  (( n >= limit )) && echo "github.sh: pr-list-ready hit the --limit ($limit) page; queue may be truncated" >&2

  # Non-draft rows with a real head sha, as: num \t branch \t sha \t approval \t
  # createdAt(ISO). approval is computed IN jq and a PR with an empty head sha is
  # dropped (it is not a merge candidate) so NO field is ever empty — a bare `read`
  # with IFS=<tab> collapses consecutive tabs (tab is IFS-whitespace), and an empty
  # middle field would silently shift the Marshal's columns. createdAt stays RAW
  # here; the ISO->epoch conversion is per-row in the loop (iso_to_epoch, guarded),
  # so one malformed timestamp degrades that row, it never aborts the enumeration.
  local rows
  rows="$(jq -r '
    .[]
    | select(.isDraft == false)
    | select((.headRefOid // "") != "")
    | [ .number, .headRefName, .headRefOid,
        (if .reviewDecision == "APPROVED" then "APPROVED" else "PENDING" end),
        .createdAt ]
    | @tsv' <<<"$list_json" 2>/dev/null)" || die_state "pr-list-ready-parse" "cannot parse gh pr list output"
  [[ -n "$rows" ]] || return 0

  # Refine the FIFO key with the ReadyForReviewEvent when the PR was readied from
  # draft (else createdAt), convert to epoch (guarded), emit the contract row.
  local num branch sha approval created_iso ready_iso ready_ts
  while IFS="$(printf '\t')" read -r num branch sha approval created_iso; do
    [[ -n "$num" ]] || continue
    ready_iso="$(gh_ready_for_review_iso "$num")"
    [[ -n "$ready_iso" ]] || ready_iso="$created_iso"
    ready_ts="$(iso_to_epoch "$ready_iso")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$ready_ts" "$num" "$branch" "$sha" "$approval"
  done <<<"$rows"
}

# --- Dispatch -----------------------------------------------------------------

(( $# >= 1 )) || usage
SUB="$1"; shift
case "$SUB" in
  pr-open)              cmd_pr_open "$@" ;;
  pr-ready)             cmd_pr_ready "$@" ;;
  pr-state)             cmd_pr_state "$@" ;;
  pr-comment)           cmd_pr_comment "$@" ;;
  pr-approve)           cmd_pr_approve "$@" ;;
  pr-decline)           cmd_pr_decline "$@" ;;
  pr-merge)             cmd_pr_merge "$@" ;;
  pr-merge-strategies)  cmd_pr_merge_strategies "$@" ;;
  build-status)         cmd_build_status "$@" ;;
  pr-list-ready)        cmd_pr_list_ready "$@" ;;
  *) usage ;;
esac
