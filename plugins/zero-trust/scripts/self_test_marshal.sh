#!/usr/bin/env bash
# self_test_marshal.sh — hermetic self-test for the Merge Marshal domain's
# deterministic substrate (marshal.sh, the canonical claim_overlap.sh,
# branch_age_watcher.sh) driven end-to-end through a MOCK host backend
# (mock_host.py via uv, ADR 0015). Lives inside plugins/zero-trust (ADR 0025).
#
# Ground rules (mirroring skills/autopilot/scripts/self_test.sh):
#   - Hermetic: everything runs inside a mktemp -d sandbox with local BARE repos
#     standing in for `origin`. No network, no host API, no credentials, no
#     writes outside the sandbox.
#   - Every assertion cites an id. A field-found bug lands here as a failing
#     assertion before (or with) its fix.
#   - The pure kernels (claim_overlap, branch_age) run with no external deps.
#     The loop sections drive the mock host and therefore require uv (ADR 0015);
#     they are gated on UV_OK and skipped-with-warning if uv is absent.
#
# Usage: bash plugins/zero-trust/scripts/self_test_marshal.sh
# Exit 0 = all assertions pass; non-zero = at least one failure.
#
# Portability: bash 3.2 (macOS default) + BSD userland safe.

set -u
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"   # repo root (has pyproject.toml)
MARSHAL="$HERE/marshal.sh"
CLAIM="$HERE/../skills/autopilot/scripts/claim_overlap.sh"   # the ONE canonical copy (ADR 0009/0025)
WATCH="$HERE/branch_age_watcher.sh"
MOCK="$HERE/mock_host.sh"
TAB="$(printf '\t')"

PASS=0
FAIL=0
fail() { echo "FAIL [$1] $2" >&2; FAIL=$((FAIL+1)); }
pass() { echo "ok   [$1] $2"; PASS=$((PASS+1)); }
assert_eq()        { if [[ "$3" == "$4" ]]; then pass "$1" "$2"; else fail "$1" "$2 — expected [$3], got [$4]"; fi; }
assert_contains()  { if grep -qF -- "$3" <<<"$4"; then pass "$1" "$2"; else fail "$1" "$2 — missing [$3] in:\n$4"; fi; }
assert_not_contains() { if grep -qF -- "$3" <<<"$4"; then fail "$1" "$2 — found forbidden [$3]"; else pass "$1" "$2"; fi; }

SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT INT TERM

export GIT_AUTHOR_NAME=selftest GIT_AUTHOR_EMAIL=selftest@local \
       GIT_COMMITTER_NAME=selftest GIT_COMMITTER_EMAIL=selftest@local
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# ==============================================================================
# claim_overlap.sh — the CANONICAL primitive (ADR 0009), single copy since
# ADR 0025 (skills/autopilot/scripts/claim_overlap.sh). The Marshal consumes it
# directly; it does NOT ship an independent implementation. These assertions
# mirror autopilot's AV3-09 matrix so the primitive is exercised from the
# Marshal's calling side too, and any behaviour drift reds here. (Single-copy
# uniqueness itself is asserted by CO10 below.)
# ==============================================================================
echo "== claim_overlap.sh (CO) =="

# Inventory columns: pr-ref <TAB> branch <TAB> state <TAB> age_bd <TAB> comma-files.
# The Marshal's own drain namespace is story/ (its in-flight branches).
CLAIM_INV="$SANDBOX/claim_inv.tsv"
{
  printf 'gh/101\tstory/other-a\tDRAFT\t1\tapi/limiter.py,lib/x.py\n'
  printf 'gh/102\tstory/other-b\tOPEN\t0\tcore/engine.py\n'
  printf 'gh/103\tstory/other-c\tDRAFT\t5\tdocs/old.md\n'
  printf 'gh/104\tstory/mine-z\tDRAFT\t0\townpath.py\n'
} > "$CLAIM_INV"
co() { bash "$CLAIM" --self-namespace story/mine- --inventory "$CLAIM_INV" "$@"; }

# CO01 — a fresh foreign DRAFT PR overlapping our files is a BINDING claim (exit 2).
out="$(co api/limiter.py 2>&1)"; rc=$?
assert_eq       CO01 "foreign draft overlap blocks (exit 2)" "2" "$rc"
assert_contains CO01 "binding claim emits blocked_by_pr" "blocked_by_pr=gh/101 class=BINDING" "$out"

# CO02 — a foreign ready (non-draft OPEN) PR is a TERMINAL claim (exit 2).
out="$(co core/engine.py 2>&1)"; rc=$?
assert_eq       CO02 "foreign ready overlap blocks (exit 2)" "2" "$rc"
assert_contains CO02 "terminal claim emits blocked_by_pr" "blocked_by_pr=gh/102 class=TERMINAL" "$out"

