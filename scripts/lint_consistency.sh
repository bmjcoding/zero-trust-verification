#!/usr/bin/env bash
# Repo-level cross-domain consistency lint (MS §13.3 host; ADR 0001, narrowed by
# ADR 0025).
#
# The suite ships as ONE plugin (plugins/zero-trust, ADR 0025) consumed by an LLM
# that treats its artifacts as ground truth. The old byte-identity vendoring rules
# (V1 manifest schema, V3 validator scripts, V4 claim-overlap, V5 escalation
# block, V7 mutation adapter map, V8 OWM vendoring) were DELETED with the copies
# they policed — the consolidation leaves a single canonical file per artifact,
# so there is nothing left to drift. Surviving rules keep their historical IDs
# (never renumber; a retired ID stays retired):
#
#   V2  — the `## Behavior coverage` PR-body format. One canonical definition
#         (docs/specs/behavior-coverage-format.md) that the autopilot AV3-05
#         producer and the codebase-health CH-06 consumer both use.
#   V6  — the product marketplace (ADR 0001/0025): ONE root .claude-plugin/
#         marketplace.json is the single entry point registering EXACTLY the one
#         zero-trust plugin, whose source dir carries its own plugin.json.
#   V9  — the triage telemetry-adapter observable contract (ADR 0006/0013;
#         register TR-08): references/telemetry-contract.md is the single source
#         of the <!-- vendored:telemetry-contract --> block; any copy carrying
#         the block is byte-identical. Plus: the resume helpers
#         (profile_resolve.py / resume_projection.py) exist exactly once under
#         scripts/ — any re-vendored second copy must be byte-identical.
#   V10 — the remediation loop's two lint-pinned tables (ADR 0017/0018; register
#         RL-02/03/13): classify_fix.sh's escalate-class table (ADR-0002-citing,
#         superset of the Category-TX catalog) + slug_provenance.tsv (§12
#         provenance anchors, no invented slugs).
#   V11 — outcome-store pins + the H1 anti-laundering guard (ADR 0023; register
#         OM-09): single canonical outcome schema, single-source
#         outcome-store-contract block, and no [det] acceptance may claim a
#         real-repo agent-graded number.
#   V12 — the System-Design Coverage tier's two structural guards (ADR 0021/0022;
#         register SD-12): unfalsifiability (no raw missing-X finding for a
#         non-app locus) + no parallel SD comparator outside manifest_join.py.
#   V13 — the /health-loop attended wave drain pins (ADR 0024; register HL):
#         presence coupling, config vocabulary, gate-status-subset, read-only.
#
# $LINT_ROOT points the lint at a fixture tree so the self-test can plant a drift
# and prove each integrity rule has teeth (scripts/suite_self_test.sh). All rules
# honor it via $ROOT.
#
# Exit 0 = all rules pass. Exit 1 = at least one violation (each printed).
# Reporter: reads files, mutates nothing.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# $LINT_ROOT lets the self-test point the lint at a fixture tree (to prove the
# integrity rules have teeth); defaults to the real repo root.
ROOT="${LINT_ROOT:-$(cd "$HERE/.." && pwd)}"

# The single plugin's root (ADR 0025). Every in-plugin path below hangs off this.
ZT="$ROOT/plugins/zero-trust"

FAIL=0
violation() { echo "LINT-FAIL [$1] $2" >&2; FAIL=1; }
ok()        { echo "lint ok   [$1] $2"; }

# ── V2: the `## Behavior coverage` format has one canonical definition both
#        the AV3-05 producer and the CH-06 consumer honor ───────────────────────
FMT_DOC="$ROOT/docs/specs/behavior-coverage-format.md"
CONSUMER="$ZT/skills/cleanup-audit/scripts/check_behavior_coverage.sh"
PRODUCER_REF="$ZT/skills/autopilot/references/validator-prompts.md"

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

