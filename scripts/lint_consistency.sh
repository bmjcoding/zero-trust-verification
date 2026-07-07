#!/usr/bin/env bash
# Repo-level cross-plugin consistency lint (MS §13.3 vendoring-lint host; ADR 0001).
#
# The suite's plugins are consumed by an LLM that treats vendored artifacts as
# ground truth; two copies of one contract that drift are a coin-flip at runtime.
# This is the CROSS-PLUGIN host (autopilot and codebase-health each also have a
# plugin-local self-test/lint; this one pins contracts that span more than one
# plugin — the ones ADR 0001 says must be vendored from a SINGLE source):
#
#   V1 — the Verification-Manifest JSON Schema. There is ONE canonical copy
#        (schema/verification-manifest/v1.schema.json). Any vendored copy shipped
#        inside a plugin (for standalone install) must be byte-identical to it.
#        SCOPED to */verification-manifest/v1.schema.json: other schemas that reuse
#        the leaf name v1.schema.json (e.g. org-memory's record schema under
#        schema/org-memory/) are DIFFERENT single-source schemas, not manifest-schema
#        copies, and are pinned by their own rule (ADR 0019 / lint V8), not V1.
#   V2 — the `## Behavior coverage` PR-body format. One canonical definition
#        (docs/specs/behavior-coverage-format.md) that the autopilot AV3-05
#        producer and the codebase-health CH-06 consumer both use.
#   V3 — the manifest validator scripts (validate_manifest.sh + .py, ADR 0001/0014).
#        One canonical copy under scripts/; vendored copies byte-identical. The
#        autopilot `--union` checker shares the .sh name but is a DISTINCT tool
#        (exempt only while it carries the union tool's own union-only tokens; a
#        drifted single-file validator copy that merely mentions --union is flagged).
#   V4 — the claim-overlap primitive (autopilot + Marshal, ADR 0009), byte-identical.
#   V5 — the ADR 0002 escalation-criterion block, vendored VERBATIM into every
#        tier's prompt (autopilot planner/implementer, spec-gen SKILL, audit
#        severity-rubric); byte-identical AND present in all three tiers.
#   V6 — the product marketplace (ADR 0001/0011/0019/0020): ONE root .claude-plugin/
#        marketplace.json is the single entry point registering all six plugins,
#        each with a source dir carrying its own .claude-plugin/plugin.json.
#   V9 — the triage telemetry-adapter observable contract (ADR 0006/0013; register
#        TR-08): reference/telemetry-contract.md is the single source; any vendored
#        backend-contract copy is byte-identical (the host-contract precedent). V9
#        because V7 (mutation map) / V8 (OWM) are taken; V10 is the parallel
#        remediation-loop chip's rule — no collision.
#   V8 — OWM vendoring lint (ADR 0019, register OWM-10): org-memory's manifest-parse
#        path uses the CANONICAL validate_manifest toolchain (never a forked parser),
#        and its format-recognizer references name the single-source docs; if the
#        OWM-09 enumeration path is vendored, its copy is byte-identity-pinned.
#        (V7 is the parallel mutation-testing stream's rule; V8 does not collide.)
#   V7 — the mutation adapter map (ADR 0016): the vendored
#        <!-- vendored:mutation-adapter-map --> doc block AND the executable
#        resolver mutation_adapter.sh are byte-identical across the autopilot D6.5
#        producer and the codebase-health PR-Gate consumer (the only two copies —
#        MT-10 sole source), and the [BLOCKED: vacuous-test] producer / mutant-on-
#        core-path consumer tokens are pinned so producer and consumer cannot drift.
#
# $LINT_ROOT points the lint at a fixture tree so the self-test can plant a drift
# and prove each byte-identity rule has teeth (scripts/suite_self_test.sh; the
# codebase-health CH-10 assertions also drive V1). All rules honor it via $ROOT.
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
  done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -path "$ROOT/.claude" -prune -o -path '*/verification-manifest/v1.schema.json' -print 2>/dev/null)
  [ "$copies" -eq 0 ] && ok V1 "single canonical manifest schema; no vendored copies to drift (ADR 0001)"
fi

# ── V2: the `## Behavior coverage` format has one canonical definition both
#        the AV3-05 producer and the CH-06 consumer honor ───────────────────────
FMT_DOC="$ROOT/docs/specs/behavior-coverage-format.md"
CONSUMER="$ROOT/plugins/codebase-health/skills/cleanup-audit/scripts/check_behavior_coverage.sh"
PRODUCER_REF="$ROOT/plugins/autopilot/references/validator-prompts.md"

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

# ── V3: vendored VALIDATOR SCRIPTS byte-identical to the canonical (ADR 0001) ──
# The manifest validator ships as two files — validate_manifest.sh (the exit-code
# entrypoint) and validate_manifest.py (the logic, ADR 0014). There is ONE
# canonical copy of each under scripts/; any copy a plugin vendors for standalone
# install (spec-gen does) must be byte-identical to it. ONE legitimate collision:
# plugins/autopilot/scripts/validate_manifest.sh is the `--union` multi-doc checker
# (AV3-03), NOT a vendored copy of the single-file validator — it is exempt only
# while it carries the union tool's own union-only tokens (`--union` AND
# `manifest-id-collision`, which the single-file validator never contains), so a
# drifted single-file-validator copy that merely mentions `--union` in a comment
# is NOT exempted — it is flagged.
v3_exempt() {  # <relpath> <abs-file> -> 0 iff this is the genuine union tool
  case "$1" in
    plugins/autopilot/scripts/validate_manifest.sh)
      grep -q -- '--union' "$2" && grep -q 'manifest-id-collision' "$2" ;;
    *) return 1 ;;
  esac
}
for base in validate_manifest.sh validate_manifest.py; do
  canon="$ROOT/scripts/$base"
  if [ ! -f "$canon" ]; then
    violation V3 "canonical validator missing: scripts/$base"
    continue
  fi
  v3_copies=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ "$c" = "$canon" ] && continue
    rel="${c#$ROOT/}"
    v3_copies=$((v3_copies+1))
    if cmp -s "$canon" "$c"; then
      ok V3 "vendored validator byte-identical: $rel"
    elif v3_exempt "$rel" "$c"; then
      ok V3 "distinct same-named tool (not a vendored copy), exempt: $rel"
    else
      violation V3 "vendored validator DRIFTED from canonical: $rel (ADR 0001 — vendor byte-for-byte from scripts/$base)"
    fi
  done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -path "$ROOT/.claude" -prune -o -name node_modules -prune -o -name "$base" -print 2>/dev/null)
  [ "$v3_copies" -eq 0 ] && ok V3 "single canonical validator scripts/$base; no vendored copies to drift (ADR 0001)"
