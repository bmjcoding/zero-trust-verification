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
# cksum of the round's VOLATILE-NORMALIZED, ORDER-INDEPENDENT failure skeleton.
# Normalization (see fingerprint()) drops volatile digits (durations, pass/fail
# counts, clock/date components) and `0x` addresses from every whitespace token
# EXCEPT a test NODE-ID token — one containing the `::` pytest/unittest node
# separator, e.g. `tests/test_auth.py::test_login[0]` — which is kept verbatim so
# its parametrize index survives. Blanket `tr -d '0-9'` (the pre-P2-a logic) erased
# that index, collapsing `test_login[0]`/`[1]` to one skeleton and false-greening a
# parametrized test that fails a different case index each round (AV3-12 / P2-a).
# Keying on the `::` token — NOT on brackets, which also hold volatile durations
# like `[123 ns]` — preserves the index without false-reddening a deterministic run
# whose output carries a bracketed number (AV3-12.9). Lines are sorted so a mere
# reordering of the SAME failure set (expected under the order-randomized round) is
# not mistaken for flake, while a changed failure SET — membership, incl. a
# pass/fail flip on a verbose line — still diverges. Output with no `::` token has
# every token digit-stripped, so a non-pytest runner keeps its prior all-digits-
# volatile signal. Any divergence across rounds -> `[BLOCKED: flaky-test]`.
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

# Volatile-normalize one round's output into a stable failure skeleton (reads
# stdin, writes stdout). Rule, applied per whitespace token:
#   - A NODE-ID token (contains `::`, the pytest/unittest node separator) is kept
#     VERBATIM — its parametrize index (`test_login[0]` vs `[1]`) identifies WHICH
#     case failed and must survive.
#   - Every OTHER token has its digits dropped (volatile durations, pass/fail
#     counts, clock/date components collapse to the same skeleton round to round).
# `0x<hex>` addresses are first folded to a digit-free token (`HEXADDR`) so their
# a-f letters can't survive the strip and false-diverge. Keying on `::` rather than
# on brackets is deliberate: a bracket may hold a duration (`[123 ns]`), so keeping
# all bracketed digits would false-RED a deterministic run (P2-a regression, guarded
# by AV3-12.9). bash 3.2 + BSD/macOS awk safe: assigning `$0` (via the bare gsub)
# re-splits the fields; no interval quantifiers, no `\b`, no GNU-only extensions.
_dg_normalize() {
  awk '
    {
      gsub(/0[xX][0-9A-Fa-f]+/, "HEXADDR")
      out = ""
      for (i = 1; i <= NF; i++) {
        tok = $i
        if (index(tok, "::") == 0) gsub(/[0-9]/, "", tok)
        out = (i == 1 ? tok : out " " tok)
      }
      print out
    }
  '
}

# Per-round signature = "<exit>:<cksum of the sorted normalized skeleton>". The sort
# makes the skeleton the SET of (normalized) output lines — order-independent,
# matching "the set of failing test node ids"; the exit code guards the pass/fail
# boundary itself.
fingerprint() {  # <exit> <output>
  local ck
  ck="$(printf '%s' "$2" | _dg_normalize | LC_ALL=C sort | cksum | awk '{print $1}')"
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
