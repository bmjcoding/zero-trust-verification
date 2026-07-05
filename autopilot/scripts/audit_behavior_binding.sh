#!/usr/bin/env bash
# audit_behavior_binding.sh
#
# DRAIN Step D6 Behavior-ID -> test-ID binding audit (MS §13.9/§13.11 / AV3-05).
# The manifest declares Behavior intent; the planner maps each Subtask to
# Behavior IDs (AV3-02); the implementer writes tests. D6 must VERIFY — from the
# git log, not the implementer's self-report — that each mapped Behavior is
# actually bound to a real test: a `test: <id>.<n> RED` commit in the Subtask's
# range must NAME the bound test. D7.3 then publishes the mapping as a grep-able
# `## Behavior coverage` PR-body section; D7.4 mirrors it to the tracker.
#
# The coverage file is that section's content — one line per Behavior:
#     - B-pricing-001: tests/test_pricing.py::test_rejects_expired_lock
#     - B-pricing-002: tests/test_pricing.py::test_a, tests/test_pricing.py::test_b
# (Behavior ID, then >=1 comma-separated pytest-style node IDs.)
#
# For each Behavior, every bound test's function name (the token after the last
# `::`) MUST appear in a `test: ... RED` commit subject/body within <base>..HEAD.
# That is the "RED commit naming a bound test per behavior" evidence.
#
# Usage:  audit_behavior_binding.sh --coverage <file> --base <base-ref>
# Output: OK (exit 0), or a `[BLOCKED: <reason>] <detail>` line + exit 1:
#   unbound-behavior   <B-id>            (no test node IDs mapped)
#   unproven-binding   <B-id> <test>     (bound test not named in any RED commit)
# Exit 64 usage.
#
# Portability: bash 3.2 + BSD userland safe.

set -u

COVERAGE=""
BASE=""

usage() { echo "usage: audit_behavior_binding.sh --coverage <file> --base <base-ref>" >&2; exit 64; }

while (( $# )); do
  case "$1" in
    --coverage) COVERAGE="${2:-}"; shift 2 || usage ;;
    --base)     BASE="${2:-}"; shift 2 || usage ;;
    *) usage ;;
  esac
done

[[ -n "$COVERAGE" && -n "$BASE" ]] || usage
[[ -f "$COVERAGE" ]] || { echo "audit_behavior_binding: coverage not found: $COVERAGE" >&2; exit 64; }
git rev-parse --verify -q HEAD >/dev/null 2>&1 || { echo "audit_behavior_binding: no HEAD" >&2; exit 64; }
git rev-parse --verify -q "$BASE^{commit}" >/dev/null 2>&1 || { echo "audit_behavior_binding: base ref not found: $BASE" >&2; exit 64; }

block() { echo "[BLOCKED: $1] $2"; exit 1; }

# Gather the text (subject + body) of every `test: ... RED` commit in range.
reds_text=""
for h in $(git log --reverse --pretty=format:'%H' "${BASE}..HEAD" 2>/dev/null); do
  subj="$(git log -1 --pretty=format:'%s' "$h")"
  case "$subj" in
    test:*RED*) reds_text="$reds_text
$(git log -1 --pretty=format:'%s%n%b' "$h")" ;;
  esac
done

# Walk the coverage lines: `- <B-id>: node1, node2, ...`
while IFS= read -r line; do
  # Only `- B-...:` coverage rows.
  case "$line" in
    *-\ B-*:*|*"- B-"*:*) : ;;
    *) continue ;;
  esac
  bid="$(printf '%s' "$line" | sed -n 's/^[[:space:]]*-[[:space:]]*\(B-[A-Za-z0-9-]*\):.*/\1/p')"
  [[ -z "$bid" ]] && continue
  nodes="$(printf '%s' "$line" | sed 's/^[[:space:]]*-[[:space:]]*B-[A-Za-z0-9-]*:[[:space:]]*//')"

  # No mapped tests -> unbound.
  case "$nodes" in ''|*[![:space:]]*) : ;; esac
  if [[ -z "${nodes// }" ]]; then block unbound-behavior "$bid"; fi

  had_one=0
  oldIFS="$IFS"; IFS=','
  for node in $nodes; do
    node="${node# }"; node="${node% }"
    [[ -z "$node" ]] && continue
    had_one=1
    # Test function name = token after the last "::" (or the whole node).
    fn="${node##*::}"
    grep -qF -- "$fn" <<<"$reds_text" || { IFS="$oldIFS"; block unproven-binding "$bid $fn"; }
  done
  IFS="$oldIFS"
  (( had_one )) || block unbound-behavior "$bid"
done < "$COVERAGE"

echo "OK"
exit 0