done

# ── V4: vendored claim-overlap primitive byte-identical (ADR 0009) ────────────
# The open-PR file-surface intersection is consumed by autopilot's G4/D2 and the
# Marshal's nudge watcher; ADR 0009 vendors it into both, byte-identical. The
# canonical copy is autopilot's (the Marshal adopts it); pin every copy to it.
v4_canon="$ROOT/plugins/autopilot/scripts/claim_overlap.sh"
if [ ! -f "$v4_canon" ]; then
  v4_canon="$(find "$ROOT" -path "$ROOT/.git" -prune -o -path "$ROOT/.claude" -prune -o -name node_modules -prune -o -name 'claim_overlap.sh' -print 2>/dev/null | sort | head -1)"
fi
if [ -z "$v4_canon" ]; then
  ok V4 "no claim_overlap.sh present; nothing to pin (ADR 0009)"
else
  v4_copies=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ "$c" = "$v4_canon" ] && continue
    v4_copies=$((v4_copies+1))
    rel="${c#$ROOT/}"
    if cmp -s "$v4_canon" "$c"; then
      ok V4 "vendored claim_overlap byte-identical: $rel"
    else
      violation V4 "vendored claim_overlap DRIFTED from ${v4_canon#$ROOT/}: $rel (ADR 0009 — byte-identical copies)"
    fi
  done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -path "$ROOT/.claude" -prune -o -name node_modules -prune -o -name 'claim_overlap.sh' -print 2>/dev/null | sort)
  [ "$v4_copies" -eq 0 ] && ok V4 "single claim_overlap.sh (${v4_canon#$ROOT/}); no vendored copy to drift (ADR 0009)"
fi

# ── V5: vendored escalation-criterion block byte-identical across tiers (ADR 0002)
# The ADR 0002 autonomy boundary + MUST-escalate trilist is vendored VERBATIM into
# every tier's decision-making prompt, delimited by
# <!-- vendored:escalation-criterion:begin/end -->. Two guarantees:
#   (a) PRESENCE — the block lives in each EXPECTED prompt (pinned below), so a
#       removal or a move to the wrong file is caught, not just a byte drift;
#   (b) IDENTITY — every well-formed copy (the expected five AND any stray copy
#       elsewhere) is byte-identical. A file that only *mentions* a marker in prose
#       without a matching begin/end PAIR is documentation, not a copy (no false
#       positive); an EXPECTED prompt with unpaired markers IS flagged.
v5_begin='vendored:escalation-criterion:begin'
v5_end='vendored:escalation-criterion:end'
v5_extract() { awk -v b="$v5_begin" -v e="$v5_end" '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$1"; }
v5_expected="plugins/autopilot/references/planner-prompt.md
plugins/autopilot/references/implementer-prompt.md
plugins/spec-gen/skills/spec/SKILL.md
plugins/codebase-health/skills/cleanup-audit/references/severity-rubric.md
plugins/triage/skills/triage/SKILL.md"
v5_is_expected() {  # <relpath> -> 0 if one of the pinned prompts
  case "$1" in
    plugins/autopilot/references/planner-prompt.md|plugins/autopilot/references/implementer-prompt.md|plugins/spec-gen/skills/spec/SKILL.md|plugins/codebase-health/skills/cleanup-audit/references/severity-rubric.md|plugins/triage/skills/triage/SKILL.md) return 0 ;;
    *) return 1 ;;
  esac
}
v5_canon_txt=""; v5_canon_file=""; v5_bad=0
# (a) presence + identity across the pinned expected prompts (all three tiers)
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  f="$ROOT/$rel"
  if [ ! -f "$f" ]; then
    violation V5 "expected escalation-block prompt missing: $rel (ADR 0002)"; v5_bad=1; continue
  fi
  nb=$(grep -c "$v5_begin" "$f" 2>/dev/null || true)
  ne=$(grep -c "$v5_end" "$f" 2>/dev/null || true)
  if [ "${nb:-0}" -eq 0 ] || [ "${ne:-0}" -eq 0 ]; then
    violation V5 "expected prompt lacks the vendored escalation block: $rel (ADR 0002)"; v5_bad=1; continue
  fi
  if [ "$nb" != "$ne" ]; then
    violation V5 "unpaired escalation markers ($nb begin / $ne end): $rel"; v5_bad=1; continue
  fi
  blk="$(v5_extract "$f")"
  if [ -z "$v5_canon_file" ]; then
    v5_canon_txt="$blk"; v5_canon_file="$rel"
  elif [ "$blk" != "$v5_canon_txt" ]; then
    violation V5 "escalation block DRIFTED: $rel differs from $v5_canon_file (ADR 0002 — byte-identical)"; v5_bad=1
  fi
done <<V5EXP
$v5_expected
V5EXP
# (b) any OTHER file carrying a WELL-FORMED block must also match (stray fork); a
#     lone/unpaired marker is prose (a doc about the mechanism) and is ignored.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  nb=$(grep -c "$v5_begin" "$f" 2>/dev/null || true)
  [ "${nb:-0}" -gt 0 ] || continue
  rel="${f#$ROOT/}"
  v5_is_expected "$rel" && continue
  ne=$(grep -c "$v5_end" "$f" 2>/dev/null || true)
  { [ "${ne:-0}" -gt 0 ] && [ "$nb" = "$ne" ]; } || continue   # not a well-formed copy -> prose, skip
  blk="$(v5_extract "$f")"
  if [ -n "$v5_canon_file" ] && [ "$blk" != "$v5_canon_txt" ]; then
    violation V5 "stray escalation copy DRIFTED from $v5_canon_file: $rel (ADR 0002)"; v5_bad=1
  else
    ok V5 "additional escalation copy byte-identical: $rel"
  fi
done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -path "$ROOT/.claude" -prune -o -name node_modules -prune -o -name '*.md' -print 2>/dev/null | sort)
[ "$v5_bad" -eq 0 ] && ok V5 "escalation-criterion block present + byte-identical across the five pinned escalation-bearing prompts (ADR 0002; +triage TR-06)"

