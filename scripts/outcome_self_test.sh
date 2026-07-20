#!/usr/bin/env bash
# outcome_self_test.sh — hermetic self-test for the outcome-measurement layer
# (ADR 0023; register OM-01..OM-08). Every [det] acceptance in the register is
# covered by a named assertion here (the CH-10-style close). All fixtures are built
# in a mktemp sandbox with local repos; no network, no live host, no credentials.
#
# The store writer needs the uv-locked jsonschema toolchain (ADR 0015); if it is
# unreachable the WHOLE layer SKIPS with a loud notice (skip-honesty — never a false
# green, never a false red). ON TOP of that, the host-dependent assertions (DORA
# build-status + the digest post) drive the Marshal MOCK host, which needs uv; they
# are additionally gated on UV_OK and SKIPPED-with-a-notice when uv is absent. The
# suite's component_skips detector turns any skip into PASS(skips).
#
# Usage: bash scripts/outcome_self_test.sh
# Exit 0 = all assertions pass; non-zero = at least one failure.
# Portability: bash 3.2 (macOS) + BSD userland safe.
set -u
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ZT="$ROOT/plugins/zero-trust"   # the outcome family lives in the plugin (ADR 0031)
STORE_SH="$ZT/scripts/outcome_store.sh"
BASELINE_SH="$ZT/scripts/outcome_baseline.sh"
EXTERNAL_SH="$ZT/scripts/outcome_external.sh"
ANNOTATE_SH="$ZT/scripts/outcome_annotate.sh"
REPORT_SH="$ZT/scripts/outcome_report.sh"
CAPTURE_SH="$ZT/scripts/outcome_capture.sh"
EMIT_SH="$ZT/skills/cleanup-audit/scripts/outcome_emit.sh"
DIGEST_SH="$ZT/scripts/outcome_digest.sh"
MOCK="$ZT/scripts/mock_host.sh"

py() { if command -v uv >/dev/null 2>&1 && [ -f "$ZT/pyproject.toml" ]; then uv run --no-project python "$@"; else python3 "$@"; fi; }
jget() { py - "$@"; }  # convenience: run inline python reading argv

PASS=0; FAIL=0
pass() { echo "ok   [$1] $2"; PASS=$((PASS+1)); }
fail() { echo "FAIL [$1] $2" >&2; FAIL=$((FAIL+1)); }
assert_eq() { if [ "$3" = "$4" ]; then pass "$1" "$2"; else fail "$1" "$2 — expected [$3] got [$4]"; fi; }
assert_rc() { if [ "$3" = "$4" ]; then pass "$1" "$2 (rc=$4)"; else fail "$1" "$2 — expected rc=$3 got rc=$4"; fi; }
assert_contains() { case "$4" in *"$3"*) pass "$1" "$2";; *) fail "$1" "$2 — missing [$3]";; esac; }
assert_absent()   { case "$4" in *"$3"*) fail "$1" "$2 — found forbidden [$3]";; *) pass "$1" "$2";; esac; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT INT TERM
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=ost GIT_AUTHOR_EMAIL=ost@local GIT_COMMITTER_NAME=ost GIT_COMMITTER_EMAIL=ost@local

metric_val() { # <store> <name> -> value (or "None")
  py - "$1" "$2" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
snaps=[d.get("baseline")] if d.get("baseline") else []
snaps+=d.get("runs",[])
val="None"
for s in snaps:
    if not s: continue
    for m in s.get("metrics",[]):
        if m["name"]==sys.argv[2]: val=str(m.get("value"))
print(val)
PY
}

# Skip-honesty (register OM-09): the store/baseline/emit/external/digest assertions
# all route through the store writer, which needs the uv-locked jsonschema toolchain
# (ADR 0015). We probe EXACTLY as the real assertions resolve deps — through
# outcome_store.sh (which self-bootstraps via `uv run --project`) — not a bare
# `--no-project` import, so the probe can never disagree with the assertions. If the
# store toolchain is unreachable we SKIP the whole layer with a loud notice the
# suite's component_skips() detector catches: PASS-WITH-SKIPS, never a false green or
# false red. (The suite runs a `uv run --project` component before this one, so the
# toolchain is warm; standalone in a fresh clone this bootstraps it.)
if ! ( printf '{"schema_version":1,"runs":[]}' > "$SANDBOX/_probe.json" \
       && bash "$STORE_SH" validate --store "$SANDBOX/_probe.json" >/dev/null 2>&1 ); then
  echo "  [skip] outcome-store jsonschema toolchain unavailable (ADR 0015) — ALL outcome self-test sections SKIPPED (skip-honesty; the suite requires uv)"
  echo "outcome_self_test: PASS=0 FAIL=0 (SKIPPED — no jsonschema toolchain)"
  exit 0
