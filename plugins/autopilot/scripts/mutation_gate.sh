#!/usr/bin/env bash
# mutation_gate.sh
#
# DRAIN Step D6.5 anti-vacuous gate (ADR 0016 / MT-02, MT-03, MT-07, MT-08).
# Complement to the D6.4 N=5 anti-flaky gate: D6.4 catches a test that passes for
# the wrong reason (nondeterminism); D6.5 catches a test that passes for NO reason
# (vacuity). A survived mutant on a line THIS Subtask changed is deterministic
# proof a test executes that line and constrains nothing — coverage theater.
#
# RUNNER-AGNOSTIC, like determinism_gate.sh: it takes the ALREADY-RESOLVED mutation
# command (the orchestrator resolves `gates.test_mutation` with {files} = the
# Subtask's changed product files) plus the tool NAME (for the survivor→location
# resolver, mutation_adapter.sh). It runs the tool, normalizes survivors, and
# filters them to the changed LINES of `prev_pushed_sha..HEAD` (the range D6.2
# audits). A survivor on a changed line → `[BLOCKED: vacuous-test]`.
#
# ISOLATION (loop-safety invariant 1 — probes never mutate operator-visible state):
# a mutation tool rewrites source on disk, so D6.5 must NEVER run on the live Story
# checkout. It runs inside an EXPLICIT `git worktree add <throwaway> HEAD` torn down
# by an EXIT/INT/TERM trap (`git worktree remove --force`), modeled on
# repo_shape_probe.sh's trap discipline and gated behind a clean-index precheck.
# The live checkout is never touched — even on injected mid-run failure.
#
# BUDGET (MT-07): honors `--max-mutants` (default 40) and `--max-seconds` (default
# 120). Exceeding either → `[note] mutation-budget-exhausted — partial (N of M)`,
# exit 0, NEVER a false `[BLOCKED]` (inconclusive ≠ survivor — the D6.4
# skipped-randomization honesty). Defaults are agent-decided (reversible).
#
# DEGRADE (MT-08): no tool for the language, `gates.test_mutation` omitted, or an
# unsupported tool → SKIP with a loud stderr `[note] no mutation tool for <lang> —
# D6.5 anti-vacuous gate skipped (optional)`, exit 0 — like D6.4 skipping the
# order-randomized round. The skip is visible, never silent. A file-granular
# survivor (a tool with no line resolver, e.g. go-mutesting) cannot be pinned to a
# changed line, so it is comment-only, never a block (MT-05 degrade).
#
# Usage:
#   mutation_gate.sh --tool <stryker|cargo-mutants|mutmut|go-mutesting> \
#       --run-cmd '<resolved gates.test_mutation for {files}>' \
#       --base <prev_pushed_sha-or-origin/<trunk>> \
#       [--files '<changed product files>'] [--lang <label>] \
#       [--max-mutants <n>] [--max-seconds <s>]
# Output: `NON-VACUOUS (…)` exit 0 · `[BLOCKED: vacuous-test] <detail>` exit 1 ·
#         skip/partial `[note]` exit 0 · clean-index refuse / usage exit 64.
#
# Portability: bash 3.2 + BSD userland safe. No `timeout` (absent on stock macOS);
# the wall-clock budget uses a background job + poll + process-group kill.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="$HERE/mutation_adapter.sh"

TOOL=""; RUN_CMD=""; BASE=""; FILES=""; LANG_LABEL=""
MAX_MUTANTS=40; MAX_SECONDS=120

usage() { echo "usage: mutation_gate.sh --tool <t> --run-cmd '<cmd>' --base <ref> [--files '<f…>'] [--lang <l>] [--max-mutants <n>] [--max-seconds <s>]" >&2; exit 64; }

while (( $# )); do
  case "$1" in
    --tool)        TOOL="${2:-}"; shift 2 || usage ;;
    --run-cmd)     RUN_CMD="${2:-}"; shift 2 || usage ;;
    --base)        BASE="${2:-}"; shift 2 || usage ;;
    --files)       FILES="${2:-}"; shift 2 || usage ;;
    --lang)        LANG_LABEL="${2:-}"; shift 2 || usage ;;
    --max-mutants) MAX_MUTANTS="${2:-}"; shift 2 || usage ;;
    --max-seconds) MAX_SECONDS="${2:-}"; shift 2 || usage ;;
    -h|--help)     awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) usage ;;
  esac