# ── V6: one product-entry marketplace registering EXACTLY the six installable
#        plugins (ADR 0001 / 0011 / 0019 / 0020). The repo-root .claude-plugin/marketplace.json
#        is the single entry point; the registered set must be exactly the six,
#        each NAME paired with its OWN source dir, and each source dir must carry a
#        .claude-plugin/plugin.json whose name matches. Structural, per-object
#        validation via python3 (catches a name<->source swap or a rogue 7th
#        plugin that independent greps miss); a reduced grep check if python3 is
#        absent. Formatting-insensitive.
MKT="$ROOT/.claude-plugin/marketplace.json"
if [ ! -f "$MKT" ]; then
  violation V6 "root product marketplace missing: .claude-plugin/marketplace.json (ADR 0001)"
else
  # single entry point: no other marketplace.json in the product tree
  v6_extra=0
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    [ "$m" = "$MKT" ] && continue
    violation V6 "stray marketplace.json (single product entry point only, ADR 0001/0011): ${m#$ROOT/}"
    v6_extra=$((v6_extra+1))
  done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -path "$ROOT/.claude" -prune -o -name node_modules -prune -o -name 'marketplace.json' -print 2>/dev/null)
  [ "$v6_extra" -eq 0 ] && ok V6 "single product-entry marketplace (.claude-plugin/marketplace.json)"

  if command -v python3 >/dev/null 2>&1; then
    v6_out="$(python3 - "$ROOT" "$MKT" <<'PYV6' 2>/dev/null
import json, os, sys
root, mkt = sys.argv[1], sys.argv[2]
expected = {
    "spec-gen": "./plugins/spec-gen",
    "autopilot": "./plugins/autopilot",
    "codebase-health": "./plugins/codebase-health",
    "marshal": "./plugins/marshal",
    "org-memory": "./plugins/org-memory",
    "triage": "./plugins/triage",
}
try:
    d = json.load(open(mkt))
except Exception as e:
    print("invalid marketplace JSON: %s" % e); sys.exit(0)
got = {}
for p in (d.get("plugins") or []):
    got[p.get("name")] = p.get("source")
for n in sorted(set(expected) - set(got)):
    print("plugin '%s' not registered in root marketplace" % n)
for n in sorted(set(got) - set(expected)):
    print("unexpected plugin '%s' registered (source=%s) - the product is exactly six" % (n, got[n]))
for n, src in expected.items():
    if n in got and got[n] != src:
        print("plugin '%s' registered source '%s' != expected '%s' (name<->source mismatch)" % (n, got[n], src))
for n, src in got.items():
    if not src:
        print("plugin '%s' has no source" % n); continue
    rel = src[2:] if src.startswith("./") else src
    pdir = os.path.join(root, rel)
    pj = os.path.join(pdir, ".claude-plugin", "plugin.json")
    if not os.path.isdir(pdir):
        print("plugin '%s' source dir missing: %s" % (n, src)); continue
    if not os.path.isfile(pj):
        print("plugin '%s' source lacks .claude-plugin/plugin.json (not independently installable): %s" % (n, src)); continue
    try:
        pjn = json.load(open(pj)).get("name")
    except Exception as e:
        print("plugin '%s' plugin.json invalid under %s: %s" % (n, src, e)); continue
    if pjn != n:
        print("plugin.json name '%s' != registered name '%s' under %s" % (pjn, n, src))
