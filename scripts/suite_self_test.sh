#!/usr/bin/env bash
# suite_self_test.sh — ONE command that proves the whole Zero-Trust Verification
# suite (ADR 0001/0019: one product, five independently installable plugins). It runs,
# in order, and reports a single green/red:
#
#   1. cross-plugin vendoring lints (scripts/lint_consistency.sh) — GREEN run
#   2. vendoring-lint RED-tests — plant a drift per byte-identity/integrity rule
#      (V1 schema, V3 validator + its exemption, V4 claim-overlap, V5 escalation,
#      V6 marketplace incl. name<->source swap and a rogue plugin, V7 mutation
#      adapter map/resolver/producer+consumer tokens, V8 OWM manifest-parse fork)
#      and assert the lint catches it, plus a few false-POSITIVE guards — so no
#      vendor lint is vacuous and none reds on a benign reformat/prose mention
#   3. the root manifest-validator self-test (scripts/self_test.sh)
#   4. every plugin's own self-test: autopilot, spec-gen, codebase-health, marshal,
#      org-memory
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
# seed the five plugin.json source dirs into a sandbox
seed_plugins() {
  local d="$1" src
  for src in plugins/spec-gen plugins/autopilot plugins/codebase-health plugins/marshal plugins/org-memory; do
    mkdir -p "$d/$src/.claude-plugin"; cp "$ROOT/$src/.claude-plugin/plugin.json" "$d/$src/.claude-plugin/"
  done
}
# seed the V7 mutation-adapter-map artifacts (ADR 0016): the two vendored doc-block
# copies + the two byte-identical resolver copies + the producer/consumer scripts.
seed_mut() {
  local d="$1"
  mkdir -p "$d/plugins/codebase-health/skills/cleanup-audit/references" \
           "$d/plugins/autopilot/references" \
           "$d/plugins/codebase-health/skills/cleanup-audit/scripts" \
           "$d/plugins/autopilot/scripts"
  cp "$ROOT/plugins/codebase-health/skills/cleanup-audit/references/cross-language-tooling.md" "$d/plugins/codebase-health/skills/cleanup-audit/references/"
  cp "$ROOT/plugins/autopilot/references/mutation-adapters.md"                                  "$d/plugins/autopilot/references/"
  cp "$ROOT/plugins/codebase-health/skills/cleanup-audit/scripts/mutation_adapter.sh"           "$d/plugins/codebase-health/skills/cleanup-audit/scripts/"
  cp "$ROOT/plugins/autopilot/scripts/mutation_adapter.sh"                                       "$d/plugins/autopilot/scripts/"
  cp "$ROOT/plugins/autopilot/scripts/mutation_gate.sh"                                          "$d/plugins/autopilot/scripts/"
  cp "$ROOT/plugins/codebase-health/skills/cleanup-audit/scripts/check_mutation_survivors.sh"   "$d/plugins/codebase-health/skills/cleanup-audit/scripts/"
}

# seed what lint V8 (OWM vendoring) needs into a sandbox: the canonical validator +
# manifest schema, and the whole org-memory plugin (its engine + vendored copies).
seed_owm() {
  local d="$1"
  mkdir -p "$d/scripts" "$d/schema/verification-manifest" "$d/plugins"
  cp "$ROOT/scripts/validate_manifest.py" "$d/scripts/"
  cp "$ROOT/scripts/validate_manifest.sh" "$d/scripts/"
  cp "$ROOT/schema/verification-manifest/v1.schema.json" "$d/schema/verification-manifest/"
  cp -R "$ROOT/plugins/org-memory" "$d/plugins/org-memory"
}

