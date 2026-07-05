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

# ── PR-Gate / manifest wiring (CH-01..CH-10). The Verification-Manifest
# validator, its schema, and the §13.4 join fixture pair are repo-root
# artifacts vendored per ADR 0001 — CH items CONSUME them. In this monorepo
# they sit one level above codebase-health/; a standalone install would vendor
# them (and set $VALIDATE_MANIFEST). Every manifest-reading section below
# [skip]s loudly when the validator is absent (blocked-on the spec-gen drain),
# so this self-test stays green outside the monorepo — never a silent pass.
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
VALIDATE_MANIFEST="${VALIDATE_MANIFEST:-$REPO_ROOT/scripts/validate_manifest.sh}"
export VALIDATE_MANIFEST
JOIN_FIX="$REPO_ROOT/tests/fixtures/join"          # reference PASS pair (manifest.yaml + journeys.json v2)
MANIFEST_FIX="$REPO_ROOT/tests/fixtures/manifest"  # shared validator fixture suite (no second schema copy)
CH_FIX="$ROOT/test-fixtures/pr-gate"               # plugin-local CH fail-variant / history / rot fixtures
have_validator() { [ -x "$VALIDATE_MANIFEST" ]; }

# uv-first Python (ADR 0015 "everything uv"): a hermetic interpreter with no
# hand-managed venv. Falls back to python3 (the validate_manifest.sh precedent)
# so the self-test still runs where uv is absent.
if command -v uv >/dev/null 2>&1 && [ -f "$REPO_ROOT/pyproject.toml" ]; then
  PYRUN=(uv run --quiet --project "$REPO_ROOT" python)
else
  PYRUN=(python3)
fi

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok  - $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
assert_grep()     { if grep -qiE "$2" "$1" 2>/dev/null; then ok "$3"; else fail "$3"; fi; }
assert_not_grep() { if grep -qiE "$2" "$1" 2>/dev/null; then fail "$3"; else ok "$3"; fi; }
# assert_py CODE MSG — CODE is Python that exits 0 on pass, non-zero on fail.
assert_py()       { if "${PYRUN[@]}" -c "$1" >/dev/null 2>&1; then ok "$2"; else fail "$2"; fi; }

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
"${PYRUN[@]}" "$SKILL_SCRIPTS/render_report.py" "$WORK/report.md" -o "$WORK/report.html" >/dev/null 2>&1
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
"${PYRUN[@]}" -c "import json,sys; json.load(open('hookout.txt'))" 2>/dev/null && ok "hook output is valid JSON" || fail "hook output is valid JSON"
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
"${PYRUN[@]}" "$SKILL_SCRIPTS/render_report.py" "$WORK/table.md" -o "$WORK/table.html" >/dev/null 2>&1
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
"${PYRUN[@]}" -c "import json; json.load(open('audit/ts_knip.json'))" 2>/dev/null && ok "ts_knip.json is pure JSON" || fail "ts_knip.json is pure JSON"
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
"${PYRUN[@]}" -c "import json; json.load(open('$DUP'))" 2>/dev/null && ok "dup_jscpd.json is valid JSON (real tool output, normalized)" || fail "dup_jscpd.json is valid JSON (real tool output, normalized)"
assert_grep "$DUP" 'report_email\.py' "ND1: report_email.py present in dup_jscpd.json"
assert_grep "$DUP" 'report_slack\.py' "ND1: report_slack.py present in dup_jscpd.json (the clone pair)"
assert_not_grep "$DUP" 'megamodule\.py' "GF1/ND1 precision: varied helper bodies keep megamodule.py out of dup_jscpd.json"
if "${PYRUN[@]}" - "$WORK/planted/planted_pkg" <<'PY'
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

echo "== 14. CH-01 manifest ingestion + consumer degrade (MS §8/§11/§13.10) =="
# RED-FIRST: ingest_manifest.sh is net-new — every assertion below fails on two
# consecutive runs until the script lands. Manifest-reading, so it [skip]s
# loudly when the vendored validator is absent (blocked-on the spec-gen drain).
if have_validator; then
  ING="$SKILL_SCRIPTS/ingest_manifest.sh"
  # MODE matrix — all five tokens off the shared validator fixture suite (no
  # second schema copy): valid-complete, incomplete, boolean-in-enum (norway),
  # unsupported-version, plus a nonexistent path for ABSENT.
  bash "$ING" "$JOIN_FIX/manifest.yaml"                 > "$WORK/ing_complete.txt"  2>&1
  bash "$ING" "$MANIFEST_FIX/incomplete.yaml"           > "$WORK/ing_incomp.txt"    2>&1
  bash "$ING" "$MANIFEST_FIX/norway-enum.yaml"          > "$WORK/ing_invalid.txt"   2>&1
  bash "$ING" "$MANIFEST_FIX/unsupported-version.yaml"  > "$WORK/ing_unsup.txt"     2>&1
  bash "$ING" "$WORK/no-such-manifest.yaml"             > "$WORK/ing_absent.txt"     2>&1
  assert_grep "$WORK/ing_complete.txt" '^MODE=COMPLETE$'       "CH-01: complete manifest -> MODE=COMPLETE (exit 0)"
  assert_grep "$WORK/ing_incomp.txt"   '^MODE=INCOMPLETE$'     "CH-01: incomplete manifest -> MODE=INCOMPLETE (exit 3)"
  assert_grep "$WORK/ing_invalid.txt"  '^MODE=SCHEMA-INVALID$' "CH-01: boolean-in-enum manifest -> MODE=SCHEMA-INVALID (exit 4)"
  assert_grep "$WORK/ing_unsup.txt"    '^MODE=UNSUPPORTED$'    "CH-01: schema_version 2 -> MODE=UNSUPPORTED (exit 5)"
  assert_grep "$WORK/ing_absent.txt"   '^MODE=ABSENT$'        "CH-01: missing manifest -> MODE=ABSENT"
  # Degrade table (invariant 4 + 6): absent/incomplete/unsupported each surface
  # BOTH manifest facets in Not-covered — never a silent skip.
  assert_grep "$WORK/ing_absent.txt" '\[not-covered\] manifest-coverage .§12 join.' "CH-01 degrade: absent -> coverage facet in Not-covered (no silent skip)"
  assert_grep "$WORK/ing_absent.txt" '\[not-covered\] rot-vs-manifest'              "CH-01 degrade: absent -> rot-vs-manifest facet in Not-covered"
  assert_grep "$WORK/ing_incomp.txt" '\[not-covered\] manifest-coverage'            "CH-01 degrade: incomplete -> coverage facet in Not-covered (as-absent, MS §11)"
  assert_grep "$WORK/ing_unsup.txt"  'MANIFEST-UNSUPPORTED: schema_version 2 > supported 1' "CH-01: unsupported names the offending version (MS §8)"
  # MS §11: schema-invalid is a DEFECT, never degraded to manifest-less — it
  # reports the schema error and is NOT treated as an absence.
  assert_grep     "$WORK/ing_invalid.txt" 'schema-invalid|not one of'  "CH-01: schema-invalid reports the schema error (not a silent skip)"
  assert_grep     "$WORK/ing_invalid.txt" 'DEFECT, not an absence'     "CH-01: schema-invalid framed as defect, never degraded to manifest-less (MS §11)"
  assert_not_grep "$WORK/ing_invalid.txt" 'heuristic journeys'         "CH-01: schema-invalid does NOT take the absent/manifest-less degrade path"
  # Reporter posture (loop-safety invariant 1): ingest never blocks — exit 0 on
  # every MODE, including schema-invalid and unsupported.
  bash "$ING" "$MANIFEST_FIX/norway-enum.yaml" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then ok "CH-01: ingest exits 0 on schema-invalid (reporter, never blocks — invariant 1)"; else fail "CH-01: ingest exits 0 on schema-invalid [rc=$rc]"; fi
