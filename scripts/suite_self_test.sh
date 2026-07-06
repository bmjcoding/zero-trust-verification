#!/usr/bin/env bash
# suite_self_test.sh — ONE command that proves the whole Zero-Trust Verification
# suite (ADR 0001: one product, four independently installable plugins). It runs,
# in order, and reports a single green/red:
#
#   1. cross-plugin vendoring lints (scripts/lint_consistency.sh) — GREEN run
#   2. vendoring-lint RED-tests — plant a drift per byte-identity/integrity rule
#      (V1 schema, V3 validator + its exemption, V4 claim-overlap, V5 escalation,
#      V6 marketplace incl. name<->source swap and a rogue plugin) and assert the
#      lint catches it, plus a few false-POSITIVE guards — so no vendor lint is
#      vacuous and none reds on a benign reformat/prose mention
#   3. the root manifest-validator self-test (scripts/self_test.sh)
#   4. every plugin's own self-test: autopilot, spec-gen, codebase-health, marshal
#
# HONESTY: a plugin self-test can `exit 0` while SKIPPING guarded sections when an
# optional dep is absent (autopilot's mock server, marshal's uv/jq loop backends,
# codebase-health's ruff C901 checks). This orchestrator DETECTS those skip
# notices and refuses to report an unqualified green: a skipped run is PASS-but-
# INCOMPLETE, and `SUITE_STRICT=1` turns any skip into a hard failure.
#
# uv is the single Python toolchain (ADR 0015); the validator + spec-gen +
# codebase-health self-tests bootstrap their deps through `uv run`.
#
# Usage: bash scripts/suite_self_test.sh          (SUITE_STRICT=1 to fail on skips)
# Exit 0 = every component green; non-zero = at least one component red (or, under
#          SUITE_STRICT, any skipped section).
#
# Portability: bash 3.2 (macOS default) + BSD userland safe.
set -u
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LINT="$ROOT/scripts/lint_consistency.sh"

if ! command -v uv >/dev/null 2>&1; then
  echo "suite_self_test: uv not found — install uv (https://docs.astral.sh/uv/) per ADR 0015" >&2
  exit 69
fi

LOGDIR="$(mktemp -d)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$LOGDIR" "$SANDBOX"' EXIT INT TERM

FAILED=""        # names of components that went red
SKIPPED=""       # names of components that PASSed but skipped guarded sections
RESULTS=""       # "name=STATUS" lines for the final summary