done

case "$MAX_MUTANTS" in ''|*[!0-9]*) usage ;; esac
case "$MAX_SECONDS" in ''|*[!0-9]*) usage ;; esac
[ -x "$ADAPTER" ] || { echo "[note] mutation-gate: mutation_adapter.sh not found beside this script — D6.5 skipped" >&2; exit 0; }

supported_tool() { case "$1" in stryker|cargo-mutants|mutmut|go-mutesting) return 0 ;; *) return 1 ;; esac; }

# ── MT-08 graceful degrade: no tool / no command / unsupported tool → SKIP loud ─
lbl="${LANG_LABEL:-the configured language}"
if [ -z "$TOOL" ] || [ -z "$RUN_CMD" ]; then
  echo "[note] no mutation tool for $lbl — D6.5 anti-vacuous gate skipped (optional)" >&2
  exit 0
fi
if ! supported_tool "$TOOL"; then
  echo "[note] no mutation tool for $lbl — D6.5 anti-vacuous gate skipped (optional) (tool '$TOOL' has no adapter)" >&2
  exit 0
fi
[ -n "$BASE" ] || usage

# ── Repo sanity + clean-index precheck (MT-02) ────────────────────────────────
# Refuse when TRACKED files have uncommitted (staged or unstaged) changes: the
# throwaway is checked out at HEAD, so a divergent tracked working tree means D6.5
# would gate a state the operator has not committed. UNTRACKED artifacts (coverage
# files, __pycache__, node_modules) are common at D6.5 and never reach the
# HEAD-based throwaway, so they do NOT trip the precheck (loop-safety invariant 1).
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "[note] mutation-gate: not inside a git repo — D6.5 skipped" >&2; exit 0; }
if ! git diff --quiet HEAD 2>/dev/null; then
  echo "[note] mutation-gate: clean-index precheck FAILED — tracked files have uncommitted changes; refusing (loop-safety invariant 1: the live checkout is never mutated). Commit or stash first." >&2
  exit 64
fi

# ── Throwaway worktree + teardown trap (MT-02) ────────────────────────────────
WT_PARENT="$(mktemp -d 2>/dev/null)" || { echo "[note] mutation-gate: mktemp failed — D6.5 skipped" >&2; exit 0; }
WT="$WT_PARENT/mut-wt"
_cleanup() {
  # Best-effort; NEVER fail the gate from cleanup. Force-remove the throwaway
  # worktree and prune the admin entry so the live tree is left pristine.
  git worktree remove --force "$WT" >/dev/null 2>&1 || true
  rm -rf "$WT_PARENT" >/dev/null 2>&1 || true
  git worktree prune >/dev/null 2>&1 || true
}
trap _cleanup EXIT INT TERM

if ! git worktree add --detach --quiet "$WT" HEAD >/dev/null 2>&1; then
  echo "[note] mutation-gate: 'git worktree add' failed — D6.5 skipped (inconclusive, no block)" >&2
  exit 0
fi
echo "[note] mutation-gate: isolated throwaway worktree $WT (live checkout is never mutated)" >&2

# ── Run the resolved tool INSIDE the throwaway, under the wall-clock budget ────
RAW="$WT_PARENT/raw.out"
: > "$RAW"
set -m 2>/dev/null || true                 # each bg job → its own process group (portable group-kill)
( cd "$WT" && eval "$RUN_CMD" ) > "$RAW" 2>/dev/null &
run_pid=$!
set +m 2>/dev/null || true
elapsed=0; timed_out=0
while kill -0 "$run_pid" 2>/dev/null; do
  sleep 1
  elapsed=$((elapsed + 1))
  if [ "$elapsed" -ge "$MAX_SECONDS" ]; then
    kill -TERM -"$run_pid" 2>/dev/null || kill -TERM "$run_pid" 2>/dev/null || true
    sleep 1
    kill -KILL -"$run_pid" 2>/dev/null || kill -KILL "$run_pid" 2>/dev/null || true
    timed_out=1
    break
  fi