else
  echo "  [skip] validate_manifest.sh absent — CH-01 manifest-ingestion checks skipped (blocked-on the spec-gen validator drain)"
fi

echo "== 15. CH-02 journeys.json v2: manifest_journey_id + step event_name (MS §12/§13.10) =="
# Both fields are OPTIONAL and additive: a v2 file carries them, a v1 file omits
# them and STILL parses (missing field != corrupt). The reference v2 half is the
# repo-root §13.4 join pair; the v1 half is a plugin-local fixture.
V2J="$JOIN_FIX/journeys.json"
V1J="$CH_FIX/journeys.v1.json"
assert_py "import json,sys; d=json.load(open('$V2J')); sys.exit(0 if d.get('schema_version')==2 else 1)" "CH-02: v2 journeys.json parses (schema_version==2)"
assert_py "import json,sys; d=json.load(open('$V1J')); sys.exit(0 if d.get('schema_version')==1 else 1)" "CH-02: v1 journeys.json still parses (missing field != corrupt, degrade rule)"
# v2 journey carries the backref; a vital v2 step carries event_name.
assert_py "import json,sys; j=json.load(open('$V2J'))['journeys'][0]; sys.exit(0 if j.get('manifest_journey_id') else 1)" "CH-02: v2 journey carries manifest_journey_id backref"
assert_py "import json,sys; s=json.load(open('$V2J'))['journeys'][0]['steps'][0]; sys.exit(0 if s.get('event_name') and s.get('vital_class') else 1)" "CH-02: v2 vital step carries event_name (real §12 row-2 join key)"
# additive proof: the v1 file has NEITHER new field.
assert_not_grep "$V1J" 'manifest_journey_id' "CH-02: v1 fixture omits manifest_journey_id (additive, not required)"
assert_not_grep "$V1J" 'event_name'          "CH-02: v1 fixture omits step event_name (additive, not required)"
# journey-trace.md schema doc bumped to v2 with both optional fields documented.
JT="$SKILL_SCRIPTS/../references/journey-trace.md"
assert_grep "$JT" 'schema_version.* 2'      "CH-02: journey-trace.md schema documented as v2"
assert_grep "$JT" 'manifest_journey_id'     "CH-02: journey-trace.md documents manifest_journey_id (journey-level)"
assert_grep "$JT" 'event_name'              "CH-02: journey-trace.md documents step event_name"
# the §13.4 backref points at an EXISTING manifest journeys[].id (not a dangling ref).
if have_validator; then
  MJID="$("${PYRUN[@]}" -c "import json; print(json.load(open('$V2J'))['journeys'][0]['manifest_journey_id'])" 2>/dev/null)"
  if [ -n "$MJID" ] && grep -qE "id:[[:space:]]*$MJID\b" "$JOIN_FIX/manifest.yaml"; then
    ok "CH-02: v2 backref ($MJID) points at an existing manifest journeys[].id (§13.4 pair)"
  else
    fail "CH-02: v2 backref points at an existing manifest journeys[].id (§13.4 pair) [mjid=$MJID]"
  fi
else
  echo "  [skip] validate_manifest.sh absent — CH-02 §13.4-pair backref check skipped"
fi