# CO03 — a branch under our OWN drain namespace is never a foreign claim.
out="$(co ownpath.py 2>&1)"; rc=$?
assert_eq       CO03 "own-namespace overlap does not block (exit 0)" "0" "$rc"
assert_contains CO03 "own-namespace claim is excluded" "excluded=gh/104" "$out"

# CO04 — a foreign PR stale beyond 2 business days is ADVISORY, not blocking.
out="$(co docs/old.md 2>&1)"; rc=$?
assert_eq       CO04 "stale (>2bd) overlap is advisory (exit 0)" "0" "$rc"
assert_contains CO04 "stale claim is advisory" "advisory=gh/103" "$out"

# CO05 — no shared files -> clean, silent.
out="$(co unrelated/file.py 2>&1)"; rc=$?
assert_eq       CO05 "no overlap is clean (exit 0)" "0" "$rc"
assert_eq       CO05 "no overlap prints nothing" "" "$out"

# CO06 — D2 eligibility: a claimed Subtask waits until its blocked_by_pr resolves.
assert_eq       CO06 "blocked_by MERGED -> eligible (exit 0)"  "0" "$(bash "$CLAIM" eligibility --pr-state MERGED   >/dev/null 2>&1; echo $?)"
assert_eq       CO06 "blocked_by DECLINED -> eligible"         "0" "$(bash "$CLAIM" eligibility --pr-state DECLINED >/dev/null 2>&1; echo $?)"
assert_eq       CO06 "blocked_by OPEN -> ineligible (exit 2)"  "2" "$(bash "$CLAIM" eligibility --pr-state OPEN     >/dev/null 2>&1; echo $?)"
assert_eq       CO06 "blocked_by DRAFT -> ineligible (exit 2)" "2" "$(bash "$CLAIM" eligibility --pr-state DRAFT    >/dev/null 2>&1; echo $?)"

# CO07 — usage guardrails.
( bash "$CLAIM" --inventory "$CLAIM_INV" >/dev/null 2>&1 ); assert_eq CO07 "no owned files is a usage error -> exit 64" "64" "$?"
( bash "$CLAIM" eligibility --pr-state BOGUS >/dev/null 2>&1 ); assert_eq CO07 "unknown pr-state is a usage error -> exit 64" "64" "$?"

# CO10 — determinism (stable output) AND single-copy uniqueness (ADR 0025: the
# canonical claim_overlap.sh is the ONLY copy in the tree — a second copy would
# reintroduce the vendored-drift class the consolidation retired).
r1="$(co api/limiter.py core/engine.py 2>&1)"; r2="$(co api/limiter.py core/engine.py 2>&1)"
assert_eq       CO10 "output is deterministic across runs" "$r1" "$r2"
assert_eq       CO10 "exactly ONE claim_overlap.sh in the tree (the canonical; no vendored copy to drift)" \
  "1" "$(find "$ROOT" -path "$ROOT/.git" -prune -o -path "$ROOT/.claude" -prune -o -name 'claim_overlap.sh' -print 2>/dev/null | wc -l | tr -d ' ')"

# ==============================================================================
# branch_age_watcher.sh — staleness / 48h planning-failure watcher (ADR 0012/0009)
# ==============================================================================
echo "== branch_age_watcher.sh (BA) =="

NOW=1000000; H=3600
AGES="$SANDBOX/ages.tsv"
printf 'fresh\t%s\nstale\t%s\nboundary\t%s\nfuture\t%s\n' \
  $((NOW-1*H)) $((NOW-50*H)) $((NOW-48*H)) $((NOW+5*H)) > "$AGES"

out="$(bash "$WATCH" --max-age-hours 48 --now $NOW < "$AGES")"
assert_contains BA01 "50h branch flagged stale" "50${TAB}stale" "$out"
assert_contains BA02 "boundary at exactly 48h flagged (>=)" "48${TAB}boundary" "$out"
assert_not_contains BA03 "1h branch not flagged" "fresh" "$out"
assert_not_contains BA04 "future-dated commit not flagged" "future" "$out"
# Ordering: oldest first.
assert_eq       BA05 "sorted by age desc (stale before boundary)" "50${TAB}stale
48${TAB}boundary" "$out"

out="$(bash "$WATCH" --max-age-hours 100 --now $NOW < "$AGES")"
assert_eq       BA06 "no branch past a 100h ceiling -> empty" "" "$out"