fi

# ============================================================================
# OM-01 — outcome store schema + degrade
# ============================================================================
echo "== OM-01 outcome store (OS) =="
STORE="$SANDBOX/os.json"
printf '{"captured_at":"t","git_sha":"g","kind":"run","metrics":[{"name":"deploy_frequency","value":3.5,"honesty_class":"deterministic","provenance":"git-log"}]}' \
  | bash "$STORE_SH" append-run --store "$STORE" >/dev/null 2>&1; assert_rc OS01 "append-run to absent store creates it" 0 $?
bash "$STORE_SH" validate --store "$STORE" >/dev/null 2>&1; assert_rc OS01 "resulting store validates" 0 $?
printf '{"captured_at":"t","git_sha":"g","metrics":[{"name":"x","value":1,"provenance":"p"}]}' \
  | bash "$STORE_SH" append-run --store "$STORE" >/dev/null 2>&1; assert_rc OS02 "row WITHOUT honesty_class rejected schema-invalid" 4 $?
printf '{"captured_at":"t","git_sha":"g","metrics":[{"name":"x","provenance":"p","honesty_class":"deterministic"}]}' \
  | bash "$STORE_SH" append-run --store "$STORE" >/dev/null 2>&1; assert_rc OS03 "optional value absent is accepted (absent != 0)" 0 $?
# corrupt store -> refuse, byte-identical
printf 'not json {{{' > "$STORE"; H1="$(cksum < "$STORE")"
printf '{"captured_at":"t","git_sha":"g","metrics":[]}' | bash "$STORE_SH" append-run --store "$STORE" >/dev/null 2>&1
assert_rc OS04 "write against corrupt store exits non-zero" 5 $?
H2="$(cksum < "$STORE")"; assert_eq OS04 "corrupt store left byte-identical" "$H1" "$H2"
printf '{"schema_version":99,"runs":[]}' > "$STORE"
printf '{"captured_at":"t","git_sha":"g","metrics":[]}' | bash "$STORE_SH" append-run --store "$STORE" >/dev/null 2>&1
assert_rc OS05 "unknown schema_version refused" 5 $?
# OM-01 H1 anti-laundering (structural): the schema binds each metric name to its
# honesty class, so a MISLABELED row cannot enter the store (not just an unlabeled one).
printf '{"captured_at":"t","git_sha":"g","metrics":[{"name":"emission_share","value":0.9,"honesty_class":"deterministic","provenance":"journeys.json@x"}]}' \
  | bash "$STORE_SH" append-run --store "$SANDBOX/laund1.json" >/dev/null 2>&1
assert_rc OS06 "laundered emission_share (agent-graded metric tagged deterministic) rejected schema-invalid" 4 $?
printf '{"captured_at":"t","git_sha":"g","metrics":[{"name":"deploy_frequency","value":3,"honesty_class":"agent-graded","provenance":"g"}]}' \
  | bash "$STORE_SH" append-run --store "$SANDBOX/laund2.json" >/dev/null 2>&1
assert_rc OS06 "DORA metric mislabeled agent-graded rejected schema-invalid" 4 $?
printf '{"captured_at":"t","git_sha":"g","metrics":[{"name":"paged_share","value":0.5,"honesty_class":"agent-graded","provenance":"g"}]}' \
  | bash "$STORE_SH" append-run --store "$SANDBOX/laund3.json" >/dev/null 2>&1
assert_rc OS06 "external metric mislabeled agent-graded rejected schema-invalid" 4 $?

# ============================================================================
# DORA fixture (shared by OM-02 / OM-03) — a hand-computed history
# ============================================================================
FIX="$SANDBOX/repo"; mkdir -p "$FIX"; ( cd "$FIX" && git init -q && git config commit.gpgsign false && git checkout -q -b main )
E=1000000000
gc() { ( cd "$FIX" && git add -A && GIT_AUTHOR_DATE="@${3:-$1}" GIT_COMMITTER_DATE="@$1" git commit -q -m "$2" ); }
( cd "$FIX" && printf 'a\n' > defs.txt && printf 'a\n' > calls.txt ); gc $E root
( cd "$FIX" && printf 'a\nb\n' > defs.txt && printf 'a\nb\n' > calls.txt ); gc $((E+86400)) D1 $E
D1SHA="$( cd "$FIX" && git rev-parse HEAD )"
( cd "$FIX" && printf 'a\nb\n' > defs.txt && printf 'a\nb\nZZZ\n' > calls.txt ); gc $((E+2*86400)) "D2 broken"
( cd "$FIX" && printf 'a\nb\nZZZ\n' > defs.txt && printf 'a\nb\nZZZ\n' > calls.txt ); gc $((E+3*86400)) "D3 fix"
( cd "$FIX" && printf 'a\n' > defs.txt && printf 'a\n' > calls.txt ); gc $((E+4*86400)) "Revert D1. This reverts commit ${D1SHA}."
SINCE=$E; UNTIL=$((E+8*7*86400))
STATE="$SANDBOX/state.json"; printf '{"trunk":"main","prs":[]}' > "$STATE"