echo "== 16. CH-03 §12 intended↔discovered comparator — every row, full truth tables (MS §12) =="
# RED-FIRST: manifest_join.sh/.py are net-new. Manifest-reading + YAML, so this
# [skip]s loudly without the vendored validator/toolchain (blocked-on the drain).
if have_validator; then
  JOINSH="$SKILL_SCRIPTS/manifest_join.sh"
  MREF="$JOIN_FIX/manifest.yaml"; JREF="$JOIN_FIX/journeys.json"
  # helper: run the join into $WORK/join.out (extra args after journeys, e.g. --env=prod)
  JOIN() { if [ -n "${3:-}" ]; then bash "$JOINSH" "$1" "$2" "$3" > "$WORK/join.out" 2>&1; else bash "$JOINSH" "$1" "$2" > "$WORK/join.out" 2>&1; fi; }
  # helper: assert a ROW <kind> has verdict <verdict>
  row_is()  { if grep -qE "^ROW $1 $2\b" "$WORK/join.out"; then ok "$3"; else fail "$3 [got: $(grep -E "^ROW $1 " "$WORK/join.out" | head -1)]"; fi; }
  # helper: mutate the reference discovered journeys.json (exposes j=journey, s=step0)
  mut() { "${PYRUN[@]}" -c "import json; d=json.load(open('$JREF')); j=d['journeys'][0]; s=j['steps'][0]; $1; json.dump(d,open('$2','w'))"; }

  # manifest intent variants via portable single-line scalar swaps (no in-place sed).
  sed 's/required_emission: OBSERVED/required_emission: LOG-ONLY/' "$MREF" > "$WORK/m_logonly.yaml"
  sed 's/default: paged/default: dashboard-only/'                  "$MREF" > "$WORK/m_seamdash.yaml"
  sed 's/default: paged/default: none/'                            "$MREF" > "$WORK/m_seamnone.yaml"

  # ── reference pair: every row PASSes ──────────────────────────────────────
  JOIN "$MREF" "$JREF"
  row_is journey-backref PASS "CH-03 backref: exact manifest_journey_id match -> PASS"
  row_is criticality     PASS "CH-03 criticality: declared CORE == derived CORE -> PASS"
  row_is emission        PASS "CH-03 emission(OBSERVED): grade OBSERVED -> PASS"
  row_is seam            PASS "CH-03 seam(paged): discovered paged -> PASS"
  row_is idempotency     PASS "CH-03 idempotency(required): guard present -> PASS"
  assert_grep "$WORK/join.out" '^ROW compensation NOTE' "CH-03 compensation: informational NOTE (no pass/fail)"
  # CH-AMEND-A fingerprint scopes: step rows path:symbol; journey rows source(no line):name
  assert_grep "$WORK/join.out" 'ROW emission .*fpsrc=app/payments\.py:capture:manifest-emission-drift'                "CH-03 CH-AMEND-A: step row uses path:symbol fingerprint"
  assert_grep "$WORK/join.out" 'ROW criticality .*fpsrc=app/payments\.py:Payment capture:manifest-criticality-drift'  "CH-03 CH-AMEND-A: journey row uses <source-no-line>:<name> fingerprint (line stripped)"
  assert_not_grep "$WORK/join.out" 'fpsrc=app/payments\.py:12'  "CH-03 CH-AMEND-A: no line numbers leak into any fingerprint (audit-state-and-verify.md)"

  # ── emission lattice (rows 3+4): intent OBSERVED / LOG-ONLY × {OBSERVED,LOG-ONLY,DARK}
  mut "s['emission_grade']='LOG-ONLY'" "$WORK/j.json"; JOIN "$MREF" "$WORK/j.json"; row_is emission FAIL "CH-03 emission(OBSERVED): grade LOG-ONLY -> FAIL"
  mut "s['emission_grade']='DARK'"     "$WORK/j.json"; JOIN "$MREF" "$WORK/j.json"; row_is emission FAIL "CH-03 emission(OBSERVED): grade DARK -> FAIL"
  mut "s['emission_grade']='OBSERVED'" "$WORK/j.json"; JOIN "$WORK/m_logonly.yaml" "$WORK/j.json"; row_is emission PASS "CH-03 emission(LOG-ONLY): grade OBSERVED -> PASS"
  mut "s['emission_grade']='LOG-ONLY'" "$WORK/j.json"; JOIN "$WORK/m_logonly.yaml" "$WORK/j.json"; row_is emission PASS "CH-03 emission(LOG-ONLY): grade LOG-ONLY -> PASS"
  mut "s['emission_grade']='DARK'"     "$WORK/j.json"; JOIN "$WORK/m_logonly.yaml" "$WORK/j.json"; row_is emission FAIL "CH-03 emission(LOG-ONLY): grade DARK -> FAIL (DARK never satisfies)"
  # emission severity: DARK on a traced CORE money path -> HIGH (severity-rubric 1.4.0 amendment)
  mut "s['emission_grade']='DARK'"     "$WORK/j.json"; JOIN "$MREF" "$WORK/j.json"
  assert_grep "$WORK/join.out" '^ROW emission FAIL sev=HIGH' "CH-03 emission severity: DARK on traced CORE money path -> HIGH"

  # ── seam lattice (row 5) ──────────────────────────────────────────────────
  mut "s['alert_seam']='dashboard-only'" "$WORK/j.json"; JOIN "$MREF" "$WORK/j.json"; row_is seam FAIL "CH-03 seam(paged): discovered dashboard-only -> FAIL"
  mut "s['alert_seam']='unknown'"        "$WORK/j.json"; JOIN "$MREF" "$WORK/j.json"; row_is seam NEEDS-VERIFICATION "CH-03 seam(paged): discovered unknown -> NEEDS-VERIFICATION (not a violation)"
  mut "s['alert_seam']='paged'"          "$WORK/j.json"; JOIN "$WORK/m_seamdash.yaml" "$WORK/j.json"; row_is seam PASS "CH-03 seam(dashboard-only): discovered paged -> PASS (dashboard-only<-paged)"
  mut "s['alert_seam']='dashboard-only'" "$WORK/j.json"; JOIN "$WORK/m_seamdash.yaml" "$WORK/j.json"; row_is seam PASS "CH-03 seam(dashboard-only): discovered dashboard-only -> PASS"
  mut "s['alert_seam']='paged'"          "$WORK/j.json"; JOIN "$WORK/m_seamnone.yaml" "$WORK/j.json"; row_is seam PASS "CH-03 seam(none): discovered paged -> PASS (none<-anything)"
  mut "s['alert_seam']='unknown'"        "$WORK/j.json"; JOIN "$WORK/m_seamnone.yaml" "$WORK/j.json"; row_is seam PASS "CH-03 seam(none): discovered unknown -> PASS (unknown satisfies only intent none)"
  # env selection: env-keyed intent map collapses to the audited-env key
  mut "s['alert_seam']='dashboard-only'" "$WORK/j.json"
  JOIN "$CH_FIX/manifest.seam-env.yaml" "$WORK/j.json" "--env=prod";    row_is seam PASS "CH-03 seam env-collapse: --env=prod picks 'none' -> PASS against dashboard-only"
  JOIN "$CH_FIX/manifest.seam-env.yaml" "$WORK/j.json" "--env=default"; row_is seam FAIL "CH-03 seam env-collapse: --env=default picks 'paged' -> FAIL against dashboard-only"

  # ── idempotency lattice (row 6) ───────────────────────────────────────────
  mut "s['duplicate_guard']='absent'" "$WORK/j.json"; JOIN "$MREF" "$WORK/j.json"; row_is idempotency FAIL "CH-03 idempotency(required): guard absent -> FAIL"
  assert_grep "$WORK/join.out" '^ROW idempotency FAIL sev=HIGH' "CH-03 idempotency severity: absent on traced CORE money write -> HIGH (ADR-0004 blocking class)"
  mut "s['duplicate_guard']='n/a'"    "$WORK/j.json"; JOIN "$MREF" "$WORK/j.json"; row_is idempotency NEEDS-VERIFICATION "CH-03 idempotency(required): guard n/a -> NEEDS-VERIFICATION"

  # ── criticality drift (row 8) ─────────────────────────────────────────────
  mut "j['criticality']='SUPPORTING'" "$WORK/j.json"; JOIN "$MREF" "$WORK/j.json"; row_is criticality FAIL "CH-03 criticality: declared CORE != derived SUPPORTING -> FAIL (MED needs-verification)"
  assert_grep "$WORK/join.out" '^ROW criticality FAIL sev=MED' "CH-03 criticality drift caps at MED needs-verification"

  # ── backref fallbacks (row 1) + no-join not-covered ───────────────────────
  mut "j['manifest_journey_id']=None" "$WORK/j.json"; JOIN "$MREF" "$WORK/j.json"
  assert_grep "$WORK/join.out" 'backref=NAME' "CH-03 backref: absent id falls back to exact name match -> NAME"
  row_is journey-backref PASS "CH-03 backref: name-fallback still joins -> PASS"
  mut "j['manifest_journey_id']=None; j['name']='Totally Different Journey'" "$WORK/j.json"; JOIN "$MREF" "$WORK/j.json"
  row_is journey-backref NO-JOIN "CH-03 backref: absent id + non-matching name -> NO-JOIN"
  assert_grep     "$WORK/join.out" '\[not-covered\] journey' "CH-03 no-join: emits a Not-covered line (invariant 6)"
  assert_not_grep "$WORK/join.out" '^ROW criticality FAIL'   "CH-03 no-join: does NOT emit a false criticality drift finding"

  # ── event_name step join (row 2): non-matching discovered event -> not-covered
  mut "s['event_name']='some.other.event'" "$WORK/j.json"; JOIN "$MREF" "$WORK/j.json"
  assert_grep "$WORK/join.out" 'STEP pay.captured match=NONE'                "CH-03 step-join: manifest event_name with no discovered emitter -> match=NONE"
  assert_grep "$WORK/join.out" "\[not-covered\] step event_name 'pay.captured'" "CH-03 step-join: unmatched step is Not-covered, not a false drift finding"
