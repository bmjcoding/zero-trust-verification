#!/usr/bin/env bash
# Hermetic self-test for the Verification Manifest validator.
# Uses uv (ADR 0015) to self-bootstrap deps from pyproject.toml + uv.lock, then
# runs tests/run_cases.py. No manual venv, no pip.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if ! command -v uv >/dev/null 2>&1; then
  echo "self_test: uv not found — install uv (https://docs.astral.sh/uv/) per ADR 0015" >&2
  exit 69
fi

# uv run auto-syncs the locked env (ruamel.yaml YAML-1.2 + jsonschema) before running.
exec uv run --project "$ROOT" python "$ROOT/tests/run_cases.py"
