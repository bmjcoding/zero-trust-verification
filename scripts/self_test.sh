#!/usr/bin/env bash
# Hermetic self-test for the Verification Manifest validator.
# Bootstraps the project venv (ADR 0014 deps), then runs tests/run_cases.py.
# No network, no external state. Exits non-zero on any failure.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VENV="$ROOT/.venv"

if [[ ! -x "$VENV/bin/python" ]]; then
  echo "[setup] creating venv + installing dev deps"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip -r "$ROOT/requirements-dev.txt"
fi

# Guard: the deps must be the YAML 1.2 stack (ADR 0014), never PyYAML.
"$VENV/bin/python" - <<'PY'
import importlib, sys
for mod in ("ruamel.yaml", "jsonschema"):
    try:
        importlib.import_module(mod)
    except ImportError:
        sys.exit(f"missing dev dep: {mod} (see requirements-dev.txt)")
PY

exec "$VENV/bin/python" "$ROOT/tests/run_cases.py"
