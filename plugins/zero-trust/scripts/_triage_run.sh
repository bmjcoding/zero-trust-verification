#!/usr/bin/env bash
# _triage_run.sh — shared runner sourced by the triage .sh wrappers that drive a
# Python script needing ruamel/jsonschema (loop_guard.py, correlate.py,
# emit_incident_spec.py, resume_projection.py). It routes the invocation through
# `uv run` against the nearest pyproject.toml (the repo root; ADR 0015), falling
# back to an ambient python3 that already carries the deps — the exact philosophy
# of scripts/validate_manifest.sh and org-memory's _owm_run.sh, so a
# standalone-installed plugin still runs when its host env provides the deps.
#
# The stdlib-only ingest path (normalize.py) does NOT need this — it runs on bare
# python3 so the default OTLP-JSON backend stays lean and hermetic.
#
# Portability: bash 3.2 (macOS default) + BSD userland safe.
set -u

triage_find_project() {
  local d="$1"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    if [ -f "$d/pyproject.toml" ]; then printf '%s\n' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

# triage_py <script.py> <args...> — run a triage python script with deps resolved.
triage_py() {
  local script="$1"; shift
  local here proj
  here="$(cd "$(dirname "$script")" && pwd)"
  proj="$(triage_find_project "$here" || true)"
  if command -v uv >/dev/null 2>&1 && [ -n "${proj:-}" ]; then
    uv run --project "$proj" python "$script" "$@"
    return $?
  fi
  local py
  py="$(command -v python3 || true)"
  if [ -z "${py:-}" ]; then
    echo "triage: neither uv (with pyproject) nor python3 available (ADR 0015)" >&2
    return 69
  fi
  "$py" "$script" "$@"
}
