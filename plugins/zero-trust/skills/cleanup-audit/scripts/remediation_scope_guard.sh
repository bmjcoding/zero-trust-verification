#!/usr/bin/env bash
# RL-12 — Loop-safety scope guard (loop-safety invariant 1; ADR 0017; the user's
# explicit attack: "it MUST NOT run whole-repo").
#
# Loop-safety invariant 1: "Mutation-testing tools mutate the working tree, so no
# command, agent, or script ever runs one — their pre-existing reports are ingested
# like coverage", and probes are "never the whole suite". The remediation loop
# therefore adds ZERO new probe/execution surface: its only compute is deterministic
# string routing over an ALREADY-COMPUTED state file.
#
# This guard grep-asserts, over the loop's CODE paths, that:
#   (a) NO mutation-testing tool is invoked (mutmut|cosmic-ray|stryker|pitest|
#       cargo-mutants) under ANY loop path — mutation findings enter ONLY as
#       pre-existing ingested reports via the normal audit stream (RL-01);
#   (b) NO whole-repo `run_audit.sh` call exists in any loop path — the loop reads
#       the already-computed state.json, never re-executing detection.
#
# Scans loop SCRIPTS (.sh/.py) only — prose docs legitimately NAME these tools to
# say the loop forbids them; code is where an invocation would live. This guard
# excludes ITSELF (it defines the forbidden patterns). Non-vacuous: the self-test
# red-tests it by planting an invocation into a copied loop script.
#
# Usage:  remediation_scope_guard.sh [--dir <loop-scripts-dir>]
# Exit:   0 clean · 1 a forbidden invocation found (each printed).
set -uo pipefail

RL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN_DIR="$RL_DIR"
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) SCAN_DIR="${2:-}"; shift 2 ;;
    *) echo "remediation_scope_guard: unknown arg: $1" >&2; exit 64 ;;
  esac
done

# The loop's own code files (RL-01..RL-11 substrate). The guard itself is excluded
# — it is the one file that legitimately contains the forbidden token strings.
LOOP_FILES="read_findings.sh finding_eligible.sh classify_fix.sh remediation_route.sh remediation_depth.sh already_filed.sh remediation_stamp.sh build_register.sh remediation_lib.sh remediation_state.py"

MUT_RE='(^|[^A-Za-z0-9_.-])(mutmut|cosmic-ray|stryker|pitest|cargo-mutants)([^A-Za-z0-9_.-]|$)'
AUDIT_RE='run_audit\.sh'

fail=0
for f in $LOOP_FILES; do
  p="$SCAN_DIR/$f"
  [ -f "$p" ] || continue
  if grep -nEi "$MUT_RE" "$p" >/dev/null 2>&1; then
    echo "SCOPE-VIOLATION [mutation-tool] $f invokes/names a mutation-testing tool (loop-safety invariant 1 — mutation reports are INGESTED, never run):" >&2
    grep -nEi "$MUT_RE" "$p" | sed 's/^/    /' >&2
    fail=1
  fi
  if grep -nE "$AUDIT_RE" "$p" >/dev/null 2>&1; then
    echo "SCOPE-VIOLATION [whole-repo] $f calls run_audit.sh (the loop reads the already-computed state.json; it runs NO whole-repo scan — RL-12):" >&2
    grep -nE "$AUDIT_RE" "$p" | sed 's/^/    /' >&2
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "scope-guard ok: loop code paths invoke no mutation tool and no whole-repo run_audit (RL-12 / invariant 1)"
fi
exit "$fail"
