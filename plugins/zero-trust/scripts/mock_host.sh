#!/usr/bin/env bash
# mock_host.sh
#
# Thin CLI wrapper presenting the host.sh interface, backed by mock_host.py.
# Point the Marshal at it in tests: MARSHAL_HOST=<this>. All Python is routed
# through `uv run` (ADR 0015) so the self-test self-bootstraps the locked env
# with no manual venv. The mock needs only the stdlib, but running it under uv
# keeps every Python invocation in the repo on one toolchain.
#
# Env (consumed by mock_host.py):
#   MARSHAL_MOCK_STATE  state JSON path
#   MARSHAL_MOCK_REPO   bare origin repo (--git-dir)
# Optional:
#   MARSHAL_UV_PROJECT  pyproject root for `uv run --project` (default: nearest
#                       ancestor of this script containing pyproject.toml).

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_project_root() {
  if [[ -n "${MARSHAL_UV_PROJECT:-}" ]]; then
    printf '%s' "$MARSHAL_UV_PROJECT"; return 0
  fi
  local d="$HERE"
  while [[ "$d" != "/" ]]; do
    [[ -f "$d/pyproject.toml" ]] && { printf '%s' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

command -v uv >/dev/null 2>&1 || { echo "mock_host.sh: uv not found (ADR 0015)" >&2; exit 69; }

ROOT="$(find_project_root)" || { echo "mock_host.sh: no pyproject.toml ancestor (set MARSHAL_UV_PROJECT)" >&2; exit 78; }

exec uv run --project "$ROOT" python "$HERE/mock_host.py" "$@"
