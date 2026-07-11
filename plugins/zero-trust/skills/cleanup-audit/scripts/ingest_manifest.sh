#!/usr/bin/env bash
# CH-01 — Verification Manifest ingestion + consumer degrade (ADR 0003, MS §8/§11/§13.10).
#
# Locates a Spec's colocated manifest, validates it through the vendored
# `scripts/validate_manifest.sh` (the ONE permitted bootstrap, ADR 0001 — never
# a second schema copy), and emits a single MODE token the orchestrator gates
# facet dispatch on:
#
#   MODE=COMPLETE        validator exit 0 — facets proceed
#   MODE=INCOMPLETE      validator exit 3 — as absent (only a resumed spec
#                        session consumes an incomplete manifest, MS §11)
#   MODE=ABSENT          no manifest file at the given path
#   MODE=SCHEMA-INVALID  validator exit 4 — a DEFECT, not an absence: report the
#                        schema error, NEVER degrade to manifest-less (MS §11)
#   MODE=UNSUPPORTED     validator exit 5 — refuse; say which version; treat as
#                        absent for facet purposes (MS §8)
#
# The MS §11 degrade table is implemented verbatim as a loop-safety invariant-4
# surface: a missing/incomplete/unsupported manifest degrades exactly like a
# missing journeys.json — say so (loud [note] + a [not-covered] line so the two
# manifest-dependent facets never silently skip, invariant 6), do less, never
# guess, never block on the absence. A schema-invalid manifest is the ONE
# non-absence: it is a defect that must be fixed, so it is reported, not skipped.
#
# Usage:  ingest_manifest.sh <manifest-path>
# Output: MODE=<token> on the first line, then any degrade notes / schema errors.
# Exit:   always 0 — this is a reporter (loop-safety invariant 1). The MODE token
#         carries the state; the caller decides. A schema-invalid or unsupported
#         manifest is surfaced in the text, never via a blocking exit code here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=manifest_lib.sh
. "$SCRIPT_DIR/manifest_lib.sh"

MANIFEST="${1:-}"
if [ -z "$MANIFEST" ]; then
  echo "usage: ingest_manifest.sh <manifest-path>" >&2
  exit 64
fi

# The two facets that consume the manifest — named identically wherever they are
# skipped so the report's Not-covered section is greppable and stable.
COVERAGE_FACET="manifest-coverage (§12 join)"
ROT_FACET="rot-vs-manifest"

skip_manifest_facets() { # $1 = human reason
  echo "[note] $1"
  echo "[not-covered] $COVERAGE_FACET: $1"
  echo "[not-covered] $ROT_FACET: $1"
}

# ── ABSENT: no file. Heuristic journeys (unchanged 1.4.0 walk); the two
#    manifest facets skip loudly; severity caps per severity-rubric.md.
if [ ! -f "$MANIFEST" ]; then
  echo "MODE=ABSENT"
  skip_manifest_facets "no manifest at '$MANIFEST' — heuristic journeys only; manifest facets skipped (MS §11 absent row)"
  exit 0
fi

VALIDATOR="$(chpr_find_validator "$MANIFEST" || true)"
if [ -z "$VALIDATOR" ]; then
  # Tooling gap, not a manifest defect: degrade to manifest-less, loudly. Never
  # best-effort-parse a manifest without its validator (MS §8).
  echo "MODE=ABSENT"
  echo "[note] [MANIFEST-TOOLING-MISSING] validate_manifest.sh not found (set \$VALIDATE_MANIFEST or vendor it) — cannot validate '$MANIFEST'"
  skip_manifest_facets "manifest present but validator unavailable — treated as absent (loud degrade, invariant 4)"
  exit 0
fi

# Validate. stdout carries the validator's own report lines; stderr carries uv
# bootstrap noise (discarded — the exit code is the contract, MS §11).
V_OUT="$("$VALIDATOR" "$MANIFEST" 2>/dev/null)"
V_CODE=$?

case "$V_CODE" in
  0)
    echo "MODE=COMPLETE"
    ;;
  3)
    echo "MODE=INCOMPLETE"
    skip_manifest_facets "manifest completeness: incomplete — treated as absent for facet purposes; only a resumed spec-tier session consumes it (MS §11 incomplete row)"
    ;;
  4)
    # Schema-invalid is a DEFECT, not an absence (MS §11): report the error and
    # do NOT degrade to manifest-less. Still surfaced in Not-covered so the
    # comparator's non-run is never silent (invariant 6) — but framed as a
    # defect to fix, not an absence to route around.
    echo "MODE=SCHEMA-INVALID"
    echo "[note] manifest is schema-invalid — a DEFECT, not an absence (MS §11); fix the manifest, do NOT proceed manifest-less"
    printf '%s\n' "$V_OUT" | sed 's/^/    /'
    echo "[not-covered] $COVERAGE_FACET: manifest schema-invalid (defect) — comparator not run until fixed"
    echo "[not-covered] $ROT_FACET: manifest schema-invalid (defect) — rot-vs-manifest not run until fixed"
    ;;
  5)
    SV="$(chpr_schema_version "$MANIFEST")"
    echo "MODE=UNSUPPORTED"
    echo "[note] [MANIFEST-UNSUPPORTED: schema_version ${SV:-?} > supported 1] — refusing to best-effort-parse (MS §8); treating as absent for facet purposes but recording the version"
    skip_manifest_facets "manifest schema_version ${SV:-?} unsupported — treated as absent, version recorded (MS §11 unsupported row)"
    ;;
  *)
    # Any other exit (e.g. 64 usage, 69 tooling) — degrade loudly, never guess.
    echo "MODE=ABSENT"
    echo "[note] validator returned unexpected exit $V_CODE — treating manifest as absent (loud degrade, invariant 4)"
    printf '%s\n' "$V_OUT" | sed 's/^/    /'
    skip_manifest_facets "validator error (exit $V_CODE) — treated as absent"
    ;;
esac
exit 0