# ── V6: one product-entry marketplace registering EXACTLY the one installable
#        plugin (ADR 0001 / 0025). The repo-root .claude-plugin/marketplace.json
#        is the single entry point; the registered set must be exactly
#        {zero-trust -> ./plugins/zero-trust}, and the source dir must carry a
#        .claude-plugin/plugin.json whose name matches. Structural, per-object
#        validation via python3 (catches a wrong source pairing or a rogue 2nd
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
    violation V6 "stray marketplace.json (single product entry point only, ADR 0001/0025): ${m#$ROOT/}"
    v6_extra=$((v6_extra+1))
  done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -path "$ROOT/.claude" -prune -o -name node_modules -prune -o -name 'marketplace.json' -print 2>/dev/null)
  [ "$v6_extra" -eq 0 ] && ok V6 "single product-entry marketplace (.claude-plugin/marketplace.json)"

  if command -v python3 >/dev/null 2>&1; then
    v6_out="$(python3 - "$ROOT" "$MKT" <<'PYV6' 2>/dev/null
import json, os, sys
root, mkt = sys.argv[1], sys.argv[2]
expected = {
    "zero-trust": "./plugins/zero-trust",
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
    print("unexpected plugin '%s' registered (source=%s) - the product is exactly the one zero-trust plugin (ADR 0025)" % (n, got[n]))
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
        print("plugin '%s' source lacks .claude-plugin/plugin.json (not installable): %s" % (n, src)); continue
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
      ok V6 "root marketplace registers exactly the zero-trust plugin; name<->source pairing + plugin.json name verified (structural)"
    fi
  else
    # reduced fallback (python3 absent): name+source presence + installability only
    v6_bad=0
    while IFS='|' read -r pname psrc; do
      [ -n "$pname" ] || continue
      grep -q "\"name\": \"$pname\"" "$MKT"  || { violation V6 "plugin '$pname' not registered in root marketplace"; v6_bad=1; }
      grep -q "\"source\": \"$psrc\"" "$MKT" || { violation V6 "plugin '$pname' source '$psrc' not registered"; v6_bad=1; }
      pdir="$ROOT/${psrc#./}"
      { [ -d "$pdir" ] && [ -f "$pdir/.claude-plugin/plugin.json" ]; } || { violation V6 "plugin '$pname' source not installable: $psrc"; v6_bad=1; }
    done <<'V6PLUGINS'
zero-trust|./plugins/zero-trust
V6PLUGINS
    [ "$v6_bad" -eq 0 ] && ok V6 "zero-trust plugin registered + installable (reduced grep check; python3 absent)"
  fi
fi

# ── V9: the triage telemetry-adapter observable contract (ADR 0006/0013; register
#        TR-08). plugins/zero-trust/references/telemetry-contract.md is the SINGLE
#        SOURCE of the <!-- vendored:telemetry-contract --> block; any backend-
#        contract copy (references/backends.md, …) carries it byte-identical — the
#        host-contract precedent, the marker-block mechanism. A lone/unpaired
#        marker in prose is documentation, not a copy (no false positive).
#        The ID stays V9 (V7/V8 are retired, never reused; V10 is remediation's).
v9_begin='vendored:telemetry-contract:begin'
v9_end='vendored:telemetry-contract:end'
v9_extract() { awk -v b="$v9_begin" -v e="$v9_end" '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$1"; }
v9_canon_file="$ZT/references/telemetry-contract.md"
if [ ! -f "$v9_canon_file" ]; then
  ok V9 "triage telemetry-contract not present; nothing to pin (register TR-08)"
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
  # (2) the resume helpers triage shares with the spec tier (profile_resolve.py,
  #     resume_projection.py; register TR-04/TR-07) live exactly ONCE, under the
  #     plugin's scripts/ (ADR 0025 collapsed the vendored pair into one file).
  #     If a second same-named copy ever reappears anywhere in the tree, it must
  #     be byte-identical to the canonical — an UNPINNED re-vendored copy is the
  #     drift-fork this lint exists to prevent (ADR 0001 §18 mandate, post-0025).
  for v9base in profile_resolve.py resume_projection.py; do
    v9c="$ZT/scripts/$v9base"
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      [ "$c" = "$v9c" ] && continue
      rel="${c#$ROOT/}"
      if [ ! -f "$v9c" ]; then
        violation V9 "canonical plugins/zero-trust/scripts/$v9base missing while a copy exists at $rel (ADR 0025 — one canonical)"; v9_bad=1
      elif cmp -s "$v9c" "$c"; then
        ok V9 "second $v9base copy byte-identical to canonical: $rel"
      else
        violation V9 "re-vendored $v9base DRIFTED from canonical: $rel (ADR 0001 §18 — byte-for-byte from plugins/zero-trust/scripts/$v9base)"; v9_bad=1
      fi
    done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -path "$ROOT/.claude" -prune -o -name node_modules -prune -o -name __pycache__ -prune -o -name "$v9base" -print 2>/dev/null | sort)
  done
  [ "$v9_bad" -eq 0 ] && ok V9 "triage single-source artifacts (telemetry-contract block + resume helpers) pinned (register TR-04/07/08, ADR 0001/0025)"
fi

# ── V10: the remediation loop's two lint-pinned tables (ADR 0017 / 0018; register
#        RL-02/RL-03/RL-13). The loop is WIRING and holds no quality opinion — but
#        two of its inputs ARE pinned contracts that must not silently drift:
#   (a) classify_fix.sh's escalate-class table CITES ADR 0002 and its money/auth
#       membership is a SUPERSET of audit-state-and-verify.md's Category-TX slug
#       catalog (a TX slug silently dropped from the classifier would let a
#       money-path fix auto-drain — the exact failure ADR 0002 forbids);
#   (b) slug_provenance.tsv — every slug exists in the audit taxonomy AND each
#       provenance matches SPEC_1.4.0 §12 (a slug flipped det<->agent changes what
#       the loop autonomously files; drift → red).
RL_SCRIPTS="$ZT/skills/cleanup-audit/scripts"
CLASSIFY="$RL_SCRIPTS/classify_fix.sh"
PROVTSV="$RL_SCRIPTS/slug_provenance.tsv"
TAXONOMY="$ZT/skills/cleanup-audit/references/audit-state-and-verify.md"
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
    TAX_REFS="$ZT/skills/cleanup-audit/references"
    TAX_MROT="$ZT/skills/cleanup-audit/scripts/check_memory_rot.sh"
    TAX_DEBT="$ZT/skills/cleanup-audit/scripts/debt_patterns.sh"
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

# ── V11: outcome-store pins + the H1 anti-laundering guard (ADR 0023; register
#        OM-09). Outcome measurement writes a shared store from TWO producers (the
#        Marshal outcome-capture/digest modes + the audit outcome-emit step); they
#        must not drift on the store contract, and NO agent-graded number may be
#        laundered as deterministic. Three guarantees:
#   (a) plugins/zero-trust/schema/outcome/v1.schema.json is the single canonical
#       outcome-store schema (ADR 0025: one copy); any other copy in the tree is
#       byte-identical.
#   (b) the <!-- vendored:outcome-store-contract --> block has ONE source
#       (docs/specs/outcome-store-contract.md); every well-formed copy is
#       byte-identical (the marker mechanism; a lone/unpaired marker in prose is
#       documentation, not a copy — no false positive).
#   (c) the H1 anti-laundering guard, mechanized over the register: the real-repo
#       emission-share acceptance is tagged [audit-run], and NO [det] acceptance
#       claims a real-repo agent-graded number.
OUTCANON="$ZT/schema/outcome/v1.schema.json"
if [ ! -f "$OUTCANON" ]; then
  ok V11 "no outcome-store schema present; nothing to pin (ADR 0023)"
else
  v11_bad=0
  # (a) any other outcome-store schema copy is byte-identical to the canonical.
  o_copies=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ "$c" = "$OUTCANON" ] && continue
    o_copies=$((o_copies+1))
    if cmp -s "$OUTCANON" "$c"; then
      ok V11 "outcome-store schema copy byte-identical: ${c#$ROOT/}"
    else
      violation V11 "outcome-store schema copy DRIFTED from canonical: ${c#$ROOT/} (ADR 0023/0025 — the one schema lives at plugins/zero-trust/schema/outcome/v1.schema.json)"; v11_bad=1
    fi
  done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -path "$ROOT/.claude" -prune -o -name node_modules -prune -o -path '*/outcome/v1.schema.json' -print 2>/dev/null)
  [ "$o_copies" -eq 0 ] && ok V11 "single canonical outcome-store schema; no copies to drift (ADR 0023/0025)"

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
        violation V11 "vendored outcome-store-contract block DRIFTED from canonical: $rel (ADR 0023 — byte-identical; the marker-block precedent)"; v11_bad=1
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
SD_SKILL_SCRIPTS="$ZT/skills/cleanup-audit/scripts"
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
  [ "$v12_bad" -eq 0 ] && ok V12 "SD tier: unfalsifiability guard + no-parallel-comparator guard hold (register SD-12; ADR 0021/0022)"