# seed what lint V10 (remediation loop) needs: the whole codebase-health plugin
# (classify_fix.sh + slug_provenance.tsv + the audit taxonomy the slugs must exist
# in) plus the SPEC_1.4.0 §12 doc the provenance anchors cite.
seed_rl() {
  local d="$1"
  mkdir -p "$d/plugins" "$d/docs/specs"
  cp -R "$ROOT/plugins/codebase-health" "$d/plugins/codebase-health"
  cp "$ROOT/docs/specs/codebase-health-spec-1.4.0.md" "$d/docs/specs/"
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

  # V6 — a rogue SIXTH plugin with a non-existent source (org-memory is the legit 5th).
  dr="$SANDBOX/v6r"; mkdir -p "$dr/.claude-plugin"; seed_plugins "$dr"
  python3 -c "
import json
d=json.load(open('$ROOT/.claude-plugin/marketplace.json'))
d['plugins'].append({'name':'rogue-plugin','source':'./rogue'})
json.dump(d,open('$dr/.claude-plugin/marketplace.json','w'),indent=2)"
  expect_fail V6 "$dr" "rogue 6th plugin registered (org-memory is the legit 5th)"

  # V6 false-positive guard — a compact (whitespace-stripped) reserialization is fine.
  dr="$SANDBOX/v6c"; mkdir -p "$dr/.claude-plugin"; seed_plugins "$dr"
  python3 -c "import json;json.dump(json.load(open('$ROOT/.claude-plugin/marketplace.json')),open('$dr/.claude-plugin/marketplace.json','w'),separators=(',',':'))"
  expect_no_fail V6 "$dr" "compact-JSON marketplace reserialization"
else
  echo "  [note] python3 absent — V6 structural red-tests (swap / rogue / compact) skipped"
fi

# V8 — OWM manifest-parse FORK: a recognizer that parses manifests with its OWN yaml
# import instead of reusing the canonical validate_manifest is caught RED (ADR 0019 /
# register OWM-10). The mutation-testing stream owns V7; this is V8 and must not collide.
dr="$SANDBOX/v8"; seed_owm "$dr"
cat > "$dr/plugins/org-memory/scripts/owm.py" <<'PYFORK'
#!/usr/bin/env python3
# FORKED manifest recognizer (planted drift): parses the Verification Manifest with
# its OWN yaml import instead of routing through the canonical validate_manifest —
# exactly the drift V8 exists to catch (a manifest-format change would silently leave
# this parsing the old shape).
import yaml
def extract_manifest(path):
    return yaml.safe_load(open(path))
PYFORK
expect_fail V8 "$dr" "OWM manifest-parse path forks a yaml parser instead of reusing validate_manifest"

# V8 false-positive guard — a BENIGN reference reword of the real engine (a comment
# change that still routes through validate_manifest) must stay GREEN.
dr="$SANDBOX/v8p"; seed_owm "$dr"
printf '\n# benign reword: manifest parsing still routes through the canonical validate_manifest toolchain.\n' \
  >> "$dr/plugins/org-memory/scripts/owm.py"
expect_no_fail V8 "$dr" "benign comment reword that still reuses validate_manifest"
# V7 (ADR 0016 / MT-09) — the mutation adapter map must not drift between the
# autopilot D6.5 producer and the codebase-health PR-Gate consumer. Plant a drift
# per guarantee (doc block, resolver script, sole-source, producer/consumer token)
# and assert V7 fires; a benign out-of-block edit must stay green.
dr="$SANDBOX/v7"; seed_mut "$dr"
sed 's#| StrykerJS | TS/JS |#| StrykerJS | DRIFTED |#' "$dr/plugins/autopilot/references/mutation-adapters.md" > "$dr/m.tmp" \
  && mv "$dr/m.tmp" "$dr/plugins/autopilot/references/mutation-adapters.md"
expect_fail V7 "$dr" "drifted vendored mutation-adapter-map doc block"

dr="$SANDBOX/v7s"; seed_mut "$dr"
printf '\n# drift\n' >> "$dr/plugins/autopilot/scripts/mutation_adapter.sh"
expect_fail V7 "$dr" "drifted vendored mutation_adapter.sh resolver"

dr="$SANDBOX/v7c"; seed_mut "$dr"
mkdir -p "$dr/plugins/marshal/scripts"; cp "$ROOT/plugins/autopilot/scripts/mutation_adapter.sh" "$dr/plugins/marshal/scripts/"
expect_fail V7 "$dr" "a THIRD mutation_adapter.sh copy (second map, MT-10)"

dr="$SANDBOX/v7t"; seed_mut "$dr"
sed 's/BLOCKED: vacuous-test/BLOCKED: renamed-token/g' "$dr/plugins/autopilot/scripts/mutation_gate.sh" > "$dr/g.tmp" \
  && mv "$dr/g.tmp" "$dr/plugins/autopilot/scripts/mutation_gate.sh"
expect_fail V7 "$dr" "drifted [BLOCKED: vacuous-test] producer token"

dr="$SANDBOX/v7u"; seed_mut "$dr"
sed 's/mutant-on-core-path/mutant-elsewhere/g' "$dr/plugins/codebase-health/skills/cleanup-audit/scripts/check_mutation_survivors.sh" > "$dr/c.tmp" \
  && mv "$dr/c.tmp" "$dr/plugins/codebase-health/skills/cleanup-audit/scripts/check_mutation_survivors.sh"
expect_fail V7 "$dr" "drifted mutant-on-core-path consumer token"

dr="$SANDBOX/v7p"; seed_mut "$dr"
printf '\nSome extra prose AFTER the vendored block.\n' >> "$dr/plugins/autopilot/references/mutation-adapters.md"
expect_no_fail V7 "$dr" "prose appended outside the vendored map markers"

# V10 (ADR 0017/0018 / register RL-13) — the remediation loop's two lint-pinned
# tables. Plant a drift in EACH (escalate-class table + slug_provenance §12/taxonomy)
# and assert V10 fires; a benign TSV comment must stay green. Numbered V10 (V9 is
# the parallel prod-triage stream's rule — no collision).
RL_CLASSIFY_REL="plugins/codebase-health/skills/cleanup-audit/scripts/classify_fix.sh"
RL_PROV_REL="plugins/codebase-health/skills/cleanup-audit/scripts/slug_provenance.tsv"
TAB="$(printf '\t')"

# V10-a — a Category-TX money/auth slug is dropped from the escalate-class table
# (the escalate-class must stay a SUPERSET of audit-state-and-verify.md's TX catalog).
dr="$SANDBOX/v10a"; seed_rl "$dr"
sed 's/|missing-audit-trail)/)/' "$dr/$RL_CLASSIFY_REL" > "$dr/cf.tmp" && mv "$dr/cf.tmp" "$dr/$RL_CLASSIFY_REL"
expect_fail V10 "$dr" "TX slug 'missing-audit-trail' dropped from the escalate-class table (no longer a superset)"

# V10-b — a §12 provenance anchor is flipped (deterministic <-> agent), which would
# silently change what the loop autonomously files.
dr="$SANDBOX/v10b"; seed_rl "$dr"
sed "s/^dark-money-movement${TAB}deterministic/dark-money-movement${TAB}agent/" "$dr/$RL_PROV_REL" > "$dr/pv.tmp" && mv "$dr/pv.tmp" "$dr/$RL_PROV_REL"
expect_fail V10 "$dr" "§12 provenance anchor flipped (dark-money-movement deterministic->agent)"

# V10-c — an invented slug (not in the audit taxonomy) is added to the table.
dr="$SANDBOX/v10c"; seed_rl "$dr"
printf 'totally-invented-nonexistent-slug\tdeterministic\tbogus\n' >> "$dr/$RL_PROV_REL"
expect_fail V10 "$dr" "invented slug (absent from the audit taxonomy) added to slug_provenance.tsv"

# V10 false-positive guard — a benign trailing comment on the TSV stays GREEN.
dr="$SANDBOX/v10p"; seed_rl "$dr"
printf '# benign trailing note: provenance table unchanged\n' >> "$dr/$RL_PROV_REL"
expect_no_fail V10 "$dr" "benign trailing comment appended to slug_provenance.tsv"

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
run_ok "org-memory"      bash "$ROOT/plugins/org-memory/scripts/self_test.sh"

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
  echo "== suite_self_test: PASS — all components green (lints + red-tests + validator + all five plugins) =="
  echo "   NOTE: optional sections were SKIPPED (missing dev tools) in:$SKIPPED — this run is not zero-skip; see the WARN lines above."
  if [ -n "${SUITE_STRICT:-}" ]; then
    echo "== SUITE_STRICT=1: a skipped section is a failure — exiting non-zero =="
    exit 1
  fi
  echo "   (set SUITE_STRICT=1 to require a zero-skip proof.)"
  exit 0
fi
echo "== suite_self_test: PASS (lints + red-tests + validator + all five plugins, ZERO skips) =="
exit 0