else
  echo "  [skip] validate_manifest.sh absent — CH-03 §12 comparator truth tables skipped (blocked-on the spec-gen validator drain)"
fi

echo "== 17. CH-08 config-profile awareness for absence-severity (ADR 0006) =="
# The profile is a bare NAME string; the deterministic layer reads the name and
# degrades unknown -> default. It NEVER lifts the severity ceiling — the 1.4.0
# absence-severity cap holds regardless of profile (question floor, not ceiling).
if have_validator; then
  JOINSH="$SKILL_SCRIPTS/manifest_join.sh"; MREF="$JOIN_FIX/manifest.yaml"; JREF="$JOIN_FIX/journeys.json"
  # payments (recognized) is read by name off the reference manifest.
  bash "$JOINSH" "$MREF" "$JREF" > "$WORK/prof_known.out" 2>&1
  assert_grep "$WORK/prof_known.out" '^PROFILE payments recognized' "CH-08: comparator reads the profile name ('payments' recognized)"
  # unknown profile -> default + loud [note], no crash, no silent default.
  sed 's/profile: payments/profile: acme-nonexistent/' "$MREF" > "$WORK/m_unkprof.yaml"
  bash "$JOINSH" "$WORK/m_unkprof.yaml" "$JREF" > "$WORK/prof_unknown.out" 2>&1
  assert_grep "$WORK/prof_unknown.out" '^PROFILE acme-nonexistent unknown->default' "CH-08: unknown profile degrades to default"
  assert_grep "$WORK/prof_unknown.out" "\[note\] observability.profile 'acme-nonexistent' not recognized" "CH-08: unknown profile emits a loud [note] (no silent default)"
  assert_grep "$WORK/prof_unknown.out" '^ROW '  "CH-08: unknown profile does NOT crash — rows still emitted"
  # cap-holds: a DARK emission on an UNtraced (derived-SUPPORTING) step caps at
  # MED even under the payments profile — the profile cannot push an untraced
  # absence above the 1.4.0 rubric gate. (The SAME step on a traced CORE money
  # path is HIGH, asserted in CH-03 — proving it is the trace, never the profile,
  # that authorizes HIGH.)
  "${PYRUN[@]}" -c "import json; d=json.load(open('$JREF')); j=d['journeys'][0]; j['criticality']='SUPPORTING'; j['steps'][0]['emission_grade']='DARK'; json.dump(d,open('$WORK/j_untraced.json','w'))"
  bash "$JOINSH" "$MREF" "$WORK/j_untraced.json" > "$WORK/cap.out" 2>&1
  assert_grep     "$WORK/cap.out" '^ROW emission FAIL sev=MED'  "CH-08 cap: DARK on an untraced step under the payments profile stays MED"
  assert_not_grep "$WORK/cap.out" '^ROW emission FAIL sev=HIGH' "CH-08 cap: the profile cannot lift an untraced absence to HIGH (1.4.0 rubric gate holds)"
else
  echo "  [skip] validate_manifest.sh absent — CH-08 profile-awareness checks skipped (blocked-on the spec-gen validator drain)"
fi

