#!/usr/bin/env bash
# suite_self_test.sh — ONE command that proves the whole Zero-Trust Verification
# suite (ADR 0001, consolidated to a single plugin by ADR 0025). It runs, in
# order, and reports a single green/red:
#
#   1. cross-domain contract lints (scripts/lint_consistency.sh) — GREEN run
#   2. lint RED-tests — plant a violation per surviving integrity rule
#      (V6 product-entry incl. marketplace residue, a plugin.json name drift,
#      and a rogue 2nd installable plugin, V9 triage telemetry-contract
#      byte-identity + resume-helper
#      re-vendor pin, V10 remediation tables, V11 outcome-store schema/contract
#      byte-identity + the H1 anti-laundering guard, V12 System-Design Coverage
#      unfalsifiability + no-parallel-comparator guards, V13 health-loop pins)
#      and assert the lint catches it, plus false-POSITIVE guards — so no
#      surviving lint is vacuous and none reds on a benign reformat/prose
#      mention. (The retired byte-identity vendoring rules V1/V3/V4/V5/V7/V8
#      were deleted with the vendored copies they policed — ADR 0025; their
#      planted-drift red-tests went with them.)
#   3. the manifest-validator self-test (scripts/self_test.sh — drives the
#      canonical validator inside plugins/zero-trust)
#   4. every domain's own self-test: autopilot, spec-gen, codebase-health,
#      marshal, org-memory, triage (all inside the one plugin)
#   5. the outcome-measurement layer self-test (scripts/outcome_self_test.sh,
#      ADR 0023; OM-01..OM-08), skip-honest on the Marshal MOCK host
#   6. the System-Design Coverage tier self-test (scripts/sd_self_test.sh,
#      ADR 0021/0022; SD-01..SD-12), skip-honest without the validator toolchain
#
# HONESTY: a domain self-test can `exit 0` while SKIPPING guarded sections when an
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
ZT="$ROOT/plugins/zero-trust"

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

# skip signals across the domains: autopilot and marshal print an uppercase SKIPPED
# note (+ autopilot an "N skipped" counter); codebase-health prints a line-start
# "[skip]". A mid-line "[skip]" inside an assertion label is NOT a real skip.
component_skips() { { grep -nE 'SKIPPED|[1-9][0-9]* skipped' "$1"; grep -nE '^[[:space:]]*\[skip\]' "$1"; } 2>/dev/null; }

