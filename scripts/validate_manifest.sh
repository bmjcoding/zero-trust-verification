#!/usr/bin/env bash
# Verification Manifest v1 validator — shell entrypoint (the suite's exit-code contract).
# Exit: 0 complete · 3 incomplete · 4 schema-invalid · 5 unsupported version · 64 usage.
# Logic lives in validate_manifest.py (ADR 0014). Deps managed by uv (ADR 0015).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# Prefer uv (self-bootstraps ruamel.yaml YAML-1.2 + jsonschema from the lockfile).
# Fall back to an ambient python3 that already has the deps (e.g. a vendored copy
# whose host env provides them).
if command -v uv >/dev/null 2>&1 && [[ -f "$ROOT/pyproject.toml" ]]; then
  exec uv run --project "$ROOT" python "$HERE/validate_manifest.py" "$@"
fi

PY="$(command -v python3 || true)"
if [[ -z "${PY:-}" ]]; then
  echo "validate_manifest: neither uv (with pyproject) nor python3 available" >&2
  exit 69
fi
exec "$PY" "$HERE/validate_manifest.py" "$@"
