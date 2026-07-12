#!/usr/bin/env bash
# wave_preauth_check.sh — deterministic preconditions for a DELEGATED wave-PR
# approval (/health-loop preauthorization hatch, ADR 0024).
#
# Under `merge: preauthorized` (double-keyed: config flag + per-run operator
# confirmation at kickoff) the loop may approve an auto-class wave's Story PRs
# as the operator's logged delegate. Approval authority stays the operator's;
# this script is the evidence bar a PR must clear before the loop may exercise
# that delegation. ALL checks must pass, else it refuses with the failed
# precondition named. It checks EVIDENCE ON DISK — it never calls the host, so
# it is hermetically testable; the loop performs the actual `host.sh pr-approve`
# only after this exits 0, and Marshal still owns the merge (composed-state
# build, APPROVED-only). Autopilot Hard Contract §4 is untouched.
#
# Preconditions:
#   P1  tracker frontmatter STATUS: DRAINED — the whole wave's drain finished;
#       delegated approval never races a live drain.
#   P2  every checklist Subtask of --story is `[x]` — none `[ ]`, none BLOCKED.
#       (Zero matching lines is a refusal: an unknown Story proves nothing.)
#   P3  no unresolved `[BLOCKED:` entry for the Story's Subtask ids anywhere in
#       the tracker body.
#   P4  the Story branch's changed-file set (git diff --name-only of
#       merge-base(base, branch)..branch) is a SUBSET of the Runbook PR's
#       predicted file surface (runbook_pr.sh file-surface), modulo the drain's
#       own bookkeeping paths (.autopilot/ tracker deltas, docs/FIX_LOG.md).
#       A drain that touched files it never predicted does not get delegated
#       approval, however green its gates.
#
# Deliberately NOT re-run here: the D6.2 TDD commit-shape audit. It is a hard
# gate BEFORE any Subtask can reach `[x] Done`, and its own header warns that
# auditing a whole-Story range false-flags `tdd-scope-leak` (it is built for
# per-Subtask `prev_pushed_sha..HEAD` ranges). P2 checks its recorded outcome;
# re-running it wrong would manufacture false refusals.
#
# Usage:
#   wave_preauth_check.sh --tracker <tracker.md> --story <story-id>
#                         --branch <ref> --base <ref> --pr-body <file>
#                         [--repo <dir>] [--allow-prefix <path>]...
#
# Output: `OK story=<id>` + exit 0, or `[refuse] P<n> <reason>` + exit 1.
# Unreadable tracker/PR body → exit 4 (fail closed). Usage → exit 64.
#
# Portability: bash 3.2 + BSD userland safe. No associative arrays; empty-array
# expansion guarded as ${arr[@]+"${arr[@]}"}; no `grep -P`.
set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The file-surface block contract is owned by autopilot (AV3-08). Reuse its
# extractor, never fork it. In the monorepo it sits at a fixed relative path;
# a standalone layout points RUNBOOK_PR_SH at its own copy (default: the
# autopilot skill inside the same zero-trust plugin, ADR 0025).
RUNBOOK_PR_SH="${RUNBOOK_PR_SH:-$SCRIPTS_DIR/../../autopilot/scripts/runbook_pr.sh}"

usage() {
  echo "usage: wave_preauth_check.sh --tracker <tracker.md> --story <story-id> --branch <ref> --base <ref> --pr-body <file> [--repo <dir>] [--allow-prefix <path>]..." >&2
  exit 64
}

TRACKER=""; STORY=""; BRANCH=""; BASE=""; PR_BODY=""; REPO="."
ALLOW=()
# Every option takes a NON-EMPTY value; a trailing/empty value is a usage error
# (exit 64), never an infinite `shift 2` spin and never a silently-disabled
# check (an empty --allow-prefix would prefix-match EVERY path and turn P4 off).
while [ $# -gt 0 ]; do
  [ -n "${2:-}" ] || usage
  case "$1" in
    --tracker)      TRACKER="$2";  shift 2 ;;
    --story)        STORY="$2";    shift 2 ;;
    --branch)       BRANCH="$2";   shift 2 ;;
    --base)         BASE="$2";     shift 2 ;;
    --pr-body)      PR_BODY="$2";  shift 2 ;;
    --repo)         REPO="$2";     shift 2 ;;
    --allow-prefix) ALLOW=(${ALLOW[@]+"${ALLOW[@]}"} "$2"); shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$TRACKER" ] && [ -n "$STORY" ] && [ -n "$BRANCH" ] && [ -n "$BASE" ] && [ -n "$PR_BODY" ] || usage