# a component that must exit 0 (a self-test or the green lint); skip-aware.
run_ok() {  # <name> <cmd...>
  local name="$1"; shift
  note "$name"
  if "$@" > "$LOGDIR/$name.log" 2>&1; then
    grep -hE 'passed|PASS=|self-test:|run_cases:|all cross-domain' "$LOGDIR/$name.log" | tail -1
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
# 1. Contract lints — GREEN run (all surviving rules pass against the real tree)
# ==============================================================================
run_ok "lint-consistency" bash "$LINT"

# ==============================================================================
# 2. Lint RED-tests (each surviving integrity rule must catch a planted
#    violation) + false-POSITIVE guards (a benign change stays green).
#    The V1/V3/V4/V5/V7/V8 planted-drift tests were DELETED with their rules
#    (ADR 0025 — the vendored copies they policed no longer exist).
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

# seed the single plugin.json source dir into a sandbox
seed_plugins() {
  local d="$1"
  mkdir -p "$d/plugins/zero-trust/.claude-plugin"
  cp "$ZT/.claude-plugin/plugin.json" "$d/plugins/zero-trust/.claude-plugin/"
}
# seed the canonical telemetry contract + a SYNTHESIZED carrier that re-vendors
# its marker block for the V9 red-test. The live tree is copy-free (ADR 0030);
# V9 stays as a tripwire, so the red test manufactures the copy it drifts INSIDE
# the sandbox — no live-tree file is ever mutated.
seed_tel() {
  local d="$1"
  mkdir -p "$d/plugins/zero-trust/references"
  cp "$ZT/references/telemetry-contract.md" "$d/plugins/zero-trust/references/"
  { printf '# Synthesized carrier re-vendoring the telemetry-contract block (red-test fixture)\n\n'
    awk '/vendored:telemetry-contract:begin/{f=1} f{print} /vendored:telemetry-contract:end/{f=0}' \
      "$ZT/references/telemetry-contract.md"
  } > "$d/plugins/zero-trust/references/revendored-carrier.md"
}

# seed what lint V10 (remediation loop) needs: the cleanup-audit skill
# (classify_fix.sh + slug_provenance.tsv + the audit taxonomy the slugs must exist
# in) plus the SPEC_1.4.0 §12 doc the provenance anchors cite.
seed_rl() {
  local d="$1"
  mkdir -p "$d/plugins/zero-trust/skills" "$d/docs/specs"
  cp -R "$ZT/skills/cleanup-audit" "$d/plugins/zero-trust/skills/cleanup-audit"
  cp "$ROOT/docs/specs/codebase-health-spec-1.4.0.md" "$d/docs/specs/"
}

# seed what lint V11 (outcome-store pins) needs: the canonical outcome schema +
# a second copy, the canonical outcome-store-contract doc + a SYNTHESIZED carrier
# re-vendoring its marker block (the live tree is copy-free, ADR 0030 — same
# tripwire pattern as seed_tel), and the register (for the H1 anti-laundering
# guard). ADR 0023 / register OM-09.
seed_om() {
  local d="$1"
  mkdir -p "$d/plugins/zero-trust/schema/outcome" "$d/plugins/extra/schema/outcome" \
           "$d/docs/specs" "$d/plugins/zero-trust/references"
  cp "$ZT/schema/outcome/v1.schema.json" "$d/plugins/zero-trust/schema/outcome/"
  cp "$ZT/schema/outcome/v1.schema.json" "$d/plugins/extra/schema/outcome/"
  cp "$ROOT/docs/specs/outcome-store-contract.md" "$d/docs/specs/"
  { printf '# Synthesized carrier re-vendoring the outcome-store-contract block (red-test fixture)\n\n'
    awk '/vendored:outcome-store-contract:begin/{f=1} f{print} /vendored:outcome-store-contract:end/{f=0}' \
      "$ROOT/docs/specs/outcome-store-contract.md"
  } > "$d/plugins/zero-trust/references/revendored-carrier.md"
  cp "$ROOT/docs/specs/outcome-measurement-register.md" "$d/docs/specs/"
}

# seed what lint V12 (System-Design Coverage guards) reads: the CH-03 join engine
# (manifest_join.py + its wrapper) + the canonical manifest schema.
# ADR 0021/0022 / register SD-12.
seed_sd() {
  local d="$1"
  mkdir -p "$d/plugins/zero-trust/skills/cleanup-audit/scripts" \
           "$d/plugins/zero-trust/schema/verification-manifest"
  cp "$ZT/skills/cleanup-audit/scripts/manifest_join.py" "$d/plugins/zero-trust/skills/cleanup-audit/scripts/"
  cp "$ZT/skills/cleanup-audit/scripts/manifest_join.sh" "$d/plugins/zero-trust/skills/cleanup-audit/scripts/"
  cp "$ZT/schema/verification-manifest/v1.schema.json" "$d/plugins/zero-trust/schema/verification-manifest/"
}

# V6 — the plugin loses its plugin.json (the product entry point vanishes).
dr="$SANDBOX/v6"; seed_plugins "$dr"
rm "$dr/plugins/zero-trust/.claude-plugin/plugin.json"
expect_fail V6 "$dr" "product plugin.json missing"

# V6 — marketplace residue reappears at the root (the retired entry point
# comes back, ADR 0027).
dr="$SANDBOX/v6s"; seed_plugins "$dr"; mkdir -p "$dr/.claude-plugin"
printf '{"name":"zero-trust-verification","plugins":[]}\n' > "$dr/.claude-plugin/marketplace.json"
expect_fail V6 "$dr" "marketplace.json residue at the repo root"

# V6 — nested marketplace residue (inside the plugin dir).
dr="$SANDBOX/v6n"; seed_plugins "$dr"
printf '{}\n' > "$dr/plugins/zero-trust/.claude-plugin/marketplace.json"
expect_fail V6 "$dr" "nested marketplace.json residue"

# V6 — a rogue SECOND installable plugin appears under plugins/ (the product
# is exactly one — ADR 0025, policed on the tree since ADR 0027).
dr="$SANDBOX/v6r"; seed_plugins "$dr"
mkdir -p "$dr/plugins/rogue/.claude-plugin"
printf '{"name":"rogue-plugin","version":"0.0.1"}\n' > "$dr/plugins/rogue/.claude-plugin/plugin.json"
expect_fail V6 "$dr" "rogue 2nd installable plugin under plugins/"

# V6 false-positive guard — a non-installable helper dir under plugins/ (no
# plugin.json, e.g. a schema-copy fixture) is not a rogue plugin.
dr="$SANDBOX/v6x"; seed_plugins "$dr"
mkdir -p "$dr/plugins/extra/schema"
printf '{}\n' > "$dr/plugins/extra/schema/x.json"
expect_no_fail V6 "$dr" "non-installable extra dir under plugins/ (no plugin.json)"

# V6 — the plugin.json name drifts from 'zero-trust' (the skills-dir install
# resolves the plugin by this name).
if command -v python3 >/dev/null 2>&1; then
  dr="$SANDBOX/v6sw"; seed_plugins "$dr"
  python3 -c "
import json
p='$dr/plugins/zero-trust/.claude-plugin/plugin.json'
d=json.load(open(p)); d['name']='zero-trust-old'
json.dump(d,open(p,'w'),indent=2)"
  expect_fail V6 "$dr" "plugin.json name drifted from 'zero-trust'"

  # V6 false-positive guard — a compact (whitespace-stripped) reserialization is fine.
  dr="$SANDBOX/v6c"; seed_plugins "$dr"
  python3 -c "
import json
p='$dr/plugins/zero-trust/.claude-plugin/plugin.json'
json.dump(json.load(open(p)),open(p,'w'),separators=(',',':'))"
  expect_no_fail V6 "$dr" "compact-JSON plugin.json reserialization"
else
  echo "  [note] python3 absent — V6 structural red-tests (name-drift / compact) skipped"
fi

# V9 (register TR-08) — the telemetry contract has ONE copy on the live tree
# (references/telemetry-contract.md; ADR 0030) and V9 stays as a re-vendoring
# tripwire. seed_tel synthesizes a carrier re-vendoring the block IN THE SANDBOX;
# drift it -> V9 fires; a benign out-of-block append stays green (no false positive).
dr="$SANDBOX/v9"; seed_tel "$dr"
sed 's/Never a whole-fleet scan./Never a whole-fleet scan. DRIFTED./' "$dr/plugins/zero-trust/references/revendored-carrier.md" > "$dr/t.tmp" \
  && mv "$dr/t.tmp" "$dr/plugins/zero-trust/references/revendored-carrier.md"
expect_fail V9 "$dr" "drifted re-vendored telemetry-contract block (synthesized carrier)"

dr="$SANDBOX/v9p"; seed_tel "$dr"
printf '\nSome extra prose AFTER the re-vendored telemetry-contract block.\n' >> "$dr/plugins/zero-trust/references/revendored-carrier.md"
expect_no_fail V9 "$dr" "prose appended outside the telemetry-contract markers (synthesized carrier)"

# V9 resume-helper re-vendor pin (ADR 0001 §18, post-0025 shape): the resume
# helper lives exactly once under plugins/zero-trust/scripts/; a SECOND copy that
# reappears anywhere must be byte-identical to the canonical. Drift the copy ->
# V9 fires. Seed the canonical (and telemetry-contract.md so V9 runs).
dr="$SANDBOX/v9s"
mkdir -p "$dr/plugins/zero-trust/scripts" "$dr/plugins/extra/scripts" "$dr/plugins/zero-trust/references"
cp "$ZT/references/telemetry-contract.md" "$dr/plugins/zero-trust/references/"
cp "$ZT/scripts/resume_projection.py" "$dr/plugins/zero-trust/scripts/"
cp "$ZT/scripts/resume_projection.py" "$dr/plugins/extra/scripts/"
printf '\n# drift\n' >> "$dr/plugins/extra/scripts/resume_projection.py"
expect_fail V9 "$dr" "re-vendored resume helper drifted (resume_projection.py != canonical)"

# V9 re-vendor false-positive guard — an unmodified second copy stays GREEN.
dr="$SANDBOX/v9sp"
mkdir -p "$dr/plugins/zero-trust/scripts" "$dr/plugins/extra/scripts" "$dr/plugins/zero-trust/references"
cp "$ZT/references/telemetry-contract.md" "$dr/plugins/zero-trust/references/"
cp "$ZT/scripts/resume_projection.py" "$dr/plugins/zero-trust/scripts/"
cp "$ZT/scripts/resume_projection.py" "$dr/plugins/extra/scripts/"
expect_no_fail V9 "$dr" "unmodified second resume-helper copy (byte-identical to canonical)"

# V10 (ADR 0017/0018 / register RL-13) — the remediation loop's two lint-pinned
# tables. Plant a drift in EACH (escalate-class table + slug_provenance §12/taxonomy)
# and assert V10 fires; a benign TSV comment must stay green.
RL_CLASSIFY_REL="plugins/zero-trust/skills/cleanup-audit/scripts/classify_fix.sh"
RL_PROV_REL="plugins/zero-trust/skills/cleanup-audit/scripts/slug_provenance.tsv"
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

# V11 (ADR 0023 / register OM-09) — the outcome-store contract has ONE prose copy
# (docs/specs/outcome-store-contract.md; ADR 0030); V11's copy scans stay as
# re-vendoring tripwires, and the register must not launder an agent-graded number
# as [det]. Plant a drift per guarantee (block drifts go into seed_om's
# sandbox-synthesized carrier) and assert V11 fires; two false-positive guards
# (identical reformat, prose outside the block) stay green.
OM_SCHEMA_REL="plugins/extra/schema/outcome/v1.schema.json"
OM_BLOCK_REL="plugins/zero-trust/references/revendored-carrier.md"
OM_REG_REL="docs/specs/outcome-measurement-register.md"

# V11-a — a second outcome-store schema copy drifts from the canonical.
dr="$SANDBOX/v11a"; seed_om "$dr"; printf '\n' >> "$dr/$OM_SCHEMA_REL"
expect_fail V11 "$dr" "drifted second outcome-store schema copy"

# V11-b — a re-vendored outcome-store-contract block (synthesized carrier) drifts
# from the canonical.
dr="$SANDBOX/v11b"; seed_om "$dr"
sed 's/append-only/APPEND-ONLY-DRIFTED/' "$dr/$OM_BLOCK_REL" > "$dr/om.tmp" && mv "$dr/om.tmp" "$dr/$OM_BLOCK_REL"
expect_fail V11 "$dr" "drifted re-vendored outcome-store-contract block (synthesized carrier)"

# V11-c — the H1 anti-laundering guard: a [det] acceptance claims a real-repo
# agent-graded number in the register.
dr="$SANDBOX/v11c"; seed_om "$dr"
printf -- '- [det] on a REAL repo the emission share (agent-graded input) is 0.9\n' >> "$dr/$OM_REG_REL"
expect_fail V11 "$dr" "register [det] acceptance laundering a real-repo agent-graded number"

# V11 false-positive guard #1 — reformatting the canonical AND the second copy
# IDENTICALLY (both get the same trailing newline) stays green: the rule keys on
# DRIFT, not on formatting.
dr="$SANDBOX/v11p1"; seed_om "$dr"
printf '\n' >> "$dr/plugins/zero-trust/schema/outcome/v1.schema.json"; printf '\n' >> "$dr/$OM_SCHEMA_REL"
expect_no_fail V11 "$dr" "canonical + second schema copy reformatted identically (no drift)"

# V11 false-positive guard #2 — prose appended OUTSIDE the contract-block markers
# (on the synthesized carrier).
dr="$SANDBOX/v11p2"; seed_om "$dr"
printf '\nSome extra prose after the re-vendored outcome-store-contract block.\n' >> "$dr/$OM_BLOCK_REL"
expect_no_fail V11 "$dr" "prose appended outside the outcome-store-contract markers (synthesized carrier)"

# V12 (ADR 0021/0022 / register SD-12) — the System-Design Coverage tier's two
# structural guards. Plant a violation per guard and assert V12 fires; a prose
# mention of a missing-X phrase (no emit) stays green.
SD_JOINPY_REL="plugins/zero-trust/skills/cleanup-audit/scripts/manifest_join.py"

# V12-a1 — the CENTRAL PROHIBITION: the join engine EMITS a raw missing-X finding
# for a non-app control (unfalsifiable against an out-of-repo locus).
dr="$SANDBOX/v12a1"; seed_sd "$dr"
printf '\nemit("ROW abuse-controls-drift FAIL :: missing rate limit at the gateway")\n' >> "$dr/$SD_JOINPY_REL"
expect_fail V12 "$dr" "join engine emits a raw missing-X finding for a non-app SD control (unfalsifiability breach)"

# V12-a2 — the marked vendored:sd-locus-guard region is removed (the out-of-scope
# short-circuit is unguarded).
dr="$SANDBOX/v12a2"; seed_sd "$dr"
grep -v 'vendored:sd-locus-guard' "$dr/$SD_JOINPY_REL" > "$dr/j.tmp" && mv "$dr/j.tmp" "$dr/$SD_JOINPY_REL"
expect_fail V12 "$dr" "the SD locus-guard region stripped from manifest_join.py"

# V12-b1 — a SIBLING script carries an SD drift slug: a second SD comparator outside
# the CH-03 engine (ADR 0003 / MT-10 no-parallel-infra).
dr="$SANDBOX/v12b1"; seed_sd "$dr"
printf '#!/usr/bin/env bash\n# rogue: emits abuse-controls-drift outside the one join engine\necho "ROW abuse-controls-drift PASS"\n' \
  > "$dr/plugins/zero-trust/skills/cleanup-audit/scripts/sd_rogue_join.sh"
expect_fail V12 "$dr" "a sibling script carries an SD drift slug (parallel comparator)"

# V12-b2 — an SD drift row is moved OUT of the CH-03 engine (renamed away).
dr="$SANDBOX/v12b2"; seed_sd "$dr"
sed 's/timeout-budget-drift/timeout-budget-DRIFTED/g' "$dr/$SD_JOINPY_REL" > "$dr/j.tmp" && mv "$dr/j.tmp" "$dr/$SD_JOINPY_REL"
expect_fail V12 "$dr" "an SD drift row ('timeout-budget-drift') no longer lives in manifest_join.py"

# V12 false-positive guard — a PROSE comment naming a missing-X phrase (no emit/print
# call on the line) is documentation, not a raw finding: stays green.
dr="$SANDBOX/v12p"; seed_sd "$dr"
printf '\n# SD honesty note: a raw "missing rate limit" finding is exactly what this tier forbids.\n' >> "$dr/$SD_JOINPY_REL"
expect_no_fail V12 "$dr" "prose comment naming a missing-X phrase (no emit/print call)"

# V13 (ADR 0024 / register HL) — the /health-loop presence/vocabulary/read-only
# pins. Plant a violation per guard; a benign comment stays green. The seed
# carries NO product plugin.json, so the full-tree cross-domain presence
# sub-check stays out of these sandboxes by design.
seed_hl() {
  local d="$1" ca="plugins/zero-trust/skills/cleanup-audit"
  mkdir -p "$d/plugins/zero-trust/commands" "$d/$ca/references" "$d/$ca/scripts"
  cp "$ZT/commands/health-loop.md" "$d/plugins/zero-trust/commands/"
  cp "$ZT/skills/cleanup-audit/loop.config.yaml"                 "$d/$ca/"
  cp "$ZT/skills/cleanup-audit/references/health-loop.md"        "$d/$ca/references/"
  cp "$ZT/skills/cleanup-audit/references/audit-state-and-verify.md" "$d/$ca/references/"
  cp "$ZT/skills/cleanup-audit/scripts/spec_wave.sh" "$ZT/skills/cleanup-audit/scripts/wave_gate.sh" \
     "$ZT/skills/cleanup-audit/scripts/wave_gate.py" "$ZT/skills/cleanup-audit/scripts/wave_preauth_check.sh" \
     "$d/$ca/scripts/"
}
HL_CA_REL="plugins/zero-trust/skills/cleanup-audit"

# V13-a — half-shipped loop: the command ships without the gate backend.
dr="$SANDBOX/v13a"; seed_hl "$dr"
rm "$dr/$HL_CA_REL/scripts/wave_gate.py"
expect_fail V13 "$dr" "health-loop command present but wave_gate.py missing (presence coupling)"

# V13-b — config vocabulary drift: a wave_policy value outside auto|pause.
dr="$SANDBOX/v13b"; seed_hl "$dr"
sed 's/^  "3": pause/  "3": yolo/' "$dr/$HL_CA_REL/loop.config.yaml" > "$dr/c.tmp" && mv "$dr/c.tmp" "$dr/$HL_CA_REL/loop.config.yaml"
expect_fail V13 "$dr" "wave_policy \"3\" set to an unknown value (yolo)"

# V13-c — gate vocabulary escape: wave_gate.py judges a status the verifier
# lifecycle never writes.
dr="$SANDBOX/v13c"; seed_hl "$dr"
sed 's/^INCOMPLETE_STATUSES = (\"OPEN\"/INCOMPLETE_STATUSES = (\"HALFDONE\", \"OPEN\"/' \
  "$dr/$HL_CA_REL/scripts/wave_gate.py" > "$dr/g.tmp" && mv "$dr/g.tmp" "$dr/$HL_CA_REL/scripts/wave_gate.py"
expect_fail V13 "$dr" "wave_gate.py judges status HALFDONE, absent from the lifecycle"

# V13-d — read-only pin: a write path appears in the gate.
dr="$SANDBOX/v13d"; seed_hl "$dr"
printf '\n# planted drift\ndef _persist(p, data):\n    p.write_text(data)\n' >> "$dr/$HL_CA_REL/scripts/wave_gate.py"
expect_fail V13 "$dr" "wave_gate.py grows a write_text path (read-only pin)"

# V13 false-positive guard — a benign comment in loop.config.yaml stays green.
dr="$SANDBOX/v13p"; seed_hl "$dr"
printf '\n# operator note: flipped nothing, just a comment\n' >> "$dr/$HL_CA_REL/loop.config.yaml"
expect_no_fail V13 "$dr" "benign comment appended to loop.config.yaml"

# V13 false-positive guard #2 — a PROSE COMMENT in wave_gate.py naming write_text
# is documentation of the pin, not a write path: stays green (the V12 precedent).
dr="$SANDBOX/v13p2"; seed_hl "$dr"
printf '\n# note: this gate deliberately has no write_text call anywhere\n' >> "$dr/$HL_CA_REL/scripts/wave_gate.py"
expect_no_fail V13 "$dr" "prose comment in wave_gate.py naming write_text (no call)"

# V13-e — stale default-path regression (simplification review 2026-07-17 §1):
# a host/secret DEFAULT reverts to the pre-consolidation plugins/autopilot path.
# The default-resolution pin lives in the plugin.json-keyed cross-domain block,
# so this seed carries a plugin.json (unlike seed_hl's deliberately bare ones).
seed_paths() {
  local d="$1"
  seed_hl "$d"
  mkdir -p "$d/plugins/zero-trust/.claude-plugin" "$d/plugins/zero-trust/scripts/backends" \
           "$d/plugins/zero-trust/skills/autopilot/scripts"
  cp "$ZT/.claude-plugin/plugin.json" "$d/plugins/zero-trust/.claude-plugin/"
  cp "$ZT/scripts/marshal.sh" "$ZT/scripts/outcome_capture.sh" "$ZT/scripts/outcome_digest.sh" \
     "$ZT/scripts/resume_handoff.sh" "$ZT/scripts/loop_guard.py" "$d/plugins/zero-trust/scripts/"
  cp "$ZT/scripts/backends/cloudwatch.sh" "$ZT/scripts/backends/dynatrace.sh" \
     "$d/plugins/zero-trust/scripts/backends/"
  cp "$ZT/skills/autopilot/scripts/host.sh" "$ZT/skills/autopilot/scripts/secret_get.sh" \
     "$d/plugins/zero-trust/skills/autopilot/scripts/"
}
dr="$SANDBOX/v13e"; seed_paths "$dr"
sed 's|skills/autopilot/scripts/host.sh|../../autopilot/scripts/host.sh|' \
  "$dr/plugins/zero-trust/scripts/marshal.sh" > "$dr/m.tmp" && mv "$dr/m.tmp" "$dr/plugins/zero-trust/scripts/marshal.sh"
expect_fail V13 "$dr" "marshal.sh MARSHAL_HOST default reverted to the pre-consolidation autopilot path"

# V13-e false-positive guard — the clean full-tree seed (plugin.json present,
# consolidated defaults) stays green on V13.
dr="$SANDBOX/v13ep"; seed_paths "$dr"
expect_no_fail V13 "$dr" "clean full-tree seed with consolidated default paths"

if [ "$RED_FAIL" -eq 0 ]; then
  echo "  -> lint-red-tests PASS (every surviving lint caught its planted violation; no false positives)"; record "lint-red-tests" PASS
else
  echo "  -> lint-red-tests FAIL (a lint is vacuous or false-firing — see above)"; FAILED="$FAILED lint-red-tests"; record "lint-red-tests" FAIL
fi

# ==============================================================================
# 3. Manifest-validator self-test (ADR 0014/0015 — the canonical validator
#    lives inside plugins/zero-trust; the harness stays root-level dev tooling)
# ==============================================================================
run_ok "validator-self-test" bash "$ROOT/scripts/self_test.sh"

# ==============================================================================
# 4. Every domain's own self-test (all inside the one plugin, ADR 0025)
# ==============================================================================
run_ok "autopilot"       bash "$ZT/skills/autopilot/scripts/self_test.sh"
run_ok "spec-gen"        bash "$ZT/scripts/self_test_spec_gen.sh"
run_ok "codebase-health" bash "$ROOT/tests/codebase-health/self_test.sh"
run_ok "marshal"         bash "$ZT/scripts/self_test_marshal.sh"
run_ok "org-memory"      bash "$ZT/scripts/self_test_org_memory.sh"
run_ok "triage"          bash "$ZT/scripts/self_test_triage.sh"

# ==============================================================================
# 5. Outcome-measurement layer self-test (ADR 0023; register OM-01..OM-08). Its
#    host-dependent DORA/digest assertions drive the Marshal MOCK host and SKIP with
#    a loud notice when uv is absent (skip-honesty via component_skips) — never a
#    false green.
# ==============================================================================
run_ok "outcome-self-test" bash "$ROOT/scripts/outcome_self_test.sh"

# ==============================================================================
# 6. System-Design Coverage tier self-test (ADR 0021/0022; register SD-01..SD-12).
#    Declare-then-verify [det] half: schema additive-safety, the out-of-scope-by-
#    declaration short-circuit + unfalsifiability guard, the four §12 comparator
#    rows, the in-repo candidate seeds + must_not_flag negatives. Its join/validator
#    sections [skip] loudly without the validator toolchain (skip-honest).
# ==============================================================================
run_ok "sd-self-test" bash "$ROOT/scripts/sd_self_test.sh"

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
  echo "== suite_self_test: PASS — all components green (lints + red-tests + validator + all six domains) =="
  echo "   NOTE: optional sections were SKIPPED (missing dev tools) in:$SKIPPED — this run is not zero-skip; see the WARN lines above."
  if [ -n "${SUITE_STRICT:-}" ]; then
    echo "== SUITE_STRICT=1: a skipped section is a failure — exiting non-zero =="
    exit 1
  fi
  echo "   (set SUITE_STRICT=1 to require a zero-skip proof.)"
  exit 0
fi
echo "== suite_self_test: PASS (lints + red-tests + validator + all six domains, ZERO skips) =="
exit 0
