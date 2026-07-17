#!/usr/bin/env bash
# CH-03 — §12 intended↔discovered comparator (shell entrypoint; logic in
# manifest_join.py). Emits one greppable verdict line per §12 row. REPORTER:
# reads the manifest + journeys.json, never mutates either or the target, and
# always exits 0 (the ratchet reports; it never blocks — ADR 0004).
#
# Usage:  manifest_join.sh <manifest.yaml> <journeys.json> [--env=NAME]
#
# Python routes through uv (ADR 0015 "everything uv"): the manifest is YAML 1.2,
# so the join reuses the plugin pyproject's ruamel.yaml (same dep the
# vendored validator uses — no second resolution). Falls back to an ambient
# python3 that already has ruamel (the validate_manifest.sh precedent).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=manifest_lib.sh
. "$SCRIPT_DIR/manifest_lib.sh"

PY="$SCRIPT_DIR/manifest_join.py"

# Locate the repo root that carries the manifest toolchain (pyproject + ruamel):
# it is the parent of the dir holding validate_manifest.sh.
VALIDATOR="$(chpr_find_validator "${1:-}" || true)"
ROOT=""
[ -n "$VALIDATOR" ] && ROOT="$(cd "$(dirname "$VALIDATOR")/.." && pwd)"

if command -v uv >/dev/null 2>&1 && [ -n "$ROOT" ] && [ -f "$ROOT/pyproject.toml" ]; then
  exec uv run --quiet --project "$ROOT" python "$PY" "$@"
fi
exec python3 "$PY" "$@"
