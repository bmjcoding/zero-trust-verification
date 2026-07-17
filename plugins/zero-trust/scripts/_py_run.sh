#!/usr/bin/env bash
# _py_run.sh — the plugin's ONE sourced uv bootstrap (ADR 0015; ADR 0025 Wave 4).
#
# The "find the nearest pyproject.toml and route Python through uv" dance was
# previously re-implemented in _owm_run.sh, _triage_run.sh, mock_host.sh,
# validate_manifest.sh, and three --no-project runners under
# skills/cleanup-audit/scripts. This file is the single copy; every sourcing
# file keeps its exact CLI contract (same exit codes; the per-domain
# neither-uv-nor-python3 stderr text comes from PY_RUN_DIE_MSG, a plain shell
# variable the sourcing file sets).
#
# NOTE: skills/cleanup-audit/scripts/py_run.sh is NOT this file and stays
# separate — it pins `uv run --project` for TARGET-repo audits (documented
# there; the plugin-pinned variant differs for a reason).
#
# Portability: bash 3.2 (macOS default) + BSD userland safe.
if [ -n "${PY_RUN_LOADED:-}" ]; then return 0; fi
PY_RUN_LOADED=1

# py_run_find_project <start-dir> — print the nearest ancestor dir (inclusive)
# containing pyproject.toml (the uv project root); status 1 when none.
py_run_find_project() {
  local d="$1"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    if [ -f "$d/pyproject.toml" ]; then printf '%s\n' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

# the sourcing file's neither-uv-nor-python3 message (69 = EX_UNAVAILABLE,
# the ADR 0015 substrate contract).
_py_run_msg() { printf '%s\n' "${PY_RUN_DIE_MSG:-py_run: neither uv (with pyproject) nor python3 available (ADR 0015)}" >&2; }

# py_run_exec <project> <script> [args...] — REPLACE the process: `uv run
# --project` when uv and the project are available, else an ambient python3
# that already carries the deps, else the die message + exit 69.
py_run_exec() {
  local proj="$1" script="$2"; shift 2
  if command -v uv >/dev/null 2>&1 && [ -n "$proj" ] && [ -f "$proj/pyproject.toml" ]; then
    exec uv run --project "$proj" python "$script" "$@"
  fi
  local py
  py="$(command -v python3 || true)"
  if [ -z "${py:-}" ]; then _py_run_msg; exit 69; fi
  exec "$py" "$script" "$@"
}

# py_run_call <project> <script> [args...] — same resolution as py_run_exec
# but RETURNS the script's rc (69 on the die path) instead of exec'ing.
py_run_call() {
  local proj="$1" script="$2"; shift 2
  if command -v uv >/dev/null 2>&1 && [ -n "$proj" ] && [ -f "$proj/pyproject.toml" ]; then
    uv run --project "$proj" python "$script" "$@"
    return $?
  fi
  local py
  py="$(command -v python3 || true)"
  if [ -z "${py:-}" ]; then _py_run_msg; return 69; fi
  "$py" "$script" "$@"
}

# py_run_noproj [args...] — stdlib-only runner: `uv run --no-project --quiet
# python` (hermetic interpreter, no dependency resolution, no CWD
# sensitivity), ambient python3 fallback where uv is absent.
py_run_noproj() {
  if command -v uv >/dev/null 2>&1; then
    uv run --no-project --quiet python "$@"
  else
    python3 "$@"
  fi
}
