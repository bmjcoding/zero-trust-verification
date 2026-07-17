#!/usr/bin/env bash
# sd_self_test.sh — the System-Design Coverage tier's hermetic [det] proof
# (register docs/specs/system-design-coverage-register.md, SD-01..SD-12; governed
# by ADR 0021 manifest-control-locus + ADR 0022 out-of-scope-by-declaration).
#
# The tier is DECLARE-THEN-VERIFY (SD-00, the honesty spine): the manifest DECLARES
# a control `locus`; the audit VERIFIES ONLY `locus: app`; every other locus is
# reported out-of-scope-by-declaration (informational, NEVER a finding/violation/
# blocking/counted); a raw "missing X" finding on a non-app/absent locus is the
# central prohibition this suite exists to prevent.
#
# This self-test asserts ONLY the [det] half (register's honest tag split): schema
# additive-safety, the out-of-scope short-circuit + the unfalsifiability guard, the
# §12 join truth tables for the new rows, and the candidate seeds + must_not_flag
# negatives. Every agent-DERIVED value (limiter/breaker/lock presence, shed-priority,
# breadth, deadlock) is [audit-run] and NOT asserted here — it is comment-only,
# blind-eval scored, never presented as automated coverage.
#
# Mirrors scripts/outcome_self_test.sh (the immediately-prior sibling): a dedicated
# root self-test the suite orchestrator runs as a component. Skip-honest: the join /
# validator sections [skip] loudly without the vendored validator toolchain (the
# same degrade the codebase-health self-test uses), so this stays green outside the
# monorepo — never a silent pass.
#
# Portability: bash 3.2 (macOS default) + BSD userland. No `\b` in sed; empty arrays
# guarded; no GNU-only flags.
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
PLUGIN="$REPO_ROOT/plugins/zero-trust"
SKILL_SCRIPTS="$PLUGIN/skills/cleanup-audit/scripts"
JOIN_FIX="$REPO_ROOT/tests/fixtures/join"           # the ONE extended manifest+journeys.json v2 pair (SD-04)
MANIFEST_FIX="$REPO_ROOT/tests/fixtures/manifest"   # shared validator fixtures (no second schema copy)

VALIDATE_MANIFEST="${VALIDATE_MANIFEST:-$PLUGIN/scripts/validate_manifest.sh}"
export VALIDATE_MANIFEST
have_validator() { [ -x "$VALIDATE_MANIFEST" ]; }

JOINSH="$SKILL_SCRIPTS/manifest_join.sh"
JOINPY="$SKILL_SCRIPTS/manifest_join.py"
SD_SEEDS="$SKILL_SCRIPTS/sd_seeds.sh"

# uv-first Python (ADR 0015). Falls back to python3 (validate_manifest.sh precedent).
if command -v uv >/dev/null 2>&1 && [ -f "$PLUGIN/pyproject.toml" ]; then
  PYRUN=(uv run --quiet --project "$PLUGIN" python)
else
  PYRUN=(python3)
