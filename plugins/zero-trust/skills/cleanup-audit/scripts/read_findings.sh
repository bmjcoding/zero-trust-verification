#!/usr/bin/env bash
# RL-01 — Finding-stream reader (ADR 0017 step 1; loop-safety invariant 1).
#
# Emits ONE normalized record per OPEN finding from an ALREADY-COMPUTED
# audit/state.json (v2), and/or a CAPTURED pr_gate.sh run — TAB-separated:
#
#   fingerprint <TAB> severity <TAB> slug <TAB> path <TAB> symbol <TAB> status <TAB> remediation_status
#
# HARDENED (Defect A): there is NO `expected_by` column. That field lives only in
# the fixture EXPECTED_FINDINGS.yaml, never in runtime state (VERIFIED). Provenance
# is derived downstream from the slug (RL-02 / finding_eligible.sh), never read
# here as a stored field.
#
# Pure READER (mirrors pr_gate.sh's reporter-only posture): it NEVER writes state,
# NEVER re-runs the audit, NEVER walks a journey, NEVER runs a detector or a
# mutation tool. It reads the tiers' already-bounded output and executes nothing.
#
# Degrade (invariant 4): missing/corrupt/unknown-schema state → emit NOTHING plus a
# loud `[note]` on stderr, exit 0. Never a crash, never a guessed row.
#
# Usage:  read_findings.sh <state.json> [--from-pr-gate <captured_pr_gate_output>]
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remediation_lib.sh"

STATE=""; FROM_PR_GATE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from-pr-gate) FROM_PR_GATE="${2:-}"; shift 2 ;;
    -*) echo "read_findings: unknown flag: $1" >&2; exit 64 ;;
    *)  if [ -z "$STATE" ]; then STATE="$1"; else echo "read_findings: unexpected arg: $1" >&2; exit 64; fi; shift ;;
  esac
done
[ -n "$STATE" ] || { echo "usage: read_findings.sh <state.json> [--from-pr-gate <file>]" >&2; exit 64; }

if [ -n "$FROM_PR_GATE" ]; then
  rl_pyrun "$RL_STATE_PY" read "$STATE" --from-pr-gate "$FROM_PR_GATE"
else
  rl_pyrun "$RL_STATE_PY" read "$STATE"
fi