PYV6
)"
    if [ -n "$v6_out" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        violation V6 "$line"
      done <<V6OUT
$v6_out
V6OUT
    else
      ok V6 "root marketplace registers exactly the six plugins; name<->source pairing + each plugin.json name verified (structural)"
    fi
  else
    # reduced fallback (python3 absent): name+source presence + installability only
    v6_bad=0
    while IFS='|' read -r pname psrc; do
      [ -n "$pname" ] || continue
      grep -q "\"name\": \"$pname\"" "$MKT"  || { violation V6 "plugin '$pname' not registered in root marketplace"; v6_bad=1; }
      grep -q "\"source\": \"$psrc\"" "$MKT" || { violation V6 "plugin '$pname' source '$psrc' not registered"; v6_bad=1; }
      pdir="$ROOT/${psrc#./}"
      { [ -d "$pdir" ] && [ -f "$pdir/.claude-plugin/plugin.json" ]; } || { violation V6 "plugin '$pname' source not independently installable: $psrc"; v6_bad=1; }
    done <<'V6PLUGINS'
spec-gen|./plugins/spec-gen
autopilot|./plugins/autopilot
codebase-health|./plugins/codebase-health
marshal|./plugins/marshal
org-memory|./plugins/org-memory
triage|./plugins/triage
V6PLUGINS
    [ "$v6_bad" -eq 0 ] && ok V6 "six plugins registered + installable (reduced grep check; python3 absent)"
  fi
fi

# ── V8: OWM vendoring lint (ADR 0019, register OWM-10). org-memory depends on formats
#        owned elsewhere (the manifest JSON Schema + the validate_manifest toolchain).
#        This rule asserts OWM's manifest-parse path uses the CANONICAL validator —
#        never a forked parser — so a manifest-format change can never leave OWM
#        silently parsing the old shape. Extends the existing lint; no parallel infra.
#        NUMBERED V8, not V7: V7 is the parallel mutation-testing stream's rule. This
#        rule must NOT renumber or collide with it.
OWM_DIR="$ROOT/plugins/org-memory"
OWM_ENGINE="$OWM_DIR/scripts/owm.py"
if [ ! -d "$OWM_DIR" ]; then
  ok V8 "org-memory plugin not present; nothing to pin (ADR 0019)"
elif [ ! -f "$OWM_ENGINE" ]; then
  violation V8 "org-memory present but its engine scripts/owm.py is missing (ADR 0019)"
else
  v8_bad=0
  # (a) manifest parsing is ROUTED THROUGH the canonical validator (single source).
  if grep -q 'import validate_manifest' "$OWM_ENGINE"; then
    ok V8 "OWM manifest-parse path routes through the canonical validate_manifest (never a fork)"
  else
    violation V8 "OWM engine does not import validate_manifest — manifest parsing is not routed through the canonical toolchain (ADR 0019/0014)"; v8_bad=1
  fi
  # (b) FORBID a forked YAML/manifest parser inside the OWM engine (the fork signature).
  if grep -Eq '^[[:space:]]*(import[[:space:]]+yaml|from[[:space:]]+yaml|import[[:space:]]+ruamel|from[[:space:]]+ruamel)' "$OWM_ENGINE"; then
    violation V8 "OWM engine imports a YAML parser directly — a forked manifest parser (ADR 0019 — reuse validate_manifest, never fork)"; v8_bad=1
  else
    ok V8 "OWM engine forks no YAML/manifest parser (delegates to validate_manifest)"
  fi
  # (c) the vendored validator + manifest schema are byte-identical to the canonical.
  for rel in scripts/validate_manifest.py scripts/validate_manifest.sh \
             schema/verification-manifest/v1.schema.json; do
    canon="$ROOT/$rel"; vend="$OWM_DIR/$rel"
    if [ ! -f "$vend" ]; then
      violation V8 "OWM is missing its vendored $rel (needed to parse manifests standalone; ADR 0011)"; v8_bad=1
    elif cmp -s "$canon" "$vend"; then
      ok V8 "OWM vendored $rel byte-identical to canonical"
    else
      violation V8 "OWM vendored $rel DRIFTED from canonical (ADR 0001/0019 — vendor byte-for-byte)"; v8_bad=1
    fi
  done
  # (e) OWM-09 enumeration: byte-pin ONLY if it is vendored from a canonical autopilot
  #     copy. OWM takes NO runtime dependency on the autopilot plugin (ADR 0011), so an
  #     OWM-LOCAL enumeration path is legitimate and needs no pin.
  owm09="$OWM_DIR/scripts/host_repo_list.sh"
  ap09="$ROOT/plugins/autopilot/scripts/host_repo_list.sh"
  if [ -f "$owm09" ] && [ -f "$ap09" ]; then
    if cmp -s "$ap09" "$owm09"; then
      ok V8 "OWM-09 enumeration vendored byte-identical to the autopilot canonical (ADR 0001)"
    else
      violation V8 "OWM-09 enumeration copy DRIFTED from the autopilot canonical (ADR 0001)"; v8_bad=1
    fi
  elif [ -f "$owm09" ]; then
    ok V8 "OWM-09 enumeration is OWM-local (not vendored from autopilot); no byte-pin needed (ADR 0011)"
  fi
  [ "$v8_bad" -eq 0 ] && ok V8 "OWM recognizers pinned to the canonical formats (ADR 0019 / register OWM-10)"
fi
# ── V7: the mutation adapter map (ADR 0016 / MT-09/MT-10) — the ONE map, pinned
#        so the autopilot D6.5 PRODUCER and the codebase-health PR-Gate CONSUMER
#        cannot drift. Four guarantees:
#   (a) the vendored <!-- vendored:mutation-adapter-map --> DOC block is present in
#       both the canonical (cross-language-tooling.md) and the autopilot copy
#       (mutation-adapters.md), byte-identical (the V5 mechanism);
#   (b) the executable resolver mutation_adapter.sh is byte-identical across the two
#       plugins AND exists in EXACTLY those two locations — a third copy would be a
#       second map that drifts (the V3 mechanism; MT-10 "no second runner/source");
#   (c) the [BLOCKED: vacuous-test] producer token lives in the autopilot D6.5 gate;
#   (d) the mutant-on-core-path consumer token lives in the PR-Gate sibling.
v7_begin='vendored:mutation-adapter-map:begin'
v7_end='vendored:mutation-adapter-map:end'
v7_extract() { awk -v b="$v7_begin" -v e="$v7_end" '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$1"; }
v7_expected="plugins/codebase-health/skills/cleanup-audit/references/cross-language-tooling.md
plugins/autopilot/references/mutation-adapters.md"
v7_canon_txt=""; v7_canon_file=""; v7_bad=0
# (a) doc block present + byte-identical across the pinned files
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  f="$ROOT/$rel"
  if [ ! -f "$f" ]; then
    violation V7 "expected mutation-adapter-map file missing: $rel (ADR 0016)"; v7_bad=1; continue
  fi
  nb=$(grep -c "$v7_begin" "$f" 2>/dev/null || true)
  ne=$(grep -c "$v7_end" "$f" 2>/dev/null || true)
  if [ "${nb:-0}" -eq 0 ] || [ "${ne:-0}" -eq 0 ]; then
    violation V7 "expected file lacks the vendored mutation-adapter-map block: $rel (ADR 0016)"; v7_bad=1; continue
  fi
  if [ "$nb" != "$ne" ]; then
    violation V7 "unpaired mutation-adapter-map markers ($nb begin / $ne end): $rel"; v7_bad=1; continue
  fi
  blk="$(v7_extract "$f")"
  if [ -z "$v7_canon_file" ]; then
    v7_canon_txt="$blk"; v7_canon_file="$rel"
  elif [ "$blk" != "$v7_canon_txt" ]; then
    violation V7 "mutation-adapter-map block DRIFTED: $rel differs from $v7_canon_file (ADR 0016 — byte-identical)"; v7_bad=1
  fi
done <<V7EXP
$v7_expected
V7EXP

# (b) resolver byte-identity + EXACTLY the two expected copies (MT-10 sole source)
v7_canon_sh="$ROOT/plugins/codebase-health/skills/cleanup-audit/scripts/mutation_adapter.sh"
v7_copy_sh="$ROOT/plugins/autopilot/scripts/mutation_adapter.sh"
if [ ! -f "$v7_canon_sh" ]; then
  violation V7 "canonical mutation_adapter.sh missing: ${v7_canon_sh#$ROOT/} (ADR 0016)"; v7_bad=1
elif [ ! -f "$v7_copy_sh" ]; then
  violation V7 "vendored mutation_adapter.sh missing in autopilot: ${v7_copy_sh#$ROOT/} (ADR 0016)"; v7_bad=1
elif ! cmp -s "$v7_canon_sh" "$v7_copy_sh"; then
  violation V7 "vendored mutation_adapter.sh DRIFTED from canonical: ${v7_copy_sh#$ROOT/} (ADR 0016 — the one map, byte-identical)"; v7_bad=1
fi
v7_adp_seen=0
while IFS= read -r c; do
  [ -n "$c" ] || continue
  v7_adp_seen=$((v7_adp_seen+1))
  rel="${c#$ROOT/}"
  case "$rel" in
    plugins/codebase-health/skills/cleanup-audit/scripts/mutation_adapter.sh|plugins/autopilot/scripts/mutation_adapter.sh) : ;;
    *) violation V7 "unexpected mutation_adapter.sh copy (a second map that drifts): $rel (ADR 0016 / MT-10 — one map, one source)"; v7_bad=1 ;;
  esac
