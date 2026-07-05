#!/usr/bin/env bash
# Verification Manifest v1 validator — shell entrypoint (the suite's exit-code contract).
# Exit: 0 complete · 3 incomplete · 4 schema-invalid · 5 unsupported version · 64 usage.
# Logic lives in validate_manifest.py (ADR 0014). Uses the project venv if present.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if [[ -x "$ROOT/.venv/bin/python" ]]; then
  PY="$ROOT/.venv/bin/python"
else
  PY="$(command -v python3 || true)"
fi
if [[ -z "${PY:-}" ]]; then
  echo "validate_manifest: no python3 available" >&2
  exit 69
fi

exec "$PY" "$HERE/validate_manifest.py" "$@"