echo "== 18. CH-04 PR Gate diff-scoped mode (ADR 0003; MS §13.10) =="
# git fixture (section-5 precedent): base commit + a diff introducing a marker.
# pr_gate over the base must FIRE the per-diff siblings on the positional
# BASE_REF, must NOT write journeys.json, and must NOT trigger a whole-repo walk.
PRG="$WORK/prg"; mkdir -p "$PRG"
( cd "$PRG"
  git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  printf 'def f():\n    return 1\n' > mod.py
  git add mod.py && git -c user.email=t@t -c user.name=t commit -qm add-mod
  printf '# TODO: finish the thing\ndef g():\n    return None\n' >> mod.py
  git add mod.py && git -c user.email=t@t -c user.name=t commit -qm add-debt )
BASECOMMIT="$(cd "$PRG" && git rev-parse HEAD~1)"
( cd "$PRG" && bash "$SKILL_SCRIPTS/pr_gate.sh" "$BASECOMMIT" ) > "$WORK/prg.out" 2>&1
assert_grep "$WORK/prg.out" 'PR Gate — diff-scoped mode' "CH-04: pr_gate announces diff-scoped mode"
assert_grep "$WORK/prg.out" 'TODO: finish the thing'     "CH-04: per-diff sibling (check_new_debt.sh) fires on the positional BASE_REF"
# whole-repo facets NOT invoked: no journeys.json written anywhere under the target
if [ -z "$(find "$PRG" -name journeys.json 2>/dev/null)" ]; then
  ok "CH-04: no journeys.json written in diff mode (whole-repo walk not triggered)"
else
  fail "CH-04: no journeys.json written in diff mode"
fi
assert_grep "$WORK/prg.out" 'journeys.json is never written here'                    "CH-04: pr_gate states it never writes journeys.json (ADR 0003 point 2)"
assert_grep "$WORK/prg.out" '\[not-covered\] rot-vs-journeys: no prior journeys.json' "CH-04 degrade: missing prior journeys.json -> loud Not-covered (never full-walks)"
assert_grep "$WORK/prg.out" '\[not-covered\] manifest-coverage .§12 join.: no manifest' "CH-04 degrade: missing manifest -> loud Not-covered"
# --diff is NOT a recognized flag on check_new_debt.sh (arg-parser contract): the
# token is swallowed as BASE and fails to resolve — never a silent clean pass.
( cd "$PRG" && bash "$SKILL_SCRIPTS/check_new_debt.sh" --diff ) > "$WORK/diffflag.out" 2>&1; rc=$?
if [ "$rc" -eq 1 ] && grep -q "cannot resolve base ref '--diff'" "$WORK/diffflag.out"; then
  ok "CH-04: --diff is NOT a recognized flag on check_new_debt.sh (swallowed as BASE — arg-parser contract protected)"
else
  fail "CH-04: --diff must be swallowed as BASE and fail to resolve (no --diff flag added) [rc=$rc]"
fi

echo "== 19. CH-05 memory-rot facet — deterministic layer (ADR 0003 point 1; ADR 0004) =="
# git fixture: a base defining symbols that memory (ADR + journeys + manifest)
# references, then a diff deleting/moving them. The deterministic layer flags a
# dangling ref, suppresses a tombstone, and aliases a rename.
ROT="$WORK/rot"; mkdir -p "$ROT"
( cd "$ROT"
  git init -q && git config user.email t@t && git config user.name t
  mkdir -p docs/adr src
  printf 'def transfer_funds(a, b):\n    return a + b\n\ndef keep_me():\n    return 1\n\ndef orphan_helper():\n    return 9\n' > src/billing.py
  printf 'def test_legacy_capture():\n    assert True\n' > src/legacy_test.py
  printf '# ADR 0001: money movement\ntransfer_funds is the money-movement entrypoint.\n' > docs/adr/0001-x.md
  printf '{ "schema_version": 2, "journeys": [ {"name":"Transfers","steps":[{"path":"src/billing.py","symbol":"transfer_funds","vital_class":"money"}]} ] }\n' > journeys.json
  cat > manifest.yaml <<'YAML'
schema_version: 1
manifest_revision: 1
behaviors:
  - id: B-legacy-001
    title: "Legacy capture"
    lifecycle: withdrawn
    withdrawn_reason: "capture path removed in favor of the new flow"
    test_name_hint: "test_legacy_capture"
    given: "x"
    when: "y"
    then: "z"
YAML
  git add -A && git commit -qm base
  # the change: delete transfer_funds (rot), delete the tombstoned test (suppress),
  # delete orphan_helper (clean — nothing references it), move keep_me (rename).
  printf 'def only_left():\n    return 2\n' > src/billing.py
  printf 'def keep_me():\n    return 1\n' > src/util.py
  rm src/legacy_test.py
  git add -A && git commit -qm change )
RBASE="$(cd "$ROT" && git rev-parse HEAD~1)"
( cd "$ROT" && bash "$SKILL_SCRIPTS/check_memory_rot.sh" "$RBASE" --manifest manifest.yaml --journeys journeys.json ) > "$WORK/rot.out" 2>&1
assert_grep     "$WORK/rot.out" "\[FINDING blocking\] memory-rot-dangling-ref: 'transfer_funds'" "CH-05: deleted symbol still referenced by manifest/journeys/ADR -> memory-rot-dangling-ref (blocking)"
assert_grep     "$WORK/rot.out" "fpsrc=src/billing\.py:transfer_funds:memory-rot-dangling-ref"    "CH-05: finding carries a path:symbol:slug fingerprint (no line number)"
assert_grep     "$WORK/rot.out" "rot-suppressed tombstone. 'test_legacy_capture'"                 "CH-05: lifecycle:withdrawn tombstone suppresses the rot finding (MS §6)"
assert_not_grep "$WORK/rot.out" "memory-rot-dangling-ref: 'test_legacy_capture'"                  "CH-05: tombstoned deletion emits NO dangling-ref finding"
assert_grep     "$WORK/rot.out" "rot-suppressed alias. rename: 'keep_me'"                         "CH-05: renamed/moved symbol is aliased (git-follow/symbol-grep), not flagged"
assert_not_grep "$WORK/rot.out" "memory-rot-dangling-ref: 'keep_me'"                              "CH-05: renamed symbol emits NO dangling-ref finding (rename is not closure)"
assert_not_grep "$WORK/rot.out" "memory-rot-dangling-ref: 'orphan_helper'"                        "CH-05: cleanly-deleted unreferenced symbol emits NO finding (precision)"