done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -path "$ROOT/.claude" -prune -o -name node_modules -prune -o -name 'mutation_adapter.sh' -print 2>/dev/null)

# (c)+(d) producer + consumer tokens pinned to their scripts (cannot drift apart)
v7_producer="$ROOT/plugins/autopilot/scripts/mutation_gate.sh"
v7_consumer="$ROOT/plugins/codebase-health/skills/cleanup-audit/scripts/check_mutation_survivors.sh"
if [ -f "$v7_producer" ] && grep -qF '[BLOCKED: vacuous-test]' "$v7_producer"; then
  ok V7 "producer token [BLOCKED: vacuous-test] present in the autopilot D6.5 gate"
else
  violation V7 "producer token [BLOCKED: vacuous-test] missing from plugins/autopilot/scripts/mutation_gate.sh (ADR 0016 / MT-09)"; v7_bad=1
fi
if [ -f "$v7_consumer" ] && grep -qF 'mutant-on-core-path' "$v7_consumer"; then
  ok V7 "consumer token mutant-on-core-path present in the PR-Gate sibling"
else
  violation V7 "consumer token mutant-on-core-path missing from check_mutation_survivors.sh (ADR 0016 / MT-09)"; v7_bad=1
fi
[ "$v7_bad" -eq 0 ] && ok V7 "mutation adapter map + resolver byte-identical, sole-source, producer/consumer tokens pinned (ADR 0016 — cannot drift)"

# ── V9: the triage telemetry-adapter observable contract (ADR 0006/0013; register
#        TR-08). plugins/triage/reference/telemetry-contract.md is the SINGLE SOURCE
#        of the <!-- vendored:telemetry-contract --> block; any vendored backend-
#        contract copy (reference/backends.md, …) carries it byte-identical — the
#        host-contract precedent, the V5/V7 marker-block mechanism. A lone/unpaired
#        marker in prose is documentation, not a copy (no false positive).
#        NUMBERED V9: V7 (mutation adapter map) and V8 (OWM vendoring) are TAKEN; V10
#        is the parallel remediation-loop chip's rule — this must NOT renumber or collide.
v9_begin='vendored:telemetry-contract:begin'
v9_end='vendored:telemetry-contract:end'
v9_extract() { awk -v b="$v9_begin" -v e="$v9_end" '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$1"; }
v9_canon_file="$ROOT/plugins/triage/reference/telemetry-contract.md"
if [ ! -f "$v9_canon_file" ]; then
  ok V9 "triage plugin not present; no telemetry-contract to pin (register TR-08)"
else
  v9_bad=0; v9_canon_txt=""
  nb=$(grep -c "$v9_begin" "$v9_canon_file" 2>/dev/null || true)
  ne=$(grep -c "$v9_end" "$v9_canon_file" 2>/dev/null || true)
  if [ "${nb:-0}" -eq 0 ] || [ "${ne:-0}" -eq 0 ] || [ "$nb" != "$ne" ]; then
    violation V9 "canonical telemetry-contract lacks a well-formed vendored block: ${v9_canon_file#$ROOT/} (register TR-08)"; v9_bad=1
  else
    v9_canon_txt="$(v9_extract "$v9_canon_file")"
  fi
  # every OTHER file carrying a WELL-FORMED telemetry-contract block must match the canonical.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$f" = "$v9_canon_file" ] && continue
    nb=$(grep -c "$v9_begin" "$f" 2>/dev/null || true)
    [ "${nb:-0}" -gt 0 ] || continue
    ne=$(grep -c "$v9_end" "$f" 2>/dev/null || true)
    { [ "${ne:-0}" -gt 0 ] && [ "$nb" = "$ne" ]; } || continue   # unpaired marker -> prose, skip
    rel="${f#$ROOT/}"
    blk="$(v9_extract "$f")"
    if [ -n "$v9_canon_txt" ] && [ "$blk" != "$v9_canon_txt" ]; then
      violation V9 "vendored telemetry-contract copy DRIFTED from canonical: $rel (register TR-08 — byte-identical; the host-contract precedent)"; v9_bad=1
    else
      ok V9 "vendored telemetry-contract copy byte-identical: $rel"
    fi
  done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -path "$ROOT/.claude" -prune -o -name node_modules -prune -o -name '*.md' -print 2>/dev/null | sort)
  # (2) triage vendors two spec-gen scripts (profile_resolve.py, resume_projection.py;
  #     register TR-04/TR-07) — pinned byte-identical or they silently drift (ADR 0001
  #     §18 vendoring mandate). The plugin needs them to resume standalone (ADR 0011);
  #     an UNPINNED vendored copy is the drift-fork this lint exists to prevent.
  for v9rel in scripts/profile_resolve.py scripts/resume_projection.py; do
    v9c="$ROOT/plugins/spec-gen/$v9rel"; v9v="$ROOT/plugins/triage/$v9rel"
    if [ ! -f "$v9v" ]; then :
    elif [ ! -f "$v9c" ]; then
      violation V9 "canonical plugins/spec-gen/$v9rel missing (triage vendors it; ADR 0001)"; v9_bad=1
    elif cmp -s "$v9c" "$v9v"; then
      ok V9 "triage vendored spec-gen script byte-identical: plugins/triage/$v9rel"
    else
      violation V9 "triage vendored spec-gen script DRIFTED from canonical: plugins/triage/$v9rel (ADR 0001 §18 — byte-for-byte from plugins/spec-gen/$v9rel)"; v9_bad=1
    fi
  done
  [ "$v9_bad" -eq 0 ] && ok V9 "triage vendored artifacts (telemetry-contract block + spec-gen resume scripts) single-source + byte-identical (register TR-04/07/08, ADR 0001)"
fi

