#!/usr/bin/env bash
# self_test.sh — hermetic self-test for the Spec Generation tier's deterministic
# substrate (SG-6). Bootstraps deps with `uv run` (ADR 0015 — no pip, no manual
# venv), runs the Python case suite, then the consistency lint, then a planted-
# violation check proving the lint actually goes red.
#
#   1. tests/run_cases.py — validator reuse, ID allocator, resume projection,
#      profile resolution, emission shape, and the S4 output-schema field (81+
#      assertions; every SG-2/3/4/5 acceptance).
#   2. lint_consistency.sh — the 8 cross-file contract rules (expect PASS).
#   3. planted violation — tamper a sandbox copy of the vendored schema and assert
#      the byte-identity lint (L3) reports it (expect FAIL).
#
# Usage: bash scripts/self_test.sh    Exit 0 = all green.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$PLUGIN/../.." && pwd)"

if ! command -v uv >/dev/null 2>&1; then
  echo "self_test: uv not found — install uv (https://docs.astral.sh/uv/) per ADR 0015" >&2
  exit 69
fi

echo "== 1. deterministic case suite (uv run) =="
uv run --project "$PLUGIN" python "$PLUGIN/tests/run_cases.py"

echo
echo "== 2. consistency lint (L1-L8) =="
bash "$HERE/lint_consistency.sh"

echo
echo "== 3. planted-violation check (lint must go red on tampered vendored copy) =="
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
cp -R "$PLUGIN" "$SANDBOX/spec-gen"
# Tamper the vendored schema copy so it diverges from the repo-root original.
printf '\n' >> "$SANDBOX/spec-gen/schema/verification-manifest/v1.schema.json"
if SPEC_GEN_PLUGIN_ROOT="$SANDBOX/spec-gen" SPEC_GEN_REPO_ROOT="$REPO" \
     bash "$HERE/lint_consistency.sh" >/dev/null 2>&1; then
  echo "FAIL — lint PASSED on a tampered vendored schema (byte-identity rule is asleep)" >&2
  exit 1
fi
echo "ok   - lint correctly reports the planted byte-identity violation"

echo
echo "self_test: PASS"