done
wait "$run_pid" 2>/dev/null; run_rc=$?

# ── MT-07 budget: time OR mutant cap → partial [note], exit 0, never a block ───
if [ "$timed_out" -eq 1 ]; then
  echo "[note] mutation-budget-exhausted — partial (? of ?; timed out after ${MAX_SECONDS}s of max_mutation_seconds) — D6.5 inconclusive, not blocking (inconclusive != survivor)"
  exit 0
fi
total="$(bash "$ADAPTER" count "$TOOL" < "$RAW" 2>/dev/null | head -1)"
case "$total" in ''|*[!0-9]*) total=0 ;; esac
if [ "$MAX_MUTANTS" -gt 0 ] && [ "$total" -ge "$MAX_MUTANTS" ]; then
  echo "[note] mutation-budget-exhausted — partial ($MAX_MUTANTS of $total) — D6.5 inconclusive, not blocking (inconclusive != survivor)"
  exit 0
fi

# A crashed tool (no output AND non-zero exit) is inconclusive, never a block.
# NOTE: a non-zero exit alone is NOT a crash — cargo-mutants exits non-zero WHEN
# mutants survive; the survivor SET (below), not the exit code, is the verdict.
survivors="$(bash "$ADAPTER" normalize "$TOOL" < "$RAW" 2>/dev/null)"
if [ -z "$survivors" ] && [ "$run_rc" -ne 0 ]; then
  echo "[note] mutation-gate: tool exited rc=$run_rc with no parseable survivors — D6.5 inconclusive, not blocking"
  exit 0
fi
if [ -z "$survivors" ]; then
  echo "NON-VACUOUS ($total mutants, 0 survivors)"
  exit 0
fi

# ── MT-03/MT-05: filter survivors to the changed LINES of BASE..HEAD ───────────
if ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1; then
  echo "[note] mutation-gate: cannot resolve --base '$BASE' — cannot scope to changed lines, D6.5 inconclusive (not blocking)" >&2
  exit 0
fi
# added lines in BASE..HEAD (the D6.2 range), scoped to --files when given.
changed_set="$(git diff -U0 "$BASE" HEAD -- $FILES 2>/dev/null \
  | awk '/^\+\+\+ b\//{f=substr($0,7)} /^@@/{split($3,a,","); ln=substr(a[1],2)+0} /^\+[^+]/{printf "%s:%s\n", f, ln; ln++}')"

blocked=""; degraded=""
while IFS= read -r s; do
  [ -n "$s" ] || continue
  case "$s" in
    *:-)
      # file-granular (no line): cannot pin to a changed line → comment-only.
      degraded="${degraded}${s} (file-granular; cannot be pinned to a changed line)
" ;;
    *)
      if printf '%s\n' "$changed_set" | grep -qxF "$s"; then
        blocked="${blocked}${s}
"
      fi
      # a survivor off the changed lines is inherited debt — the ratchet never
      # blocks on it (ADR 0004). Silently skipped.
      ;;
  esac
done <<SURV
$survivors
SURV

if [ -n "$blocked" ]; then
  echo "[BLOCKED: vacuous-test] survived mutant(s) on line(s) this Subtask changed — a test executes the line but constrains nothing (strengthen the assertion; do NOT delete the product code — that trips D6.2 tdd-scope-leak):"
  printf '%s' "$blocked" | sed 's/^/    /'
  if [ -n "$degraded" ]; then
    echo "[note] additional file-granular survivor(s) (comment-only, not part of the block):"
    printf '%s' "$degraded" | sed 's/^/    /'
  fi
  exit 1
fi

if [ -n "$degraded" ]; then
  echo "[note] mutation-gate: file-granular survivor(s) could not be pinned to a changed line (comment-only, D6.5 not blocking — the line filter is post-hoc for file-granular tools, MT-05):"
  printf '%s' "$degraded" | sed 's/^/    /'
fi
echo "NON-VACUOUS ($total mutants, no survivor on a changed line)"
exit 0
