#!/usr/bin/env bash
# _owm_run.sh — shared runner sourced by the OWM .sh wrappers (extract_memory.sh,
# crawl.sh, index_build.sh, query.sh, coverage.sh). It routes every Python
# invocation through `uv run` against the nearest pyproject.toml (the plugin's —
# plugins/zero-trust/pyproject.toml;
# ADR 0015), falling back to an ambient python3 that already has the deps — the
# exact philosophy of scripts/validate_manifest.sh, so a standalone-installed
# plugin (whose host env provides ruamel.yaml + jsonschema) still runs.
#
# Portability: bash 3.2 (macOS default) + BSD userland safe.
set -u

# find the nearest ancestor dir containing pyproject.toml (the uv project root).
owm_find_project() {
  local d="$1"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    if [ -f "$d/pyproject.toml" ]; then printf '%s\n' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

# owm_exec <subcommand> <args...>
owm_exec() {
  local here proj
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  proj="$(owm_find_project "$here" || true)"
  if command -v uv >/dev/null 2>&1 && [ -n "${proj:-}" ]; then
    exec uv run --project "$proj" python "$here/owm.py" "$@"
  fi
  local py
  py="$(command -v python3 || true)"
  if [ -z "${py:-}" ]; then
    echo "owm: neither uv (with pyproject) nor python3 available (ADR 0015)" >&2
    exit 69
  fi
  exec "$py" "$here/owm.py" "$@"
}
