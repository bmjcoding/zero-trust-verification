#!/usr/bin/env bash
# _owm_run.sh — shared runner sourced by the OWM .sh wrappers (extract_memory.sh,
# crawl.sh, index_build.sh, query.sh, coverage.sh). Since ADR 0025 Wave 4 the
# uv bootstrap itself lives in the sibling _py_run.sh (the single copy); this
# file keeps the owm_exec contract: route every Python invocation through
# `uv run` against the nearest pyproject.toml (the plugin's —
# plugins/zero-trust/pyproject.toml; ADR 0015), falling back to an ambient
# python3 that already has the deps, so a standalone-installed plugin (whose
# host env provides ruamel.yaml + jsonschema) still runs.
#
# Portability: bash 3.2 (macOS default) + BSD userland safe.
set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_py_run.sh"

# owm_exec <subcommand> <args...>
owm_exec() {
  local here proj
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  proj="$(py_run_find_project "$here" || true)"
  PY_RUN_DIE_MSG="owm: neither uv (with pyproject) nor python3 available (ADR 0015)"
  py_run_exec "${proj:-}" "$here/owm.py" "$@"
}