# The drain's own bookkeeping is always allowed to appear in the diff: tracker
# deltas fold into the Story branch under branching.no_force_push (AP-23), and
# spec execution records fixes in docs/FIX_LOG.md (spec-format.md).
# Entries ending in `/` are directory prefixes; everything else is an EXACT
# path (a prefix match would wave `docs/FIX_LOG.md.orig` — patch(1) droppings —
# through the delegated-approval evidence bar).
ALLOW=(${ALLOW[@]+"${ALLOW[@]}"} ".autopilot/" "docs/FIX_LOG.md" "docs/DELETION_LOG.md")

refuse() { echo "[refuse] $*"; exit 1; }

[ -r "$TRACKER" ] || { echo "wave_preauth_check: tracker unreadable: $TRACKER (fail closed)" >&2; exit 4; }
[ -r "$PR_BODY" ] || { echo "wave_preauth_check: PR body unreadable: $PR_BODY (fail closed)" >&2; exit 4; }

# ── P1: tracker STATUS is DRAINED ─────────────────────────────────────────────
STATUS="$(awk '/^---$/ { fm++; next } fm == 1 && /^STATUS:/ { sub(/^STATUS:[[:space:]]*/, ""); print; exit }' "$TRACKER")"
[ -n "$STATUS" ] || { echo "wave_preauth_check: no STATUS in tracker frontmatter (fail closed)" >&2; exit 4; }
[ "$STATUS" = "DRAINED" ] || refuse "P1 tracker STATUS is '$STATUS', not DRAINED — never delegate approval on a live or escalated drain"

# ── P2: every Subtask of the Story is [x] ─────────────────────────────────────
# Checklist rows: `- [x] <id> …` / `- [ ] <id> …`; Story Subtask ids are
# `<story-id>` or `<story-id>.<n>` (planner schema). LC_ALL=C + ERE only.
STORY_RE="$(printf '%s' "$STORY" | sed -E 's/[^A-Za-z0-9_-]/\\&/g')"
ROWS="$(grep -E "^[[:space:]]*- \[( |x)\] ${STORY_RE}(\.[0-9]+)?([^A-Za-z0-9._-]|$)" "$TRACKER" || true)"
[ -n "$ROWS" ] || refuse "P2 no checklist rows for story '$STORY' in tracker — an unknown Story proves nothing"
NOT_DONE="$(printf '%s\n' "$ROWS" | grep -E '^[[:space:]]*- \[ \]' || true)"
[ -z "$NOT_DONE" ] || refuse "P2 story '$STORY' has open Subtask(s): $(printf '%s' "$NOT_DONE" | head -1 | sed -E 's/^[[:space:]]*- //')"

# ── P3: no unresolved BLOCKED entries for the Story's ids ─────────────────────
# Boundary-anchored on both sides (the P2 guard): a resolved block on sibling
# story `<story>-v2` must not refuse `<story>`.
BLOCKED="$(grep -E "\[BLOCKED[:[:space:]]" "$TRACKER" | grep -E "(^|[^A-Za-z0-9._-])${STORY_RE}(\.[0-9]+)?([^A-Za-z0-9._-]|$)" || true)"
if [ -n "$BLOCKED" ]; then
  # A block that was later resolved leaves its row `[x]`; P2 already proved all
  # rows are [x]. Body-log BLOCKED lines for this story are still a refusal:
  # the delegate cannot judge whether the resolution was reviewed.
  refuse "P3 tracker records [BLOCKED:] entries for story '$STORY' — delegated approval needs a human eye on resolved blocks"
fi

# ── P4: changed files ⊆ predicted file surface ────────────────────────────────
SURFACE="$(bash "$RUNBOOK_PR_SH" file-surface "$PR_BODY")" \
  || { echo "wave_preauth_check: predicted file surface unreadable from PR body (fail closed)" >&2; exit 4; }
MB="$(git -C "$REPO" merge-base "$BASE" "$BRANCH" 2>/dev/null)" \
  || refuse "P4 cannot compute merge-base($BASE, $BRANCH) — unknown refs"
CHANGED="$(git -C "$REPO" diff --name-only "$MB" "$BRANCH")"
[ -n "$CHANGED" ] || refuse "P4 empty diff for $BRANCH — nothing to approve"

VIOLATIONS=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if printf '%s\n' "$SURFACE" | grep -qxF "$f"; then continue; fi
  allowed=0
  for p in ${ALLOW[@]+"${ALLOW[@]}"}; do
    case "$p" in
      */) case "$f" in "$p"*) allowed=1 ;; esac ;;
      *)  [ "$f" = "$p" ] && allowed=1 ;;
    esac
    [ "$allowed" -eq 1 ] && break
  done
  [ "$allowed" -eq 1 ] || VIOLATIONS="$VIOLATIONS $f"
done <<EOF
$CHANGED
EOF
[ -z "$VIOLATIONS" ] || refuse "P4 changed file(s) outside the predicted surface:$VIOLATIONS — a drain that outran its prediction does not get delegated approval"

echo "OK story=$STORY branch=$BRANCH files=$(printf '%s\n' "$CHANGED" | grep -c .)"
