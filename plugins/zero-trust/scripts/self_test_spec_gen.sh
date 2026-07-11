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
echo "== 3. planted-violation checks (lint must go red on each planted defect) =="
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

plant_and_expect_red() {  # label  tamper_fn (called with the sandbox plugin root)
  local label="$1" fn="$2"
  local SB="$SANDBOX/case"; rm -rf "$SB"; cp -R "$PLUGIN" "$SB"
  "$fn" "$SB"
  if SPEC_GEN_PLUGIN_ROOT="$SB" SPEC_GEN_REPO_ROOT="$REPO" \
       bash "$HERE/lint_consistency.sh" >/dev/null 2>&1; then
    echo "FAIL — lint PASSED on planted violation: $label" >&2
    exit 1
  fi
  echo "ok   - lint reports planted violation: $label"
}

# 3a — L3 byte-identity: tamper the vendored schema so it diverges from repo root.
tamper_schema() { printf '\n' >> "$1/schema/verification-manifest/v1.schema.json"; }
# 3b — L2 hard-contract deletion: strip the HC6 statement from SKILL.md (the P1
# class of bug — a silent contract deletion in the orchestrator's ground truth).
tamper_hc6() {
  grep -v 'Vanilla agents only' "$1/skills/spec/SKILL.md" > "$1/skills/spec/SKILL.tmp"
  mv "$1/skills/spec/SKILL.tmp" "$1/skills/spec/SKILL.md"
}

plant_and_expect_red "L3 tampered vendored schema" tamper_schema
plant_and_expect_red "L2 deleted HC6 (vanilla-agents) from SKILL.md" tamper_hc6

echo
echo "self_test: PASS"