fi

# ── V13: the /health-loop attended wave drain (ADR 0024; register HL-01..HL-04).
#        The loop is codebase-health wiring over the autopilot + marshal domains;
#        four invariants must hold in SOURCE or the campaign's safety story
#        silently breaks:
#   (a) PRESENCE COUPLING (all-or-nothing): if commands/health-loop.md ships, its
#       config, reference, and all four substrate scripts ship with it — a
#       half-shipped loop is a command whose "deterministic script call" resolves
#       to nothing and degrades to model judgment, the exact defect class L13
#       exists for in autopilot.
#   (b) CONFIG VOCABULARY: loop.config.yaml's wave_policy keys "1".."5" are each
#       auto|pause; merge is pause|preauthorized; partial_policy is pause (v1 is
#       depth-0 by ADR 0024 decision 6 — an advance-and-carry value appearing here
#       is a design change smuggled in as config).
#   (c) GATE VOCABULARY ⊆ LIFECYCLE: every status token wave_gate.py judges must
#       exist in the audit-state-and-verify.md lifecycle — a gate token the
#       verifier never writes is a branch that can never fire (or worse, a
#       misspelling that silently reclassifies findings).
#   (d) READ-ONLY PIN: wave_gate.py never writes state and spawns no detector
#       (loop-safety invariants 1/7 — the gate reads /verify's judgment, it never
#       re-grades or re-detects). Mirrors the remediation_scope_guard posture.
#   Cross-domain presence (full tree only, keyed on the root marketplace): the
#   loop's merge step calls the autopilot host adapter and the marshal — their
#   absence in a registered suite tree is a broken dispatch table (PR-2 review
#   finding 8).
HL_CMD="$ZT/commands/health-loop.md"
HL_SKILL="$ZT/skills/cleanup-audit"
if [ ! -f "$HL_CMD" ]; then
  ok V13 "health-loop command not present; nothing to pin (ADR 0024)"
