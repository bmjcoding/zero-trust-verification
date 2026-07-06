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
#   V3 — the manifest validator scripts (validate_manifest.sh + .py, ADR 0001/0014).
#        One canonical copy under scripts/; vendored copies byte-identical. The
#        autopilot `--union` checker shares the .sh name but is a DISTINCT tool
#        (exempt only while it carries the union tool's own union-only tokens; a
#        drifted single-file validator copy that merely mentions --union is flagged).
#   V4 — the claim-overlap primitive (autopilot + Marshal, ADR 0009), byte-identical.
#   V5 — the ADR 0002 escalation-criterion block, vendored VERBATIM into every
#        tier's prompt (autopilot planner/implementer, spec-gen SKILL, audit
#        severity-rubric); byte-identical AND present in all three tiers.
#   V6 — the product marketplace (ADR 0001/0011): ONE root .claude-plugin/
#        marketplace.json is the single entry point registering all four plugins,
#        each with a source dir carrying its own .claude-plugin/plugin.json.
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

# ── V3: vendored VALIDATOR SCRIPTS byte-identical to the canonical (ADR 0001) ──
# The manifest validator ships as two files — validate_manifest.sh (the exit-code
# entrypoint) and validate_manifest.py (the logic, ADR 0014). There is ONE
# canonical copy of each under scripts/; any copy a plugin vendors for standalone
# install (spec-gen does) must be byte-identical to it. ONE legitimate collision:
# autopilot/scripts/validate_manifest.sh is the `--union` multi-doc checker
# (AV3-03), NOT a vendored copy of the single-file validator — it is exempt only
# while it carries the union tool's own union-only tokens (`--union` AND
# `manifest-id-collision`, which the single-file validator never contains), so a
# drifted single-file-validator copy that merely mentions `--union` in a comment
# is NOT exempted — it is flagged.
v3_exempt() {  # <relpath> <abs-file> -> 0 iff this is the genuine union tool
  case "$1" in
    autopilot/scripts/validate_manifest.sh)
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
v4_canon="$ROOT/autopilot/scripts/claim_overlap.sh"
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
#   (b) IDENTITY — every well-formed copy (the expected four AND any stray copy
#       elsewhere) is byte-identical. A file that only *mentions* a marker in prose
#       without a matching begin/end PAIR is documentation, not a copy (no false
#       positive); an EXPECTED prompt with unpaired markers IS flagged.
v5_begin='vendored:escalation-criterion:begin'
v5_end='vendored:escalation-criterion:end'
v5_extract() { awk -v b="$v5_begin" -v e="$v5_end" '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$1"; }
v5_expected="autopilot/references/planner-prompt.md
autopilot/references/implementer-prompt.md
plugins/spec-gen/skills/spec/SKILL.md
codebase-health/plugins/codebase-health/skills/cleanup-audit/references/severity-rubric.md"
v5_is_expected() {  # <relpath> -> 0 if one of the pinned prompts
  case "$1" in
    autopilot/references/planner-prompt.md|autopilot/references/implementer-prompt.md|plugins/spec-gen/skills/spec/SKILL.md|codebase-health/plugins/codebase-health/skills/cleanup-audit/references/severity-rubric.md) return 0 ;;
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
[ "$v5_bad" -eq 0 ] && ok V5 "escalation-criterion block present + byte-identical across all three tiers' pinned prompts (ADR 0002)"

# ── V6: one product-entry marketplace registering EXACTLY the four installable
#        plugins (ADR 0001 / 0011). The repo-root .claude-plugin/marketplace.json
#        is the single entry point; the registered set must be exactly the four,
#        each NAME paired with its OWN source dir, and each source dir must carry a
#        .claude-plugin/plugin.json whose name matches. Structural, per-object
#        validation via python3 (catches a name<->source swap or a rogue 5th
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
    "autopilot": "./autopilot",
    "codebase-health": "./codebase-health/plugins/codebase-health",
    "marshal": "./plugins/marshal",
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
    print("unexpected plugin '%s' registered (source=%s) - the product is exactly four" % (n, got[n]))
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
      ok V6 "root marketplace registers exactly the four plugins; name<->source pairing + each plugin.json name verified (structural)"
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
autopilot|./autopilot
codebase-health|./codebase-health/plugins/codebase-health
marshal|./plugins/marshal
V6PLUGINS
    [ "$v6_bad" -eq 0 ] && ok V6 "four plugins registered + installable (reduced grep check; python3 absent)"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then echo "== lint_consistency: all cross-plugin contract rules pass =="; else echo "== lint_consistency: violations found =="; fi
exit "$FAIL"
