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

. "$HERE/_py_run.sh"   # the ONE uv bootstrap (ADR 0025 Wave 4) — walker only:
                       # the mock is uv-REQUIRED (no python3 fallback; a test
                       # host must run the locked toolchain, never an ambient
                       # interpreter), so the exec below stays uv-direct.

command -v uv >/dev/null 2>&1 || { echo "mock_host.sh: uv not found (ADR 0015)" >&2; exit 69; }

ROOT="${MARSHAL_UV_PROJECT:-$(py_run_find_project "$HERE" || true)}"
[ -n "$ROOT" ] || { echo "mock_host.sh: no pyproject.toml ancestor (set MARSHAL_UV_PROJECT)" >&2; exit 78; }

exec uv run --project "$ROOT" python "$HERE/mock_host.py" "$@"