UV_OK=1
if ! command -v uv >/dev/null 2>&1; then UV_OK=0; echo "WARN: uv not found — host-dependent OM sections (DORA build-status, digest post) SKIPPED (ADR 0015 mock host needs uv)" >&2; fi

# ============================================================================
# OM-03 — DORA derivation (Class-D), a Marshal mode
# ============================================================================
echo "== OM-03 DORA capture (DR) =="
# Extract a metric value from a DORA JSON blob written to a file (program via argv;
# NEVER pipe JSON to a `py -` heredoc — the heredoc IS stdin and would shadow it).
dora_val() { # <json-blob> <metric>
  printf '%s' "$1" > "$SANDBOX/_dora.json"
  py - "$SANDBOX/_dora.json" "$2" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print({m["name"]:m["value"] for m in d["metrics"]}.get(sys.argv[2]))
PY
}
dora_norm() { # <json-blob> -> canonical name->value map
  printf '%s' "$1" > "$SANDBOX/_dnorm.json"
  py - "$SANDBOX/_dnorm.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(json.dumps({m["name"]:m["value"] for m in d["metrics"]},sort_keys=True))
PY
}
# no-host slice is pure git and hermetic (always runs)
DNOHOST="$(py "$ZT/scripts/outcome_dora.py" --repo "$FIX" --trunk main --since $SINCE --until $UNTIL)"
assert_eq DR01 "deploy_frequency = 4/8wk = 0.5 (pure git)" "0.5" "$(dora_val "$DNOHOST" deploy_frequency)"
assert_eq DR01 "lead_time median hours (pure git)" "0.0" "$(dora_val "$DNOHOST" lead_time)"
assert_eq DR02 "change_failure_rate revert-only = 1/4 = 0.25 (no host)" "0.25" "$(dora_val "$DNOHOST" change_failure_rate)"
# zero-merge window
DZ="$(py "$ZT/scripts/outcome_dora.py" --repo "$FIX" --trunk main --since $((UNTIL+1)) --until $((UNTIL+8*7*86400)))"
assert_eq DR03 "zero-merge window: deploy_freq 0" "0.0" "$(dora_val "$DZ" deploy_frequency)"
assert_eq DR03 "zero-merge window: lead_time null" "None" "$(dora_val "$DZ" lead_time)"

if [ "$UV_OK" = "1" ]; then
  DHOST="$(py "$ZT/scripts/outcome_dora.py" --repo "$FIX" --trunk main --since $SINCE --until $UNTIL --host "$MOCK" --host-repo "$FIX/.git" --host-state "$STATE")"
  assert_eq DR04 "with host: change_failure_rate = (D1 revert + D2 build) 2/4 = 0.5" "0.5" "$(dora_val "$DHOST" change_failure_rate)"
  assert_eq DR04 "with host: mttr_build = D2 red -> D3 green = 24.0h" "24.0" "$(dora_val "$DHOST" mttr_build)"
  # both-backends byte-identical contract: a SECOND adapter (a build-status table shim)
  # returning the SAME statuses yields byte-identical DORA (capture never branches on backend).
  SHIM="$SANDBOX/shim.sh"; MAP="$SANDBOX/map.tsv"
  ( cd "$FIX" && for m in "D2 broken=FAILED"; do :; done )
  # build a sha->status map matching the mock's composition (D2 FAILED, rest SUCCESSFUL)
  ( cd "$FIX" && git log --first-parent --format='%H %s' main | while read -r sha subj; do
      case "$subj" in "D2 broken") echo "$sha	FAILED";; *) echo "$sha	SUCCESSFUL";; esac
    done ) > "$MAP"
  cat > "$SHIM" <<SHIMEOF
