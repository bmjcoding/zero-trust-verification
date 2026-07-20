#!/usr/bin/env bash
# Verification Manifest v1 validator — shell entrypoint (the suite's exit-code contract).
# Exit: 0 complete · 3 incomplete · 4 schema-invalid · 5 unsupported version · 64 usage.
# Logic lives in validate_manifest.py (ADR 0014). Deps managed by uv (ADR 0015).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prefer uv (self-bootstraps ruamel.yaml YAML-1.2 + jsonschema from the lockfile).
# Fall back to an ambient python3 that already has the deps (e.g. a vendored copy
# whose host env provides them). The bootstrap is the shared _py_run.sh (ADR 0025
# Wave 4); its walker resolves the same project the old fixed-parent "$HERE/.."
# resolution did — plugins/zero-trust/pyproject.toml, the ONE uv project (ADR 0031).
. "$HERE/_py_run.sh"

PY_RUN_DIE_MSG="validate_manifest: neither uv (with pyproject) nor python3 available"
py_run_exec "$(py_run_find_project "$HERE" || true)" "$HERE/validate_manifest.py" "$@"