note() { printf '\n========== %s ==========\n' "$1"; }
record() { RESULTS="${RESULTS}${1}=${2}
"; return 0; }

# skip signals across the plugins: autopilot and marshal print an uppercase SKIPPED
# note (+ autopilot an "N skipped" counter); codebase-health prints a line-start
# "[skip]". A mid-line "[skip]" inside an assertion label is NOT a real skip.
component_skips() { { grep -nE 'SKIPPED|[1-9][0-9]* skipped' "$1"; grep -nE '^[[:space:]]*\[skip\]' "$1"; } 2>/dev/null; }

# a component that must exit 0 (a self-test or the green lint); skip-aware.
run_ok() {  # <name> <cmd...>
  local name="$1"; shift
  note "$name"
  if "$@" > "$LOGDIR/$name.log" 2>&1; then
    grep -hE 'passed|PASS=|self-test:|run_cases:|all cross-plugin' "$LOGDIR/$name.log" | tail -1
    local sk; sk="$(component_skips "$LOGDIR/$name.log")"
    if [ -n "$sk" ]; then
      echo "  -> $name PASS *WITH SKIPS* (optional sections not run):"
      printf '%s\n' "$sk" | sed 's/^/       /'
      SKIPPED="$SKIPPED $name"; record "$name" "PASS(skips)"
    else
      echo "  -> $name PASS"; record "$name" PASS
    fi
  else
    echo "  (last 25 lines)"; tail -25 "$LOGDIR/$name.log"
    echo "  -> $name FAIL"; FAILED="$FAILED $name"; record "$name" FAIL
  fi
}

# ==============================================================================
# 1. Vendoring lints — GREEN run (all rules pass against the real tree)
# ==============================================================================
run_ok "lint-consistency" bash "$LINT"

# ==============================================================================
# 2. Vendoring lints — RED-tests (each byte-identity/integrity rule must catch a
#    planted drift) + a few false-POSITIVE guards (a benign change stays green).
# ==============================================================================
note "lint-red-tests (planted-drift teeth + false-positive guards)"
RED_FAIL=0
expect_fail() {  # <rule> <sandbox-root> <desc>
  local rule="$1" dr="$2" desc="$3"
  local out="$SANDBOX/$rule.fail.out"
  if LINT_ROOT="$dr" bash "$LINT" > "$out" 2>&1; then
    echo "  RED MISS [$rule] lint stayed GREEN on: $desc"; RED_FAIL=1; return
  fi
  if grep -q "LINT-FAIL \[$rule\]" "$out"; then
    echo "  RED OK   [$rule] caught: $desc"
  else
    echo "  RED MISS [$rule] failed but NOT on $rule: $desc"; RED_FAIL=1
  fi
}
expect_no_fail() {  # <rule> <sandbox-root> <desc> — rule must NOT fire (no false positive)
  local rule="$1" dr="$2" desc="$3"
  local out="$SANDBOX/$rule.pass.out"
  LINT_ROOT="$dr" bash "$LINT" > "$out" 2>&1
  if grep -q "LINT-FAIL \[$rule\]" "$out"; then
    echo "  FALSE-POS[$rule] fired on benign: $desc"; RED_FAIL=1
  else
    echo "  GREEN OK [$rule] tolerated: $desc"
  fi
}

# seed the four pinned escalation prompts (identical blocks) into a sandbox
seed_esc() {
  local d="$1"
  mkdir -p "$d/plugins/autopilot/references" "$d/plugins/spec-gen/skills/spec" \
           "$d/plugins/codebase-health/skills/cleanup-audit/references"
  cp "$ROOT/plugins/autopilot/references/planner-prompt.md"     "$d/plugins/autopilot/references/"
  cp "$ROOT/plugins/autopilot/references/implementer-prompt.md" "$d/plugins/autopilot/references/"
  cp "$ROOT/plugins/spec-gen/skills/spec/SKILL.md"      "$d/plugins/spec-gen/skills/spec/"
  cp "$ROOT/plugins/codebase-health/skills/cleanup-audit/references/severity-rubric.md" \
     "$d/plugins/codebase-health/skills/cleanup-audit/references/"
}
# seed the four plugin.json source dirs into a sandbox
seed_plugins() {
  local d="$1" src
  for src in plugins/spec-gen plugins/autopilot plugins/codebase-health plugins/marshal; do
    mkdir -p "$d/$src/.claude-plugin"; cp "$ROOT/$src/.claude-plugin/plugin.json" "$d/$src/.claude-plugin/"
  done
}

# V1 — a vendored manifest schema copy drifts from canonical.
dr="$SANDBOX/v1"; mkdir -p "$dr/schema/verification-manifest" "$dr/plugins/x/schema/verification-manifest"
cp "$ROOT/schema/verification-manifest/v1.schema.json" "$dr/schema/verification-manifest/v1.schema.json"
{ cat "$ROOT/schema/verification-manifest/v1.schema.json"; printf '\n'; } > "$dr/plugins/x/schema/verification-manifest/v1.schema.json"
expect_fail V1 "$dr" "drifted vendored v1.schema.json"

# V3 — a vendored validator script drifts from canonical.
dr="$SANDBOX/v3"; mkdir -p "$dr/scripts" "$dr/plugins/spec-gen/scripts"
cp "$ROOT/scripts/validate_manifest.sh" "$dr/scripts/"; cp "$ROOT/scripts/validate_manifest.py" "$dr/scripts/"
cp "$ROOT/scripts/validate_manifest.py" "$dr/plugins/spec-gen/scripts/"; printf '\n# drift\n' >> "$dr/plugins/spec-gen/scripts/validate_manifest.py"
expect_fail V3 "$dr" "drifted vendored validate_manifest.py"

# V3 exemption guard #1 — a non-union tool squatting the exempt path.
dr="$SANDBOX/v3x"; mkdir -p "$dr/scripts" "$dr/plugins/autopilot/scripts"
cp "$ROOT/scripts/validate_manifest.sh" "$dr/scripts/"; cp "$ROOT/scripts/validate_manifest.py" "$dr/scripts/"
printf '#!/usr/bin/env bash\necho not-the-union-tool\n' > "$dr/plugins/autopilot/scripts/validate_manifest.sh"
expect_fail V3 "$dr" "non-union tool squatting the exempt validate_manifest.sh path"

# V3 exemption guard #2 — a DRIFTED single-file-validator copy that merely mentions
# `--union` in a comment must NOT be exempted (it lacks the union-only token).
dr="$SANDBOX/v3u"; mkdir -p "$dr/scripts" "$dr/plugins/autopilot/scripts"
cp "$ROOT/scripts/validate_manifest.sh" "$dr/scripts/"; cp "$ROOT/scripts/validate_manifest.py" "$dr/scripts/"
{ cat "$ROOT/scripts/validate_manifest.sh"; printf '\n# a drifted copy that only mentions --union in a comment\necho INJECTED\n'; } > "$dr/plugins/autopilot/scripts/validate_manifest.sh"
expect_fail V3 "$dr" "drifted validator merely mentioning --union is still flagged"

# V4 — the Marshal's claim_overlap copy drifts from autopilot's canonical.
dr="$SANDBOX/v4"; mkdir -p "$dr/plugins/autopilot/scripts" "$dr/plugins/marshal/scripts"
cp "$ROOT/plugins/autopilot/scripts/claim_overlap.sh" "$dr/plugins/autopilot/scripts/"
cp "$ROOT/plugins/autopilot/scripts/claim_overlap.sh" "$dr/plugins/marshal/scripts/"; printf '\n# drift\n' >> "$dr/plugins/marshal/scripts/claim_overlap.sh"
expect_fail V4 "$dr" "drifted vendored claim_overlap.sh"

# V5 — one escalation-block copy is reworded (byte drift).
dr="$SANDBOX/v5"; seed_esc "$dr"
sed 's/reject-and-alert/DRIFTED-WORD/' "$dr/plugins/spec-gen/skills/spec/SKILL.md" > "$dr/sk.tmp" \
  && mv "$dr/sk.tmp" "$dr/plugins/spec-gen/skills/spec/SKILL.md"
expect_fail V5 "$dr" "reworded escalation block in one tier"

# V5 presence — an expected prompt loses its block entirely (removal / wrong-file move).
dr="$SANDBOX/v5m"; seed_esc "$dr"
grep -v 'vendored:escalation-criterion' "$dr/plugins/codebase-health/skills/cleanup-audit/references/severity-rubric.md" > "$dr/sr.tmp" \
  && mv "$dr/sr.tmp" "$dr/plugins/codebase-health/skills/cleanup-audit/references/severity-rubric.md"
expect_fail V5 "$dr" "escalation block removed from the audit's pinned prompt"

# V5 false-positive guard — a doc that only MENTIONS the begin marker in prose is ignored.
dr="$SANDBOX/v5p"; seed_esc "$dr"; mkdir -p "$dr/docs"
printf 'This guide explains the vendored:escalation-criterion:begin marker.\n' > "$dr/docs/guide.md"
expect_no_fail V5 "$dr" "prose mention of the begin marker (no pair)"

# V6 — a registered plugin source loses its plugin.json (no longer installable).
dr="$SANDBOX/v6"; mkdir -p "$dr/.claude-plugin"
cp "$ROOT/.claude-plugin/marketplace.json" "$dr/.claude-plugin/"; seed_plugins "$dr"
rm "$dr/plugins/marshal/.claude-plugin/plugin.json"
expect_fail V6 "$dr" "registered plugin missing its plugin.json"

# V6 — a nested/stray marketplace.json reappears (single entry point violated).
dr="$SANDBOX/v6s"; mkdir -p "$dr/.claude-plugin"
cp "$ROOT/.claude-plugin/marketplace.json" "$dr/.claude-plugin/"; seed_plugins "$dr"
cp "$ROOT/.claude-plugin/marketplace.json" "$dr/plugins/marshal/.claude-plugin/marketplace.json"
expect_fail V6 "$dr" "stray nested marketplace.json"

# V6 — name<->source swap (each name and source still present, but paired wrong).
if command -v python3 >/dev/null 2>&1; then
  dr="$SANDBOX/v6sw"; mkdir -p "$dr/.claude-plugin"; seed_plugins "$dr"
  python3 -c "
import json
d=json.load(open('$ROOT/.claude-plugin/marketplace.json'))
by={p['name']:p for p in d['plugins']}
by['marshal']['source'],by['spec-gen']['source']=by['spec-gen']['source'],by['marshal']['source']
json.dump(d,open('$dr/.claude-plugin/marketplace.json','w'),indent=2)"
  expect_fail V6 "$dr" "name<->source swap (spec-gen<->marshal)"