# ── V10: the remediation loop's two lint-pinned tables (ADR 0017 / 0018; register
#        RL-02/RL-03/RL-13). The loop is WIRING and holds no quality opinion — but
#        two of its inputs ARE vendored contracts that must not silently drift:
#   (a) classify_fix.sh's escalate-class table CITES ADR 0002 and its money/auth
#       membership is a SUPERSET of audit-state-and-verify.md's Category-TX slug
#       catalog (a TX slug silently dropped from the classifier would let a
#       money-path fix auto-drain — the exact failure ADR 0002 forbids);
#   (b) slug_provenance.tsv — every slug exists in the audit taxonomy AND each
#       provenance matches SPEC_1.4.0 §12 (a slug flipped det<->agent changes what
#       the loop autonomously files; drift → red).
#        NUMBERED V10, not V9: V9 is the parallel prod-triage stream's rule. This
#        rule must NOT renumber or collide with it.
RL_SCRIPTS="$ROOT/plugins/codebase-health/skills/cleanup-audit/scripts"
CLASSIFY="$RL_SCRIPTS/classify_fix.sh"
PROVTSV="$RL_SCRIPTS/slug_provenance.tsv"
TAXONOMY="$ROOT/plugins/codebase-health/skills/cleanup-audit/references/audit-state-and-verify.md"
CHSPEC="$ROOT/docs/specs/codebase-health-spec-1.4.0.md"
if [ ! -f "$CLASSIFY" ] && [ ! -f "$PROVTSV" ]; then
  ok V10 "remediation loop not present; nothing to pin (ADR 0017)"
else
  v10_bad=0
  # (a) escalate-class table: cites ADR 0002, and is a SUPERSET of the TX catalog.
  if [ ! -f "$CLASSIFY" ]; then
    violation V10 "classify_fix.sh missing but the loop is present (register RL-03)"; v10_bad=1
  else
    if grep -qF 'ADR 0002' "$CLASSIFY"; then
      ok V10 "escalate-class table cites the ADR-0002 block"
    else
      violation V10 "classify_fix.sh escalate-class table does not cite ADR 0002 (register RL-03/V10)"; v10_bad=1
    fi
    # The money/auth Category-TX catalog is authored in audit-state-and-verify.md.
    # Each TX slug must be present THERE (source of truth) AND in classify_fix.sh
    # (the escalate-class must be a superset). A drop on either side → red.
    for tx in non-idempotent-handler missing-dedup-guard unsafe-retry double-submit-window missing-compensation missing-audit-trail; do
      if [ -f "$TAXONOMY" ] && ! grep -qF "$tx" "$TAXONOMY"; then
        violation V10 "TX slug '$tx' absent from audit-state-and-verify.md catalog (V10 hardcoded list needs reconciling)"; v10_bad=1
      fi
      if ! grep -qF "$tx" "$CLASSIFY"; then
        violation V10 "escalate-class table is NOT a superset: TX slug '$tx' missing from classify_fix.sh (money-path fix could auto-drain — ADR 0002)"; v10_bad=1
      fi
    done
  fi
  # (b) slug_provenance.tsv: taxonomy existence + §12 provenance match.
  if [ ! -f "$PROVTSV" ]; then
    violation V10 "slug_provenance.tsv missing but the loop is present (register RL-02)"; v10_bad=1
  else
    # "audit taxonomy" = the references + SPEC §12 + the detector scripts that
    # DEFINE defect kinds — deliberately NOT the loop's own routing tables
    # (slug_provenance.tsv / classify_fix.sh), else a slug would match itself and
    # an invented slug would slip through.
    TAX_REFS="$ROOT/plugins/codebase-health/skills/cleanup-audit/references"
    TAX_MROT="$ROOT/plugins/codebase-health/skills/cleanup-audit/scripts/check_memory_rot.sh"
    TAX_DEBT="$ROOT/plugins/codebase-health/skills/cleanup-audit/scripts/debt_patterns.sh"
    v10_tax=""
    [ -d "$TAX_REFS" ] && v10_tax="$v10_tax $TAX_REFS"
    [ -f "$CHSPEC" ]   && v10_tax="$v10_tax $CHSPEC"
    [ -f "$TAX_MROT" ] && v10_tax="$v10_tax $TAX_MROT"
    [ -f "$TAX_DEBT" ] && v10_tax="$v10_tax $TAX_DEBT"
    # every slug exists in the audit taxonomy (kebab or underscore form).
    while IFS="$(printf '\t')" read -r slug prov _rest; do
      case "$slug" in ''|'#'*) continue ;; esac
      [ -n "$prov" ] || continue
      case "$prov" in
        deterministic|agent) : ;;
        *) violation V10 "slug_provenance.tsv: slug '$slug' has invalid provenance '$prov' (must be deterministic|agent)"; v10_bad=1 ;;
      esac
      alt="$(printf '%s' "$slug" | tr '-' '_')"
      if [ -z "$v10_tax" ] || ! grep -rIqiE "($slug|$alt)" $v10_tax 2>/dev/null; then
        violation V10 "slug_provenance.tsv: slug '$slug' does not exist in the audit taxonomy (invented slug — register RL-02/V10)"; v10_bad=1
      fi
    done < "$PROVTSV"
    # §12 provenance anchors (docs/specs/codebase-health-spec-1.4.0.md §12): a slug
    # flipped det<->agent silently changes what the loop autonomously files.
    v10_anchor() {  # <slug> <expected-provenance> <§12-ref>
      local got
      got="$(awk -F'\t' -v s="$1" '/^[[:space:]]*#/{next} NF<2{next} $1==s{print $2; exit}' "$PROVTSV")"
      if [ -z "$got" ]; then
        violation V10 "slug_provenance.tsv missing §12 anchor slug '$1' (expected $2, $3)"; v10_bad=1
      elif [ "$got" != "$2" ]; then
        violation V10 "slug_provenance.tsv: '$1' provenance '$got' != §12 '$2' ($3) — determinism sweep drift"; v10_bad=1
      fi
    }
    v10_anchor dark-money-movement    deterministic "J3/§12-flip"
    v10_anchor giant-file             deterministic "GF1"
    v10_anchor memory-rot-dangling-ref deterministic "CH-05-det-layer"
    v10_anchor log-only-refund        agent "J5"
    v10_anchor non-idempotent-handler agent "TX1"
    v10_anchor unsafe-retry           agent "TX2"
    v10_anchor missing-compensation   agent "TX3"
    v10_anchor convoluted-branching   agent "JC1"
  fi
  [ "$v10_bad" -eq 0 ] && ok V10 "remediation escalate-class table (ADR-0002 superset of TX catalog) + slug_provenance §12 taxonomy pinned (register RL-02/03/13)"
fi

