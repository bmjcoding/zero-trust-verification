#!/usr/bin/env bash
# self_test.sh — hermetic [det]/[det-cond] self-test for the Production-Telemetry
# Triage plugin (TR-08; register docs/specs/prod-triage-register.md, ADR 0020).
#
# Every assertion cites a TR-## id and is a MECHANICAL claim only (exact match, flag
# presence, schema validity, exit code, byte-comparison) — NEVER live telemetry, join
# precision on a real incident, or agent judgment, which are the register's [drain]
# residuals and are NOT asserted here. [det-cond] assertions run against TRIAGE-OWNED
# fixtures with an explicit 'not end-to-end suite proof' banner.
#
# Ground rules (mirroring plugins/org-memory/scripts/self_test.sh):
#   - Hermetic: the OTLP-JSON `default` backend IS the test backend; fixtures live in
#     the plugin + a mktemp sandbox; no network, no host API, no credentials.
#   - Non-vacuous (the Marshal-P0 lesson): the CloudWatch/Dynatrace backends are
#     jsonschema-asserted from REAL canned responses (not mock-only); the loop-guard
#     dedupe truly shells to a host adapter; the emitted manifest truly round-trips
#     the VENDORED validator (exit 3) and the VENDORED spec-gen resume projector.
#   - Python needing ruamel/jsonschema runs through `uv run`; stdlib logic (ingest,
#     JSON) runs on bare python3.
#
# Usage: bash plugins/triage/scripts/self_test.sh
# Exit 0 = all assertions pass; non-zero = at least one failure.
# Portability: bash 3.2 (macOS default) + BSD userland safe.

set -u
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$PLUGIN/../.." && pwd)"          # repo root (has pyproject.toml)

TELEMETRY="$HERE/telemetry.sh"
LOOP_GUARD="$HERE/loop_guard.py"
CORRELATE="$HERE/correlate.py"
EMIT="$HERE/emit_incident_spec.py"
PROFILE="$HERE/profile_resume.sh"
HANDOFF="$HERE/resume_handoff.sh"
RESOLVER="$HERE/profile_resolve.py"
WIN_SCHEMA="$PLUGIN/schema/triage/incident-window.schema.json"
CORR_SCHEMA="$PLUGIN/schema/triage/correlation.schema.json"
MOCK_HOST="$PLUGIN/fixtures/host/mock_host.sh"
JOIN_MANIFEST="$ROOT/tests/fixtures/join/manifest.yaml"
CANON_SKILL="$ROOT/plugins/spec-gen/skills/spec/SKILL.md"
TRI_SKILL="$PLUGIN/skills/triage/SKILL.md"
LINT="$ROOT/scripts/lint_consistency.sh"

OTLP="$PLUGIN/fixtures/otlp/incident.json"
OTLP_DRIFT="$PLUGIN/fixtures/otlp/class-drift.json"
CW_FX="$PLUGIN/fixtures/cloudwatch/incident.json"
DT_FX="$PLUGIN/fixtures/dynatrace/incident.json"

# bounded window over 2026-07-06 (fixtures are on that day; one otlp record is 07-05).
SINCE="2026-07-06T00:00:00Z"; UNTIL="2026-07-06T23:59:59Z"
SINCE_E=1783296000; OVER_E=1783468800   # 07-06 00:00 .. 07-08 00:00 (2 days > 24h)