  # V6 — a rogue 5th plugin with a non-existent source.
  dr="$SANDBOX/v6r"; mkdir -p "$dr/.claude-plugin"; seed_plugins "$dr"
  python3 -c "
import json
d=json.load(open('$ROOT/.claude-plugin/marketplace.json'))
d['plugins'].append({'name':'rogue-plugin','source':'./rogue'})
json.dump(d,open('$dr/.claude-plugin/marketplace.json','w'),indent=2)"
  expect_fail V6 "$dr" "rogue 5th plugin registered"

  # V6 false-positive guard — a compact (whitespace-stripped) reserialization is fine.
  dr="$SANDBOX/v6c"; mkdir -p "$dr/.claude-plugin"; seed_plugins "$dr"
  python3 -c "import json;json.dump(json.load(open('$ROOT/.claude-plugin/marketplace.json')),open('$dr/.claude-plugin/marketplace.json','w'),separators=(',',':'))"
  expect_no_fail V6 "$dr" "compact-JSON marketplace reserialization"
else
  echo "  [note] python3 absent — V6 structural red-tests (swap / rogue / compact) skipped"
fi

if [ "$RED_FAIL" -eq 0 ]; then
  echo "  -> lint-red-tests PASS (every vendor lint caught its planted drift; no false positives)"; record "lint-red-tests" PASS
else
  echo "  -> lint-red-tests FAIL (a vendor lint is vacuous or false-firing — see above)"; FAILED="$FAILED lint-red-tests"; record "lint-red-tests" FAIL
fi

# ==============================================================================
# 3. Root manifest-validator self-test (ADR 0014/0015)
# ==============================================================================
run_ok "validator-self-test" bash "$ROOT/scripts/self_test.sh"

# ==============================================================================
# 4. Every plugin's own self-test
# ==============================================================================
run_ok "autopilot"       bash "$ROOT/plugins/autopilot/scripts/self_test.sh"
run_ok "spec-gen"        bash "$ROOT/plugins/spec-gen/scripts/self_test.sh"
run_ok "codebase-health" bash "$ROOT/tests/codebase-health/self_test.sh"
run_ok "marshal"         bash "$ROOT/plugins/marshal/scripts/self_test.sh"

# ==============================================================================
# Summary
# ==============================================================================
note "suite summary"
printf '%s' "$RESULTS" | while IFS='=' read -r n s; do
  [ -n "$n" ] && printf '  %-24s %s\n' "$n" "$s"
done
echo
if [ -n "$FAILED" ]; then
  echo "== suite_self_test: FAIL —$FAILED =="
  exit 1
fi
if [ -n "$SKIPPED" ]; then
  echo "== suite_self_test: PASS — all components green (lints + red-tests + validator + all four plugins) =="
  echo "   NOTE: optional sections were SKIPPED (missing dev tools) in:$SKIPPED — this run is not zero-skip; see the WARN lines above."
  if [ -n "${SUITE_STRICT:-}" ]; then
    echo "== SUITE_STRICT=1: a skipped section is a failure — exiting non-zero =="
    exit 1
  fi
  echo "   (set SUITE_STRICT=1 to require a zero-skip proof.)"
  exit 0
fi
echo "== suite_self_test: PASS (lints + red-tests + validator + all four plugins, ZERO skips) =="
exit 0
