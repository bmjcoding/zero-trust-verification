#!/usr/bin/env bash
# determinism_gate.sh
#
# DRAIN Step D6 closing-test determinism gate (AV3-12). A flaky test trains the
# loop to ignore red, so before a Subtask's tests are trusted D6 runs them N times
# (default 5) and requires every round to agree. RUNNER-AGNOSTIC: it takes the
# already-resolved test command (the orchestrator resolves `gates.test_scoped`
# with {paths} = the Subtask's test files) and compares the rounds' exit codes AND
# failure fingerprints — it never parses a specific runner's output.
#
# One round is ORDER-RANDOMIZED via the resolved `gates.test_random` command
# (`--random-cmd`). When the repo has no randomization mechanism (no
# gates.test_random), that round is SKIPPED with a loud `[note]` on stderr —
# never silently (a silent skip would claim order-independence it never checked).
#
# Determinism signal per round: (exit_code, fingerprint) where fingerprint =
# cksum of the output with digits stripped — so volatile durations / pass-counts
# (all digits) don't matter, but a different set of failing test NAMES does. Any
# divergence across rounds -> `[BLOCKED: flaky-test]`.
#
# Usage:
#   determinism_gate.sh --cmd '<resolved test command>' \
#       [--random-cmd '<resolved order-randomized command>'] [--runs <n>]
# Output: `DETERMINISTIC (<n> rounds)` exit 0 · `[BLOCKED: flaky-test] <detail>`
#         exit 1 · usage exit 64. The skipped-randomization `[note]` is on stderr.
#
# Portability: bash 3.2 + BSD userland safe (cksum is POSIX).

set -u

CMD=""
RANDCMD=""
RUNS=5

usage() { echo "usage: determinism_gate.sh --cmd '<command>' [--random-cmd '<command>'] [--runs <n>]" >&2; exit 64; }

while (( $# )); do
  case "$1" in
    --cmd)        CMD="${2:-}"; shift 2 || usage ;;
    --random-cmd) RANDCMD="${2:-}"; shift 2 || usage ;;
    --runs)       RUNS="${2:-}"; shift 2 || usage ;;
    *) usage ;;
  esac
done

[[ -n "$CMD" ]] || usage
case "$RUNS" in ''|*[!0-9]*) usage ;; esac
(( RUNS >= 2 )) || { echo "determinism_gate: --runs must be >= 2" >&2; exit 64; }

# Per-round signature = "<exit>:<digit-stripped-output-cksum>".
fingerprint() {  # <exit> <output>
  local ck
  ck="$(printf '%s' "$2" | tr -d '0-9' | cksum | awk '{print $1}')"
  printf '%s:%s' "$1" "$ck"
}

first_sig=""
divergent_round=""
# The LAST round is the order-randomized one.
for (( i=1; i<=RUNS; i++ )); do
  if (( i == RUNS )); then
    if [[ -n "$RANDCMD" ]]; then
      run_cmd="$RANDCMD"
    else
      echo "[note] no test randomization mechanism (gates.test_random unset) — order-randomized round SKIPPED (ran the scoped command again instead)" >&2
      run_cmd="$CMD"
    fi
  else
    run_cmd="$CMD"
  fi

  out="$(bash -c "$run_cmd" 2>&1)"; ec=$?
  sig="$(fingerprint "$ec" "$out")"
  if [[ -z "$first_sig" ]]; then
    first_sig="$sig"
  elif [[ "$sig" != "$first_sig" ]]; then
    divergent_round="$i"
    echo "[BLOCKED: flaky-test] round $i diverged (sig $sig != round-1 sig $first_sig)"
    break
  fi
done

[[ -z "$divergent_round" ]] || exit 1
echo "DETERMINISTIC ($RUNS rounds)"
exit 0
