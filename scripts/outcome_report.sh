#!/usr/bin/env bash
# outcome_report.sh — render the outcome store to a markdown digest + optional
# machine-parseable JSON artifact (ADR 0023; OM-07). Report-only: ALWAYS exits 0
# (ADR 0004). Every metric line carries its honesty-class badge; a Class-A row can
# never render as [det]. Logic in outcome_report.py.
#
# Usage: outcome_report.sh --store PATH [--json ARTIFACT.json] [--min-weeks N]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v uv >/dev/null 2>&1 && [ -f "$HERE/../pyproject.toml" ]; then
  uv run --no-project python "$HERE/outcome_report.py" "$@"
else
  python3 "$HERE/outcome_report.py" "$@"
fi
exit 0
