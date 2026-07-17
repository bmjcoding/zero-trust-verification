#!/usr/bin/env bash
# _triage_run.sh — shared runner sourced by the triage .sh wrappers that drive a
# Python script needing ruamel/jsonschema (loop_guard.py, correlate.py,
# emit_incident_spec.py, resume_projection.py). Since ADR 0025 Wave 4 the uv
# bootstrap itself lives in the sibling _py_run.sh (the single copy); this file
# keeps the triage_py contract: route the invocation through `uv run` against
# the nearest pyproject.toml (the plugin's — plugins/zero-trust/pyproject.toml;
# ADR 0015), falling back to an ambient python3 that already carries the deps,
# so a standalone-installed plugin still runs when its host env provides them.
#
# The stdlib-only ingest path (normalize.py) does NOT need this — it runs on
# bare python3 so the default OTLP-JSON backend stays lean and hermetic.
#
# Portability: bash 3.2 (macOS default) + BSD userland safe.
set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_py_run.sh"

# triage_py <script.py> <args...> — run a triage python script with deps resolved.
triage_py() {
  local script="$1"; shift
  local here proj
  here="$(cd "$(dirname "$script")" && pwd)"
  proj="$(py_run_find_project "$here" || true)"
  PY_RUN_DIE_MSG="triage: neither uv (with pyproject) nor python3 available (ADR 0015)"
  py_run_call "${proj:-}" "$script" "$@"
}