echo "== 20. CH-06 behavior-ID coverage — claimed vs proven (MS §13.11; ADR 0004) =="
# git fixture: a RED commit proves B-pay-001; a real test node proves B-pay-002;
# B-pay-003 is claimed but has neither -> the ADR-0004 blocking finding.
BCOV="$WORK/bcov"; mkdir -p "$BCOV"
( cd "$BCOV"
  git init -q && git config user.email t@t && git config user.name t
  git commit -q --allow-empty -m base
  mkdir -p tests
  printf 'def test_capture_is_idempotent():\n    assert True\n' > tests/test_capture.py
  git add -A && git commit -qm "RED B-pay-001 test_capture_is_idempotent: failing before impl"
  printf 'def test_refund_once():\n    assert True\n' > tests/test_refund.py
  git add -A && git commit -qm "add refund test node for B-pay-002" )
BCBASE="$(cd "$BCOV" && git rev-parse HEAD~2)"
cat > "$BCOV/manifest.yaml" <<'YAML'
schema_version: 1
behaviors:
  - id: B-pay-001
  - id: B-pay-002
  - id: B-pay-003
YAML
cat > "$BCOV/pr_mixed.md" <<'MD'
# PR
## Behavior coverage
- B-pay-001: tests/test_capture.py::test_capture_is_idempotent
- B-pay-002: tests/test_refund.py::test_refund_once
- B-pay-003: tests/test_missing.py::test_never_written
MD
cat > "$BCOV/pr_clean.md" <<'MD'
# PR
## Behavior coverage
- B-pay-001: tests/test_capture.py::test_capture_is_idempotent
- B-pay-002: tests/test_refund.py::test_refund_once
MD
( cd "$BCOV" && bash "$SKILL_SCRIPTS/check_behavior_coverage.sh" manifest.yaml pr_mixed.md "$BCBASE" ) > "$WORK/bcov_mixed.out" 2>&1; rc=$?
assert_grep "$WORK/bcov_mixed.out" '\[coverage\] B-pay-001 proven via RED-commit'       "CH-06: RED commit in range proves a claimed behavior"
assert_grep "$WORK/bcov_mixed.out" '\[coverage\] B-pay-002 proven via test-node'        "CH-06: an existing test node proves a claimed behavior"
assert_grep "$WORK/bcov_mixed.out" '\[FINDING blocking\] behavior-claimed-unproven: behavior B-pay-003' "CH-06: claimed-but-unproven behavior -> ADR-0004 blocking finding"
if [ "$rc" -eq 1 ]; then ok "CH-06: unproven claim yields a blocking exit (deterministic, may gate)"; else fail "CH-06: unproven claim yields a blocking exit [rc=$rc]"; fi
( cd "$BCOV" && bash "$SKILL_SCRIPTS/check_behavior_coverage.sh" manifest.yaml pr_clean.md "$BCBASE" ) > "$WORK/bcov_clean.out" 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then ok "CH-06: every claim proven -> clean pass (exit 0)"; else fail "CH-06: every claim proven -> clean pass [rc=$rc]"; fi
assert_not_grep "$WORK/bcov_clean.out" 'FINDING blocking' "CH-06: no blocking finding when every claimed behavior is proven"
# degrade: manifest absent -> skip + loud [note], never blocks a manifest-less PR
( cd "$BCOV" && bash "$SKILL_SCRIPTS/check_behavior_coverage.sh" /no/such/manifest.yaml pr_mixed.md "$BCBASE" ) > "$WORK/bcov_nomani.out" 2>&1; rc=$?
assert_grep "$WORK/bcov_nomani.out" '\[note\] no manifest' "CH-06 degrade: manifest absent -> loud [note] (MS §11)"
if [ "$rc" -eq 0 ]; then ok "CH-06 degrade: manifest-absent never blocks (exit 0)"; else fail "CH-06 degrade: manifest-absent never blocks [rc=$rc]"; fi

echo "== 21. CH-07 SG-8 provenance + main-lineage ID reservation (spec-gen SG-8; MS §6) =="
# git fixture: main seeds the manifest (reserving B-main-001); a never-merged
# branch hand-edits confirmation/completeness and adds B-branch-001.
PROV="$WORK/prov"; mkdir -p "$PROV"
( cd "$PROV"
  git init -q -b main && git config user.email t@t && git config user.name t
  cat > manifest.yaml <<'YAML'
schema_version: 1
manifest_revision: 1
completeness: incomplete
behaviors:
  - id: B-main-001
    confirmation: proposed
YAML
  git add -A && git commit -qm "main: seed manifest"
  git checkout -q -b feature/hand-edit
  cat > manifest.yaml <<'YAML'
schema_version: 1
manifest_revision: 2
completeness: complete
behaviors:
  - id: B-main-001
    confirmation: confirmed
  - id: B-branch-001
    confirmation: proposed
YAML
  git add -A && git commit -qm "hand-edit manifest confirmation/completeness" )
PMAIN="$(cd "$PROV" && git rev-parse main)"
# non-spec branch -> provenance finding (comment-only, CH-AMEND-C)
( cd "$PROV" && bash "$SKILL_SCRIPTS/check_provenance.sh" "$PMAIN" "feature/hand-edit" --manifest manifest.yaml --main-ref "$PMAIN" ) > "$WORK/prov_nonspec.out" 2>&1; rc=$?
assert_grep "$WORK/prov_nonspec.out" '\[FINDING comment-only\] sg8-provenance-hand-edit'      "CH-07: manifest single-writer edit from a non-spec branch -> provenance finding"
assert_grep "$WORK/prov_nonspec.out" 'COMMENT-ONLY .⟨CH-AMEND-C⟩'                              "CH-07: provenance finding ships comment-only (CH-AMEND-C, not silently promoted to blocking)"
if [ "$rc" -eq 0 ]; then ok "CH-07: comment-only provenance never blocks (exit 0)"; else fail "CH-07: comment-only provenance never blocks [rc=$rc]"; fi
# spec-session branch -> clean (the authorized single writer)
( cd "$PROV" && bash "$SKILL_SCRIPTS/check_provenance.sh" "$PMAIN" "spec/payments" --manifest manifest.yaml --main-ref "$PMAIN" ) > "$WORK/prov_spec.out" 2>&1
assert_grep     "$WORK/prov_spec.out" '\[clean\] provenance'          "CH-07: same edit from a spec-session branch -> clean (MS §7 authorized writer)"
assert_not_grep "$WORK/prov_spec.out" 'FINDING'                       "CH-07: spec-session edit emits no provenance finding"
# main-lineage reservation: main IDs reserved; never-merged-branch IDs not reserved
assert_grep "$WORK/prov_nonspec.out" '\[reserved\] B-main-001'        "CH-07: an ID on main's lineage IS reserved (MS §6)"
assert_grep "$WORK/prov_nonspec.out" '\[not-reserved\] B-branch-001'  "CH-07: an ID only on a never-merged branch is NOT reserved (⟨MS-AMEND-3⟩)"