#!/usr/bin/env bash
# minimal second backend: answer build-status --sha from a sha->status table.
set -u
[ "\$1" = "build-status" ] || exit 0
sha=""; while [ \$# -gt 0 ]; do [ "\$1" = "--sha" ] && sha="\$2"; shift; done
grep -F "\$sha" "$MAP" | cut -f2 | head -1
SHIMEOF
  chmod +x "$SHIM"
  DSHIM="$(py "$ZT/scripts/outcome_dora.py" --repo "$FIX" --trunk main --since $SINCE --until $UNTIL --host "$SHIM")"
  DHOSTN="$(dora_norm "$DHOST")"; DSHIMN="$(dora_norm "$DSHIM")"
  # non-vacuity precondition: both derivations must be NON-EMPTY and carry the
  # host-derived mttr_build (else DR05 would pass on mutual emptiness).
  assert_contains DR05 "backend maps are non-empty (mttr_build present, not degenerate)" "mttr_build" "$DHOSTN"
  assert_eq DR05 "both backends yield byte-identical DORA (backend-agnostic contract)" "$DHOSTN" "$DSHIMN"
  # OM-03 writes ONLY the store: capture makes zero host writes
  CST="$SANDBOX/cap.json"; CSTATE="$SANDBOX/cstate.json"; printf '{"trunk":"main","prs":[]}' > "$CSTATE"
  bash "$CAPTURE_SH" --store "$CST" --repo "$FIX" --trunk main --since $SINCE --until $UNTIL --now $UNTIL --host "$MOCK" --host-repo "$FIX/.git" --host-state "$CSTATE" >/dev/null 2>&1
  assert_rc DR06 "marshal outcome-capture appends a run" 0 $?
  WRITES="$(py - "$CSTATE" <<'PY'
import json,sys;d=json.load(open(sys.argv[1]));print(len(d.get("comments",[]))+len(d.get("merges",[])))
PY
)"
  assert_eq DR06 "outcome-capture makes ZERO host writes (comments+merges)" "0" "$WRITES"
  KIND="$(py - "$CST" <<'PY'
import json,sys;d=json.load(open(sys.argv[1]));print("baseline" if d.get("baseline") else "run-only")
PY
)"
  assert_eq DR06 "outcome-capture writes a run, not a baseline" "run-only" "$KIND"
else
  echo "  [skip] DR04/DR05/DR06 host-dependent DORA assertions SKIPPED (no uv/mock host)"
fi

# ============================================================================
# OM-02 — baseline capture, frozen, refuse-second
# ============================================================================
echo "== OM-02 baseline (BL) =="
J="$SANDBOX/journeys.json"
cat > "$J" <<'JSON'
{"schema_version":2,"source_run":{"kind":"audit","git_sha":"base1234"},"journeys":[
 {"name":"Pay","criticality":"CORE","steps":[
   {"vital_class":"money","emission_grade":"OBSERVED"},
   {"vital_class":"money","emission_grade":"DARK"}]}]}
JSON
BSTORE="$SANDBOX/baseline.json"
if [ "$UV_OK" = "1" ]; then HOSTARGS="--host $MOCK --host-repo $FIX/.git --host-state $STATE"; else HOSTARGS=""; fi
bash "$BASELINE_SH" capture --store "$BSTORE" --repo "$FIX" --trunk main --since $SINCE --until $UNTIL --now $UNTIL $HOSTARGS --journeys "$J" >/dev/null 2>&1
assert_rc BL01 "baseline capture succeeds" 0 $?
FROZEN="$(py - "$BSTORE" <<'PY'
import json,sys;print(json.load(open(sys.argv[1]))["baseline"].get("frozen"))
PY
)"
assert_eq BL01 "baseline is frozen:true" "True" "$FROZEN"
DORADET="$(py - "$BSTORE" <<'PY'
import json,sys
b=json.load(open(sys.argv[1]))["baseline"]
dora=[m for m in b["metrics"] if m["name"] in ("deploy_frequency","lead_time","change_failure_rate","mttr_build")]
print("all-det" if dora and all(m["honesty_class"]=="deterministic" for m in dora) else "MIXED")
PY
)"
assert_eq BL01 "all four DORA fields tagged deterministic" "all-det" "$DORADET"
EMHC="$(py - "$BSTORE" <<'PY'
import json,sys
b=json.load(open(sys.argv[1]))["baseline"]
em=[m for m in b["metrics"] if m["name"]=="emission_share"]
print(em[0]["honesty_class"] if em else "MISSING")
PY
)"
assert_eq BL02 "emission-share field tagged agent-graded (NOT laundered as det)" "agent-graded" "$EMHC"
# refuse-second, byte-identical
B1="$(cksum < "$BSTORE")"
bash "$BASELINE_SH" capture --store "$BSTORE" --repo "$FIX" --trunk main --since $SINCE --until $UNTIL --now $((UNTIL+1000)) $HOSTARGS --journeys "$J" >/dev/null 2>&1
assert_rc BL03 "second capture on a frozen store is refused" 6 $?
B2="$(cksum < "$BSTORE")"; assert_eq BL03 "frozen store left byte-identical on refuse" "$B1" "$B2"
# window_short
WSTORE="$SANDBOX/wshort.json"
bash "$BASELINE_SH" capture --store "$WSTORE" --repo "$FIX" --trunk main --weeks 8 --now $((E+3*86400)) $HOSTARGS >/dev/null 2>&1
WS="$(py - "$WSTORE" <<'PY'
import json,sys;print(json.load(open(sys.argv[1]))["baseline"].get("window_short"))
PY
)"
assert_eq BL04 "trailing window shorter than minimum -> window_short:true" "True" "$WS"