fi

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok  - $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
assert_grep()     { if grep -qiE "$2" "$1" 2>/dev/null; then ok "$3"; else fail "$3"; fi; }
assert_not_grep() { if grep -qiE "$2" "$1" 2>/dev/null; then fail "$3"; else ok "$3"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

echo "== sd_self_test: System-Design Coverage tier (SD-01..SD-12), [det] half only =="

# ── join helpers (mirror the CH-03 §12 harness) ──────────────────────────────
MREF="$JOIN_FIX/manifest.yaml"; JREF="$JOIN_FIX/journeys.json"
# JOIN <manifest> <journeys> [extra] -> $WORK/join.out
JOIN() { if [ -n "${3:-}" ]; then bash "$JOINSH" "$1" "$2" "$3" > "$WORK/join.out" 2>&1; else bash "$JOINSH" "$1" "$2" > "$WORK/join.out" 2>&1; fi; }
# row_is <kind> <verdict> <msg> — assert a `ROW <kind> <verdict>` line
row_is()  { if grep -qE "^ROW $1 $2( |\$)" "$WORK/join.out"; then ok "$3"; else fail "$3 [got: $(grep -E "^ROW $1 " "$WORK/join.out" | head -1)]"; fi; }
# mut <python-on-discovered> <out> — mutate the reference journeys.json (j=journey, s=step0)
mut() { "${PYRUN[@]}" -c "import json; d=json.load(open('$JREF')); j=d['journeys'][0]; s=j['steps'][0]; $1; json.dump(d,open('$2','w'))"; }
# mmut <python-on-declared> <out> — mutate the reference manifest.yaml (round-trip YAML; j=journey0, s=step0)
mmut() { "${PYRUN[@]}" -c "from ruamel.yaml import YAML; y=YAML(); d=y.load(open('$MREF')); j=d['journeys'][0]; s=j['steps'][0]; $1; y.dump(d,open('$2','w'))"; }

# =============================================================================
# SD-02 — schema additive-safety (validator fixtures). additive-optional under
# schema_version 1; a field-absent manifest stays complete (ADR 0008 straight-
# through); none-declared is first-class legal; a bad locus is schema-invalid
# (Norway defense). No validator-code edit — proved purely by fixtures.
# =============================================================================
echo "== SD-02. schema additive-safety (validator fixtures; no validator-code edit) =="
if have_validator; then
  vexit() { bash "$VALIDATE_MANIFEST" "$1" >/dev/null 2>&1; echo $?; }
  # field-absent-complete -> exit 0 (straight-through preserved, ADR 0008)
  c=$(vexit "$MANIFEST_FIX/valid-complete.yaml")
  [ "$c" = 0 ] && ok "SD-02: SD-field-absent complete manifest -> validator exit 0 (straight-through, ADR 0008)" \
               || fail "SD-02: field-absent-complete must exit 0 [got $c]"
  # none-declared -> exit 0 (first-class legal enum, MS §8)
  c=$(vexit "$MANIFEST_FIX/sd-none-declared.yaml")
  [ "$c" = 0 ] && ok "SD-02: none-declared locus family -> validator exit 0 (first-class legal)" \
               || fail "SD-02: none-declared must exit 0 [got $c]"
  # app-locus complete -> exit 0 (the join reference manifest validates)
  c=$(vexit "$MREF")
  [ "$c" = 0 ] && ok "SD-02: app-locus SD-field manifest (the join fixture) -> validator exit 0" \
               || fail "SD-02: app-locus SD-field manifest must exit 0 [got $c]"
  # bool/Norway-in-locus-enum -> exit 4 (schema-invalid; the Norway defense, MS §2)
  c=$(vexit "$MANIFEST_FIX/sd-locus-norway.yaml")
  [ "$c" = 4 ] && ok "SD-02: bool/Norway value in a locus enum -> validator exit 4 (schema-invalid, Norway defense)" \
               || fail "SD-02: Norway-in-locus must exit 4 (schema-invalid) [got $c]"
else
  echo "  [skip] validate_manifest.sh absent — SD-02 validator fixtures skipped (blocked-on the spec-gen validator drain)"
fi

# =============================================================================
# SD-01 — the locus field family lives in the ONE canonical schema (ADR 0025
# collapsed the three vendored copies into it; SD-01 vendored-contract
# acceptance, post-consolidation shape: single copy, nothing to re-sync).
# =============================================================================
echo "== SD-01. locus-field schema — single canonical copy (ADR 0025) =="
CANON_SCHEMA="$PLUGIN/schema/verification-manifest/v1.schema.json"
[ -f "$CANON_SCHEMA" ] && ok "SD-01: canonical manifest schema present (plugins/zero-trust/schema/verification-manifest)" \
                       || fail "SD-01: canonical manifest schema missing (plugins/zero-trust/schema/verification-manifest)"
sd01_copies=$(find "$REPO_ROOT" -path "$REPO_ROOT/.git" -prune -o -path "$REPO_ROOT/.claude" -prune -o -path '*/verification-manifest/v1.schema.json' -print 2>/dev/null | wc -l | tr -d ' ')
[ "$sd01_copies" = "1" ] && ok "SD-01: exactly ONE verification-manifest schema in the tree (no vendored copy to drift)" \
                         || fail "SD-01: expected exactly 1 verification-manifest schema, found $sd01_copies (a second copy reintroduces the drift class ADR 0025 retired)"
# the canonical validator sits BESIDE the schema (its _HERE.parent/schema/... resolution)
[ -f "$PLUGIN/scripts/validate_manifest.py" ] && ok "SD-01: canonical validator co-located with the schema (plugins/zero-trust/scripts + schema)" \
                                              || fail "SD-01: canonical validate_manifest.py missing beside the schema (its ../schema resolution would break)"
# the new locus family is actually present in the canonical schema
assert_grep "$CANON_SCHEMA" '"controlLocus"'        "SD-01: canonical schema defines the controlLocus enum (ADR 0021 vocabulary)"
assert_grep "$CANON_SCHEMA" '"none-declared"'       "SD-01: controlLocus enum carries none-declared (first-class honest answer)"
assert_grep "$CANON_SCHEMA" '"abuse_controls"'      "SD-01: journey gains additive abuse_controls (SD §3.1)"
assert_grep "$CANON_SCHEMA" '"resilience_posture"'  "SD-01: step gains additive resilience_posture (SD §3.2)"
assert_grep "$CANON_SCHEMA" '"isolation_requirement"' "SD-01: step gains additive isolation_requirement (SD §3.3)"
assert_grep "$CANON_SCHEMA" '"timeout_budget_ms"'   "SD-01: step gains additive timeout_budget_ms (SD §3.7)"

# =============================================================================
# SD-03/04/05/06/07/10 — the comparator rows (extend CH-03 manifest_join.py) with
# the out-of-scope short-circuit + the unfalsifiability guard. Verify ONLY app.
# =============================================================================
echo "== SD-03..10. declare-then-verify comparator rows (extend CH-03; verify only locus:app) =="
if have_validator; then
  # ── reference pair (app-locus everywhere): every SD row PASSes / NOTEs ──────
  JOIN "$MREF" "$JREF"
  # the pre-existing CH-03 rows still PASS (additive-safety over the join engine)
  row_is emission    PASS "SD-04 additive: pre-existing CH-03 emission row still PASSes on the extended fixture"
  row_is idempotency PASS "SD-04 additive: pre-existing CH-03 idempotency row still PASSes on the extended fixture"
  # the four new SD rows (app-locus reference -> satisfied / NOTE)
  row_is abuse-controls-drift    PASS "SD-05: app-locus + discovered limiter present -> PASS (comment-only)"
  row_is resilience-posture-drift PASS "SD-06: app-locus breaker + discovered breaker -> PASS (comment-only)"
  row_is isolation-drift         NOTE "SD-07: app-locus + discovered explicit-lock candidate -> NOTE candidate (comment-only)"
  row_is timeout-budget-drift    PASS "SD-10: discovered timeout <= declared budget -> PASS (deterministic-in-join)"
  # every SD row is comment-only — NONE reaches a blocking severity (ADR 0022)
  assert_not_grep "$WORK/join.out" '^ROW (abuse-controls|resilience-posture|isolation|timeout-budget)-drift .*sev=HIGH' \
     "SD-00: no SD row ever emits sev=HIGH (agent-derived discovered side caps comment-only, MT-06)"
  assert_grep "$WORK/join.out" '^ROW abuse-controls-drift PASS comment-only' "SD-05: the app-locus abuse-controls row is explicitly comment-only"
  # CH-03 fingerprint reuse: SD step rows carry path:symbol:slug + a recomputed fp
  assert_grep "$WORK/join.out" 'ROW timeout-budget-drift .*fpsrc=app/payments\.py:capture:timeout-budget-drift' "SD-04: SD step row reuses the CH-AMEND-A path:symbol fingerprint scheme"
  EXP_FP="$(printf '%s' 'app/payments.py:capture:timeout-budget-drift' | { command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum -a 1; } | cut -c1-12)"
  assert_grep "$WORK/join.out" "fp=$EXP_FP" "SD-04: timeout-budget-drift fp == first-12-hex sha1(path:symbol:slug), independently recomputed"

  # ── SD-05 abuse-controls lattice ───────────────────────────────────────────
  mut "j['abuse_control']='absent'" "$WORK/j.json"; JOIN "$MREF" "$WORK/j.json"
  row_is abuse-controls-drift FAIL "SD-05: app-locus + NO discovered limiter -> FAIL (comment-only, candidate)"
  assert_grep "$WORK/join.out" '^ROW abuse-controls-drift FAIL comment-only' "SD-05: the abuse-controls FAIL is comment-only (never blocking)"
  # THE UNFALSIFIABILITY GUARD (SD-03): non-app locus -> out-of-scope, ZERO findings,
  # and NEVER a raw 'missing rate limit' finding. This is the tier's central prohibition.
  mmut "j['abuse_controls']['locus']='gateway'" "$WORK/m_gw.yaml"; JOIN "$WORK/m_gw.yaml" "$WORK/j.json"
  assert_grep     "$WORK/join.out" '\[out-of-scope-by-declaration\] abuse-controls .locus=gateway.' "SD-03: gateway-locus abuse_controls -> exactly one out-of-scope-by-declaration line"
  assert_not_grep "$WORK/join.out" '^ROW abuse-controls-drift (FAIL|PASS)' "SD-03: gateway-locus emits NO abuse-controls finding row (out-of-scope short-circuit)"
  assert_not_grep "$WORK/join.out" 'missing rate' "SD-03 UNFALSIFIABILITY: a gateway-locus control NEVER mints a raw 'missing rate limit' finding (the central prohibition)"
  # none-declared and absent-field are equally silent (no finding)
  mmut "j['abuse_controls']['locus']='none-declared'" "$WORK/m_nd.yaml"; JOIN "$WORK/m_nd.yaml" "$WORK/j.json"
  assert_grep     "$WORK/join.out" '\[out-of-scope-by-declaration\] abuse-controls .locus=none-declared.' "SD-03: none-declared abuse_controls -> out-of-scope line (honest, not an omission)"
  assert_not_grep "$WORK/join.out" '^ROW abuse-controls-drift FAIL' "SD-03: none-declared emits NO abuse-controls finding"
  mmut "del j['abuse_controls']" "$WORK/m_noabuse.yaml"; JOIN "$WORK/m_noabuse.yaml" "$WORK/j.json"
  assert_not_grep "$WORK/join.out" '^ROW abuse-controls-drift' "SD-03: abuse_controls entirely absent -> NO abuse-controls row at all (additive-safe; nothing declared)"

  # ── SD-06 resilience-posture lattice ───────────────────────────────────────
  mut "s['resilience_mechanism']='none'" "$WORK/j.json"; JOIN "$MREF" "$WORK/j.json"
  row_is resilience-posture-drift FAIL "SD-06: app-locus breaker + no discovered breaker -> FAIL (comment-only)"
  assert_grep "$WORK/join.out" '^ROW resilience-posture-drift FAIL comment-only' "SD-06: the resilience FAIL is comment-only"
  # shed-priority is DERIVED from criticality (agent) -> a comment-only NOTE always
  assert_grep "$WORK/join.out" 'shed-priority' "SD-06: shed-priority is emitted as an agent-derived comment-only note (never [det])"
  # sidecar locus -> out-of-scope, no finding
  mmut "s['resilience_posture']['locus']='sidecar'" "$WORK/m_sc.yaml"; JOIN "$WORK/m_sc.yaml" "$WORK/j.json"
  assert_grep     "$WORK/join.out" '\[out-of-scope-by-declaration\] resilience-posture .locus=sidecar.' "SD-06: sidecar-locus resilience_posture -> out-of-scope line"
  assert_not_grep "$WORK/join.out" '^ROW resilience-posture-drift (FAIL|PASS)' "SD-06: sidecar-locus emits NO resilience finding row"
  assert_not_grep "$WORK/join.out" 'missing circuit breaker|no circuit breaker' "SD-06 UNFALSIFIABILITY: a sidecar-locus breaker NEVER mints a raw 'missing circuit breaker' finding"

  # ── SD-07 isolation lattice ────────────────────────────────────────────────
  # app-locus + discovered explicit-lock candidate -> NOTE candidate (comment-only, verdict needs runtime)
  JOIN "$MREF" "$JREF"; row_is isolation-drift NOTE "SD-07: app-locus isolation + discovered explicit-lock -> NOTE candidate (not a verdict)"
  # db-config locus -> out-of-scope + the 'unknown — isolation configured outside repo' degrade
  mmut "s['isolation_requirement']['locus']='db-config'" "$WORK/m_db.yaml"; JOIN "$WORK/m_db.yaml" "$JREF"
  assert_grep     "$WORK/join.out" '\[out-of-scope-by-declaration\] isolation .locus=db-config.' "SD-07: db-config isolation -> out-of-scope line"
  assert_grep     "$WORK/join.out" 'unknown — isolation configured outside repo' "SD-07: db-config isolation carries the honest 'unknown — isolation configured outside repo' degrade"
  assert_not_grep "$WORK/join.out" '^ROW isolation-drift (FAIL|PASS)' "SD-07: db-config isolation emits NO isolation finding/verdict row"

  # ── SD-10 timeout-budget lattice (the one deterministic-in-join SD row) ─────
  mut "s['timeout_ms']=9000" "$WORK/j.json"; JOIN "$MREF" "$WORK/j.json"
  row_is timeout-budget-drift FAIL "SD-10: discovered timeout 9000ms > declared budget 3000ms -> FAIL (deterministic-in-join)"
  assert_grep     "$WORK/join.out" '^ROW timeout-budget-drift FAIL comment-only' "SD-10: even the deterministic-in-join timeout finding ships comment-only through the soak (ADR 0022)"
  assert_not_grep "$WORK/join.out" '^ROW timeout-budget-drift FAIL .*sev=HIGH' "SD-10: timeout drift is never a blocking severity"
  # absent budget -> per-call candidate only; composition reports unknown
  mmut "del s['timeout_budget_ms']" "$WORK/m_notb.yaml"; JOIN "$WORK/m_notb.yaml" "$JREF"
  assert_not_grep "$WORK/join.out" '^ROW timeout-budget-drift FAIL' "SD-10: absent budget -> NO composition finding (composition unknown, honest)"
else
  echo "  [skip] validate_manifest.sh absent — SD-03..10 comparator rows skipped (blocked-on the spec-gen validator drain)"
fi

# =============================================================================
# SD-11 — honest deterministic in-repo SEEDS (candidates, never verdicts). Each
# seed emits candidates to an audit/ file with a must_not_flag negative guarding
# precision. Deadlock has NO [det] seed (a Lock/acquire regex is precision-hostile,
# SD §3.9) — a guard asserts none exists.
# =============================================================================
echo "== SD-11. honest in-repo seeds (candidates, not verdicts) + must_not_flag negatives =="
if [ -x "$SD_SEEDS" ]; then
  SRC="$WORK/seedsrc"; OUT="$WORK/seedout"; mkdir -p "$SRC/app" "$SRC/tests" "$SRC/migrations"
  # money-as-float ∩ VITAL  (positive) + Decimal-correct (must_not_flag)
  printf 'def charge_customer(amount):\n    total = amount * 1.075\n    return round(total, 2)\n' > "$SRC/app/money_bad.py"
  printf 'from decimal import Decimal\ndef charge_account(amount):\n    total = Decimal("0.00") + amount\n    return total\n' > "$SRC/app/money_ok.py"
  # tz-in-production (positive) + tz-aware (must_not_flag) + a test-path copy (gated OUT)
  printf 'import datetime\ndef stamp():\n    return datetime.utcnow()\n' > "$SRC/app/tz_bad.py"
  printf 'import datetime\ndef stamp_ok():\n    return datetime.now(datetime.timezone.utc)\n' > "$SRC/app/tz_ok.py"
  printf 'import datetime\ndef test_stamp():\n    return datetime.utcnow()\n' > "$SRC/tests/test_tz.py"
  # timeout-kwarg-absence (positive) + timeout= present (must_not_flag)
  printf 'import requests\ndef fetch():\n    return requests.get("http://x")\n' > "$SRC/app/http_bad.py"
  printf 'import requests\ndef fetch_ok():\n    return requests.get("http://x", timeout=5)\n' > "$SRC/app/http_ok.py"
  # jitter-absence over retries (positive) + jittered (must_not_flag)
  printf 'import backoff\n@backoff.on_exception(backoff.expo, Exception)\ndef retry_bad():\n    pass\n' > "$SRC/app/retry_bad.py"
  printf 'import backoff\n@backoff.on_exception(backoff.expo, Exception, jitter=backoff.full_jitter)\ndef retry_ok():\n    pass\n' > "$SRC/app/retry_ok.py"
  # Queue-without-maxsize (positive) + bounded (must_not_flag)
  printf 'import queue\nq = queue.Queue()\n' > "$SRC/app/queue_bad.py"
  printf 'import queue\nq = queue.Queue(maxsize=100)\n' > "$SRC/app/queue_ok.py"
  # migration DDL destructive (positive) + additive (must_not_flag)
  printf 'ALTER TABLE loans DROP COLUMN legacy_rate;\n' > "$SRC/migrations/0002_drop.sql"
  printf 'ALTER TABLE loans ADD COLUMN note TEXT;\n' > "$SRC/migrations/0003_add.sql"
  # SD-09 least-privilege breadth (positive) + scoped (must_not_flag)
  printf 'FROM python:3.12\nUSER root\nCOPY . /app\n' > "$SRC/app/Dockerfile.bad"
  printf 'FROM python:3.12\nRUN useradd appuser\nUSER appuser\n' > "$SRC/app/Dockerfile.ok"
  printf 'GRANT ALL PRIVILEGES ON loans TO svc;\n' > "$SRC/migrations/0004_grant_all.sql"
  printf 'GRANT SELECT ON loans TO reader;\n' > "$SRC/migrations/0005_grant_select.sql"
  printf '{"Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}]}\n' > "$SRC/app/iam_bad.json"
  printf '{"Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}]}\n' > "$SRC/app/iam_ok.json"

  bash "$SD_SEEDS" "$SRC" "$OUT" >/dev/null 2>&1
  seed_has()  { if grep -q "$2" "$OUT/$1" 2>/dev/null; then ok "$3"; else fail "$3 [not in $OUT/$1]"; fi; }
  seed_lacks(){ if grep -q "$2" "$OUT/$1" 2>/dev/null; then fail "$3 [$2 leaked into $OUT/$1]"; else ok "$3"; fi; }

  seed_has   sd_money_float.txt      'money_bad.py'  "SD-11 money-as-float: float×VITAL candidate flagged"
  seed_lacks sd_money_float.txt      'money_ok.py'   "SD-11 money-as-float must_not_flag: Decimal-correct money NOT flagged (precision guard)"
  seed_has   sd_tz_production.txt    'tz_bad.py'     "SD-11 tz-in-production: naive datetime.utcnow() candidate flagged"
  seed_lacks sd_tz_production.txt    'tz_ok.py'      "SD-11 tz must_not_flag: tz-aware datetime.now(tz) NOT flagged"
  seed_lacks sd_tz_production.txt    'test_tz.py'    "SD-11 tz gate: a test-path file is excluded (TEST_PATH_RE, production-only)"
  seed_has   sd_timeout_absence.txt  'http_bad.py'   "SD-11 timeout-kwarg-absence: requests.get without timeout= candidate flagged"
  seed_lacks sd_timeout_absence.txt  'http_ok.py'    "SD-11 timeout must_not_flag: requests.get(..., timeout=5) NOT flagged"
  seed_has   sd_jitter_absence.txt   'retry_bad.py'  "SD-11 jitter-absence: retry without jitter candidate flagged"
  seed_lacks sd_jitter_absence.txt   'retry_ok.py'   "SD-11 jitter must_not_flag: jittered retry NOT flagged"
  seed_has   sd_queue_unbounded.txt  'queue_bad.py'  "SD-11 Queue-without-maxsize: unbounded Queue() candidate flagged"
  seed_lacks sd_queue_unbounded.txt  'queue_ok.py'   "SD-11 queue must_not_flag: Queue(maxsize=) NOT flagged"
  seed_has   sd_migration_ddl.txt    '0002_drop.sql' "SD-11 migration DDL: destructive DROP COLUMN candidate flagged"
  seed_lacks sd_migration_ddl.txt    '0003_add.sql'  "SD-11 migration must_not_flag: additive ADD COLUMN NULL NOT flagged"
  # SD-09 least-privilege breadth seeds (in-repo slivers ONLY, NOT an access review)
  seed_has   sd_least_privilege.txt  'Dockerfile.bad'         "SD-09 least-privilege: Dockerfile USER root candidate flagged"
  seed_lacks sd_least_privilege.txt  'Dockerfile.ok'          "SD-09 least-privilege must_not_flag: USER appuser NOT flagged"
  seed_has   sd_least_privilege.txt  '0004_grant_all.sql'     "SD-09 least-privilege: GRANT ALL in checked-in DDL candidate flagged"
  seed_lacks sd_least_privilege.txt  '0005_grant_select.sql'  "SD-09 least-privilege must_not_flag: GRANT SELECT NOT flagged"
  seed_has   sd_least_privilege.txt  'iam_bad.json'           "SD-09 least-privilege: IAM \"*\" wildcard candidate flagged"
  seed_lacks sd_least_privilege.txt  'iam_ok.json'            "SD-09 least-privilege must_not_flag: a scoped IAM action NOT flagged"
  # the SD-09 mandate MUST disclaim access-review / audit-grade coverage (SD §3.5)
  assert_grep "$OUT/sd_least_privilege.txt" 'NOT an access review' "SD-09: the report disclaims access-review scope (never audit-grade entitlement coverage)"
  # every seed output is labelled a CANDIDATE, not a finding/verdict
  assert_grep "$OUT/sd_money_float.txt" 'candidate' "SD-11: seed output is labelled a candidate (not a verdict)"

  # deadlock has NO [det] seed (the honesty guard, SD §3.9) — the seed producer
  # must define NO deadlock regex and produce NO sd_deadlock candidate file.
  if grep -qiE 'DEADLOCK_RE|sd_deadlock|\.acquire\(' "$SD_SEEDS" 2>/dev/null; then
    fail "SD-11 deadlock honesty: sd_seeds.sh must define NO deadlock/Lock-acquire seed (precision-hostile, SD §3.9)"
  else
    ok "SD-11 deadlock honesty: NO [det] deadlock seed exists (a Lock/acquire regex would violate the determinism-first clause)"
  fi
  [ -f "$OUT/sd_deadlock.txt" ] && fail "SD-11 deadlock honesty: no sd_deadlock candidate file may be produced" \
                                || ok "SD-11 deadlock honesty: no sd_deadlock candidate file produced"
else
  echo "  [skip] sd_seeds.sh absent/not-executable — SD-11 seed cases skipped"
fi

# =============================================================================
# SD-12 — the no-second-comparator invariant (the [det] structural half; the lint
# V12 guards + red-tests live in scripts/suite_self_test.sh). The four SD drift
# rows live in the CH-03 engine manifest_join.py, NOT a parallel sibling.
# =============================================================================
echo "== SD-12. SD rows live in the one CH-03 join engine (no parallel comparator) =="
for slug in abuse-controls-drift resilience-posture-drift isolation-drift timeout-budget-drift; do
  assert_grep "$JOINPY" "$slug" "SD-12: '$slug' row lives in the CH-03 join engine manifest_join.py"
done

# =============================================================================
echo
if [ "$FAIL" -eq 0 ]; then
  echo "sd_self_test: PASS=$PASS FAIL=0"
  exit 0
else
  echo "sd_self_test: PASS=$PASS FAIL=$FAIL"
  exit 1
fi
