#!/usr/bin/env bash
# Self-test for the codebase-health suite's deterministic layer.
#
# Runs run_audit.sh, render_report.py, and check_new_debt.sh against the
# planted-defect corpus (test-fixtures/planted/ + EXPECTED_FINDINGS.yaml) and
# asserts recall + exclusion behavior. Exits non-zero on any miss.
#
# This is the ground-truth harness: agent prompts can't be unit-tested, but
# everything mechanical can — and every real-world miss gets planted into the
# corpus before its fix (see references/audit-state-and-verify.md).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SCRIPTS="$ROOT/plugins/codebase-health/skills/cleanup-audit/scripts"
FIXTURE_SRC="$ROOT/test-fixtures/planted"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok  - $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
assert_grep()     { if grep -qiE "$2" "$1" 2>/dev/null; then ok "$3"; else fail "$3"; fi; }
assert_not_grep() { if grep -qiE "$2" "$1" 2>/dev/null; then fail "$3"; else ok "$3"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 0. required dev dependencies (Decision 8, SPEC_1.4.0) =="
# jscpd is a REQUIRED dev dependency of THIS self-test: ND1's near-duplicate
# pair is scored off REAL jscpd output in dup_jscpd.json — a shim-only pass is
# forbidden. The gate fails loudly at startup but is COUNTED rather than an
# abort, so a red run still reports every assertion below it (the summary exit
# code is non-zero either way; a red run must fail completely, not stop at the
# first gate). run_audit.sh keeps its graceful [skip] degrade for TARGET repos
# only (Decision 5) — the self-test asserts that path separately in section 11.
if command -v jscpd >/dev/null 2>&1; then
  ok "jscpd on PATH (REQUIRED dev dependency of self_test.sh: npm i -g jscpd)"
else
  fail "FATAL: jscpd missing — REQUIRED dev dependency of self_test.sh (npm i -g jscpd); ND1 cannot be scored"
fi

echo "== 1. run_audit.sh against the planted corpus =="
cp -R "$FIXTURE_SRC" "$WORK/planted"
# logs live OUTSIDE the scanned tree — the runner's own output mentions marker
# words ("stubs", ...) and would otherwise become a planted marker itself
( cd "$WORK/planted" && bash "$SKILL_SCRIPTS/run_audit.sh" . > "$WORK/run1.log" 2>&1 )
M="$WORK/planted/audit/markers.txt"
S="$WORK/planted/audit/suppressions.txt"

assert_grep "$WORK/run1.log" "Detected stack:.*python" "stack detection finds python (manifest in TARGET)"
[ -f "$M" ] && ok "markers.txt written" || fail "markers.txt written"
assert_grep "$M" "TODO: wire up"           "A1: uppercase TODO caught"
assert_grep "$M" "todo: also handle"       "A2: lowercase todo caught (case-insensitive)"
assert_grep "$M" "for now"                 "A3: 'for now' caught (taxonomy marker)"
assert_grep "$M" "WIP - do not rely"       "A4: WIP caught"
assert_grep "$M" "TBD: batch size"         "A5: TBD caught"
assert_grep "$M" "PLACEHOLDER until"       "A6: PLACEHOLDER caught"
assert_grep "$M" "NotImplementedError"     "A7: NotImplementedError caught"
assert_not_grep "$M" "node_modules"        "X1: vendored node_modules excluded from markers"
# N2 precision: word boundaries — innocent identifiers must not match
assert_not_grep "$M" "ui\.py"              "N2: on_swipe/HACKATHON/stubborn/XXXL/placeholder_text NOT flagged (word boundaries)"
[ -f "$S" ] && ok "suppressions.txt written" || fail "suppressions.txt written"
# G1 must match the PLANT in auth.py itself, not the answer key (which lives outside planted/)
assert_grep "$S" "auth\.py:.*nosec"        "G1: '# nosec' (with space) caught at its plant in auth.py"
assert_grep "$S" "noqa"                    "G2: noqa suppression caught"
assert_grep "$S" "mypy: ignore-errors"     "G3: file-level mypy suppression caught"
assert_grep "$S" "@ts-nocheck"             "G4: file-level @ts-nocheck caught"
[ -f "$WORK/planted/audit/counts.env" ] && ok "counts.env written (ratchet input)" || fail "counts.env written (ratchet input)"
# answer-key isolation: the manifest must not be inside the scanned tree
[ ! -e "$WORK/planted/EXPECTED_FINDINGS.yaml" ] && ok "answer key lives outside the scanned tree" || fail "answer key lives outside the scanned tree"
assert_grep "$WORK/planted/audit/excluded_dirs.txt" "node_modules" "excluded dirs recorded for Not-covered (no silent truncation)"

echo "== 2. no self-poisoning: second run over same tree, counts stable =="
# This guard covers ALL EIGHT ratcheted counts (SPEC_1.4.0 loop-safety notes:
# "the section-2 stability guard extends to all eight counts"), not just
# marker_count — the 1.4.0 artifacts must not seed themselves either.
# (Section 11 additionally rechecks the two navigability counts on a third run.)
counts1=$(grep '_count=' "$WORK/planted/audit/counts.env" | sort)
m1=$(grep '^marker_count=' "$WORK/planted/audit/counts.env" | cut -d= -f2)
( cd "$WORK/planted" && bash "$SKILL_SCRIPTS/run_audit.sh" . > "$WORK/run2.log" 2>&1 )
counts2=$(grep '_count=' "$WORK/planted/audit/counts.env" | sort)
if [ "$counts1" = "$counts2" ] && [ -n "$m1" ] && [ "$m1" -gt 0 ]; then
  ok "all ratcheted counts stable across runs (marker_count=$m1) — audit/ excluded from its own seed"
else
  fail "ratcheted counts drifted between runs — audit/ self-poisoning [run1: $(echo "$counts1" | tr '\n' ' ')| run2: $(echo "$counts2" | tr '\n' ' ')]"
fi

echo "== 3. monorepo detection: TARGET manifest, not cwd =="
mkdir -p "$WORK/mono"
cp -R "$FIXTURE_SRC" "$WORK/mono/py_subpkg"
( cd "$WORK/mono" && bash "$SKILL_SCRIPTS/run_audit.sh" py_subpkg > "$WORK/mono.log" 2>&1 )
assert_grep "$WORK/mono.log" "Detected stack:.*python" "python detected from TARGET subdir (cwd has no manifest)"

echo "== 4. renderer: pills, false-positive guard, pipe paragraph =="
cat > "$WORK/report.md" <<'EOF'
# Report
### [HIGH] Fake validator accepts anything
- Location: planted_pkg/auth.py:9
### Safe Deletion Workflow
A paragraph with a pipe | that must stay a paragraph.

| Tag | Severity |
| --- | --- |
| IL-H1 | HIGH |
EOF
python3 "$SKILL_SCRIPTS/render_report.py" "$WORK/report.md" -o "$WORK/report.html" >/dev/null 2>&1
assert_grep "$WORK/report.html" '<h3 id="high-fake-validator[^"]*"><span class="pill high">HIGH</span>' "heading-format finding gets a severity pill"
assert_grep "$WORK/report.html" '<h3 id="safe-deletion-workflow">Safe Deletion Workflow</h3>' "ordinary 'Safe ...' heading NOT pill-ified"
assert_grep "$WORK/report.html" '<p>A paragraph with a pipe \|' "pipe-in-prose stays a paragraph"
assert_grep "$WORK/report.html" '<td><span class="pill high">HIGH</span></td>' "table-cell severity still pilled"

echo "== 5. check_new_debt.sh: flags newly introduced debt, warn-only =="
mkdir -p "$WORK/repo" && cd "$WORK/repo"
git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'def f():\n    return 1\n' > clean.py
git add clean.py && git -c user.email=t@t -c user.name=t commit -qm clean
printf '# TODO: finish this\ndef g():\n    return None  # type: ignore\n' > new.py
git add new.py
# REWRITTEN for Decision 1 (SPEC_1.4.0): the CLI/CI surface is strict by
# DEFAULT — new gated debt exits 1 with no flag. (Hook surface stays warn-only
# unconditionally; asserted below.)
out=$(bash "$SKILL_SCRIPTS/check_new_debt.sh" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -q "TODO: finish this"; then ok "new marker flagged, exit 1 (strict-default CLI surface)"; else fail "new marker flagged, exit 1 (strict-default CLI surface) [rc=$rc]"; fi
if echo "$out" | grep -q "type: ignore"; then ok "new suppression flagged"; else fail "new suppression flagged"; fi
bash "$SKILL_SCRIPTS/check_new_debt.sh" --strict >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then ok "--strict exits 1 on new debt (CI gate)"; else fail "--strict exits 1 on new debt [rc=$rc]"; fi
# hook mode on a TRACKED file: emits hookSpecificOutput JSON (the only channel Claude sees)
echo '{"tool_input":{"file_path":"new.py"}}' | bash "$SKILL_SCRIPTS/check_new_debt.sh" --hook > hookout.txt 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q '"hookSpecificOutput"' hookout.txt && grep -q "TODO" hookout.txt; then ok "hook mode (tracked file): additionalContext JSON with the debt"; else fail "hook mode (tracked file): additionalContext JSON [rc=$rc]"; fi
python3 -c "import json,sys; json.load(open('hookout.txt'))" 2>/dev/null && ok "hook output is valid JSON" || fail "hook output is valid JSON"
# hook mode on an UNTRACKED file (the common 'Claude wrote a new file' case — no diff exists)
printf '# FIXME: brand new debt\n' > untracked.py
echo '{"tool_input":{"file_path":"untracked.py"}}' | bash "$SKILL_SCRIPTS/check_new_debt.sh" --hook > hookout2.txt 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q "FIXME" hookout2.txt; then ok "hook mode (untracked file): whole-file scan catches new-file debt"; else fail "hook mode (untracked file) [rc=$rc]"; fi
rm untracked.py
# unresolvable base ref must never look like a clean pass
# REWRITTEN for Decision 1: no flag needed — strict is the CLI default now.
bash "$SKILL_SCRIPTS/check_new_debt.sh" no-such-ref > badref.txt 2>&1; rc=$?
if [ "$rc" -eq 1 ] && grep -q "cannot resolve" badref.txt; then ok "unresolvable BASE: loud + exit 1 under the strict default (no silent pass)"; else fail "unresolvable BASE under the strict default [rc=$rc]"; fi
git -c user.email=t@t -c user.name=t commit -qm add
out=$(bash "$SKILL_SCRIPTS/check_new_debt.sh" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "no diff → silent, exit 0"; else fail "no diff → silent, exit 0 [rc=$rc out=$out]"; fi

# --- 5b. 1.4.0 hook sections + the ONE strictness contract (Decision 1, §4.3;
# --- pre-flight fix C). RED-FIRST: check_new_debt.sh neither sources the new
# --- regexes nor builds the flaky/vacuity/stdout/commented sections yet, and
# --- its CLI default is still warn-only — the positive assertions below fail
# --- until Wave 1 lands. Failures accumulate like every other section.
mkdir -p tests
printf 'import time\n\n\ndef test_poll_ready():\n    time.sleep(2)\n    assert 2 + 2 == 4\n' > tests/test_new_flaky.py
# (untracked test file) hook surface: flaky warn text, exit 0
echo '{"tool_input":{"file_path":"tests/test_new_flaky.py"}}' | bash "$SKILL_SCRIPTS/check_new_debt.sh" --hook > hookflaky.txt 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -qi "nondeterminism" hookflaky.txt; then ok "hook (untracked test file): flaky warn section, exit 0"; else fail "hook (untracked test file): flaky warn section, exit 0 [rc=$rc]"; fi
# hook mode ignores strictness flags ENTIRELY (loop-safety invariant 3 pin)
echo '{"tool_input":{"file_path":"tests/test_new_flaky.py"}}' | bash "$SKILL_SCRIPTS/check_new_debt.sh" --hook --strict >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then ok "hook with gated debt + strictness flags still exits 0 (invariant 3)"; else fail "hook with gated debt + strictness flags still exits 0 (invariant 3) [rc=$rc]"; fi
# (staged flaky-only diff) CLI surface
git add tests/test_new_flaky.py
out=$(bash "$SKILL_SCRIPTS/check_new_debt.sh" 2>&1); rc=$?
if echo "$out" | grep -qi "nondeterminism"; then ok "flaky-only diff still produces a report (fix C: no literal-append early exit)"; else fail "flaky-only diff still produces a report (fix C: no literal-append early exit)"; fi
if [ "$rc" -eq 1 ]; then ok "new flaky test line fails the strict-default CLI (exit 1)"; else fail "new flaky test line fails the strict-default CLI (exit 1) [rc=$rc]"; fi
bash "$SKILL_SCRIPTS/check_new_debt.sh" --no-strict >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then ok "--no-strict escape hatch: exit 0 on the same diff"; else fail "--no-strict escape hatch: exit 0 on the same diff [rc=$rc]"; fi
WARN_ONLY=1 bash "$SKILL_SCRIPTS/check_new_debt.sh" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then ok "WARN_ONLY=1 escape hatch: exit 0 on the same diff"; else fail "WARN_ONLY=1 escape hatch: exit 0 on the same diff [rc=$rc]"; fi
git reset -q && rm -rf tests
# (prod file with a sleep) flaky section is TEST_PATH_RE-scoped — silent here
printf 'import time\n\n\ndef poll_upstream():\n    time.sleep(2)\n    return True\n' > prodpoll.py
git add prodpoll.py
out=$(bash "$SKILL_SCRIPTS/check_new_debt.sh" 2>&1)
if echo "$out" | grep -qi "nondeterminism"; then fail "prod-file sleep: no flaky section (TEST_PATH_RE scoping)"; else ok "prod-file sleep: no flaky section (TEST_PATH_RE scoping)"; fi
git reset -q && rm prodpoll.py
# (vacuous test line) warn section
mkdir -p tests && printf 'def test_settings_ok():\n    assert True\n' > tests/test_vac.py
git add tests/test_vac.py
out=$(bash "$SKILL_SCRIPTS/check_new_debt.sh" 2>&1)
if echo "$out" | grep -qi "vacuous"; then ok "vacuous-test warn section (assert True in a new test line)"; else fail "vacuous-test warn section (assert True in a new test line)"; fi
git reset -q && rm -rf tests
# (.skip token on a NON-test path) stays silent — same scoping rule
printf 'export const disabledDemo = it.skip("demo", () => {});\n' > runner_tools.ts
git add runner_tools.ts
out=$(bash "$SKILL_SCRIPTS/check_new_debt.sh" 2>&1)
if echo "$out" | grep -qiE "vacuous|skipped"; then fail "non-test .skip line: silent (TEST_PATH_RE scoping)"; else ok "non-test .skip line: silent (TEST_PATH_RE scoping)"; fi
git reset -q && rm runner_tools.ts
# (print on a prod path) stdout warn section, but NEVER a gate — exit 0 under strict default
printf 'def serve(req):\n    print("served", req)\n    return 200\n' > prod_log.py
git add prod_log.py
out=$(bash "$SKILL_SCRIPTS/check_new_debt.sh" 2>&1); rc=$?
if echo "$out" | grep -qi "stdout"; then ok "stdout-logging warn section on a non-test print"; else fail "stdout-logging warn section on a non-test print"; fi
if [ "$rc" -eq 0 ]; then ok "print-only diff passes the strict-default CLI (stdout never gates)"; else fail "print-only diff passes the strict-default CLI (stdout never gates) [rc=$rc]"; fi
git reset -q && rm prod_log.py
# (commented-out code block) warn section; prose-only comments stay silent
printf '# def legacy_total(items):\n#     total = 0\n#     for i in items:\n#         total += i\n#     return total\ndef total(items):\n    return sum(items)\n' > blocky.py
git add blocky.py
out=$(bash "$SKILL_SCRIPTS/check_new_debt.sh" 2>&1)
if echo "$out" | grep -qi "commented"; then ok "commented-out code block warn section (>= CO_MIN_RUN/CO_MIN_CODE)"; else fail "commented-out code block warn section (>= CO_MIN_RUN/CO_MIN_CODE)"; fi
git reset -q && rm blocky.py
printf '# This module sums totals for the report.\n# The caller validates inputs first.\n# Results are cached upstream by the runner.\ndef total_v2(items):\n    return sum(items)\n' > prosey.py
git add prosey.py
out=$(bash "$SKILL_SCRIPTS/check_new_debt.sh" 2>&1)
if echo "$out" | grep -qi "commented"; then fail "prose-only comment run: silent (leader anchoring)"; else ok "prose-only comment run: silent (leader anchoring)"; fi
git reset -q && rm prosey.py

echo "== 6. table rendering: backtick pipes, trailing prose, overflow =="
cat > "$WORK/table.md" <<'EOF'
# T
| Tag | Status | Evidence |
| --- | --- | --- |
| IL-H1 | OPEN | uses `a | b` pipe in code |
Coverage: 10 of 12 files | 2 skipped.
EOF
python3 "$SKILL_SCRIPTS/render_report.py" "$WORK/table.md" -o "$WORK/table.html" >/dev/null 2>&1
assert_grep "$WORK/table.html" 'uses <code>a \| b</code> pipe in code' "backtick-pipe cell kept intact (no truncation)"
assert_grep "$WORK/table.html" '<p>Coverage: 10 of 12 files \| 2 skipped.</p>' "single-pipe prose after table stays prose"
assert_grep "$WORK/table.html" '<td><span class="pill high">OPEN</span></td>' "verify-status pill rendered"

echo "== 7. knip JSON kept clean of stderr (PATH shim) =="
mkdir -p "$WORK/nodeproj/bin" && cd "$WORK/nodeproj"
echo '{}' > package.json
cat > bin/knip <<'SHIM'
#!/usr/bin/env bash
echo "a knip warning" >&2
echo '{"files":[],"issues":[]}'
SHIM
chmod +x bin/knip
PATH="$WORK/nodeproj/bin:$PATH" bash "$SKILL_SCRIPTS/run_audit.sh" . > "$WORK/knip.log" 2>&1
python3 -c "import json; json.load(open('audit/ts_knip.json'))" 2>/dev/null && ok "ts_knip.json is pure JSON" || fail "ts_knip.json is pure JSON"
grep -q "a knip warning" audit/ts_knip.err && ok "knip stderr captured in sidecar .err" || fail "knip stderr captured in sidecar .err"

echo "== 8. shared classifiers + test-health deterministic layer (SPEC_1.4.0 §8) =="
# RED-FIRST (Wave 0): debt_patterns.sh defines neither TEST_PATH_RE nor
# FLAKY_RE/TEST_VACUOUS_RE/TEST_SKIP_RE yet, and run_audit.sh writes none of
# the test-health artifacts — every deterministic assertion below FAILS on two
# consecutive runs until Wave 1 lands. Failures accumulate in the same
# PASS/FAIL counters, so a red run still reports every assertion (no abort).
# ${VAR-} default expansions keep `set -u` from killing the red run.
# HONESTY CLAUSE: the agent-scored plants (TF2/TF6/TF8, TQ1/TQ4/TQ5/TQ8, LG3,
# LG4, SEC3, TX1-TX3, J5, JC1-JC2, MN1) have NO assertions anywhere in this
# script — they are scored ONLY by the manual blind-corpus eval.
# shellcheck source=/dev/null
. "$SKILL_SCRIPTS/debt_patterns.sh"
A="$WORK/planted/audit"
CE="$A/counts.env"

# unit cases for the ONE path classifier (grep file:line: prefix form)
if [ -n "${TEST_PATH_RE-}" ]; then
  printf '%s' 'tests/test_sync_flaky.py:31:x' | grep -qE "$TEST_PATH_RE" && ok "TEST_PATH_RE: tests/ grep-prefix classified as a test path" || fail "TEST_PATH_RE: tests/ grep-prefix classified as a test path"
  printf '%s' 'web/app.spec.ts:13:x' | grep -qE "$TEST_PATH_RE" && ok "TEST_PATH_RE: .spec.ts grep-prefix classified as a test path" || fail "TEST_PATH_RE: .spec.ts grep-prefix classified as a test path"
  printf '%s' 'tests/conftest.py:22:x' | grep -qE "$TEST_PATH_RE" && ok "TEST_PATH_RE: conftest.py classified as a test path" || fail "TEST_PATH_RE: conftest.py classified as a test path"
  printf '%s' 'planted_pkg/poller.py:45:x' | grep -qE "$TEST_PATH_RE" && fail "TEST_PATH_RE: poller.py must NOT classify as a test path (N4)" || ok "TEST_PATH_RE: poller.py must NOT classify as a test path (N4)"
  printf '%s' 'web/__snapshots__/app.test.ts.snap:3:x' | grep -qE "$TEST_PATH_RE" && fail "TEST_PATH_RE: .snap stamp must NOT classify as a test path (TQ8 artifact)" || ok "TEST_PATH_RE: .snap stamp must NOT classify as a test path (TQ8 artifact)"
else
  fail "TEST_PATH_RE: tests/ grep-prefix classified as a test path (regex undefined)"
  fail "TEST_PATH_RE: .spec.ts grep-prefix classified as a test path (regex undefined)"
  fail "TEST_PATH_RE: conftest.py classified as a test path (regex undefined)"
  fail "TEST_PATH_RE: poller.py must NOT classify as a test path (regex undefined)"
  fail "TEST_PATH_RE: .snap stamp must NOT classify as a test path (regex undefined)"
fi

# recall — the seven deterministic flakiness plants (FLAKY_RE gated INTO TEST_PATH_RE)
TFK="$A/test_flakiness.txt"
[ -f "$TFK" ] && ok "test_flakiness.txt written" || fail "test_flakiness.txt written"
assert_grep "$TFK" 'tests/test_sync_flaky\.py:[0-9]+:.*time\.sleep\('                    "TF1: sleep-as-sync caught in test_sync_flaky.py"
assert_grep "$TFK" 'tests/test_clock_random\.py:[0-9]+:.*random\.randint\('              "TF3: unseeded random.randint caught"
assert_grep "$TFK" 'tests/test_clock_random\.py:[0-9]+:.*datetime\.now\(\)'              "TF4: wall-clock datetime.now caught"
assert_grep "$TFK" 'tests/test_shared_state\.py:[0-9]+:.*requests\.get\("https://'       "TF5: real-network requests.get with a literal URL caught"
assert_grep "$TFK" 'tests/test_sync_flaky\.py:[0-9]+:.*@pytest\.mark\.flaky\(reruns=3\)' "TF7: retry-until-pass decorator caught"
assert_grep "$TFK" 'web/app\.spec\.ts:[0-9]+:.*setTimeout\('                             "TF9: setTimeout in a .spec.ts caught"
assert_grep "$TFK" 'web/app\.spec\.ts:[0-9]+:.*Math\.random\('                           "TF10: Math.random in a .spec.ts caught"
assert_not_grep "$TFK" 'conftest\.py' "N3: remedies conftest.py contributes zero lines to test_flakiness.txt"
assert_not_grep "$TFK" 'poller\.py'   "N4: production poller.py excluded by TEST_PATH_RE scoping"

# pre-flight fix H — \breruns=[1-9] digit anchor, pinned by conftest's literal reruns=0
assert_grep "$WORK/planted/tests/conftest.py" 'reruns=0' "N3 pin (fixture integrity): literal reruns=0 line present in conftest.py"
if [ -n "${FLAKY_RE-}" ]; then
  printf '%s' '# CI pins reruns=0'           | grep -qE "$FLAKY_RE" && fail "fix H: reruns=0 must NOT match FLAKY_RE (digit anchor)" || ok "fix H: reruns=0 must NOT match FLAKY_RE (digit anchor)"
  printf '%s' '@pytest.mark.flaky(reruns=3)' | grep -qE "$FLAKY_RE" && ok "fix H: reruns=[1-9] still matches FLAKY_RE" || fail "fix H: reruns=[1-9] still matches FLAKY_RE"
else
  fail "fix H: reruns=0 must NOT match FLAKY_RE (regex undefined)"
  fail "fix H: reruns=[1-9] still matches FLAKY_RE (regex undefined)"
fi

# vacuity artifact (TEST_VACUOUS_RE gated INTO TEST_PATH_RE)
TVA="$A/test_vacuity.txt"
[ -f "$TVA" ] && ok "test_vacuity.txt written" || fail "test_vacuity.txt written"
assert_grep "$TVA" 'tests/test_auth\.py:[0-9]+:.*assert True'                     "TQ2: bare 'assert True' caught in test_vacuity.txt"
assert_grep "$TVA" 'web/app\.test\.ts:[0-9]+:.*expect\(true\)\.toBe\(true\)'      "TQ3: expect(true).toBe(true) caught in test_vacuity.txt"
assert_not_grep "$TVA" 'test_transform\.py' "N5: real behavior-constraining tests contribute zero lines to test_vacuity.txt"
assert_not_grep "$TVA" 'conftest\.py'       "N3 (vacuity half): canned-data remedies file has no line in test_vacuity.txt"

# skip artifact (TEST_SKIP_RE gated INTO TEST_PATH_RE)
TSK="$A/test_skips.txt"
[ -f "$TSK" ] && ok "test_skips.txt written" || fail "test_skips.txt written"
assert_grep "$TSK" 'tests/test_auth\.py:[0-9]+:.*@pytest\.mark\.skip' "TQ6: @pytest.mark.skip caught in test_skips.txt"
assert_grep "$TSK" 'web/app\.test\.ts:[0-9]+:.*it\.skip\('            "TQ7: it.skip caught in test_skips.txt"
assert_not_grep "$TSK" 'ui\.py' "N2 ext: queue.skip(3) excluded by the (it|test|describe|xit) receiver anchor"

# three new ratchet keys
assert_grep "$CE" '^flaky_count=[0-9]+'        "flaky_count written to counts.env"
assert_grep "$CE" '^test_vacuity_count=[0-9]+' "test_vacuity_count written to counts.env"
assert_grep "$CE" '^test_skip_count=[0-9]+'    "test_skip_count written to counts.env"

echo "== 9. logging: stdout-as-log-channel deterministic layer (Category LOG) =="
# RED-FIRST like section 8: LOGGING_RE and stdout_logging.txt land in Wave 1.
SL="$A/stdout_logging.txt"
[ -f "$SL" ] && ok "stdout_logging.txt written" || fail "stdout_logging.txt written"
assert_grep "$SL" 'planted_pkg/service\.py:[0-9]+:.*print\('             "LG1: print( on a request path listed (service.py get_order_status)"
assert_grep "$SL" 'planted_pkg/service\.py:[0-9]+:.*sys\.stdout\.write\(' "LG2: sys.stdout.write( listed (service.py record_dispatch)"
assert_grep "$SL" 'web/app\.ts:[0-9]+:.*console\.log\('                  "LG5: console.log inside render() listed (web/app.ts)"
# N6 is candidates-not-verdicts: the CLI print lines MUST be listed (the agent
# judges CLI-vs-log; grep does not), while the pprint decoy matches nothing.
assert_grep     "$SL" 'planted_pkg/report_cli\.py:' "N6 precondition: CLI print lines ARE listed as candidates"
assert_not_grep "$SL" 'pprint\('   "N6 decoy: pprint( never matches (\\b anchor on print)"
assert_not_grep "$SL" 'widgets\.ts' "N7: game_console.log/sprintf boundary traps excluded (\\b anchors)"
assert_not_grep "$SL" 'ui\.py'      "N2 ext: blueprint()/imprint() decoys excluded (\\b anchor)"
# tests-path exemption — non-vacuous by construction: tests/test_storage.py
# holds a deliberate diagnostic print( that LOGGING_RE matches raw.
if [ -f "$SL" ] && [ -n "${TEST_PATH_RE-}" ] && ! grep -E "$TEST_PATH_RE" "$SL" 2>/dev/null | grep -q .; then
  ok "tests-path exemption: TEST_PATH_RE lines gated out of stdout_logging.txt (test_storage.py print)"
else
  fail "tests-path exemption: TEST_PATH_RE lines gated out of stdout_logging.txt (test_storage.py print)"
fi
assert_grep "$CE" '^stdout_logging_count=[0-9]+' "stdout_logging_count written (report-only — never gates, even under strict)"

echo "== 10. business-vital / tx seeds (V/J deterministic + TX/N8 corroboration) =="
# Seed regexes (VITAL_RE/TELEMETRY_RE/TX_GUARD_RE/TX_RETRY_RE) live in
# run_audit.sh per SPEC_1.4.0 §4 (seeds, not debt) — so this section asserts
# ARTIFACTS, not sourced variables. RED-FIRST: none are written until Wave 1.
VC="$A/vital_candidates.txt"
TEL="$A/telemetry.txt"
TXG="$A/tx_guards.txt"
TXR="$A/tx_retries.txt"
assert_grep "$VC"  'billing\.py:[0-9]+:.*def transfer_funds\(' "V1: transfer_funds def-site in vital_candidates.txt"
assert_grep "$VC"  'billing\.py:[0-9]+:.*def approve_loan\('   "V2: approve_loan def-site in vital_candidates.txt"
assert_grep "$TEL" 'billing\.py:[0-9]+:.*payment\.charged'     "V3: payment.charged emission in telemetry.txt"
# J3/J4 dark-vital seed arithmetic — deterministic PRIMARY score per the §12
# sweep (vital candidate AND no emission); V1/V2 above are the presence halves,
# section 12 asserts the README CORE anchor. The agent walk is the lens.
assert_not_grep "$TEL" 'transfer_funds' "J3 seed: transfer_funds absent from telemetry.txt (DARK)"
assert_not_grep "$TEL" 'approve_loan'   "J4 seed: approve_loan absent from telemetry.txt (DARK)"
# J5 seed halves — corroboration only (LOG-ONLY vs DARK grading stays agent work)
assert_grep     "$VC"  'def refund_payment\(' "J5 seed: refund_payment IS a vital candidate"
assert_not_grep "$TEL" 'refund_payment'       "J5 seed: refund_payment absent from telemetry.txt"
assert_not_grep "$TEL" '_LOG\.info'           "J5 pin: prose _LOG.info lines are NOT emissions (TELEMETRY_RE precision)"
# TX seeds — corroboration for the agent-scored TX family, plus the N8 contract
assert_grep     "$TXR" 'billing\.py:[0-9]+:.*for attempt in range\(3\)' "TX2 seed: submit_payout keyless retry loop in tx_retries.txt"
assert_not_grep "$TXR" 'poller\.py' "N4: poller.py contributes nothing to tx_retries.txt (no attempt-loop shape)"
assert_grep     "$TXG" 'billing\.py:[0-9]+:.*if event_id in _PROCESSED_EVENTS' "N8 seed: handle_refund_webhook guard line IS in tx_guards.txt"
assert_not_grep "$VC" 'ui\.py'        "N2 ext: recharge_battery_icon/AUTHORED_BY/turbocharged/wire_format/credits_remaining excluded from vital_candidates.txt"
assert_not_grep "$VC" 'node_modules'  "X1: vendored files absent from vital_candidates.txt"
# ratchet discipline: counts.env holds EXACTLY the 8 ratcheted keys — vitals,
# telemetry, and tx seeds are priority inputs, never counted (never ratcheted).
if [ -f "$CE" ] && [ "$(grep -c '_count=' "$CE" 2>/dev/null)" = "8" ]; then
  ok "counts.env holds exactly the 8 ratcheted keys (seeds never counted)"
else
  fail "counts.env holds exactly the 8 ratcheted keys (seeds never counted) [found: $(grep -c '_count=' "$CE" 2>/dev/null || echo 0)]"
fi

echo "== 11. navigability: size ladder, clone pair (REAL jscpd), commented code =="
# RED-FIRST: giant_files.txt / commented_code.txt / dup_jscpd.json land in
# Wave 1. jscpd itself is gated at section 0 (REQUIRED dev dependency,
# Decision 8) — a shim-only pass is forbidden here.
GFI="$A/giant_files.txt"
CC="$A/commented_code.txt"
DUP="$A/dup_jscpd.json"
assert_grep "$GFI" 'planted_pkg/megamodule\.py' "GF1: megamodule.py listed in giant_files.txt (400 [attention] rung)"
nb=$(awk 'NF' "$WORK/planted/planted_pkg/megamodule.py" 2>/dev/null | wc -l | tr -d ' ')
if [ -n "$nb" ] && [ "$nb" -ge 400 ] && [ "$nb" -lt 800 ]; then
  ok "GF1 fixture integrity: megamodule.py holds 400-799 non-blank lines ($nb)"
else
  fail "GF1 fixture integrity: megamodule.py holds 400-799 non-blank lines ($nb)"
fi
assert_not_grep "$GFI" 'node_modules' "X1: vendored files absent from giant_files.txt"
# ND1 — deterministic per Decision 8: the byte-identical pair in REAL jscpd output
python3 -c "import json; json.load(open('$DUP'))" 2>/dev/null && ok "dup_jscpd.json is valid JSON (real tool output, normalized)" || fail "dup_jscpd.json is valid JSON (real tool output, normalized)"
assert_grep "$DUP" 'report_email\.py' "ND1: report_email.py present in dup_jscpd.json"
assert_grep "$DUP" 'report_slack\.py' "ND1: report_slack.py present in dup_jscpd.json (the clone pair)"
assert_not_grep "$DUP" 'megamodule\.py' "GF1/ND1 precision: varied helper bodies keep megamodule.py out of dup_jscpd.json"
if python3 - "$WORK/planted/planted_pkg" <<'PY'
import re, sys
root = sys.argv[1]
def body(name):
    src = open(f"{root}/{name}").read()
    m = re.search(r"^def format_report_rows.*?(?=^def )", src, re.S | re.M)
    return m.group(0) if m else None
e = body("report_email.py"); s = body("report_slack.py")
sys.exit(0 if e is not None and e == s else 1)
PY
then ok "ND1 fixture integrity: format_report_rows byte-identical across the pair"; else fail "ND1 fixture integrity: format_report_rows byte-identical across the pair"; fi
# CO1 — commented-out block above apply_discount
assert_grep "$CC" 'planted_pkg/checkout\.py' "CO1: commented-out block above apply_discount listed in commented_code.txt"
if [ -n "${CODE_COMMENT_RE-}" ]; then
  co=$(grep -cE "$CODE_COMMENT_RE" "$WORK/planted/planted_pkg/checkout.py" 2>/dev/null)
  if [ -n "$co" ] && [ "$co" -ge "${CO_MIN_CODE-2}" ]; then
    ok "CO1 fixture integrity: >= CO_MIN_CODE code-shaped comment lines in checkout.py ($co)"
  else
    fail "CO1 fixture integrity: >= CO_MIN_CODE code-shaped comment lines in checkout.py ($co)"
  fi
  grep -qE "$CODE_COMMENT_RE" "$WORK/planted/planted_pkg/metrics.py" && fail "N11 regex unit: CODE_COMMENT_RE matches zero metrics.py lines (leader anchoring)" || ok "N11 regex unit: CODE_COMMENT_RE matches zero metrics.py lines (leader anchoring)"
else
  fail "CO1 fixture integrity: >= CO_MIN_CODE code-shaped comment lines in checkout.py (CODE_COMMENT_RE undefined)"
  fail "N11 regex unit: CODE_COMMENT_RE matches zero metrics.py lines (CODE_COMMENT_RE undefined)"
fi
assert_not_grep "$CC" 'planted_pkg/metrics\.py' "N11: prose comments with mid-sentence code words NOT in commented_code.txt"
assert_not_grep "$CC" 'node_modules' "X1: vendored files absent from commented_code.txt"
# two new ratchet keys + run-over-run stability (section-2 guard extended)
assert_grep "$CE" '^giant_file_count=[0-9]+'     "giant_file_count written to counts.env"
assert_grep "$CE" '^commented_code_count=[0-9]+' "commented_code_count written to counts.env"
g2=$(grep '^giant_file_count=' "$CE" 2>/dev/null | cut -d= -f2)
c2=$(grep '^commented_code_count=' "$CE" 2>/dev/null | cut -d= -f2)
( cd "$WORK/planted" && bash "$SKILL_SCRIPTS/run_audit.sh" . > "$WORK/run3.log" 2>&1 )
g3=$(grep '^giant_file_count=' "$CE" 2>/dev/null | cut -d= -f2)
c3=$(grep '^commented_code_count=' "$CE" 2>/dev/null | cut -d= -f2)
if [ -n "$g2" ] && [ "$g2" = "$g3" ] && [ -n "$c2" ] && [ "$c2" = "$c3" ]; then
  ok "giant_file_count/commented_code_count stable across runs ($g2/$c2) — no self-poisoning"
else
  fail "giant_file_count/commented_code_count stable across runs [run2=$g2/$c2 run3=$g3/$c3]"
fi
# TARGET-repo degrade (Decision 5): with jscpd stripped from PATH, run_audit.sh
# must print the loud [skip] miss line, never a silent pass (self_test itself
# still hard-requires jscpd — that gate is section 0).
mkdir -p "$WORK/degrade"
cp -R "$FIXTURE_SRC" "$WORK/degrade/planted"
( cd "$WORK/degrade/planted" && PATH="/usr/bin:/bin" bash "$SKILL_SCRIPTS/run_audit.sh" . > "$WORK/degrade.log" 2>&1 )
assert_grep "$WORK/degrade.log" 'jscpd not installed' "target-repo degrade: loud [skip] miss line when jscpd is absent (PATH-stripped run)"

echo "== 12. journey fixture integrity (README anchors + C901 profile) =="
# Fixture-integrity guards: green from Wave 0 by design (they pin the CORPUS,
# not the detectors — the red-first gate applies to sections 5b and 8-11).
# They keep the J3/JC1/JC2/N10 criticality-weighting contracts scorable.
R="$WORK/planted/README.md"
assert_grep     "$R" '## Transfers'   "J3 anchor: '## Transfers' CORE section present in README"
assert_grep     "$R" 'transfer_funds' "J3 anchor: transfer_funds named on the documented journey"
assert_grep     "$R" 'submit_order'   "JC1 anchor: submit_order on the documented CORE order journey"
assert_grep     "$R" 'format_receipt' "JC2 anchor: format_receipt on the same CORE journey"
assert_not_grep "$R" 'dump_state'     "N10: dump_state appears on NO documented journey"
# ruff-conditional (3 assertions; loud [skip] when absent — ruff is NOT a
# mandated dev dependency, per Decision 8 only jscpd is).
if command -v ruff >/dev/null 2>&1; then
  RUFF_OUT="$(ruff check --isolated --select C901 --config 'lint.mccabe.max-complexity=10' "$WORK/planted/planted_pkg/checkout.py" "$WORK/planted/planted_pkg/debughelpers.py" 2>/dev/null)"
  echo "$RUFF_OUT" | grep -q 'submit_order'   && ok "JC1 metric half: C901 fires for submit_order" || fail "JC1 metric half: C901 fires for submit_order"
  echo "$RUFF_OUT" | grep -q 'dump_state'     && ok "N10: C901 fires for dump_state (same profile, off-journey)" || fail "N10: C901 fires for dump_state (same profile, off-journey)"
  echo "$RUFF_OUT" | grep -q 'format_receipt' && fail "JC2: format_receipt stays metric-INVISIBLE (no C901)" || ok "JC2: format_receipt stays metric-INVISIBLE (no C901)"
else
  echo "  [skip] ruff not installed — 3 C901 journey-fixture integrity checks skipped"
fi

echo "== 13. post-1.4.0-eval registration LOCKS (already-green pins only) =="
# LOCK section (miss-to-fixture, post-1.4.0-eval registrations): every
# assertion below pins behavior that was ALREADY green when added — existing
# seed artifacts and fixture substrate for the blind-eval extras registered in
# EXPECTED_FINDINGS.yaml (SEC4/SEC5/B4/P2/TX4-TX7, the TF5 collection facet,
# the N3 frozen_clock QA fix). The defects themselves are agent-scored (blind
# eval only, per the honesty clause) — NO detector behavior is asserted here;
# these locks only keep the substrate and seed halves from drifting out from
# under the new answer-key entries. The red-first rule does not apply to
# locks: they are pins of green behavior, not new detection assertions.
# LOCK TX7 seed half: charge_card def-site was already a vital candidate.
assert_grep "$VC" 'billing\.py:[0-9]+:.*def charge_card\(' "LOCK TX7 seed: charge_card def-site in vital_candidates.txt (already-green pin)"
# LOCK TX6 substrate: the dedup store is a module-level in-memory set.
assert_grep "$WORK/planted/planted_pkg/billing.py" '^_PROCESSED_EVENTS: set = set\(\)' "LOCK TX6 substrate: module-level in-memory _PROCESSED_EVENTS set present"
# LOCK P2 substrate: the two module-level stores exist (unbounded by construction).
assert_grep "$WORK/planted/planted_pkg/service.py" '^_SESSIONS: dict = \{\}'   "LOCK P2 substrate: module-level _SESSIONS store present in service.py"
assert_grep "$WORK/planted/planted_pkg/service.py" '^_FULFILLED: set = set\(\)' "LOCK P2 substrate: module-level _FULFILLED store present in service.py"
# LOCK B4 substrate: hardcoded rows + the parsed-but-never-applied --window flag.
assert_grep "$WORK/planted/planted_pkg/report_cli.py" '^_ROWS = \[' "LOCK B4 substrate: hardcoded _ROWS constant present in report_cli.py"
assert_grep "$WORK/planted/planted_pkg/report_cli.py" '\-\-window'  "LOCK B4 substrate: --window flag still parsed (and never applied to _ROWS)"
# LOCK TF5 facet substrate: the HTTP-client import stays module-level.
assert_grep "$WORK/planted/tests/test_shared_state.py" '^import requests' "LOCK TF5 facet: module-level HTTP-client import present in test_shared_state.py"
# LOCK TX7 placement: the TX7 slug token is a TX_GUARD_RE alternate, so the
# fixture annotation must never name it — no PLANT comment line may leak into
# the tx_guards.txt seed artifact (green after the 2026-07-04 placement fix).
assert_not_grep "$TXG" '# PLANT' "LOCK TX7 placement: no PLANT annotation line leaks into tx_guards.txt (slug token kept out of the fixture comment)"
# LOCK N3 QA fix: frozen_clock patches via sys.modules, never the
# import-mode-sensitive dotted string (green at time of adding).
assert_grep     "$WORK/planted/tests/conftest.py" 'sys\.modules' "LOCK N3 QA: frozen_clock patches via sys.modules (import-mode-proof)"
assert_not_grep "$WORK/planted/tests/conftest.py" '"tests\.test_clock_random\.datetime"' "LOCK N3 QA: import-mode-sensitive dotted-string target gone from conftest"

echo
echo "== self-test: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