# ============================================================================
# OM-04 — journey emission share (Class-A), audit outcome-emit
# ============================================================================
echo "== OM-04 emission-share (EM) =="
EM3="$SANDBOX/j3.json"
cat > "$EM3" <<'JSON'
{"schema_version":2,"source_run":{"kind":"audit","git_sha":"emit77"},"journeys":[
 {"name":"Pay","criticality":"CORE","steps":[
   {"vital_class":"money","emission_grade":"OBSERVED"},
   {"vital_class":"auth","emission_grade":"OBSERVED"},
   {"vital_class":"money","emission_grade":"DARK"},
   {"vital_class":null,"emission_grade":null}]},
 {"name":"Dev","criticality":"DEV","steps":[{"vital_class":"money","emission_grade":"DARK"}]}]}
JSON
ES="$SANDBOX/emit.json"
bash "$EMIT_SH" --store "$ES" --journeys "$EM3" --repo "$FIX" --now $E >/dev/null 2>&1; assert_rc EM01 "outcome-emit on a valid trace succeeds" 0 $?
EMROW="$(py - "$ES" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))["runs"][0]["metrics"]
r=[x for x in m if x["name"]=="emission_share"][0]
print("%s|%s|%s" % (r["value"], r["honesty_class"], r["provenance"]))
PY
)"
assert_eq EM01 "exact CORE money/auth OBSERVED share 2/3 = 0.6667" "0.6667" "${EMROW%%|*}"
assert_contains EM01 "every emitted row honesty_class: agent-graded" "agent-graded" "$EMROW"
assert_contains EM01 "provenance journeys.json@<sha>" "journeys.json@emit77" "$EMROW"
# H2: no alert_seam / paged field
EMJSON="$(py - "$ES" <<'PY'
import json,sys;print(json.dumps(json.load(open(sys.argv[1]))["runs"][0]["metrics"]))
PY
)"
assert_absent EM02 "no alert_seam field (H2)" "alert_seam" "$EMJSON"
assert_absent EM02 "no paged field (H2)" "paged" "$EMJSON"
# v1 (pre-CH-02) parses and yields a share
V1STORE="$SANDBOX/v1emit.json"
bash "$EMIT_SH" --store "$V1STORE" --journeys "$ROOT/tests/codebase-health/test-fixtures/pr-gate/journeys.v1.json" --repo "$FIX" --now $E >/dev/null 2>&1
assert_eq EM03 "v1 journeys.json still parses -> share present" "0.0" "$(metric_val "$V1STORE" emission_share)"
# degrade: absent/corrupt/unknown -> no row, exit 0
DEGSTORE="$SANDBOX/deg.json"
bash "$EMIT_SH" --store "$DEGSTORE" --journeys "$SANDBOX/nope.json" --repo "$FIX" >/dev/null 2>&1; assert_rc EM04 "absent journeys.json exits 0 (degrade)" 0 $?
assert_eq EM04 "absent journeys.json writes NO store row" "no-store" "$([ -f "$DEGSTORE" ] && echo has-store || echo no-store)"
printf 'not json{{' > "$SANDBOX/corrupt.json"
bash "$EMIT_SH" --store "$DEGSTORE" --journeys "$SANDBOX/corrupt.json" --repo "$FIX" >/dev/null 2>&1; assert_rc EM04 "corrupt journeys.json exits 0" 0 $?
printf '{"schema_version":3,"journeys":[]}' > "$SANDBOX/v3.json"
OUT="$(bash "$EMIT_SH" --store "$DEGSTORE" --journeys "$SANDBOX/v3.json" --repo "$FIX" 2>&1)"; assert_rc EM04 "unknown-schema journeys.json exits 0" 0 $?
assert_contains EM04 "unknown-schema emits a loud [note]" "[note]" "$OUT"