# ── V11: outcome-store vendoring + the H1 anti-laundering guard (ADR 0023; register
#        OM-09). Outcome measurement writes a shared store from TWO producers (the
#        Marshal outcome-capture/digest modes + the audit outcome-emit step); they
#        must not drift on the store contract, and NO agent-graded number may be
#        laundered as deterministic. Three guarantees:
#   (a) schema/outcome/v1.schema.json is the single canonical outcome-store schema;
#       any vendored copy shipped for standalone install (Marshal/audit) is
#       byte-identical (the V1/V8 mechanism).
#   (b) the <!-- vendored:outcome-store-contract --> block has ONE source
#       (docs/specs/outcome-store-contract.md); every well-formed vendored copy is
#       byte-identical (the V5/V7/V9 marker mechanism; a lone/unpaired marker in
#       prose is documentation, not a copy — no false positive).
#   (c) the H1 anti-laundering guard, mechanized over the register: the real-repo
#       emission-share acceptance is tagged [audit-run], and NO [det] acceptance
#       claims a real-repo agent-graded number.
#        NUMBERED V11: V7 (mutation) / V8 (OWM) / V9 (triage) / V10 (remediation) are
#        TAKEN; this rule must NOT renumber or collide with them.
OUTCANON="$ROOT/schema/outcome/v1.schema.json"
if [ ! -f "$OUTCANON" ]; then
  ok V11 "no outcome-store schema present; nothing to pin (ADR 0023)"
else
  v11_bad=0
  # (a) vendored outcome-store schema copies byte-identical to the canonical.
  o_copies=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ "$c" = "$OUTCANON" ] && continue
    o_copies=$((o_copies+1))
    if cmp -s "$OUTCANON" "$c"; then
      ok V11 "vendored outcome-store schema byte-identical: ${c#$ROOT/}"
    else
      violation V11 "vendored outcome-store schema DRIFTED from canonical: ${c#$ROOT/} (ADR 0023 — vendor byte-for-byte from schema/outcome/v1.schema.json)"; v11_bad=1
    fi
  done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -path "$ROOT/.claude" -prune -o -name node_modules -prune -o -path '*/outcome/v1.schema.json' -print 2>/dev/null)
  [ "$o_copies" -eq 0 ] && ok V11 "single canonical outcome-store schema; no vendored copies to drift (ADR 0023)"

  # (a2) STRUCTURAL H1 guard: the schema must BIND each metric name to its honesty
  #      class (emission_share -> agent-graded; the DORA family -> deterministic), so a
  #      mislabeled/laundered row is schema-INVALID at the store boundary. This is the
  #      robust enforcement (the register grep in (c) is a keyword backstop only). A
  #      future edit that drops the binding is caught here.
  if grep -q '"emission_share"' "$OUTCANON" && grep -q '"agent-graded"' "$OUTCANON" \
     && grep -q '"deploy_frequency"' "$OUTCANON" && grep -q 'allOf' "$OUTCANON"; then
    ok V11 "schema structurally binds metric name -> honesty_class (emission_share => agent-graded; DORA => deterministic) — a laundered row is schema-invalid"
  else
    violation V11 "outcome-store schema lost its name<->honesty_class binding (H1 structural guard); a mislabeled emission_share/DORA row could enter the store (ADR 0023)"; v11_bad=1
  fi

  # (b) the vendored outcome-store-contract block: single source + byte-identical.
  v11_begin='vendored:outcome-store-contract:begin'
  v11_end='vendored:outcome-store-contract:end'
  v11_extract() { awk -v b="$v11_begin" -v e="$v11_end" '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$1"; }
  v11_canon_file="$ROOT/docs/specs/outcome-store-contract.md"
  v11_canon_txt=""
  if [ ! -f "$v11_canon_file" ]; then
    ok V11 "no canonical outcome-store-contract doc; contract-block pin skipped (ADR 0023)"
  else
    nb=$(grep -c "$v11_begin" "$v11_canon_file" 2>/dev/null || true)
    ne=$(grep -c "$v11_end" "$v11_canon_file" 2>/dev/null || true)
    if [ "${nb:-0}" -eq 0 ] || [ "${ne:-0}" -eq 0 ] || [ "$nb" != "$ne" ]; then
      violation V11 "canonical outcome-store-contract doc lacks a well-formed vendored block: ${v11_canon_file#$ROOT/} (ADR 0023)"; v11_bad=1
    else
      v11_canon_txt="$(v11_extract "$v11_canon_file")"
    fi
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ "$f" = "$v11_canon_file" ] && continue
      nb=$(grep -c "$v11_begin" "$f" 2>/dev/null || true)
      [ "${nb:-0}" -gt 0 ] || continue
      ne=$(grep -c "$v11_end" "$f" 2>/dev/null || true)
      { [ "${ne:-0}" -gt 0 ] && [ "$nb" = "$ne" ]; } || continue   # unpaired marker -> prose, skip
      rel="${f#$ROOT/}"
      blk="$(v11_extract "$f")"
      if [ -n "$v11_canon_txt" ] && [ "$blk" != "$v11_canon_txt" ]; then
        violation V11 "vendored outcome-store-contract block DRIFTED from canonical: $rel (ADR 0023 — byte-identical; the V5/V7/V9 precedent)"; v11_bad=1
      else
        ok V11 "vendored outcome-store-contract block byte-identical: $rel"
      fi
    done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -path "$ROOT/.claude" -prune -o -name node_modules -prune -o -name '*.md' -print 2>/dev/null | sort)
  fi

  # (c) the H1 anti-laundering guard over the register (skipped if the register is
  #     absent, e.g. in a schema/block-only sandbox red-test).
  REG="$ROOT/docs/specs/outcome-measurement-register.md"
  if [ -f "$REG" ]; then
    # the real-repo emission-share acceptance MUST carry the [audit-run] tag.
    if grep -F '[audit-run]' "$REG" | grep -Eiq 'emission[ -]?share'; then
      ok V11 "register: the real-repo emission share is tagged [audit-run] (H1 honesty residual present)"
    else
      violation V11 "register: no [audit-run] acceptance for the real-repo emission share (H1 residual missing — register OM-09)"; v11_bad=1
    fi
    # NO [det]/[deterministic] ACCEPTANCE may claim a real/live/production-repo
    # agent-graded number (the laundering H1 exists to prevent). A [det] line about the
    # FIXTURE arithmetic is legitimate; one mentioning BOTH agent-graded AND a real repo
    # is not. Blockquote (`>`) lines are DESIGN RATIONALE, not acceptances (the H1 note
    # there correctly says the real-repo metric is [audit-run]) — excluded. This is a
    # keyword BACKSTOP over the register prose, broadened past the exact red-test
    # phrasing; the STRUCTURAL guarantee is the schema binding in (a2), not this grep.
    launder="$(grep -iE '\[det\]|\[deterministic\]' "$REG" | grep -v '^[[:space:]]*>' \
               | grep -iE 'agent[ -]?graded' \
               | grep -iE '(real|live|production)[ -]?(repo|repository)' || true)"
    if [ -n "$launder" ]; then
      violation V11 "register: a [det] acceptance claims a real/live/production-repo agent-graded number (H1 laundering): ${launder}"; v11_bad=1
    else
      ok V11 "register: no [det] acceptance claims a real-repo agent-graded number (H1 keyword backstop holds; schema binding in (a2) is the structural guarantee)"
    fi
  fi
  [ "$v11_bad" -eq 0 ] && ok V11 "outcome-store schema + contract block single-source byte-identical + H1 anti-laundering guard holds (ADR 0023 / register OM-09)"
