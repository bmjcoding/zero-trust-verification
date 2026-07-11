#!/usr/bin/env bash
# marshal.sh — the Merge Marshal serial backstop loop (ADR 0010, ADR 0011).
#
# One invocation = one serial pass of the merge queue. Shift-left machinery
# (derived claims ADR 0009, sizing ADR 0012) prevents Textual Conflicts; this
# loop exists for the one thing they cannot prevent — Composition Breaks — by
# building and testing the COMPOSED state (main + this PR, rebased) before it
# merges. It is WIRING, not a checker (ADR 0011): it forms no quality opinion.
# Every decision is a timestamp, a sha, a build state, or a file-surface
# intersection — all git/API-provable, no agent judgment in the merge path.
#
# The pass:
#   1. List ready PRs via the host adapter; keep the APPROVED ones; order them
#      strict FIFO by ready-for-review timestamp (tie-break: PR number). A human
#      hotfix pin (MARSHAL_HOTFIX_PIN) is the ONLY override — it moves one PR to
#      the head and is logged to the Force Audit (ADR 0010).
#   2. For the head PR: rebase onto current trunk, OR refuse per D7.0's
#      file/hunk budget (an oversized/conflicting rebase is a planning failure,
#      not a merge-time problem) and kick back with a comment, then move on.
#   3. Wait for build-status on the POST-REBASE sha — the composed-state
#      verification. Green -> merge (one PR in flight; the pass stops). Red ->
#      comment, evict, next in line. Still building -> leave it for the next fire.
#
# All PR/build ops go through ONE host entrypoint ($MARSHAL_HOST -> host.sh),
# so the loop is host-agnostic (ADR 0013): GitHub, Bitbucket DC, or the mock.
# The host must expose the usual surface PLUS `pr-list-ready` (queue enumeration
# with the ready timestamp + approval state) — see reference/host-contract.md.
# The smallest write scope (ADR 0011): rebase-push and merge, nothing else.
#
# Env:
#   MARSHAL_HOST              path to the host adapter CLI (default: the sibling
#                             plugins/autopilot/scripts/host.sh). Tests point it at the
#                             mock backend.
#   MARSHAL_MAIN              trunk branch name (default: main).
#   MARSHAL_REBASE_FILE_BUDGET  D7.0 file budget (default: 2).
#   MARSHAL_REBASE_HUNK_BUDGET  D7.0 hunk budget (default: 3).
#   MARSHAL_HOTFIX_PIN        PR number to pin to the queue head (Force Audit).
#   MARSHAL_FORCE_AUDIT_LOG   Force Audit path (default: .marshal/force-audit.log).
#   MARSHAL_MERGE_STRATEGY    strategy passed to pr-merge (default: host default).
#   MARSHAL_BUILD_POLL_MAX    build-status poll attempts (default: 30).
#   MARSHAL_BUILD_POLL_INTERVAL  seconds between polls (default: 20; tests use 0).
#   MARSHAL_ACTOR             actor recorded in the Force Audit (default: $USER).
#   MARSHAL_NOW               epoch override for the Force Audit timestamp (tests).
#
# Runs in the working clone (CWD = a git repo whose `origin` is the shared repo).
# Exit 0 on a clean pass (merged, waiting, or nothing to do); non-zero only on an
# operational fault (not a git repo, host adapter missing).
#
# Portability: bash 3.2 (macOS default) + BSD userland safe. No associative
# arrays, no mapfile, no GNU-only date/sed.

set -u
set +x
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Outcome-measurement modes (ADR 0023, report-only). A first-arg dispatch, BEFORE
# any merge-pass setup, so the outcome modes never touch the merge queue and a
# no-arg invocation runs the serial pass exactly as before (backward compatible).
# These modes open no PR, file no finding, gate nothing — they read history and
# the last audit's output and write only the outcome store.
case "${1:-}" in
  outcome-capture) shift; exec bash "$HERE/outcome_capture.sh" "$@" ;;
  outcome-digest)  shift; exec bash "$HERE/outcome_digest.sh"  "$@" ;;