# ============================================================================
# OM-05 / OM-06 — external adapters + annotated fallback + source-absent
# ============================================================================
echo "== OM-05/06 external (EX) =="
EXS="$SANDBOX/ext.json"
printf 'hotfix-1\nhotfix-2\n# ignored\n' > "$SANDBOX/escapes.txt"
bash "$EXTERNAL_SH" defect-escape --store "$EXS" --source-file "$SANDBOX/escapes.txt" --deploys 8 --now $E --repo "$FIX" >/dev/null 2>&1
assert_eq EX01 "defect-escape deterministic 2/8 = 0.25" "0.25" "$(metric_val "$EXS" defect_escape_rate)"
DEHC="$(py - "$EXS" <<'PY'
import json,sys
m=[x for r in json.load(open(sys.argv[1]))["runs"] for x in r["metrics"] if x["name"]=="defect_escape_rate"][0]
print(m["honesty_class"])
PY
)"
assert_eq EX01 "defect-escape tagged deterministic" "deterministic" "$DEHC"
EXABS="$SANDBOX/exabs.json"
OUT="$(bash "$EXTERNAL_SH" defect-escape --store "$EXABS" --now $E --repo "$FIX" 2>&1)"
assert_contains EX02 "no source -> [OUTCOME-SOURCE-ABSENT: defect-escape]" "OUTCOME-SOURCE-ABSENT: defect-escape" "$OUT"
assert_eq EX02 "source-absent writes no store row" "no-store" "$([ -f "$EXABS" ] && echo has-store || echo no-store)"
# annotated
ANS="$SANDBOX/ann.json"
bash "$ANNOTATE_SH" defect-escape --store "$ANS" --value 0.05 --count 3 --window 8w --now $E --repo "$FIX" >/dev/null 2>&1
ANHC="$(py - "$ANS" <<'PY'
import json,sys
m=[x for r in json.load(open(sys.argv[1]))["runs"] for x in r["metrics"] if x["name"]=="defect_escape_rate"][0]
print("%s|%s" % (m["value"], m["honesty_class"]))
PY
)"
assert_eq EX03 "annotated value round-trips tagged human-annotated" "0.05|human-annotated" "$ANHC"
# incident deterministic + source-absent
INS="$SANDBOX/inc.json"
cat > "$SANDBOX/incsrc.json" <<'JSON'
{"incidents":[{"journey":"Pay","mttr_minutes":120},{"journey":"Pay","mttr_minutes":60},{"journey":"Login","mttr_minutes":30}],
 "alerts":[{"journey":"Pay","seam":"dashboard-only"},{"journey":"Login","seam":"paged"},{"journey":"Checkout","seam":"paged"}]}
JSON
cat > "$SANDBOX/incj.json" <<'JSON'
{"schema_version":2,"journeys":[
 {"name":"Pay","criticality":"CORE","steps":[{"vital_class":"money","emission_grade":"DARK"}]},
 {"name":"Login","criticality":"CORE","steps":[{"vital_class":"auth","emission_grade":"OBSERVED"}]}]}
JSON
bash "$EXTERNAL_SH" incident --store "$INS" --source-file "$SANDBOX/incsrc.json" --journeys "$SANDBOX/incj.json" --now $E --repo "$FIX" >/dev/null 2>&1
assert_eq EX04 "incident_count = 3" "3" "$(metric_val "$INS" incident_count)"
assert_eq EX04 "paged_share = 2/3 = 0.6667" "0.6667" "$(metric_val "$INS" paged_share)"
INABS="$SANDBOX/incabs.json"
OUT="$(bash "$EXTERNAL_SH" incident --store "$INABS" --now $E --repo "$FIX" 2>&1)"
assert_contains EX05 "no incident source -> incident-system absent" "OUTCOME-SOURCE-ABSENT: incident-system" "$OUT"
assert_contains EX05 "no alert config -> alert-config absent" "OUTCOME-SOURCE-ABSENT: alert-config" "$OUT"