echo "== 22. CH-09 spec_hash · manifest_revision monotonicity · ID reuse/renumber (MS §9/§11/§13.11) =="
# git-init inline fixture (section-5 precedent): a base rev-2 manifest on a
# lineage + a committed spec whose bytes hash to spec.spec_hash. Each check runs
# the current (working-tree) manifest against `git show <base>:manifest`.
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }
HIST="$WORK/hist"; mkdir -p "$HIST"
SPEC_LINE='Payment capture spec.'
HHASH="sha256:$(printf '%s\n' "$SPEC_LINE" | sha256_of)"
write_manifest() { cat > "$HIST/manifest.yaml"; }  # reads heredoc from stdin
( cd "$HIST"
  git init -q -b main && git config user.email t@t && git config user.name t
  printf '%s\n' "$SPEC_LINE" > payments.md )
cat > "$HIST/manifest.yaml" <<YAML
schema_version: 1
manifest_revision: 2
completeness: complete
spec:
  path: payments.md
  title: "Payment capture"
  spec_hash: "$HHASH"
behaviors:
  - id: B-pay-001
    title: "Captures once"
    lifecycle: active
  - id: B-pay-002
    title: "Refunds once"
    lifecycle: active
  - id: B-pay-003
    title: "Legacy path"
    lifecycle: withdrawn
    withdrawn_reason: "retired"
YAML
( cd "$HIST" && git add -A && git commit -qm "base rev2" )
HBASE="$(cd "$HIST" && git rev-parse HEAD)"
hist_run() { ( cd "$HIST" && bash "$SKILL_SCRIPTS/check_manifest_history.sh" manifest.yaml "$HBASE" ) > "$WORK/hist.out" 2>&1; hrc=$?; }

# clean counterpart: identical manifest -> every check clean, exit 0
hist_run
assert_grep "$WORK/hist.out" '\[clean\] spec_hash'          "CH-09 clean: recomputed spec_hash matches (complete manifest)"
assert_grep "$WORK/hist.out" '\[clean\] manifest_revision'  "CH-09 clean: revision monotonic"
assert_grep "$WORK/hist.out" '\[clean\] id reuse/renumber'  "CH-09 clean: no ID reuse/renumber/tombstone-reuse"
if [ "$hrc" -eq 0 ]; then ok "CH-09 clean: no blocking finding (exit 0)"; else fail "CH-09 clean exit 0 [rc=$hrc]"; fi
# the recompute matches the CANONICAL `git show :<path> | sha256sum` definition
CANON="sha256:$(cd "$HIST" && git show :payments.md | sha256_of)"
RECOMP="$(grep -oE 'recomputed sha256:[0-9a-f]{64}' "$WORK/hist.out" | sed 's/recomputed //')"
if [ "$RECOMP" = "$CANON" ]; then ok "CH-09: recompute equals canonical git show :<path> | sha256sum (byte-for-byte, shared definition)"; else fail "CH-09: recompute matches canonical byte-hash [recomp=$RECOMP canon=$CANON]"; fi

# spec_hash-mismatch: edit the committed spec, keep the declared hash -> comment-only rot (does NOT gate)
( cd "$HIST" && printf '%s\n' "$SPEC_LINE EDITED" > payments.md && git add payments.md )
hist_run
assert_grep "$WORK/hist.out" '\[FINDING comment-only\] spec-hash-rot' "CH-09: edited Spec + unchanged spec_hash -> spec-hash-rot (comment-only, MS §9)"
if [ "$hrc" -eq 0 ]; then ok "CH-09: spec-hash-rot is comment-only — does NOT gate (exit 0)"; else fail "CH-09: spec-hash-rot must not gate [rc=$hrc]"; fi
( cd "$HIST" && git checkout -q payments.md )

# monotonicity: content change, revision NOT bumped -> finding
write_manifest <<YAML
schema_version: 1
manifest_revision: 2
completeness: complete
spec:
  path: payments.md
  title: "Payment capture"
  spec_hash: "$HHASH"
behaviors:
  - id: B-pay-001
    title: "Captures once"
    lifecycle: active
  - id: B-pay-002
    title: "Refunds twice"
    lifecycle: active
  - id: B-pay-003
    title: "Legacy path"
    lifecycle: withdrawn
    withdrawn_reason: "retired"
YAML
hist_run
assert_grep "$WORK/hist.out" 'manifest-revision-non-monotonic' "CH-09: content change without a revision bump -> non-monotonic finding"

# ID-reuse: same ID bound to a different entry (rev bumped to isolate) -> blocking
write_manifest <<YAML
schema_version: 1
manifest_revision: 3
completeness: complete
spec:
  path: payments.md
  title: "Payment capture"
  spec_hash: "$HHASH"
behaviors:
  - id: B-pay-001
    title: "A completely different behavior"
    lifecycle: active
  - id: B-pay-002
    title: "Refunds once"
    lifecycle: active
  - id: B-pay-003
    title: "Legacy path"
    lifecycle: withdrawn
    withdrawn_reason: "retired"