fi

# ── V12: the System-Design Coverage tier's two structural guards (ADR 0021/0022;
#        register SD-12). The tier is REPORT-ONLY and adds NO join engine (ADR 0003)
#        — two invariants must hold in SOURCE or the declare-then-verify honesty spine
#        silently breaks:
#   (a) UNFALSIFIABILITY (SD-00/SD-03): the CH-03 join engine (manifest_join.py) routes
#       every non-app locus through the out-of-scope-by-declaration emitter and NEVER
#       emits a raw "missing X" finding for a non-app control (unfalsifiable against an
#       out-of-repo locus — the central prohibition). The marked vendored:sd-locus-guard
#       region must be present, the out-of-scope emitter must exist, and NO emitted
#       output line anywhere in the engine may carry a raw missing/no-<control> phrase.
#   (b) NO PARALLEL COMPARATOR (SD-04/SD-12; MT-10 precedent): the four SD drift rows
#       live IN manifest_join.py, not a sibling — a second join engine that drifts is
#       exactly what ADR 0003 forbids. Each slug must be present in manifest_join.py and
#       ABSENT from every other cleanup-audit script.
#        NUMBERED V12: V7 (mutation) / V8 (OWM) / V9 (triage) / V10 (remediation) / V11
#        (outcome) are TAKEN. V1 ALREADY byte-pins the three vendored SD-01 schema copies
#        (its find walks the new-field-bearing */verification-manifest/v1.schema.json
#        copies automatically) — V12 does NOT duplicate that; it adds (a)+(b) only.
SD_SKILL_SCRIPTS="$ROOT/plugins/codebase-health/skills/cleanup-audit/scripts"
JOINPY="$SD_SKILL_SCRIPTS/manifest_join.py"
SD_SLUGS="abuse-controls-drift resilience-posture-drift isolation-drift timeout-budget-drift"
if [ ! -f "$JOINPY" ]; then
  ok V12 "CH-03 join engine not present; no SD rows to guard (register SD-12)"
else
  v12_bad=0
  # (a) unfalsifiability — the marked guard region is present.
  if grep -qF 'vendored:sd-locus-guard:begin' "$JOINPY" && grep -qF 'vendored:sd-locus-guard:end' "$JOINPY"; then
    ok V12 "unfalsifiability: the vendored:sd-locus-guard region is present in the CH-03 join engine"
  else
    violation V12 "the SD locus-guard region (vendored:sd-locus-guard) is missing from manifest_join.py — the out-of-scope short-circuit is unguarded (SD-00 / ADR 0022)"; v12_bad=1
  fi
  # (a) the out-of-scope-by-declaration emitter exists (non-app loci have somewhere to go).
  if grep -qF 'out-of-scope-by-declaration' "$JOINPY"; then
    ok V12 "unfalsifiability: the join engine emits out-of-scope-by-declaration for non-app loci (ADR 0022)"
  else
    violation V12 "manifest_join.py no longer emits out-of-scope-by-declaration — non-app SD loci would fall through (ADR 0022)"; v12_bad=1
  fi
  # (a) the CENTRAL PROHIBITION: no EMITTED line mints a raw missing-X finding for an SD
  #     control. Restrict the scan to emit(/print( CALLS so a comment ABOUT the prohibition
  #     (prose) is not a false positive; a raw "missing rate limit"/"no circuit breaker"/…
  #     phrase inside an emitted string IS the defect this tier exists to prevent.
  v12_missingx='(missing|no)[[:space:]]+(rate[ -]?limit|circuit[ -]?breaker|breaker|load[ -]?shed|bulkhead|isolation[ -]?level|key[ -]?rotation|entitlement)'
  if grep -E '(emit|print)\(' "$JOINPY" 2>/dev/null | grep -iqE "$v12_missingx"; then
    violation V12 "manifest_join.py EMITS a raw missing-X finding for an SD control — unfalsifiable against an out-of-repo locus (the central prohibition, SD-00 / ADR 0021)"; v12_bad=1
  else
    ok V12 "unfalsifiability: no emitted line mints a raw missing-X finding for an SD control (the central prohibition holds)"
  fi
  # (b) no parallel comparator — each SD drift row lives IN the CH-03 engine.
  for slug in $SD_SLUGS; do
    grep -qF "$slug" "$JOINPY" || { violation V12 "SD drift row '$slug' is missing from the CH-03 join engine manifest_join.py (moved out / never added — SD-04)"; v12_bad=1; }
  done
  # (b) ... and NOWHERE ELSE under cleanup-audit/scripts — a sibling carrying an SD slug
  #     is a second comparator that drifts (MT-10 "one map, one source"; ADR 0003).
  if [ -d "$SD_SKILL_SCRIPTS" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in
        "$JOINPY"|"$SD_SKILL_SCRIPTS/manifest_join.sh") continue ;;
      esac
      for slug in $SD_SLUGS; do
        if grep -qF "$slug" "$f"; then
          violation V12 "SD drift row '$slug' found in a sibling (${f#$ROOT/}) — a parallel SD comparator outside the CH-03 engine (ADR 0003 / SD-12 no-parallel-infra)"; v12_bad=1
        fi
      done
    done < <(find "$SD_SKILL_SCRIPTS" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) 2>/dev/null)
  fi
  [ "$v12_bad" -eq 0 ] && ok V12 "SD tier: unfalsifiability guard + no-parallel-comparator guard hold (register SD-12; ADR 0021/0022; V1 byte-pins the 3 vendored SD-01 schema copies)"
fi

echo
if [ "$FAIL" -eq 0 ]; then echo "== lint_consistency: all cross-plugin contract rules pass =="; else echo "== lint_consistency: violations found =="; fi
exit "$FAIL"