esac

MARSHAL_HOST="${MARSHAL_HOST:-$HERE/../../autopilot/scripts/host.sh}"
TRUNK="${MARSHAL_MAIN:-main}"
FILE_BUDGET="${MARSHAL_REBASE_FILE_BUDGET:-2}"
HUNK_BUDGET="${MARSHAL_REBASE_HUNK_BUDGET:-3}"
PIN="${MARSHAL_HOTFIX_PIN:-}"
FORCE_AUDIT_LOG="${MARSHAL_FORCE_AUDIT_LOG:-.marshal/force-audit.log}"
MERGE_STRATEGY="${MARSHAL_MERGE_STRATEGY:-}"
POLL_MAX="${MARSHAL_BUILD_POLL_MAX:-30}"
POLL_INTERVAL="${MARSHAL_BUILD_POLL_INTERVAL:-20}"
ACTOR="${MARSHAL_ACTOR:-${USER:-unknown}}"

log() { echo "marshal: $*"; }
host() { bash "$MARSHAL_HOST" "$@"; }

now_iso() {
  if [[ -n "${MARSHAL_NOW:-}" ]]; then
    date -u -r "$MARSHAL_NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d "@$MARSHAL_NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || echo "$MARSHAL_NOW"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

git rev-parse --git-dir >/dev/null 2>&1 || { echo "marshal.sh: not a git repo (CWD)" >&2; exit 65; }
[[ -f "$MARSHAL_HOST" ]] || { echo "marshal.sh: host adapter not found: $MARSHAL_HOST" >&2; exit 66; }

WORK="$(mktemp -d)"
WORK_BRANCH="marshal/work"
cleanup() {
  # Leave the working clone on a detached trunk and drop the scratch branch so
  # repeated fires start clean; never touch anything on origin here.
  git checkout -q --detach "origin/$TRUNK" 2>/dev/null || true
  git branch -D "$WORK_BRANCH" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- 1. enumerate + order -----------------------------------------------------

git fetch -q origin 2>/dev/null || true

READY="$WORK/ready.tsv"      # ready_ts \t num \t branch \t head_sha \t approval
host pr-list-ready > "$READY" 2>/dev/null || true

ORDER="$WORK/order.tsv"
: > "$ORDER"

PIN_APPLIED=0
if [[ -n "$PIN" ]]; then
  if awk -F'\t' -v p="$PIN" '$2==p{found=1} END{exit found?0:1}' "$READY"; then
    awk -F'\t' -v p="$PIN" '$2==p' "$READY" >> "$ORDER"
    PIN_APPLIED=1
    log "pin pr=$PIN"
    mkdir -p "$(dirname "$FORCE_AUDIT_LOG")" 2>/dev/null || true
    printf '%s\thotfix-pin\tpr=%s\tactor=%s\tby=marshal\n' "$(now_iso)" "$PIN" "$ACTOR" >> "$FORCE_AUDIT_LOG"
  else
    log "pin pr=$PIN ignored=not-ready"
  fi
fi

# APPROVED, non-empty PR number (drop malformed rows so they don't inflate the
# candidate count / phantom the order log), excluding an already-pinned PR,
# strict FIFO by ready_ts then num.
awk -F'\t' -v p="$PIN" -v pinned="$PIN_APPLIED" \
  '$2!="" && $5=="APPROVED" && !(pinned=="1" && $2==p)' "$READY" \
  | sort -t"$(printf '\t')" -k1,1n -k2,2n >> "$ORDER"

N_ORDER=$(awk 'END{print NR+0}' "$ORDER")
ORDER_NUMS=$(awk -F'\t' '{printf (NR>1?",":"") $2} END{print ""}' "$ORDER")
log "candidates n=$N_ORDER order=${ORDER_NUMS:-none}"

# --- helpers for one candidate ------------------------------------------------

post_comment() {  # <num> <body-text...>
  local num="$1"; shift
  local body_file="$WORK/comment.$num.txt"
  printf '%s\n' "$*" > "$body_file"
  host pr-comment --num "$num" --body-file "$body_file" >/dev/null 2>&1 || true
}

# Prints "<overlap_files> <overlap_hunks>" for the rebase of origin/<branch>.
rebase_cost() {  # <branch>
  local branch="$1" base ofiles ohunks
  base="$(git merge-base "origin/$TRUNK" "origin/$branch" 2>/dev/null)"
  if [[ -z "$base" ]]; then echo "-1 -1"; return; fi
  local bf="$WORK/bf" mf="$WORK/mf"
  git diff --name-only "$base" "origin/$branch" 2>/dev/null | sort -u > "$bf"
  git diff --name-only "$base" "origin/$TRUNK"  2>/dev/null | sort -u > "$mf"
  local overlap="$WORK/overlap"
  comm -12 "$bf" "$mf" > "$overlap"
  ofiles=$(awk 'END{print NR+0}' "$overlap")
  if (( ofiles == 0 )); then echo "0 0"; return; fi
  # Count trunk-side hunks in the overlap files — the surface the branch must
  # reconcile. Read paths line-by-line into an array so a path with spaces is one
  # argument, not word-split (which would under-count the budget surface).
  local -a oflist=()
  while IFS= read -r f; do [[ -n "$f" ]] && oflist+=("$f"); done < "$overlap"
  ohunks=$(git diff "$base" "origin/$TRUNK" -- "${oflist[@]}" 2>/dev/null | grep -c '^@@' || true)
  echo "$ofiles $ohunks"
}

# --- 2 + 3. process the queue head-first --------------------------------------

MERGED_PR="none"
WAITED_PR="none"
EVICTED=0

while IFS="$(printf '\t')" read -r ready_ts num branch head_sha approval; do
  [[ -z "${num:-}" ]] && continue
  log "consider pr=$num branch=$branch ready_ts=$ready_ts approval=$approval"

  # Determine the post-rebase sha (the composed-state head).
  new_sha=""
  if git merge-base --is-ancestor "origin/$TRUNK" "origin/$branch" 2>/dev/null; then
    # Branch already contains trunk — nothing to rebase, no push.
    new_sha="$(git rev-parse "origin/$branch" 2>/dev/null)"
    log "rebase pr=$num result=already-current overlap_files=0 overlap_hunks=0 sha=$new_sha"
  else
    # D7.0 budget gate: refuse an oversized rebase before attempting it.
    set -- $(rebase_cost "$branch")
    ofiles="$1"; ohunks="$2"
    if (( ofiles < 0 )); then
      # No common ancestor with the trunk (unrelated histories): there is no
      # rebase to budget. Refuse explicitly rather than let the sentinel slip
      # past the gate and mis-report as a plain conflict.
      log "rebase pr=$num result=refuse-no-base"
      post_comment "$num" "Merge Marshal: $branch has no common ancestor with $TRUNK (unrelated histories) — there is nothing to rebase onto. Re-create this branch from the current trunk."
      log "kickback pr=$num reason=rebase-no-base"
      EVICTED=$((EVICTED+1))
      continue
    fi
    if (( ofiles > FILE_BUDGET || ohunks > HUNK_BUDGET )); then
      log "rebase pr=$num result=refuse-budget overlap_files=$ofiles overlap_hunks=$ohunks"
      post_comment "$num" "Merge Marshal: rebase onto $TRUNK exceeds the D7.0 budget (overlap ${ofiles} file(s)/${ohunks} hunk(s); budget ${FILE_BUDGET} file(s)/${HUNK_BUDGET} hunk(s)). An oversized rebase is a planning failure — re-plan this Story against the current trunk (ADR 0012), do not blind-rebase."
      log "kickback pr=$num reason=rebase-budget"
      EVICTED=$((EVICTED+1))
      continue
    fi
    # Attempt the rebase on a scratch branch; a conflict is also a refuse.
    git checkout -q -B "$WORK_BRANCH" "origin/$branch" 2>/dev/null
    if git rebase -q "origin/$TRUNK" >/dev/null 2>&1; then
      new_sha="$(git rev-parse HEAD 2>/dev/null)"
      # Smallest write scope: push the rebased head to the PR branch only.
      if git push -q --force-with-lease="refs/heads/$branch:$head_sha" origin "HEAD:refs/heads/$branch" 2>/dev/null \
         || git push -q --force-with-lease origin "HEAD:refs/heads/$branch" 2>/dev/null; then
        git fetch -q origin 2>/dev/null || true
        log "rebase pr=$num result=clean overlap_files=$ofiles overlap_hunks=$ohunks sha=$new_sha"
      else
        log "rebase pr=$num result=push-failed sha=$new_sha"
        post_comment "$num" "Merge Marshal: could not fast-forward-push the rebased branch (the branch moved under the Marshal). Will retry next fire."
        EVICTED=$((EVICTED+1))
        git rebase --abort >/dev/null 2>&1 || true
        continue
      fi
    else
      git rebase --abort >/dev/null 2>&1 || true
      log "rebase pr=$num result=refuse-conflict"
      post_comment "$num" "Merge Marshal: rebase onto $TRUNK conflicts. Ownership claims (ADR 0009) should have prevented this Textual Conflict — re-plan against the current trunk; do not blind-rebase."
      log "kickback pr=$num reason=rebase-conflict"
      EVICTED=$((EVICTED+1))
      continue
    fi
  fi

  if [[ -z "$new_sha" ]]; then
    log "rebase pr=$num result=no-sha"
    EVICTED=$((EVICTED+1))
    continue
  fi

  # Compose-state verification: build-status on the post-rebase sha.
  state="UNKNOWN"
  poll=0
  while :; do
    state="$(host build-status --sha "$new_sha" 2>/dev/null || echo UNKNOWN)"
    # Strip stray whitespace / CR so a backend that emits "SUCCESSFUL\r" or a
    # trailing space still matches — a mis-match would fall through to "wait"
    # forever (fail-safe, but the queue would never drain).
    state="$(printf '%s' "$state" | tr -d '[:space:]')"
    case "$state" in
      SUCCESSFUL|FAILED) break ;;
    esac
    poll=$((poll+1))
    if (( poll >= POLL_MAX )); then break; fi
    if (( POLL_INTERVAL > 0 )); then sleep "$POLL_INTERVAL"; fi
  done
  log "build pr=$num sha=$new_sha state=$state"

  case "$state" in
    SUCCESSFUL)
      merge_rc=0
      if [[ -n "$MERGE_STRATEGY" ]]; then
        host pr-merge --num "$num" --strategy "$MERGE_STRATEGY" >/dev/null 2>&1 || merge_rc=$?
      else
        host pr-merge --num "$num" >/dev/null 2>&1 || merge_rc=$?
      fi
      if (( merge_rc != 0 )); then
        # The composed build was green but the merge call itself failed (branch
        # protection, a race, transient host error). Do NOT report a merge that
        # did not happen; leave the PR at the head and stop — the next fire
        # re-selects and retries it. Still one PR in flight.
        log "merge pr=$num result=failed rc=$merge_rc"
        WAITED_PR="$num"
        break
      fi
      log "merge pr=$num strategy=${MERGE_STRATEGY:-default}"
      MERGED_PR="$num"
      break            # one PR in flight — the pass ends on the first merge
      ;;
    FAILED)
      post_comment "$num" "Merge Marshal: the COMPOSED-state build failed on the post-rebase head $new_sha. Each branch was green against its own fork point; together they are red (a Composition Break). Fix on the branch and it re-enters the queue."
      log "kickback pr=$num reason=build-failed"
      EVICTED=$((EVICTED+1))
      continue         # evict, next in line
      ;;
    *)
      # INPROGRESS / UNKNOWN: the composed build is not decided. Never merge an
      # unverified composition; leave the PR in place for the next fire. One PR
      # is in flight, so the pass stops here.
      log "wait pr=$num state=$state"
      WAITED_PR="$num"
      break
      ;;
  esac
done < "$ORDER"

log "done merged=$MERGED_PR evicted=$EVICTED waited=$WAITED_PR"
exit 0
