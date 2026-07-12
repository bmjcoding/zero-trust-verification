#!/usr/bin/env bash
# wave_gate.sh — /health-loop wave-advance gate (ADR 0024). Thin wrapper over
# wave_gate.py; see that file for the full contract.
#
# Pure READER of audit/state.json — never writes it, never runs a detector,
# never re-grades a /verify verdict (loop-safety invariants 1/7; pinned by a
# scope-guard grep in the self-test, the remediation_scope_guard.sh precedent).
#
# Usage:  wave_gate.sh <state.json> <fingerprint-list-file>
# Exit:   0 ADVANCE · 2 INCOMPLETE · 3 REGRESSION/RATCHET · 4 UNREADABLE · 64 usage
#
# Portability: bash 3.2 + BSD userland safe.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remediation_lib.sh"

[ $# -eq 2 ] || { echo "usage: wave_gate.sh <state.json> <fingerprint-list-file>" >&2; exit 64; }

rl_pyrun "$RL_SCRIPTS_DIR/wave_gate.py" "$1" "$2"