else
  v13_bad=0
  # (a) presence coupling — all-or-nothing.
  for f in "$HL_SKILL/loop.config.yaml" \
           "$HL_SKILL/references/health-loop.md" \
           "$HL_SKILL/scripts/spec_wave.sh" \
           "$HL_SKILL/scripts/wave_gate.sh" \
           "$HL_SKILL/scripts/wave_gate.py" \
           "$HL_SKILL/scripts/wave_preauth_check.sh"; do
    if [ ! -f "$f" ]; then
      violation V13 "half-shipped loop: ${f#$ROOT/} is missing while commands/health-loop.md exists (ADR 0024 presence coupling)"; v13_bad=1
    fi
  done
  # (b) config vocabulary.
  HL_CFG="$HL_SKILL/loop.config.yaml"
  if [ -f "$HL_CFG" ]; then
    for k in 1 2 3 4 5; do
      if ! grep -qE "^[[:space:]]*\"$k\":[[:space:]]*(auto|pause)([[:space:]]|#|$)" "$HL_CFG"; then
        violation V13 "loop.config.yaml wave_policy key \"$k\" is missing or not auto|pause (ADR 0024)"; v13_bad=1
      fi
    done
    grep -qE '^[[:space:]]*merge:[[:space:]]*(pause|preauthorized)([[:space:]]|#|$)' "$HL_CFG" \
      || { violation V13 "loop.config.yaml merge is missing or not pause|preauthorized (ADR 0024 decision 4)"; v13_bad=1; }
    grep -qE '^[[:space:]]*partial_policy:[[:space:]]*pause([[:space:]]|#|$)' "$HL_CFG" \
      || { violation V13 "loop.config.yaml partial_policy is missing or not pause — v1 is depth-0 only (ADR 0024 decision 6)"; v13_bad=1; }
  fi
  # (c) gate vocabulary ⊆ the audit-state-and-verify lifecycle.
  HL_GATE_PY="$HL_SKILL/scripts/wave_gate.py"
  HL_LIFECYCLE="$HL_SKILL/references/audit-state-and-verify.md"
  if [ -f "$HL_GATE_PY" ] && [ -f "$HL_LIFECYCLE" ]; then
    hl_tokens="$(grep -E '^(PASS_STATUSES|INCOMPLETE_STATUSES) = ' "$HL_GATE_PY" | grep -oE '"[A-Z_]+"' | tr -d '"'; echo REGRESSED)"
    for s in $hl_tokens; do
      if ! grep -qE "(^|[^A-Z])$s([^A-Z]|$)" "$HL_LIFECYCLE"; then
        violation V13 "wave_gate.py judges status '$s' which is not in the audit-state-and-verify.md lifecycle — a gate branch the verifier can never feed"; v13_bad=1
      fi
    done
  fi
  # (d) read-only pin. Comment lines are excluded so PROSE ABOUT the pin (a
  #     docstring or note naming write_text) is not a false positive — the V12
  #     emit/print-call scoping precedent.
  if [ -f "$HL_GATE_PY" ]; then
    if grep -vE '^[[:space:]]*#' "$HL_GATE_PY" | grep -qE 'write_text|json\.dump|open\([^)]*,[[:space:]]*["'"'"'](w|a)'; then
      violation V13 "wave_gate.py carries a write path — the gate is a pure reader of /verify's judgment (loop-safety invariants 1/7)"; v13_bad=1
    fi
    if grep -vE '^[[:space:]]*#' "$HL_GATE_PY" | grep -qE 'run_audit\.sh|mutmut|cosmic-ray|stryker|pitest|cargo-mutants'; then
      violation V13 "wave_gate.py spawns a detector/mutation tool — the gate never re-detects (loop-safety invariant 1)"; v13_bad=1
    fi
  fi
  # Cross-domain presence — only meaningful in a full registered tree.
  if [ -f "$ROOT/.claude-plugin/marketplace.json" ]; then
    [ -f "$ZT/skills/autopilot/scripts/host.sh" ] \
      || { violation V13 "health-loop ships but the autopilot host adapter (skills/autopilot/scripts/host.sh) is absent — the merge step's PR surface is unresolvable"; v13_bad=1; }
    [ -f "$ZT/scripts/marshal.sh" ] \
      || { violation V13 "health-loop ships but the marshal (scripts/marshal.sh) is absent — no merge executor for the campaign"; v13_bad=1; }
  fi
  [ "$v13_bad" -eq 0 ] && ok V13 "health-loop: presence coupling + config vocabulary + gate-status-subset + read-only pin hold (ADR 0024)"
fi

echo
if [ "$FAIL" -eq 0 ]; then echo "== lint_consistency: all cross-domain contract rules pass =="; else echo "== lint_consistency: violations found =="; fi
exit "$FAIL"
