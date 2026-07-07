#!/usr/bin/env bash
# RL-05 — Router: per eligible finding → DRAIN | ESCALATE | SKIP:<reason>.
#
# Composes the deterministic pieces into ONE verdict, in precedence order:
#   1. Guard 1 (already_filed.sh)      — an open/WONTFIX record → SKIP:already-filed
#      (idempotency wins over everything; never re-file — ADR 0018 Guard 1)
#   2. RL-02 (finding_eligible.sh)     — INELIGIBLE → SKIP:<eligibility-reason>
#   3. Guard 2 (remediation_depth.sh)  — depth>=1 (or unknown) → ESCALATE
#      regardless of slug class (a fix-of-a-fix surfaces to a human)
#   4. RL-03 (classify_fix.sh)         — DRAIN (reversible+gate-verifiable) else ESCALATE
#
# DETERMINISTIC COMPOSITION ONLY — NO LLM judgment in the router (ADR 0017). Every
# branch is a deterministic sibling call; the orchestrator (/remediate) acts on
# the verdict, this script decides nothing by opinion.
#
# Usage:
#   remediation_route.sh --fingerprint FP --severity SEV --slug SLUG --state STATE
#                        [--branch BR] [--self-namespace NS] [--config CFG]
# Output: one of DRAIN | ESCALATE | SKIP:<reason>  (exit 0)
set -uo pipefail

RL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FP=""; SEV=""; SLUG=""; STATE=""; BRANCH=""; SELF_NS="remediation/"; CONFIG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fingerprint)    FP="${2:-}"; shift 2 ;;
    --severity)       SEV="${2:-}"; shift 2 ;;
    --slug)           SLUG="${2:-}"; shift 2 ;;
    --state)          STATE="${2:-}"; shift 2 ;;
    --branch)         BRANCH="${2:-}"; shift 2 ;;
    --self-namespace) SELF_NS="${2:-}"; shift 2 ;;
    --config)         CONFIG="${2:-}"; shift 2 ;;
    *) echo "remediation_route: unknown arg: $1" >&2; exit 64 ;;
  esac
done
[ -n "$SLUG" ] && [ -n "$SEV" ] || { echo "usage: remediation_route.sh --fingerprint FP --severity SEV --slug SLUG --state STATE [--branch BR] [--self-namespace NS] [--config CFG]" >&2; exit 64; }

# 1. Guard 1 — idempotency wins over everything (never re-file).
if [ -n "$FP" ] && [ -n "$STATE" ]; then
  filed="$(bash "$RL_DIR/already_filed.sh" "$FP" "$STATE" 2>/dev/null | head -1)"
  case "$filed" in FILED*) echo "SKIP:already-filed"; exit 0 ;; esac
fi

# 2. RL-02 — eligibility (severity floor ∧ deterministic provenance).
elig="$(bash "$RL_DIR/finding_eligible.sh" --severity "$SEV" --slug "$SLUG" ${CONFIG:+--config "$CONFIG"} 2>/dev/null | head -1)"
case "$elig" in
  ELIGIBLE) : ;;
  INELIGIBLE:*) echo "SKIP:${elig#INELIGIBLE:}"; exit 0 ;;
  *) echo "SKIP:ineligibility-indeterminate"; exit 0 ;;   # fail-safe
esac

# 3. Guard 2 — depth ceiling. A finding on the loop's own namespace escalates
#    regardless of class; an undetermined depth also escalates (fail-safe).
depth="0"
if [ -n "$BRANCH" ]; then
  d="$(bash "$RL_DIR/remediation_depth.sh" --branch "$BRANCH" --self-namespace "$SELF_NS" 2>/dev/null | sed -n 's/^depth=//p' | head -1)"
  [ -n "$d" ] && depth="$d"
fi
case "$depth" in
  0) : ;;
  unknown) echo "ESCALATE"; exit 0 ;;
  *) echo "ESCALATE"; exit 0 ;;   # depth >= 1 (Guard 2)
esac

# 4. RL-03 — classify the FIX.
class="$(bash "$RL_DIR/classify_fix.sh" "$SLUG" 2>/dev/null | head -1)"
case "$class" in
  DRAIN)    echo "DRAIN" ;;
  ESCALATE) echo "ESCALATE" ;;
  *)        echo "ESCALATE" ;;    # fail-safe
esac
exit 0