YAML
hist_run
assert_grep "$WORK/hist.out" '\[FINDING blocking\] id-reuse: B-pay-001' "CH-09: ID reused for a different entry -> blocking (MS §11)"
if [ "$hrc" -eq 1 ]; then ok "CH-09: ID-reuse gates (blocking exit 1)"; else fail "CH-09: ID-reuse must gate [rc=$hrc]"; fi

# renumber: same entry, new ID -> blocking
write_manifest <<YAML
schema_version: 1
manifest_revision: 3
completeness: complete
spec:
  path: payments.md
  title: "Payment capture"
  spec_hash: "$HHASH"
behaviors:
  - id: B-pay-001
    title: "Captures once"
    lifecycle: active
  - id: B-pay-050
    title: "Refunds once"
    lifecycle: active
  - id: B-pay-003
    title: "Legacy path"
    lifecycle: withdrawn
    withdrawn_reason: "retired"
YAML
hist_run
assert_grep "$WORK/hist.out" "\[FINDING blocking\] id-renumber: entry 'Refunds once' renumbered B-pay-002 -> B-pay-050" "CH-09: entry renumbered -> blocking (MS §11)"

# tombstone-reuse: a withdrawn ID resurrected -> blocking (reserved forever)
write_manifest <<YAML
schema_version: 1
manifest_revision: 3
completeness: complete
spec:
  path: payments.md
  title: "Payment capture"
  spec_hash: "$HHASH"
behaviors:
  - id: B-pay-001
    title: "Captures once"
    lifecycle: active
  - id: B-pay-002
    title: "Refunds once"
    lifecycle: active
  - id: B-pay-003
    title: "A brand new behavior on a reused id"
    lifecycle: active
YAML
hist_run
assert_grep "$WORK/hist.out" '\[FINDING blocking\] id-tombstone-reuse: B-pay-003' "CH-09: reusing a tombstoned (withdrawn) ID -> blocking (MS §6, reserved forever)"

# incomplete manifest: spec_hash check skipped (⟨MS-AMEND-1⟩)
write_manifest <<YAML
schema_version: 1
manifest_revision: 3
completeness: incomplete
incomplete_fields: ["spec.spec_hash"]
spec:
  path: payments.md
  title: "Payment capture"
behaviors:
  - id: B-pay-001
    title: "Captures once"
    lifecycle: active
  - id: B-pay-002
    title: "Refunds once"
    lifecycle: active
  - id: B-pay-003
    title: "Legacy path"
    lifecycle: withdrawn
    withdrawn_reason: "retired"
YAML
hist_run
assert_grep "$WORK/hist.out" 'MS-AMEND-1' "CH-09: incomplete manifest -> spec_hash check skipped (⟨MS-AMEND-1⟩)"

echo "== 23. CH-10 consistency-lint host + uv migration (1.4.0 house rules) =="
# Repo-level cross-plugin lint (MS §13.3 vendoring host): schema byte-identity +
# the shared `## Behavior coverage` format. [skip]s outside the monorepo.
LINT="$REPO_ROOT/scripts/lint_consistency.sh"
if [ -x "$LINT" ]; then
  bash "$LINT" > "$WORK/lint.out" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then ok "CH-10: repo-level lint_consistency.sh passes (schema byte-identity + behavior-coverage format)"; else fail "CH-10: repo-level lint passes [rc=$rc]"; fi
  assert_grep "$WORK/lint.out" '\[V1\].*schema'                   "CH-10: V1 covers the vendored manifest schema copy (ADR 0001)"
  assert_grep "$WORK/lint.out" '\[V2\].*behavior-coverage format' "CH-10: V2 covers the shared ## Behavior coverage format (CH-06)"
  # the byte-identity rule has TEETH: a drifted vendored copy is caught.
  DR="$WORK/lintroot"; mkdir -p "$DR/schema/verification-manifest" "$DR/plugins/x/schema/verification-manifest"
  cp "$REPO_ROOT/schema/verification-manifest/v1.schema.json" "$DR/schema/verification-manifest/v1.schema.json"
  { cat "$REPO_ROOT/schema/verification-manifest/v1.schema.json"; echo '  // drifted byte'; } > "$DR/plugins/x/schema/verification-manifest/v1.schema.json"
  LINT_ROOT="$DR" bash "$LINT" > "$WORK/lint_drift.out" 2>&1; rc=$?
  assert_grep "$WORK/lint_drift.out" 'LINT-FAIL \[V1\].*DRIFTED' "CH-10: lint catches a drifted vendored schema copy (byte-identity has teeth)"
  if [ "$rc" -ne 0 ]; then ok "CH-10: lint exits non-zero on drift (a gate that would actually block)"; else fail "CH-10: lint must exit non-zero on drift [rc=$rc]"; fi
else
  echo "  [skip] repo-level scripts/lint_consistency.sh absent (standalone install) — CH-10 cross-plugin lint checks skipped"
fi
# the canonical behavior-coverage format doc is the ONE source both plugins vendor.
assert_grep "$REPO_ROOT/docs/specs/behavior-coverage-format.md" 'behavior-id.: .test-path.::.test-node' "CH-10: canonical ## Behavior coverage format pinned in one doc (CH-06 producer+consumer)"
# uv migration (ADR 0015): the plugin's Python routes through pyrun/uv, not bare python3.
assert_grep     "$SKILL_SCRIPTS/py_run.sh"         'uv run'    "CH-10 uv: py_run.sh defines the uv-first runner (ADR 0015)"
assert_grep     "$SKILL_SCRIPTS/run_audit.sh"      'pyrun '    "CH-10 uv: run_audit.sh jscpd-normalize routed through pyrun"
assert_grep     "$SKILL_SCRIPTS/check_new_debt.sh" 'pyrun '    "CH-10 uv: check_new_debt.sh hook-JSON routed through pyrun"
assert_not_grep "$SKILL_SCRIPTS/run_audit.sh"      'python3 -c' "CH-10 uv: no bare 'python3 -c' left in run_audit.sh"
assert_not_grep "$SKILL_SCRIPTS/check_new_debt.sh" 'python3 -c' "CH-10 uv: no bare 'python3 -c' left in check_new_debt.sh"

echo
echo "== self-test: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