# --refs mode over a real repo with one old (2020) and one just-now branch.
BAREPO="$SANDBOX/barepo"; mkdir -p "$BAREPO"
( cd "$BAREPO" && git init -q && git config commit.gpgsign false \
  && GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" git commit -q --allow-empty -m init \
  && git branch story/old \
  && git checkout -q -b story/new \
  && git commit -q --allow-empty -m recent )     # recent = real now, not stale
out="$( cd "$BAREPO" && bash "$WATCH" --refs 'refs/heads/story/*' --max-age-hours 48 )"
assert_contains BA07 "--refs flags the 2020 branch" "story/old" "$out"
assert_not_contains BA08 "--refs does not flag the just-committed branch" "story/new" "$out"

( bash "$WATCH" --now notanint < "$AGES" >/dev/null 2>&1 ); assert_eq BA09 "non-integer --now -> usage exit 64" "64" "$?"

# --refs outside a git repo must FAIL (exit 65), not silently succeed — the check
# has to run in the main shell, not inside the pipeline subshell.
NOTREPO="$SANDBOX/notrepo"; mkdir -p "$NOTREPO"
( cd "$NOTREPO" && bash "$WATCH" --refs 'refs/heads/*' >/dev/null 2>&1 ); assert_eq BA10 "--refs outside a git repo -> exit 65" "65" "$?"

# ==============================================================================
# marshal.sh — the serial backstop loop, via the MOCK host backend
# ==============================================================================
UV_OK=1
if ! command -v uv >/dev/null 2>&1; then
  UV_OK=0
  echo "WARN: uv not found — Marshal loop sections (ML*) SKIPPED (ADR 0015 requires uv)" >&2
fi

CASE_N=0
mk_case() {  # -> sets ORIGIN WC STATE ; fresh bare origin + working clone
  CASE_N=$((CASE_N+1))
  CASE="$SANDBOX/case$CASE_N"; mkdir -p "$CASE"
  ORIGIN="$CASE/origin.git"; WC="$CASE/wc"; STATE="$CASE/state.json"
  git init -q --bare "$ORIGIN"
  git clone -q "$ORIGIN" "$WC" 2>/dev/null
  git -C "$WC" config commit.gpgsign false
}
main_init() {  # <defs-lines> <calls-lines>  (\n-separated); commits + pushes main
  ( cd "$WC" && printf '%b' "$1" > defs.txt && printf '%b' "$2" > calls.txt \
      && git add -A && git commit -qm init && git branch -M main && git push -q -u origin main )
}
mk_branch() {  # <name> <defs-lines> <calls-lines>  -- forks LOCAL main
  # --allow-empty so a branch identical to main still exists as a live claim
  # (the tests that need a real diff supply differing defs/calls).
  ( cd "$WC" && git checkout -q main && git checkout -q -b "$1" \
      && printf '%b' "$2" > defs.txt && printf '%b' "$3" > calls.txt \
      && git add -A && git commit -q --allow-empty -m "$1" && git push -q -u origin "$1" \
      && git checkout -q main )
}
mk_branch_files() {  # <name> <file=content>...  -- forks LOCAL main with arbitrary files
  name="$1"; shift
  ( cd "$WC" && git checkout -q main && git checkout -q -b "$name" \
      && while (( $# )); do f="${1%%=*}"; c="${1#*=}"; printf '%b' "$c" > "$f"; shift; done \
      && git add -A && git commit -q --allow-empty -m "$name" && git push -q -u origin "$name" \
      && git checkout -q main )
}
edit_main() {  # <file=content>...  -- advances LOCAL main and pushes
  ( cd "$WC" && git checkout -q main \
      && while (( $# )); do f="${1%%=*}"; c="${1#*=}"; printf '%b' "$c" > "$f"; shift; done \
      && git add -A && git commit -q --allow-empty -m advance && git push -q origin main )
}
run_marshal() {  # extra "VAR=val" env args ; echoes marshal stdout+stderr
  ( cd "$WC" && env "$@" \
      MARSHAL_HOST="$MOCK" MARSHAL_MOCK_STATE="$STATE" MARSHAL_MOCK_REPO="$ORIGIN" \
      MARSHAL_UV_PROJECT="$ROOT" \
      MARSHAL_BUILD_POLL_MAX=1 MARSHAL_BUILD_POLL_INTERVAL=0 \
      bash "$MARSHAL" 2>&1 )
}
state_list() {  # <key: merges|comments> -> comma-joined nums (tolerant of an
  # untouched seed file the mock never re-saved: default the key to []).
  uv run --project "$ROOT" python -c 'import json,sys
s=json.load(open(sys.argv[1]))
print(",".join(str(x["num"]) for x in s.get(sys.argv[2], [])))' "$STATE" "$1"
}

if (( UV_OK )); then
echo "== marshal.sh loop (ML) =="

# ---- ML01/ML02: strict FIFO + one-PR-in-flight ------------------------------
# Two approved, green, already-current PRs; the lower ready_ts merges, the pass
# stops (one in flight), the higher-ts PR is untouched this pass.
mk_case
main_init 'foo\nbar\nbaz\n' 'foo\n'
mk_branch story/a 'foo\nbar\nbaz\n' 'foo\nbaz\n'   # calls baz (defined) -> green
mk_branch story/b 'foo\nbar\nbaz\n' 'foo\nbar\n'   # calls bar (defined) -> green
cat > "$STATE" <<JSON
{"trunk":"main","prs":[
 {"num":10,"branch":"story/a","ready_ts":200,"approval":"APPROVED"},
 {"num":11,"branch":"story/b","ready_ts":100,"approval":"APPROVED"}]}
JSON
out="$(run_marshal)"
assert_contains ML01 "FIFO order is by ready_ts (11 before 10)" "candidates n=2 order=11,10" "$out"
assert_contains ML01 "lower-ts PR 11 merges first" "merge pr=11" "$out"
assert_not_contains ML02 "one PR in flight: PR 10 not merged in the same pass" "merge pr=10" "$out"
assert_eq       ML02 "only PR 11 recorded merged" "11" "$(state_list merges)"

# ---- ML03: real rebase onto advanced main + compose-verify + merge ----------
# main advances by APPENDING a def (disjoint from the branch's calls edit), so
# the branch is NOT already-current and must actually rebase — cleanly.
mk_case
main_init 'foo\nbar\n' 'foo\n'
mk_branch story/c 'foo\nbar\n' 'foo\nbar\n'         # calls bar -> green, edits calls.txt
# advance main on a disjoint file (defs.txt) so story/c must rebase but won't conflict
edit_main 'defs.txt=foo\nbar\nqux\n'
cat > "$STATE" <<JSON
{"trunk":"main","prs":[{"num":20,"branch":"story/c","ready_ts":100,"approval":"APPROVED"}]}
JSON
out="$(run_marshal)"
assert_contains ML03 "story/c rebases cleanly (not already-current)" "rebase pr=20 result=clean" "$out"
assert_contains ML03 "compose-verify green on the post-rebase sha" "build pr=20 sha=" "$out"
assert_contains ML03 "PR 20 merges after clean rebase" "merge pr=20" "$out"
assert_eq       ML03 "PR 20 recorded merged" "20" "$(state_list merges)"

# ---- ML04: Composition Break — clean rebase, RED composed build -------------
# main REMOVES a symbol (bar); the branch adds a CALL to bar on a disjoint file
# edit. Each is green at its own fork point; composed, the call is undefined.
mk_case
main_init 'foo\nbar\n' 'foo\n'
mk_branch story/d 'foo\nbar\n' 'foo\nbar\n'         # branch edits calls.txt (adds bar)
edit_main 'defs.txt=foo\n'                          # main removes bar (a rename/removal)
cat > "$STATE" <<JSON
{"trunk":"main","prs":[{"num":30,"branch":"story/d","ready_ts":100,"approval":"APPROVED"}]}
JSON
out="$(run_marshal)"
assert_contains ML04 "rebase is clean (disjoint files)" "rebase pr=30 result=clean" "$out"
assert_contains ML04 "composed build is FAILED" "state=FAILED" "$out"
assert_contains ML04 "kickback reason=build-failed" "kickback pr=30 reason=build-failed" "$out"
assert_not_contains ML04 "composition break is NOT merged" "merge pr=30" "$out"
assert_eq       ML04 "a kickback comment was posted to PR 30" "30" "$(state_list comments)"
assert_eq       ML04 "nothing merged" "" "$(state_list merges)"

# ---- ML05: D7.0 file-budget refuse ------------------------------------------
# The branch and main both add the SAME 3 files relative to the fork point
# (overlap = 3 files > 2-file budget) -> refuse before rebasing, kickback, no
# build, no merge.
mk_case
main_init 'foo\n' 'foo\n'
mk_branch_files story/e 'f1.txt=branch\n' 'f2.txt=branch\n' 'f3.txt=branch\n'
edit_main 'f1.txt=trunk\n' 'f2.txt=trunk\n' 'f3.txt=trunk\n'
cat > "$STATE" <<JSON
{"trunk":"main","prs":[{"num":40,"branch":"story/e","ready_ts":100,"approval":"APPROVED"}]}
JSON
out="$(run_marshal)"
assert_contains ML05 "rebase refused on the file budget" "result=refuse-budget" "$out"
assert_contains ML05 "overlap is 3 files" "overlap_files=3" "$out"
assert_contains ML05 "kickback reason=rebase-budget" "kickback pr=40 reason=rebase-budget" "$out"
assert_not_contains ML05 "budget-refused PR is not built" "build pr=40" "$out"
assert_eq       ML05 "budget-refused PR is not merged" "" "$(state_list merges)"

# ---- ML05b: D7.0 HUNK-budget refuse (1 file, but > 3 hunks) ------------------
# The overlap is a single file (within the 2-file budget) but the trunk changed
# it in 4 separated hunks (> 3-hunk budget) -> refuse on the hunk budget, not the
# file budget. Exercises the hunk gate independently.
mk_case
main_init 'foo\n' 'foo\n'
# a 30-line file on main
( cd "$WC" && git checkout -q main && seq 1 30 | sed 's/^/l/' > big.txt \
    && git add -A && git commit -qm addbig && git push -q origin main )
# branch touches big.txt in ONE spot (line 30) -> big.txt is in the overlap set
( cd "$WC" && git checkout -q -b story/h main \
    && seq 1 30 | sed 's/^/l/' | sed -e '30s/$/-BR/' > big.txt \
    && git add -A && git commit -qm br && git push -q -u origin story/h && git checkout -q main )
# main changes 4 well-separated regions (>= 8 lines apart => 4 distinct hunks)
( cd "$WC" && git checkout -q main \
    && seq 1 30 | sed 's/^/l/' | sed -e '2s/$/-M/' -e '10s/$/-M/' -e '18s/$/-M/' -e '26s/$/-M/' > big.txt \
    && git add -A && git commit -qm main4 && git push -q origin main )
cat > "$STATE" <<JSON
{"trunk":"main","prs":[{"num":45,"branch":"story/h","ready_ts":100,"approval":"APPROVED"}]}
JSON
out="$(run_marshal)"
assert_contains ML05b "refused on the budget (1 file within file budget)" "result=refuse-budget" "$out"
assert_contains ML05b "overlap is exactly 1 file" "overlap_files=1" "$out"
assert_contains ML05b "trunk changed it in 4 hunks (> 3)" "overlap_hunks=4" "$out"
assert_contains ML05b "kickback reason=rebase-budget" "kickback pr=45 reason=rebase-budget" "$out"
assert_eq       ML05b "hunk-budget-refused PR is not merged" "" "$(state_list merges)"

# ---- ML05c: HUNK budget over a filename WITH A SPACE (locks the array fix) ---
# Same shape as ML05b but the overlap file name contains a space. If the hunk
# counter word-split the path, git diff would see two non-existent paths, report
# 0 hunks, pass the budget, and fall through to a plain conflict — so this test
# fails (reason=rebase-conflict, overlap_hunks=0) unless paths are passed as a
# single argument.
mk_case
main_init 'foo\n' 'foo\n'
SP='big file.txt'
( cd "$WC" && git checkout -q main && seq 1 30 | sed 's/^/l/' > "$SP" \
    && git add -A && git commit -qm addbig && git push -q origin main )
( cd "$WC" && git checkout -q -b story/sp main \
    && seq 1 30 | sed 's/^/l/' | sed -e '30s/$/-BR/' > "$SP" \
    && git add -A && git commit -qm br && git push -q -u origin story/sp && git checkout -q main )
( cd "$WC" && git checkout -q main \
    && seq 1 30 | sed 's/^/l/' | sed -e '2s/$/-M/' -e '10s/$/-M/' -e '18s/$/-M/' -e '26s/$/-M/' > "$SP" \
    && git add -A && git commit -qm main4 && git push -q origin main )
cat > "$STATE" <<JSON
{"trunk":"main","prs":[{"num":46,"branch":"story/sp","ready_ts":100,"approval":"APPROVED"}]}
JSON
out="$(run_marshal)"
assert_contains ML05c "spaced-name overlap counted as 1 file" "overlap_files=1" "$out"
assert_contains ML05c "4 hunks counted despite the space in the path" "overlap_hunks=4" "$out"
assert_contains ML05c "refused on the hunk budget, not misread as a conflict" "kickback pr=46 reason=rebase-budget" "$out"

# ---- ML06: rebase CONFLICT refuse (within file budget) ----------------------
# main and branch edit the SAME single file with conflicting hunks: 1 file is
# within the 2-file budget, so it passes the budget gate but the rebase itself
# conflicts -> refuse-conflict.
mk_case
main_init 'foo\n' 'foo\n'
mk_branch story/f 'foo\n' 'foo\nBRANCHLINE\n'      # branch edits calls.txt
edit_main 'calls.txt=foo\nTRUNKLINE\n'             # main edits the same file -> conflict
cat > "$STATE" <<JSON
{"trunk":"main","prs":[{"num":50,"branch":"story/f","ready_ts":100,"approval":"APPROVED"}]}
JSON
out="$(run_marshal)"
assert_contains ML06 "rebase refused on a real conflict" "rebase pr=50 result=refuse-conflict" "$out"
assert_contains ML06 "kickback reason=rebase-conflict" "kickback pr=50 reason=rebase-conflict" "$out"
assert_eq       ML06 "conflicting PR is not merged" "" "$(state_list merges)"

# ---- ML07: red head evicted, next green merged in the SAME pass --------------
mk_case
main_init 'foo\nbar\n' 'foo\n'
mk_branch story/red   'foo\nbar\n' 'foo\nNOPE\n'   # calls NOPE (undefined) -> red
mk_branch story/green 'foo\nbar\n' 'foo\nbar\n'    # calls bar -> green
cat > "$STATE" <<JSON
{"trunk":"main","prs":[
 {"num":60,"branch":"story/red","ready_ts":100,"approval":"APPROVED"},
 {"num":61,"branch":"story/green","ready_ts":200,"approval":"APPROVED"}]}
JSON
out="$(run_marshal)"
assert_contains ML07 "red head is kicked back" "kickback pr=60 reason=build-failed" "$out"
assert_contains ML07 "next-in-line green PR merges" "merge pr=61" "$out"
assert_eq       ML07 "only the green PR merged" "61" "$(state_list merges)"

# ---- ML08: INPROGRESS -> wait (never merge an unverified composition) --------
mk_case
main_init 'foo\n' 'foo\n'
mk_branch story/wip 'foo\n' 'foo\n__INPROGRESS__\n'
cat > "$STATE" <<JSON
{"trunk":"main","prs":[{"num":70,"branch":"story/wip","ready_ts":100,"approval":"APPROVED"}]}
JSON
out="$(run_marshal)"
assert_contains ML08 "in-flight composed build reported" "state=INPROGRESS" "$out"
assert_contains ML08 "marshal waits, does not merge" "wait pr=70 state=INPROGRESS" "$out"
assert_contains ML08 "pass summary records the wait" "done merged=none evicted=0 waited=70" "$out"
assert_eq       ML08 "nothing merged while building" "" "$(state_list merges)"

# ---- ML09: PENDING approval is excluded from the candidate set --------------
mk_case
main_init 'foo\n' 'foo\n'
mk_branch story/pending 'foo\n' 'foo\n'
cat > "$STATE" <<JSON
{"trunk":"main","prs":[{"num":80,"branch":"story/pending","ready_ts":100,"approval":"PENDING"}]}
JSON
out="$(run_marshal)"
assert_contains ML09 "no approved candidates" "candidates n=0 order=none" "$out"
assert_not_contains ML09 "pending PR is never considered" "consider pr=80" "$out"

# ---- ML10: hotfix pin overrides FIFO + approval; logged to Force Audit -------
# The pinned PR (90) has a LATER ready_ts than 91 AND is only PENDING; the pin
# moves it to the head and the human vouches for it. It still must pass the
# composed build (zero-trust never bypassed).
mk_case
main_init 'foo\nbar\n' 'foo\n'
mk_branch story/hot 'foo\nbar\n' 'foo\nbar\n'      # green
mk_branch story/norm 'foo\nbar\n' 'foo\nbar\n'     # green, earlier ts, approved
cat > "$STATE" <<JSON
{"trunk":"main","prs":[
 {"num":90,"branch":"story/hot","ready_ts":500,"approval":"PENDING"},
 {"num":91,"branch":"story/norm","ready_ts":100,"approval":"APPROVED"}]}
JSON
AUDIT="$CASE/force-audit.log"
out="$(run_marshal MARSHAL_HOTFIX_PIN=90 MARSHAL_FORCE_AUDIT_LOG="$AUDIT" MARSHAL_NOW=1700000000 MARSHAL_ACTOR=bailey)"
assert_contains ML10 "pin moves PR 90 to the head" "candidates n=2 order=90,91" "$out"
assert_contains ML10 "pinned hotfix merges first" "merge pr=90" "$out"
assert_eq       ML10 "pinned PR 90 recorded merged (one in flight; 91 waits)" "90" "$(state_list merges)"
audit_body="$(cat "$AUDIT" 2>/dev/null || true)"
assert_contains ML10 "Force Audit line written for the pin" "hotfix-pin" "$audit_body"
assert_contains ML10 "Force Audit records the PR number" "pr=90" "$audit_body"
assert_contains ML10 "Force Audit records the actor" "actor=bailey" "$audit_body"

# ---- ML11: pin ignored when the pinned PR is not ready -----------------------
mk_case
main_init 'foo\n' 'foo\n'
mk_branch story/only 'foo\n' 'foo\n'
cat > "$STATE" <<JSON
{"trunk":"main","prs":[{"num":95,"branch":"story/only","ready_ts":100,"approval":"APPROVED"}]}
JSON
AUDIT2="$CASE/force-audit.log"
out="$(run_marshal MARSHAL_HOTFIX_PIN=999 MARSHAL_FORCE_AUDIT_LOG="$AUDIT2")"
assert_contains ML11 "pin of a non-ready PR is logged ignored" "pin pr=999 ignored=not-ready" "$out"
assert_eq       ML11 "no Force Audit line written for an ignored pin" "0" "$([[ -f "$AUDIT2" ]] && wc -l < "$AUDIT2" | tr -d ' ' || echo 0)"

# ---- ML14: a pinned RED hotfix is evicted, NOT merged (pin never waives build)-
# The pin overrides ordering + approval but NEVER the composed-state build gate.
# Pin a red PR ahead of an approved green one: the red pin is kicked back and the
# next-in-line green PR merges instead.
mk_case
main_init 'foo\nbar\n' 'foo\n'
mk_branch story/hotred 'foo\nbar\n' 'foo\nGHOST\n'   # calls GHOST (undefined) -> red
mk_branch story/safe   'foo\nbar\n' 'foo\nbar\n'     # green
cat > "$STATE" <<JSON
{"trunk":"main","prs":[
 {"num":100,"branch":"story/hotred","ready_ts":900,"approval":"PENDING"},
 {"num":101,"branch":"story/safe","ready_ts":100,"approval":"APPROVED"}]}
JSON
AUDIT3="$CASE/force-audit.log"
out="$(run_marshal MARSHAL_HOTFIX_PIN=100 MARSHAL_FORCE_AUDIT_LOG="$AUDIT3")"
assert_contains ML14 "pinned PR is processed at the head" "candidates n=2 order=100,101" "$out"
assert_contains ML14 "pinned RED hotfix fails the composed build" "kickback pr=100 reason=build-failed" "$out"
assert_not_contains ML14 "pin does NOT bypass the build gate — 100 not merged" "merge pr=100" "$out"
assert_eq       ML14 "only the green next-in-line merged" "101" "$(state_list merges)"
assert_contains ML14 "the pin was still recorded to the Force Audit" "pr=100" "$(cat "$AUDIT3" 2>/dev/null || true)"

# ---- ML15: build-status with trailing whitespace/CR still reads SUCCESSFUL ---
# A backend that emits "SUCCESSFUL \r\n" must not strand the queue in a forever-
# wait. The Marshal trims the status before matching.
mk_case
main_init 'foo\n' 'foo\n'
mk_branch story/noisy 'foo\n' 'foo\n__NOISY_OK__\n'
cat > "$STATE" <<JSON
{"trunk":"main","prs":[{"num":110,"branch":"story/noisy","ready_ts":100,"approval":"APPROVED"}]}
JSON
out="$(run_marshal)"
assert_contains ML15 "trailing-whitespace SUCCESSFUL is normalized" "build pr=110 sha=" "$out"
assert_contains ML15 "and the PR merges (not a permanent wait)" "merge pr=110" "$out"
assert_eq       ML15 "PR 110 recorded merged" "110" "$(state_list merges)"

# ---- ML13: green build but the merge CALL fails -> not reported merged -------
# Zero-trust in reverse: a merge that the host refuses must never be logged as a
# merge. The PR stays at the head for the next fire.
mk_case
main_init 'foo\nbar\n' 'foo\n'
mk_branch story/prot 'foo\nbar\n' 'foo\nbar\n'      # green
cat > "$STATE" <<JSON
{"trunk":"main","prs":[{"num":99,"branch":"story/prot","ready_ts":100,"approval":"APPROVED","fail_merge":true}]}
JSON
out="$(run_marshal)"
assert_contains ML13 "composed build was green" "build pr=99 sha=" "$out"
assert_contains ML13 "a refused merge is reported as failed, not merged" "merge pr=99 result=failed" "$out"
assert_not_contains ML13 "no success 'merge pr=99 strategy=' line" "merge pr=99 strategy=" "$out"
assert_eq       ML13 "nothing actually merged" "" "$(state_list merges)"
assert_contains ML13 "summary shows nothing merged" "done merged=none" "$out"

# ---- ML12: empty queue -> clean no-op ---------------------------------------
mk_case
main_init 'foo\n' 'foo\n'
cat > "$STATE" <<JSON
{"trunk":"main","prs":[]}
JSON
out="$(run_marshal)"
assert_contains ML12 "no candidates" "candidates n=0 order=none" "$out"
assert_contains ML12 "clean no-op summary" "done merged=none evicted=0 waited=none" "$out"

fi  # UV_OK

# ==============================================================================
# marshal.sh END-TO-END against the REAL github.sh backend (NOT the mock).
# ==============================================================================
# This is the production-path assertion that PR #18's Marshal mock hid (its P0):
# marshal.sh drives host.sh -> github.sh (the gh CLI), whose `pr-list-ready` was
# unimplemented on every real backend — so the loop could enumerate a queue ONLY
# against the mock. Here the loop runs unchanged against the real GitHub adapter,
# with a gh argv shim answering exactly the argv it drives. The origin bare repo
# lives at a path ENDING in github.com/acme/widget.git, so host.sh detects GITHUB
# and github.sh parses OWNER/REPO from `git remote get-url origin`, while all git
# transport stays local + hermetic (no network). If pr-list-ready regresses, the
# loop sees an empty queue and MG01/MG02 red — the assertion that would have
# caught the P0. Needs jq (the GitHub backend's dep), not uv.
GH_OK=1
if ! command -v jq >/dev/null 2>&1; then
  GH_OK=0
  echo "WARN: jq not found — github.sh backend e2e (MG*) SKIPPED (jq is required by the GitHub backend)" >&2
fi

if (( GH_OK )); then
echo "== marshal.sh e2e via the REAL github.sh backend (MG) =="

MGROOT="$SANDBOX/mg"
GBARE="$MGROOT/github.com/acme/widget.git"        # path shape drives GITHUB detection
mkdir -p "$MGROOT/github.com/acme"
git init -q --bare "$GBARE"
GWC="$MGROOT/wc"
git clone -q "$GBARE" "$GWC" 2>/dev/null
git -C "$GWC" config commit.gpgsign false
# main + two branches forked from it (both already-current: no rebase, no push).
( cd "$GWC" \
    && git commit -q --allow-empty -m init && git branch -M main && git push -q -u origin main \
    && git checkout -q -b story/a && git commit -q --allow-empty -m a && git push -q -u origin story/a \
    && git checkout -q main \
    && git checkout -q -b story/b && git commit -q --allow-empty -m b && git push -q -u origin story/b \
    && git checkout -q main )

# gh argv shim: pr-list-ready enumerates story/a (PR 10, later ready_ts) + story/b
# (PR 11, earlier ready_ts), both APPROVED + non-draft; head shas are the REAL
# branch tips (read from the bare repo). build-status is SUCCESSFUL for any sha;
# pr-merge / pr-comment succeed. Quoted heredoc — the bare path arrives via env.
MGSHIM="$MGROOT/ghshim"; mkdir -p "$MGSHIM"
cat > "$MGSHIM/gh" <<'SHIMEOF'
#!/usr/bin/env bash
set -u
BARE="${GH_SHIM_REPO:?}"
tip() { git --git-dir="$BARE" rev-parse "refs/heads/$1" 2>/dev/null; }
sub="${1:-}"; sub2="${2:-}"
case "$sub" in
  pr)
    case "$sub2" in
      list)
        printf '[{"number":10,"headRefName":"story/a","headRefOid":"%s","reviewDecision":"APPROVED","createdAt":"2026-07-05T10:00:00Z","isDraft":false},{"number":11,"headRefName":"story/b","headRefOid":"%s","reviewDecision":"APPROVED","createdAt":"2026-07-05T09:00:00Z","isDraft":false}]\n' "$(tip story/a)" "$(tip story/b)" ;;
      merge|comment) exit 0 ;;
      *) echo "mgshim: unhandled pr $sub2" >&2; exit 1 ;;
    esac ;;
  api)
    case "${2:-}" in
      graphql)                printf '{"data":{"repository":{"pullRequest":{"timelineItems":{"nodes":[]}}}}}\n' ;;
      repos/acme/widget)      printf '{"default_branch":"main"}\n' ;;
      */commits/*/status)     printf '{"state":"success","total_count":1,"statuses":[{"state":"success"}]}\n' ;;
      */commits/*/check-runs) printf '{"total_count":0,"check_runs":[]}\n' ;;
      *)                      printf '{}\n' ;;
    esac ;;
  *) echo "mgshim: unhandled $sub" >&2; exit 1 ;;
esac
SHIMEOF
chmod +x "$MGSHIM/gh"

mg_out="$( cd "$GWC" && PATH="$MGSHIM:$PATH" GH_SHIM_REPO="$GBARE" \
    MARSHAL_HOST="$ROOT/plugins/zero-trust/skills/autopilot/scripts/host.sh" \
    MARSHAL_BUILD_POLL_MAX=1 MARSHAL_BUILD_POLL_INTERVAL=0 \
    bash "$MARSHAL" 2>&1 )"
assert_contains MG01 "real github.sh pr-list-ready enumerates the queue (strict FIFO: 11 before 10)" "candidates n=2 order=11,10" "$mg_out"
assert_contains MG02 "the lower-ready_ts approved PR merges through the real backend" "merge pr=11" "$mg_out"
assert_not_contains MG02 "one PR in flight: PR 10 is not merged this pass" "merge pr=10" "$mg_out"
assert_contains MG03 "pass summary records the single real-backend merge" "done merged=11" "$mg_out"
fi  # GH_OK

# ==============================================================================
echo
echo "==============================="
echo "PASS=$PASS FAIL=$FAIL"
echo "==============================="
(( FAIL == 0 ))
