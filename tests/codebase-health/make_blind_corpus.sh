#!/usr/bin/env bash
# Generate the BLIND copy of the planted corpus for agent-level evals.
#
# The annotated corpus (test-fixtures/planted/) states each defect's category and
# expected grade in PLANT comments — fine for humans, useless as an eval (the
# agent just reads the answers). This script copies it to test-fixtures/blind/
# with every annotation line stripped, so agents judge the code, not the
# annotations. Annotation tokens are matched case-SENSITIVE and word-bounded
# (PLANT/PLANTS, MUST-NOT-FLAG, EXPECTED_FINDINGS) so real code that merely
# contains lowercase lookalikes — e.g. `from planted_pkg import ...` in tests/
# and the README J1 snippet — survives intact. Regenerate after any fixture
# change; evaluate by running /audit against test-fixtures/blind/ and scoring
# vs EXPECTED_FINDINGS.yaml.
set -euo pipefail

# This harness now lives at tests/codebase-health/, so the fixtures are a direct
# child of the harness dir (HARNESS_DIR), not one level up — anchor on it directly.
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HARNESS_DIR/test-fixtures/planted"
DST="$HARNESS_DIR/test-fixtures/blind"

rm -rf "$DST"
cp -R "$SRC" "$DST"
find "$DST" -type f \( -name '*.py' -o -name '*.ts' -o -name '*.js' -o -name '*.md' -o -name '*.toml' \) | while read -r f; do
  grep -vE '\bPLANTS?\b|\bMUST-NOT-FLAG\b|\bEXPECTED_FINDINGS\b' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
echo "blind corpus written to $DST (annotations stripped)"