# ============================================================================
# OM-07 — renderer (delta + significance + honesty badges), always exit 0
# ============================================================================
echo "== OM-07 renderer (RP) =="
RPSTORE="$SANDBOX/rp.json"
cat > "$RPSTORE" <<'JSON'
{"schema_version":1,
 "baseline":{"frozen":true,"captured_at":"b","git_sha":"b","window":{"weeks":8},"metrics":[
   {"name":"deploy_frequency","value":2.0,"honesty_class":"deterministic","provenance":"g"},
   {"name":"emission_share","value":0.4,"honesty_class":"agent-graded","provenance":"journeys.json@b"}]},
 "runs":[{"captured_at":"a","git_sha":"a","window":{"weeks":8},"metrics":[
   {"name":"deploy_frequency","value":3.0,"honesty_class":"deterministic","provenance":"g"}]},
  {"captured_at":"a2","git_sha":"a","metrics":[
   {"name":"emission_share","value":0.7,"honesty_class":"agent-graded","provenance":"journeys.json@a"}]}]}
JSON
OUT="$(bash "$REPORT_SH" --store "$RPSTORE")"; assert_rc RP01 "renderer exits 0" 0 $?
assert_contains RP01 "present metric renders a delta" "Δ +1" "$OUT"
assert_contains RP02 "Class-A row renders [agent-graded]" "emission share" "$OUT"
EMLINE="$(printf '%s\n' "$OUT" | grep 'emission share')"
assert_contains RP02 "emission line carries [agent-graded] badge" "[agent-graded]" "$EMLINE"
assert_absent   RP02 "emission line NEVER renders [det] (H1 end-to-end)" "[det]" "$EMLINE"
assert_contains RP03 "DORA delta carries a named-confounder line" "confounders:" "$OUT"
assert_contains RP04 "known external metric absent -> [OUTCOME-SOURCE-ABSENT]" "OUTCOME-SOURCE-ABSENT: defect-escape" "$OUT"
# window_short -> directional
SHORT="$SANDBOX/short.json"
cat > "$SHORT" <<'JSON'
{"schema_version":1,"baseline":{"frozen":true,"captured_at":"b","git_sha":"b","window":{"weeks":8},"metrics":[
   {"name":"deploy_frequency","value":2.0,"honesty_class":"deterministic","provenance":"g"}]},
 "runs":[{"captured_at":"a","git_sha":"a","window":{"weeks":3},"window_short":true,"metrics":[
   {"name":"deploy_frequency","value":5.0,"honesty_class":"deterministic","provenance":"g"}]}]}
JSON
assert_contains RP05 "window_short renders deltas directional" "directional, not yet significant" "$(bash "$REPORT_SH" --store "$SHORT")"
# no baseline -> [OUTCOME-NO-BASELINE], no fabricated delta
NOBASE="$SANDBOX/nobase.json"
printf '{"schema_version":1,"runs":[{"captured_at":"a","git_sha":"a","window":{"weeks":8},"metrics":[{"name":"deploy_frequency","value":5.0,"honesty_class":"deterministic","provenance":"g"}]}]}' > "$NOBASE"
OUT="$(bash "$REPORT_SH" --store "$NOBASE")"
assert_contains RP06 "no baseline -> [OUTCOME-NO-BASELINE]" "OUTCOME-NO-BASELINE" "$OUT"
assert_absent   RP06 "no baseline -> no fabricated delta" "Δ" "$OUT"
printf 'not json{{{' > "$SANDBOX/corruptstore.json"
bash "$REPORT_SH" --store "$SANDBOX/corruptstore.json" >/dev/null 2>&1; assert_rc RP07 "renderer on corrupt store still exits 0" 0 $?
# RP08 — defense-in-depth: a HAND-CRAFTED store that bypassed the schema (emission_share
# mislabeled deterministic) still cannot render [det]; the renderer badges by the
# AUTHORITATIVE class and surfaces the mismatch loudly (the H1 guard, belt AND braces).
LAUNDR="$SANDBOX/laundrender.json"
printf '{"schema_version":1,"runs":[{"captured_at":"t","git_sha":"g","metrics":[{"name":"emission_share","value":0.95,"honesty_class":"deterministic","provenance":"journeys.json@x"}]}]}' > "$LAUNDR"
RPO="$(bash "$REPORT_SH" --store "$LAUNDR")"
RPEM="$(printf '%s\n' "$RPO" | grep 'emission share')"
assert_contains RP08 "hand-crafted laundered store still badges [agent-graded]" "[agent-graded]" "$RPEM"
assert_absent   RP08 "hand-crafted laundered store NEVER renders [det]" "[det]" "$RPEM"
assert_contains RP08 "honesty mismatch surfaced loudly (not hidden)" "HONESTY-MISMATCH" "$RPEM"

