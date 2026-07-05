#!/usr/bin/env bash
# Repo-level cross-plugin consistency lint (MS §13.3 vendoring-lint host; ADR 0001).
#
# The suite's plugins are consumed by an LLM that treats vendored artifacts as
# ground truth; two copies of one contract that drift are a coin-flip at runtime.
# This is the CROSS-PLUGIN host (autopilot/codebase-health each also have a
# plugin-local self-test/lint; this one pins contracts that span more than one
# plugin — the ones ADR 0001 says must be vendored from a SINGLE source):
#
#   V1 — the Verification-Manifest JSON Schema. There is ONE canonical copy
#        (schema/verification-manifest/v1.schema.json). Any vendored copy shipped
#        inside a plugin (for standalone install) must be byte-identical to it.
#   V2 — the `## Behavior coverage` PR-body format. One canonical definition
#        (docs/specs/behavior-coverage-format.md) that the autopilot AV3-05
#        producer and the codebase-health CH-06 consumer both use.
#
# Exit 0 = all rules pass. Exit 1 = at least one violation (each printed).
# Reporter: reads files, mutates nothing.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# $LINT_ROOT lets the self-test point the lint at a fixture tree (to prove the
# byte-identity rule has teeth); defaults to the real repo root.
ROOT="${LINT_ROOT:-$(cd "$HERE/.." && pwd)}"

FAIL=0
violation() { echo "LINT-FAIL [$1] $2" >&2; FAIL=1; }
ok()        { echo "lint ok   [$1] $2"; }

# ── V1: vendored manifest-schema copies are byte-identical to the canonical ───
CANON="$ROOT/schema/verification-manifest/v1.schema.json"
if [ ! -f "$CANON" ]; then
  violation V1 "canonical manifest schema missing: $CANON"
else
  copies=0; drift=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ "$c" = "$CANON" ] && continue
    copies=$((copies+1))
    if cmp -s "$CANON" "$c"; then
      ok V1 "vendored schema copy byte-identical: ${c#$ROOT/}"
    else
      violation V1 "vendored schema copy DRIFTED from canonical: ${c#$ROOT/} (ADR 0001 — vendor byte-for-byte from schema/verification-manifest/v1.schema.json)"
      drift=$((drift+1))
    fi
  done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -path "$ROOT/.claude" -prune -o -name 'v1.schema.json' -print 2>/dev/null)
  [ "$copies" -eq 0 ] && ok V1 "single canonical manifest schema; no vendored copies to drift (ADR 0001)"
fi

# ── V2: the `## Behavior coverage` format has one canonical definition both
#        the AV3-05 producer and the CH-06 consumer honor ───────────────────────
FMT_DOC="$ROOT/docs/specs/behavior-coverage-format.md"
CONSUMER="$ROOT/codebase-health/plugins/codebase-health/skills/cleanup-audit/scripts/check_behavior_coverage.sh"
PRODUCER_REF="$ROOT/autopilot/references/validator-prompts.md"

if [ ! -f "$FMT_DOC" ]; then
  violation V2 "canonical behavior-coverage format doc missing: docs/specs/behavior-coverage-format.md"
else
  # the doc must pin the header text and the `- <id>: <node>` line shape
  if grep -q 'Behavior coverage' "$FMT_DOC" && grep -q '<behavior-id>: <test-path>::<test-node>' "$FMT_DOC"; then
    ok V2 "canonical behavior-coverage format defined once (docs/specs/behavior-coverage-format.md)"
  else
    violation V2 "format doc present but does not pin the canonical line shape ('<behavior-id>: <test-path>::<test-node>')"
  fi
  # the CH-06 consumer must parse THIS format (the `## Behavior coverage` header
  # + `::`-noded behavior lines) — not a divergent shape.
  if [ -f "$CONSUMER" ]; then
    if grep -qi 'Behavior[[:space:]]\+coverage' "$CONSUMER" && grep -q '::' "$CONSUMER"; then
      ok V2 "CH-06 consumer parses the canonical ## Behavior coverage format"
    else
      violation V2 "CH-06 consumer ($CONSUMER) does not parse the canonical format"
    fi
  fi
  # the AV3-05 producer reference must name the same behavior-coverage concept.
  if [ -f "$PRODUCER_REF" ]; then
    if grep -qi 'Behavior coverage' "$PRODUCER_REF"; then
      ok V2 "AV3-05 producer reference names the same behavior-coverage contract"
    else
      violation V2 "AV3-05 producer reference ($PRODUCER_REF) no longer names the behavior-coverage contract"
    fi
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then echo "== lint_consistency: all cross-plugin contract rules pass =="; else echo "== lint_consistency: violations found =="; fi
exit "$FAIL"