PASS=0; FAIL=0
fail() { printf 'FAIL [%s] %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }
pass() { printf 'ok   [%s] %s\n' "$1" "$2"; PASS=$((PASS+1)); }
assert_eq()           { if [ "$3" = "$4" ]; then pass "$1" "$2"; else fail "$1" "$2 — expected [$3] got [$4]"; fi; }
assert_contains()     { if printf '%s' "$4" | grep -qF -- "$3"; then pass "$1" "$2"; else fail "$1" "$2 — missing [$3]"; fi; }
assert_not_contains() { if printf '%s' "$4" | grep -qF -- "$3"; then fail "$1" "$2 — found forbidden [$3]"; else pass "$1" "$2"; fi; }
assert_rc()           { if [ "$3" -eq "$4" ]; then pass "$1" "$2"; else fail "$1" "$2 — expected rc $3 got $4"; fi; }
assert_rc_nonzero()   { if [ "$3" -ne 0 ]; then pass "$1" "$2"; else fail "$1" "$2 — expected non-zero rc, got 0"; fi; }

if ! command -v python3 >/dev/null 2>&1; then echo "self_test: python3 required (ADR 0015)" >&2; exit 69; fi
if ! command -v uv >/dev/null 2>&1; then echo "self_test: uv required (ADR 0015)" >&2; exit 69; fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

tri_py() { uv run --project "$ROOT" python "$@"; }
# validate an NDJSON stream against a schema; prints "OK=<valid> BAD=<invalid>".
schema_ndjson() {  # <schema> <ndjson-file>
  tri_py -c '
import sys, json
from jsonschema import Draft202012Validator
v = Draft202012Validator(json.load(open(sys.argv[1])))
ok=bad=0
for ln in open(sys.argv[2]):
    ln=ln.strip()
    if not ln: continue
    errs=list(v.iter_errors(json.loads(ln)))
    if errs: bad+=1; print("INVALID:", errs[0].message)
    else: ok+=1
print("OK=%d BAD=%d" % (ok,bad))
' "$1" "$2"
}
# validate a single JSON record (from stdin) against a schema; prints VALID / INVALID.
schema_one() {  # <schema>  (record on stdin)
  tri_py -c '
import sys, json
from jsonschema import Draft202012Validator
v=Draft202012Validator(json.load(open(sys.argv[1])))
rec=json.load(sys.stdin)
print("VALID" if not list(v.iter_errors(rec)) else "INVALID")
' "$1"
}
jget() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

export TRIAGE_TELEMETRY_BACKEND
export TRIAGE_OTEL_FILE

# =============================================================================
# TR-01 — telemetry adapter surface + bounded-window guard
# =============================================================================
echo "== TR-01 telemetry adapter + bounded-window guard =="

# backend detect matrix (mirrors host.sh): env override / committed config / neither.
assert_eq TR-01 "backend detect: env override authoritative" "OTEL_FILE" \
  "$(TRIAGE_TELEMETRY_BACKEND=OTEL_FILE bash "$TELEMETRY" backend)"
assert_eq TR-01 "backend detect: committed config (no env)" "OTEL_FILE" \
  "$(unset TRIAGE_TELEMETRY_BACKEND; bash "$TELEMETRY" backend)"
neither="$(TRIAGE_CONFIG=/dev/null bash "$TELEMETRY" backend 2>&1)"; nrc=$?
assert_rc_nonzero TR-01 "backend detect: neither -> REFUSE (ADR 0002 external fact)" "$nrc"
assert_contains  TR-01 "backend REFUSE names the external-fact escalation" "external fact" "$neither"

# otel_file window over the committed OTLP-JSON fixture -> TR-02 NDJSON.
win="$(TRIAGE_TELEMETRY_BACKEND=OTEL_FILE TRIAGE_OTEL_FILE="$OTLP" bash "$TELEMETRY" window --since "$SINCE" --until "$UNTIL" --service payments)"
assert_contains TR-01 "otel_file window emits pay.captured TR-02 record" "pay.captured" "$win"
# window BOUNDS the output: the 2026-07-05 record is excluded by --since.
n_2026_07_05="$(printf '%s\n' "$win" | grep -c '2026-07-05' || true)"
assert_eq TR-01 "window --since excludes the out-of-window (07-05) record" "0" "$n_2026_07_05"
# empty window -> empty output + exit 0.
emptywin="$(TRIAGE_TELEMETRY_BACKEND=OTEL_FILE TRIAGE_OTEL_FILE="$OTLP" bash "$TELEMETRY" window --since 2026-07-07T00:00:00Z --until 2026-07-07T01:00:00Z --service payments)"; ewrc=$?
assert_rc  TR-01 "empty window exits 0" 0 "$ewrc"
assert_eq  TR-01 "empty window -> empty output" "" "$emptywin"

# the bounded-window guard (the never-whole-fleet teeth).
noargs="$(TRIAGE_TELEMETRY_BACKEND=OTEL_FILE TRIAGE_OTEL_FILE="$OTLP" bash "$TELEMETRY" window --service payments 2>&1)"; narc=$?
assert_rc_nonzero TR-01 "guard: absent --since/--until -> REFUSE" "$narc"
assert_contains   TR-01 "guard: absent-window reason names the cost invariant" "bounded-window guard" "$noargs"
over="$(TRIAGE_TELEMETRY_BACKEND=OTEL_FILE TRIAGE_OTEL_FILE="$OTLP" bash "$TELEMETRY" window --since "$SINCE_E" --until "$OVER_E" --service payments 2>&1)"; orc=$?
assert_rc_nonzero TR-01 "guard: span over max_span -> REFUSE" "$orc"
assert_contains   TR-01 "guard: oversized reason names max_span" "max_span" "$over"
# unbounded-retention backend requires --service/--event scope.
cwnoscope="$(TRIAGE_TELEMETRY_BACKEND=CLOUDWATCH TRIAGE_CLOUDWATCH_FIXTURE="$CW_FX" bash "$TELEMETRY" window --since "$SINCE" --until "$UNTIL" 2>&1)"; cwnrc=$?
assert_rc_nonzero TR-01 "guard: unbounded backend + no scope -> REFUSE" "$cwnrc"
assert_contains   TR-01 "guard: unbounded reason requires a scope" "unbounded retention" "$cwnoscope"

# CloudWatch + Dynatrace canned fixtures -> SCHEMA-VALID TR-02 (jsonschema, no live call).
cwout="$SANDBOX/cw.ndjson"
TRIAGE_TELEMETRY_BACKEND=CLOUDWATCH TRIAGE_CLOUDWATCH_FIXTURE="$CW_FX" bash "$TELEMETRY" window --since "$SINCE" --until "$UNTIL" --service payments > "$cwout"
cwsc="$(schema_ndjson "$WIN_SCHEMA" "$cwout")"
assert_contains TR-01 "CloudWatch canned response -> TR-02 (0 schema-invalid)" "BAD=0" "$cwsc"
assert_not_contains TR-01 "CloudWatch produced >=1 record (non-vacuous)" "OK=0" "$cwsc"
dtout="$SANDBOX/dt.ndjson"
TRIAGE_TELEMETRY_BACKEND=DYNATRACE TRIAGE_DYNATRACE_FIXTURE="$DT_FX" bash "$TELEMETRY" window --since "$SINCE" --until "$UNTIL" --service payments > "$dtout"
dtsc="$(schema_ndjson "$WIN_SCHEMA" "$dtout")"
assert_contains TR-01 "Dynatrace canned response -> TR-02 (0 schema-invalid)" "BAD=0" "$dtsc"
assert_not_contains TR-01 "Dynatrace produced >=1 record (non-vacuous)" "OK=0" "$dtsc"

# =============================================================================
# TR-02 — normalized incident-window schema (Norway-guards)
# =============================================================================
echo "== TR-02 incident-window schema =="

TRIAGE_TELEMETRY_BACKEND=OTEL_FILE TRIAGE_OTEL_FILE="$OTLP" bash "$TELEMETRY" window --since "$SINCE" --until "$UNTIL" --service payments > "$SANDBOX/otlp.ndjson"
otsc="$(schema_ndjson "$WIN_SCHEMA" "$SANDBOX/otlp.ndjson")"
assert_contains TR-02 "OTLP normalized output validates (0 schema-invalid)" "BAD=0" "$otsc"
# a record MISSING event_name validates (DARK-in-prod) — not rejected.
darkrec='{"service":"payments","env":"prod","timestamp":"2026-07-06T12:01:00Z","emitter":"payments-svc","vital_class":"money"}'
assert_eq TR-02 "record missing event_name still validates (DARK, not dropped)" "VALID" "$(printf '%s' "$darkrec" | schema_one "$WIN_SCHEMA")"
# Norway-guard: a boolean in the vital_class enum position is schema-invalid.
badvc='{"service":"payments","env":"prod","timestamp":"2026-07-06T12:00:00Z","emitter":"x","event_name":"pay.captured","vital_class":true}'
assert_eq TR-02 "boolean in vital_class enum -> schema-invalid (Norway-guard)" "INVALID" "$(printf '%s' "$badvc" | schema_one "$WIN_SCHEMA")"
# env-reserved-set guard: env outside {dev,test,prod} is schema-invalid.
badenv='{"service":"payments","env":"production","timestamp":"2026-07-06T12:00:00Z","emitter":"x","event_name":"pay.captured","vital_class":"money"}'
assert_eq TR-02 "env outside the reserved set -> schema-invalid (§4 primitive)" "INVALID" "$(printf '%s' "$badenv" | schema_one "$WIN_SCHEMA")"

# =============================================================================
# TR-loop-guard — self-ingestion exclusion + open-incident dedupe
# =============================================================================
echo "== TR-loop-guard self-ingestion + dedupe =="

# full (unscoped) window includes the triage self-emitter record; exclude-self drops it.
TRIAGE_TELEMETRY_BACKEND=OTEL_FILE TRIAGE_OTEL_FILE="$OTLP" bash "$TELEMETRY" window --since "$SINCE" --until "$UNTIL" > "$SANDBOX/full.ndjson"
assert_contains   TR-loop-guard "unfiltered window contains the self-emitter" "triage-agent" "$(cat "$SANDBOX/full.ndjson")"
tri_py "$LOOP_GUARD" exclude-self --window "$SANDBOX/full.ndjson" --config "$PLUGIN/triage.config.yaml" > "$SANDBOX/filtered.ndjson" 2>/dev/null
assert_not_contains TR-loop-guard "exclude-self drops the self-emitter record" "triage-agent" "$(cat "$SANDBOX/filtered.ndjson")"
assert_contains     TR-loop-guard "exclude-self keeps the real payments record" "pay.captured" "$(cat "$SANDBOX/filtered.ndjson")"

# dedupe key is (event_name, journey, drift-class) and EXCLUDES any timestamp.
k1="$(tri_py "$LOOP_GUARD" incident-key --event pay.captured --journey J-pay-001 --drift-class class-drift)"
assert_eq TR-loop-guard "incident-key is deterministic + slugged" "pay-captured__j-pay-001__class-drift" "$k1"
# behavioral time-independence: two calls (wall clock advanced between them) -> the
# SAME key, so a retried incident collapses to one Spec (no hidden clock/random input).
k1b="$(tri_py "$LOOP_GUARD" incident-key --event pay.captured --journey J-pay-001 --drift-class class-drift)"
assert_eq TR-loop-guard "incident-key is time-independent (two calls -> identical key)" "$k1" "$k1b"
# grep-provable: the incident_key function's signature takes no timestamp, and the
# whole function region names no clock/time field (so retries collapse).
assert_contains     TR-loop-guard "incident_key signature is (event,journey,drift) — no timestamp param" \
  "def incident_key(event_name, journey, drift_class)" "$(cat "$LOOP_GUARD")"
keyfn="$(awk '/def incident_key/{f=1} f{print} /return "__"/{if(f){print; exit}}' "$LOOP_GUARD")"
assert_not_contains TR-loop-guard "incident_key region references NO timestamp/time field" "time" "$keyfn"

# open-incident dedupe: a ledgered incident whose PR is OPEN suppresses a duplicate.
printf '%s\t4242\n' "$k1" > "$SANDBOX/ledger.tsv"
openout="$(MOCK_PR_STATE=OPEN TRIAGE_HOST="$MOCK_HOST" tri_py "$LOOP_GUARD" is-open --key "$k1" --config "$PLUGIN/triage.config.yaml" --host "$MOCK_HOST" --ledger "$SANDBOX/ledger.tsv" 2>"$SANDBOX/isopen.err")"; oirc=$?
assert_eq TR-loop-guard "ledgered + PR OPEN -> is-open reports open" "open" "$openout"
assert_rc TR-loop-guard "is-open exits 0 when open" 0 "$oirc"
assert_contains TR-loop-guard "is-open logs already-open-incident-spec" "already-open-incident-spec" "$(cat "$SANDBOX/isopen.err")"
# THE case the register singles out (lines 155-161): a still-DRAFT incident-Spec.
# pr-list-ready OMITS drafts BY CONTRACT, so the dedupe MUST catch it via pr-state
# on the ledger — this is precisely why the loop-guard consults pr-state, not just
# enumeration. DRAFT is non-terminal -> suppressed.
draftout="$(MOCK_PR_STATE=DRAFT TRIAGE_HOST="$MOCK_HOST" tri_py "$LOOP_GUARD" is-open --key "$k1" --config "$PLUGIN/triage.config.yaml" --host "$MOCK_HOST" --ledger "$SANDBOX/ledger.tsv" 2>/dev/null)"; drc=$?
assert_eq TR-loop-guard "ledgered + PR still DRAFT -> suppressed (pr-state catches what pr-list-ready omits)" "open" "$draftout"
assert_rc TR-loop-guard "is-open exits 0 on a still-draft incident-Spec" 0 "$drc"
# a ledgered incident whose PR is MERGED (terminal) is CLEAR (no false suppression).
clearout="$(MOCK_PR_STATE=MERGED TRIAGE_HOST="$MOCK_HOST" tri_py "$LOOP_GUARD" is-open --key "$k1" --config "$PLUGIN/triage.config.yaml" --host "$MOCK_HOST" --ledger "$SANDBOX/ledger.tsv" 2>/dev/null)"; crc=$?
assert_eq TR-loop-guard "ledgered + PR MERGED (terminal) -> clear" "clear" "$clearout"
assert_rc TR-loop-guard "is-open exits non-zero (1) when clear" 1 "$crc"
# a CLOSED/DECLINED terminal PR (a withdrawn proposal) also frees the incident.
closedout="$(MOCK_PR_STATE=CLOSED TRIAGE_HOST="$MOCK_HOST" tri_py "$LOOP_GUARD" is-open --key "$k1" --config "$PLUGIN/triage.config.yaml" --host "$MOCK_HOST" --ledger "$SANDBOX/ledger.tsv" 2>/dev/null)"; ccrc=$?
assert_eq TR-loop-guard "ledgered + PR CLOSED (terminal) -> clear" "clear" "$closedout"

# =============================================================================
# TR-03 — incident<->manifest correlation (§12 key, journey DERIVED)
# =============================================================================
echo "== TR-03 correlation =="

tri_py "$CORRELATE" --window "$SANDBOX/filtered.ndjson" --manifest "$JOIN_MANIFEST" --out "$SANDBOX/corr.json"
corr="$(cat "$SANDBOX/corr.json")"
# schema-versioned + schema-valid.
assert_eq TR-03 "correlation.json is schema_version 1" "1" "$(printf '%s' "$corr" | jget 'd["schema_version"]')"
assert_eq TR-03 "correlation.json validates against its schema" "VALID" "$(schema_one "$CORR_SCHEMA" < "$SANDBOX/corr.json")"
# pay.captured -> J-pay-001, step 0, B-pay-001 — DERIVED without the v2 backref.
assert_eq TR-03 "pay.captured derives journey J-pay-001" "J-pay-001" "$(printf '%s' "$corr" | jget 'd["correlated"][0]["journey_id"]')"
assert_eq TR-03 "pay.captured derives step index 0" "0" "$(printf '%s' "$corr" | jget 'd["correlated"][0]["step_index"]')"
assert_eq TR-03 "pay.captured maps affected behavior B-pay-001" "B-pay-001" "$(printf '%s' "$corr" | jget 'd["correlated"][0]["behavior_ids"][0]')"
# unmapped-in-prod + DARK-in-prod bucketed (surfaced, never dropped).
assert_contains TR-03 "pay.refunded -> unmapped-in-prod bucket" "unmapped-in-prod" "$corr"
assert_contains TR-03 "no-event_name record -> dark-in-prod bucket" "dark-in-prod" "$corr"
# idempotent: a second run is byte-identical.
tri_py "$CORRELATE" --window "$SANDBOX/filtered.ndjson" --manifest "$JOIN_MANIFEST" --out "$SANDBOX/corr2.json"
assert_eq TR-03 "correlation.json is idempotent (detection never mutates)" "" "$(diff "$SANDBOX/corr.json" "$SANDBOX/corr2.json")"
# vital_class disagreement -> class-drift signal.
TRIAGE_TELEMETRY_BACKEND=OTEL_FILE TRIAGE_OTEL_FILE="$OTLP_DRIFT" bash "$TELEMETRY" window --since "$SINCE" --until "$UNTIL" --service payments > "$SANDBOX/drift.ndjson"
tri_py "$CORRELATE" --window "$SANDBOX/drift.ndjson" --manifest "$JOIN_MANIFEST" --out "$SANDBOX/corr_drift.json"
cd_json="$(cat "$SANDBOX/corr_drift.json")"
assert_eq TR-03 "runtime vital_class != manifest -> class-drift finding" "1" "$([ "$(printf '%s' "$cd_json" | jget 'len(d["class_drift"])')" -ge 1 ] && echo 1 || echo 0)"
assert_contains TR-03 "class-drift names the runtime class" "state-transition" "$cd_json"
# manifest-absent -> degrade: no join possible, all records DARK-context + loud note.
tri_py "$CORRELATE" --window "$SANDBOX/filtered.ndjson" --manifest "$SANDBOX/nope.yaml" --out "$SANDBOX/corr_absent.json"
ab="$(cat "$SANDBOX/corr_absent.json")"
assert_eq       TR-03 "manifest-absent -> manifest_status absent" "absent" "$(printf '%s' "$ab" | jget 'd["manifest_status"]')"
assert_contains TR-03 "manifest-absent degrades with a loud note" "manifest absent" "$ab"
assert_contains TR-03 "manifest-absent buckets records manifest-absent" "manifest-absent" "$ab"
# schema-invalid manifest -> REFUSE (never degrade to manifest-less on a broken manifest).
printf 'schema_version: 1\nmanifest_revision: not-an-int\nspec:\n  title: 5\n' > "$SANDBOX/broken.yaml"
brk="$(tri_py "$CORRELATE" --window "$SANDBOX/filtered.ndjson" --manifest "$SANDBOX/broken.yaml" 2>&1)"; brc=$?
assert_rc_nonzero TR-03 "schema-invalid manifest -> REFUSE (exit non-zero)" "$brc"
assert_contains   TR-03 "schema-invalid REFUSE names the exit-4 refusal" "schema-invalid" "$brk"
# [det-cond] audit-backref cross-check SKIPPED (CH-02 unbuilt) — NOT end-to-end suite proof.
echo "  [det-cond banner] the audit-backref cross-check below is asserted against the TRIAGE-OWNED"
echo "  fixture $PLUGIN/fixtures/journeys/journeys-v2.json — this is NOT end-to-end suite proof;"
echo "  codebase-health CH-02 is UNBUILT, so the cross-check is a deterministic SKIP, never assumed."
assert_eq       TR-03 "[det-cond] backref cross-check status is skipped-by-design" "skipped" "$(printf '%s' "$corr" | jget 'd["backref_cross_check"]["status"]')"
assert_contains TR-03 "[det-cond] skip note names CH-02 unbuilt" "backref-unavailable (CH-02 unbuilt)" "$corr"

# =============================================================================
# TR-04 — config-profile resume (reuse; floor-not-ceiling severity)
# =============================================================================
echo "== TR-04 profile resume =="

pr="$(bash "$PROFILE" resolve --manifest "$JOIN_MANIFEST")"
assert_eq TR-04 "payments manifest resolves via the VENDORED resolver" "payments" "$(printf '%s' "$pr" | jget 'd["profile"]')"
assert_eq TR-04 "resume resolution does not re-escalate" "False" "$(printf '%s' "$pr" | jget 'str(d["escalate"])')"
assert_eq TR-04 "resume source is the manifest (reuse, zero new resolver code)" "manifest" "$(printf '%s' "$pr" | jget 'd["source"]')"
# unresolvable profile falls to default + a loud escalation note (never a silent assume, ADR 0002)
# — the VENDORED resolver's fresh-mode fixture behavior, reused verbatim.
fr="$(tri_py "$RESOLVER" --mode fresh --config "$SANDBOX/no-such-config.yaml")"
assert_eq       TR-04 "no configured profile degrades to default" "default" "$(printf '%s' "$fr" | jget 'd["profile"]')"
assert_eq       TR-04 "no configured profile ESCALATES (never silently assumed)" "True" "$(printf '%s' "$fr" | jget 'str(d["escalate"])')"
# profile is a severity FLOOR, never a ceiling past the ladder cap (CH-08 floor-not-ceiling).
assert_eq TR-04 "profile floor cannot raise severity past the ladder cap" "error" \
  "$(bash "$PROFILE" severity --base info --floor critical --cap error)"
assert_eq TR-04 "profile floor DOES raise a low base up to the cap" "warn" \
  "$(bash "$PROFILE" severity --base info --floor warn --cap critical)"

# =============================================================================
# TR-05 — incident-Spec emitter (incomplete BY CONSTRUCTION; mints no ID)
# =============================================================================
echo "== TR-05 incident-Spec emitter =="

INC="$SANDBOX/incidents"
emit_out="$(TRIAGE_HOST="$MOCK_HOST" tri_py "$EMIT" --correlation "$SANDBOX/corr.json" --manifest "$JOIN_MANIFEST" --out-dir "$INC" --ledger "$SANDBOX/empty-ledger.tsv")"; erc=$?
assert_rc TR-05 "emitter exits 0 on a confident join" 0 "$erc"
MAN="$(ls "$INC"/*.manifest.yaml 2>/dev/null | head -1)"
MD="$(ls "$INC"/*.md 2>/dev/null | head -1)"
assert_eq TR-05 "emitter wrote an incident manifest" "1" "$([ -f "$MAN" ] && echo 1 || echo 0)"
# validate through the VENDORED validate_manifest.sh -> exit 3 (incomplete, resumable).
uv run --project "$ROOT" bash "$HERE/validate_manifest.sh" "$MAN" >/dev/null 2>&1; vrc=$?
assert_rc TR-05 "emitted manifest is schema-valid + completeness:incomplete (validator exit 3)" 3 "$vrc"
manbody="$(cat "$MAN")"
assert_contains TR-05 "incident manifest references EXISTING journey J-pay-001" "J-pay-001" "$manbody"
assert_contains TR-05 "incident manifest references EXISTING behavior B-pay-001" "B-pay-001" "$manbody"
assert_contains TR-05 "incident manifest declares completeness: incomplete" "completeness: incomplete" "$manbody"
assert_contains TR-05 "incomplete_fields use the rule-<n>: <path> grammar" "rule-2: journeys[J-pay-001]" "$manbody"
# mints NO new ID: no id outside the two existing ones (J-pay-001 / B-pay-001).
mintcheck="$(grep -oE '\b[JB]-[a-z0-9-]+-[0-9]{3}\b' "$MAN" | sort -u | grep -vE '^(J-pay-001|B-pay-001)$' || true)"
assert_eq TR-05 "emitter mints NO new behavior/journey ID (§6)" "" "$mintcheck"
# prose names the joined journey + behavior IDs + drift class.
mdbody="$(cat "$MD")"
assert_contains TR-05 "prose names the joined journey" "J-pay-001" "$mdbody"
assert_contains TR-05 "prose names the affected behavior" "B-pay-001" "$mdbody"
assert_contains TR-05 "prose names the drift class" "Drift class" "$mdbody"
# emitter REFUSES from a no-join correlation (degrade rule 4).
printf '{"schema_version":1,"manifest_status":"absent","correlated":[],"no_join":[{"event_name":null,"reason":"manifest-absent"}],"class_drift":[],"core_steps_absent_in_window":[],"backref_cross_check":{"status":"skipped","note":"x"},"notes":[]}\n' > "$SANDBOX/nojoin.json"
nj="$(TRIAGE_HOST="$MOCK_HOST" tri_py "$EMIT" --correlation "$SANDBOX/nojoin.json" --manifest "$JOIN_MANIFEST" --out-dir "$SANDBOX/inc_nj" --ledger "$SANDBOX/empty-ledger.tsv" 2>&1)"; njrc=$?
assert_rc_nonzero TR-05 "emitter REFUSES a no-join correlation" "$njrc"
assert_contains   TR-05 "no-join refusal surfaces the gap" "no confident join" "$nj"
# emitter honors the open-incident dedupe (suppress a duplicate; write nothing).
KEY5="$(tri_py "$LOOP_GUARD" incident-key --event pay.captured --journey J-pay-001 --drift-class vital-incident)"
printf '%s\t7777\n' "$KEY5" > "$SANDBOX/dedupe-ledger.tsv"
dd="$(MOCK_PR_STATE=OPEN TRIAGE_HOST="$MOCK_HOST" tri_py "$EMIT" --correlation "$SANDBOX/corr.json" --manifest "$JOIN_MANIFEST" --out-dir "$SANDBOX/inc_dedupe" --host "$MOCK_HOST" --ledger "$SANDBOX/dedupe-ledger.tsv" 2>&1)"; ddrc=$?
assert_rc       TR-05 "dedupe suppression is a safe success (exit 0)" 0 "$ddrc"
assert_contains TR-05 "dedupe logs already-open-incident-spec" "already-open-incident-spec" "$dd"
assert_eq       TR-05 "dedupe writes NO second incident-Spec" "0" "$([ -d "$SANDBOX/inc_dedupe" ] && ls "$SANDBOX/inc_dedupe" | grep -c manifest || echo 0)"

# =============================================================================
# TR-06 — the triage SKILL (escalation block byte-identical; invariants named)
# =============================================================================
echo "== TR-06 triage SKILL =="

canon_blk="$(awk '/vendored:escalation-criterion:begin/{f=1;next} /vendored:escalation-criterion:end/{f=0} f' "$CANON_SKILL")"
tri_blk="$(awk '/vendored:escalation-criterion:begin/{f=1;next} /vendored:escalation-criterion:end/{f=0} f' "$TRI_SKILL")"
assert_eq TR-06 "escalation block byte-identical to the canonical (V5 extends here)" "$canon_blk" "$tri_blk"
for inv in "read-only on prod" "Spec, not a patch" "bounded-window only" "no self-ingestion"; do
  assert_contains TR-06 "SKILL names invariant: $inv" "$inv" "$(cat "$TRI_SKILL")"
done
assert_contains TR-06 "SKILL is agent-first (no dashboard in path)" "no dashboard in your path" "$(cat "$TRI_SKILL")"

# =============================================================================
# TR-07 — spec-gen resume handoff (resumable-incomplete + DRAFT PR via host)
# =============================================================================
echo "== TR-07 spec-gen resume handoff =="

# the emitted manifest is accepted as resumable input by the VENDORED resume projector.
proj="$(uv run --project "$ROOT" python "$HERE/resume_projection.py" "$MAN")"
assert_eq TR-07 "vendored resume projector accepts the manifest (validator_exit 3)" "3" "$(printf '%s' "$proj" | jget 'd["validator_exit"]')"
assert_eq TR-07 "resume projector yields escalate-class question slots" "1" "$([ "$(printf '%s' "$proj" | jget 'len(d["escalate"])')" -ge 1 ] && echo 1 || echo 0)"
# the handoff opens a DRAFT PR through the host adapter + records the ledger.
OPENLOG="$SANDBOX/pr_open.log"
HANDLEDGER="$SANDBOX/handoff-ledger.tsv"
hout="$(MOCK_PR_OPEN_LOG="$OPENLOG" MOCK_PR_NUM=9001 bash "$HANDOFF" --manifest "$MAN" --prose "$MD" --incident-id "incident-x" --key "$k1" --branch "triage/incident-x" --host "$MOCK_HOST" --ledger "$HANDLEDGER" 2>&1)"; hrc=$?
assert_rc       TR-07 "handoff succeeds (exit 0)" 0 "$hrc"
assert_contains TR-07 "handoff confirms resumable-incomplete via the projector" "validator_exit=3" "$hout"
assert_contains TR-07 "handoff opened a DRAFT PR proposal" "DRAFT incident-Spec PR" "$hout"
assert_contains TR-07 "host pr-open was invoked WITH --draft (report-only, never auto-merge)" "--draft" "$(cat "$OPENLOG")"
assert_contains TR-07 "handoff recorded the incident-key -> PR in the ledger" "9001" "$(cat "$HANDLEDGER")"
# loop-safety regression (skeptic finding): the DOCUMENTED handoff passes NO --ledger,
# so the write path MUST default from triage.config.yaml loop_guard.ledger (symmetry
# with loop_guard.py's read path). Otherwise a re-fire reads an empty ledger and emits
# a DUPLICATE incident-Spec. Prove a no---ledger handoff still records the incident.
CFGLEDGER="$SANDBOX/cfg-default-ledger.tsv"
CFG2="$SANDBOX/cfg2.yaml"
printf 'loop_guard:\n  self_emitters:\n    - triage-agent\n  ledger: %s\n' "$CFGLEDGER" > "$CFG2"
TRIAGE_CONFIG="$CFG2" MOCK_PR_OPEN_LOG="$SANDBOX/pr_open2.log" MOCK_PR_NUM=9002 \
  bash "$HANDOFF" --manifest "$MAN" --prose "$MD" --incident-id "incident-y" --key "$k1" --branch "triage/incident-y" --host "$MOCK_HOST" >/dev/null 2>&1
assert_eq       TR-07 "handoff WITHOUT --ledger records to the config-default ledger (dedupe not defeated)" "1" "$([ -f "$CFGLEDGER" ] && echo 1 || echo 0)"
assert_contains TR-07 "config-default ledger holds the incident-key -> PR row" "9002" "$(cat "$CFGLEDGER" 2>/dev/null)"
# and the handoff REFUSES to open a PR without --key (loop-guard cannot dedupe without it).
nokey="$(bash "$HANDOFF" --manifest "$MAN" --incident-id "incident-z" --branch "triage/incident-z" --host "$MOCK_HOST" 2>&1)"; nkrc=$?
assert_rc_nonzero TR-07 "handoff REFUSES to open a PR without --key (dedupe safety)" "$nkrc"
assert_contains   TR-07 "no-key refusal names the ledger dedupe reason" "cannot dedupe" "$nokey"

# =============================================================================
# TR-08 — lint teeth: the NEW V9 rule catches a planted telemetry-contract drift.
# (V5 escalation / V6 marketplace / V1 schema teeth live in scripts/suite_self_test.sh.)
# =============================================================================
echo "== TR-08 lint V9 teeth (telemetry-contract byte-identity) =="

if [ -f "$LINT" ] && grep -q 'V9' "$LINT"; then
  DR="$SANDBOX/v9drift"
  mkdir -p "$DR/plugins/triage/reference"
  cp "$PLUGIN/reference/telemetry-contract.md" "$DR/plugins/triage/reference/"
  # drift the vendored backend-contract copy's block -> V9 must fire.
  sed 's/Never a whole-fleet scan./Never a whole-fleet scan. DRIFTED./' "$PLUGIN/reference/backends.md" > "$DR/plugins/triage/reference/backends.md"
  v9out="$(LINT_ROOT="$DR" bash "$LINT" 2>&1)"; v9rc=$?
  assert_rc_nonzero TR-08 "planted telemetry-contract drift -> lint fails" "$v9rc"
  assert_contains   TR-08 "the failure is on rule V9" "LINT-FAIL [V9]" "$v9out"
  # false-positive guard: byte-identical copies stay green under V9.
  DR2="$SANDBOX/v9ok"; mkdir -p "$DR2/plugins/triage/reference"
  cp "$PLUGIN/reference/telemetry-contract.md" "$PLUGIN/reference/backends.md" "$DR2/plugins/triage/reference/"
  v9ok="$(LINT_ROOT="$DR2" bash "$LINT" 2>&1)"
  assert_not_contains TR-08 "V9 does not false-fire on byte-identical copies" "LINT-FAIL [V9]" "$v9ok"
else
  echo "  [note] scripts/lint_consistency.sh has no V9 yet — the V9 teeth run once the root lint edit lands (suite_self_test also asserts it)."
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "==============================="
echo "triage self-test: PASS=$PASS FAIL=$FAIL"
echo "==============================="
[ "$FAIL" -eq 0 ]
