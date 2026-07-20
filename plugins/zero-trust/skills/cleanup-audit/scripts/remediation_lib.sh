#!/usr/bin/env bash
# remediation_lib.sh — shared helpers for the remediation-loop bridge scripts
# (RL-01..RL-12, ADR 0017/0018). Sourced, never executed.
#
# The loop is WIRING (ADR 0017): these helpers do string routing and JSON I/O
# over an ALREADY-COMPUTED audit/state.json. They run NO detector, NO mutation
# tool, and NO whole-repo scan (RL-12 / loop-safety invariant 1).
#
# Portability: bash 3.2 (macOS default) + BSD userland safe. No associative
# arrays; empty-array expansion guarded as ${arr[@]+"${arr[@]}"}; no `\b` in sed.

# Directory of the sourcing script's siblings (this file's own dir).
RL_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RL_STATE_PY="$RL_SCRIPTS_DIR/remediation_state.py"
RL_PROVENANCE_TSV="$RL_SCRIPTS_DIR/slug_provenance.tsv"

# uv-first Python, ADR 0015 build discipline: `uv run --no-project` gives a
# hermetic interpreter WITHOUT syncing any project's deps (the backend is
# stdlib-only). Fall back to an ambient python3 where uv is absent. The
# bootstrap is the plugin's shared _py_run.sh (ADR 0025 Wave 4); pwd -P so a
# skills-dir symlinked install (ADR 0027) still resolves into the clone.
. "$(cd "$RL_SCRIPTS_DIR" && pwd -P)/../../../scripts/_py_run.sh"
rl_pyrun() { py_run_noproj "$@"; }

# Read the severity floor from a remediation.config.yaml (`severity_floor:`),
# defaulting to HIGH. Deliberately a one-line grep, not a YAML parser: the loop
# owns no config schema (ADR 0017 — no new opinion). Unknown/empty → HIGH.
rl_severity_floor() {  # <config-path-or-empty>
  local cfg="${1:-}" v=""
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    v="$(grep -E '^[[:space:]]*severity_floor:' "$cfg" 2>/dev/null | head -1 \
         | sed -E 's/^[[:space:]]*severity_floor:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]"'"'"']//g')"
  fi
  case "$v" in
    CRITICAL|HIGH|MED|LOW) printf '%s' "$v" ;;
    *) printf 'HIGH' ;;
  esac
}

# Severity rank for floor comparison (higher = more severe). Unknown → 0 so an
# unrecognized severity never clears a floor (fail-safe toward inaction).
rl_sev_rank() {  # <severity>
  case "$1" in
    CRITICAL) echo 4 ;;
    HIGH)     echo 3 ;;
    MED|MEDIUM) echo 2 ;;
    LOW)      echo 1 ;;
    *)        echo 0 ;;
  esac
}
