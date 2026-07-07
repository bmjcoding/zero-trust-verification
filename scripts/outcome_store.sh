#!/usr/bin/env bash
# outcome_store.sh — the ONE shared writer path for the outcome store (ADR 0023).
# Both producers (the Marshal outcome-capture mode + the codebase-health audit
# outcome-emit step) route through this entrypoint; the logic lives in
# outcome_store.py, validated with the manifest's jsonschema toolchain (ADR 0014).
#
# Subcommands: read | validate | append-run | write-baseline   (all --store PATH)
#   append-run / write-baseline read the incoming snapshot JSON from --snapshot-file
#   or stdin.
# Exit: 0 ok · 4 schema-invalid · 5 store corrupt/unknown-version (refused,
#       byte-untouched) · 6 refuse-second baseline · 64 usage.
#
# Report-only (ADR 0004/0023): reads history, appends rows; never gates, never
# posts, never mutates a target repo. Deps managed by uv (ADR 0015).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if command -v uv >/dev/null 2>&1 && [ -f "$ROOT/pyproject.toml" ]; then
  exec uv run --project "$ROOT" python "$HERE/outcome_store.py" "$@"
fi

PY="$(command -v python3 || true)"
if [ -z "${PY:-}" ]; then
  echo "outcome_store: neither uv (with pyproject) nor python3 available" >&2
  exit 69
fi
exec "$PY" "$HERE/outcome_store.py" "$@"