# ============================================================================
# OM-08 — scheduled digest (rides the Marshal cron); read-only, posts via host
# ============================================================================
echo "== OM-08 digest (DG) =="
if [ "$UV_OK" = "1" ]; then
  DGREPO="$SANDBOX/dgrepo"; mkdir -p "$DGREPO/audit"; ( cd "$DGREPO" && git init -q && git config commit.gpgsign false && git checkout -q -b main )
  ( cd "$DGREPO" && printf 'a\n' > defs.txt && printf 'a\n' > calls.txt && git add -A && GIT_AUTHOR_DATE="@$E" GIT_COMMITTER_DATE="@$E" git commit -qm root )
  ( cd "$DGREPO" && printf 'a\nb\n' > defs.txt && printf 'a\nb\n' > calls.txt && git add -A && GIT_AUTHOR_DATE="@$E" GIT_COMMITTER_DATE="@$((E+86400))" git commit -qm D1 )
  cp "$EM3" "$DGREPO/audit/journeys.json"
  # behavioral no-fresh-audit proof (H6): record the journeys.json content hash before
  # the fire; the digest must READ it, never re-walk/rewrite it.
  JHASH_BEFORE="$(cksum < "$DGREPO/audit/journeys.json")"
  DGSTORE="$SANDBOX/dg.json"; DGSTATE="$SANDBOX/dgstate.json"; printf '{"trunk":"main","prs":[]}' > "$DGSTATE"
  OUT="$(bash "$DIGEST_SH" --store "$DGSTORE" --repo "$DGREPO" --trunk main --since $SINCE --until $UNTIL --now $UNTIL --host "$MOCK" --host-repo "$DGREPO/.git" --host-state "$DGSTATE" --artifact "$SANDBOX/DIGEST.md" --post-pr 7 2>&1)"
  assert_rc DG01 "digest fire exits 0" 0 $?
  assert_contains DG01 "step 1 capture ran" "step 1 outcome-capture ok" "$OUT"
  assert_contains DG01 "step 2 emit ran (read-only, no fresh audit)" "read-only; no fresh audit" "$OUT"
  # store has DORA + agent-graded emission
  assert_eq DG02 "store gained both a DORA run and an emission run" "3" "$(py - "$DGSTORE" <<'PY'
import json,sys
names={m["name"] for r in json.load(open(sys.argv[1]))["runs"] for m in r["metrics"]}
print("3" if {"deploy_frequency","emission_share"} <= names else "0")
PY
)"
  # exactly ONE comment posted (the digest), zero merges
  POSTED="$(py - "$DGSTATE" <<'PY'
import json,sys;d=json.load(open(sys.argv[1]));print("%d|%d" % (len(d.get("comments",[])), len(d.get("merges",[]))))
PY
)"
  assert_eq DG03 "digest posts exactly ONE comment, zero merges (Marshal write scope)" "1|0" "$POSTED"
  # the audit-side emit made zero host writes: the ONLY comment is the digest post itself.
  BODY="$(py - "$DGSTATE" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])).get("comments",[])
print(c[0]["body"][:40] if c else "")
PY
)"
  assert_contains DG03 "the single comment IS the digest (audit-emit posts nothing)" "Outcome measurement digest" "$BODY"
  assert_contains DG04 "digest declares no status check / no PR / no finding" "created no status check" "$OUT"
  # no fresh audit (H6) — BEHAVIORAL: the journeys.json the digest consumed is
  # byte-unchanged (it was READ, never re-walked/rewritten), AND no walker/run_audit
  # token appears in the fire output.
  JHASH_AFTER="$(cksum < "$DGREPO/audit/journeys.json")"
  assert_eq DG05 "journeys.json byte-unchanged — digest read it, never re-walked (H6)" "$JHASH_BEFORE" "$JHASH_AFTER"
  assert_absent DG05 "no run_audit token in the fire output" "run_audit" "$OUT"
  assert_absent DG05 "no journey-walker spawn token in the fire output" "journey-walker" "$OUT"
  # host-unreachable fire still renders + exits 0
  bash "$DIGEST_SH" --store "$SANDBOX/dg2.json" --repo "$DGREPO" --trunk main --since $SINCE --until $UNTIL --now $UNTIL --no-host --journeys "$DGREPO/audit/journeys.json" >/dev/null 2>&1
  assert_rc DG06 "host-unreachable digest still exits 0 (degrade)" 0 $?
else
  echo "  [skip] DG01-DG06 digest assertions SKIPPED (no uv/mock host)"
fi

echo
echo "==============================="
echo "outcome_self_test: PASS=$PASS FAIL=$FAIL"
echo "==============================="
[ "$FAIL" -eq 0 ]
