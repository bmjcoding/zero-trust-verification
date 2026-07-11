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

# ── Location anchors. This harness lives at tests/codebase-health/ (the repo's
# dev/test tree), two levels below the repo root; the plugin it exercises lives
# at plugins/codebase-health/. Both anchors are derived EXPLICITLY — HARNESS_DIR
# for the harness-local fixtures, REPO_ROOT for the shared repo-root artifacts —
# so `$dirname/..` heuristics (which would resolve to tests/, not the repo root)
# can never mis-derive the root and silently [skip] the CH-01..CH-10 wiring.
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
PLUGIN="$REPO_ROOT/plugins/codebase-health"
SKILL_SCRIPTS="$PLUGIN/skills/cleanup-audit/scripts"
FIXTURE_SRC="$HARNESS_DIR/test-fixtures/planted"

# ── PR-Gate / manifest wiring (CH-01..CH-10). The Verification-Manifest
# validator, its schema, and the §13.4 join fixture pair are repo-root
# artifacts vendored per ADR 0001 — CH items CONSUME them. In this monorepo
# they sit at the repo root ($REPO_ROOT); a standalone install would vendor
# them (and set $VALIDATE_MANIFEST). Every manifest-reading section below
# [skip]s loudly when the validator is absent (blocked-on the spec-gen drain),
# so this self-test stays green outside the monorepo — never a silent pass.
VALIDATE_MANIFEST="${VALIDATE_MANIFEST:-$REPO_ROOT/scripts/validate_manifest.sh}"
export VALIDATE_MANIFEST
JOIN_FIX="$REPO_ROOT/tests/fixtures/join"          # reference PASS pair (manifest.yaml + journeys.json v2)
MANIFEST_FIX="$REPO_ROOT/tests/fixtures/manifest"  # shared validator fixture suite (no second schema copy)
CH_FIX="$HARNESS_DIR/test-fixtures/pr-gate"        # plugin-local CH fail-variant / history / rot fixtures
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
git init -q && git config commit.gpgsign false && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
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
# ruff-conditional (3 assertions). ruff is NOT a mandated dev dependency
# (Decision 8: only jscpd is), but per ADR 0015 ("everything uv") we source it
# through uv (`uvx` = uv tool run) when it isn't already on PATH. It still
# [skip]s loudly if NEITHER PATH nor uv can provide it (offline / cold-cache
# degrade) — a missing optional linter is never a hard failure here.
RUFF=""
if command -v ruff >/dev/null 2>&1; then
  RUFF="ruff"
elif command -v uv >/dev/null 2>&1 && uvx ruff --version >/dev/null 2>&1; then
  RUFF="uvx ruff"
fi
if [ -n "$RUFF" ]; then
  RUFF_OUT="$($RUFF check --isolated --select C901 --config 'lint.mccabe.max-complexity=10' "$WORK/planted/planted_pkg/checkout.py" "$WORK/planted/planted_pkg/debughelpers.py" 2>/dev/null)"
  echo "$RUFF_OUT" | grep -q 'submit_order'   && ok "JC1 metric half: C901 fires for submit_order" || fail "JC1 metric half: C901 fires for submit_order"
  echo "$RUFF_OUT" | grep -q 'dump_state'     && ok "N10: C901 fires for dump_state (same profile, off-journey)" || fail "N10: C901 fires for dump_state (same profile, off-journey)"
  echo "$RUFF_OUT" | grep -q 'format_receipt' && fail "JC2: format_receipt stays metric-INVISIBLE (no C901)" || ok "JC2: format_receipt stays metric-INVISIBLE (no C901)"
else
  echo "  [skip] ruff unavailable (not on PATH and uv could not provide it) — 3 C901 journey-fixture integrity checks skipped"
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
  # the fp= hash is the canonical first-12-hex of sha1(path:symbol:slug) — recompute it independently.
  EXP_FP="$(printf '%s' 'app/payments.py:capture:manifest-emission-drift' | { command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum -a 1; } | cut -c1-12)"
  assert_grep "$WORK/join.out" "fp=$EXP_FP" "CH-03: emission fp == first-12-hex sha1(path:symbol:slug), independently recomputed"

  # ── emission lattice (rows 3+4): intent OBSERVED / LOG-ONLY × {OBSERVED,LOG-ONLY,DARK}
  mut "s['emission_grade']='LOG-ONLY'" "$WORK/j.json"; JOIN "$MREF" "$WORK/j.json"; row_is emission FAIL "CH-03 emission(OBSERVED): grade LOG-ONLY -> FAIL"
  mut "s['emission_grade']='DARK'"     "$WORK/j.json"; JOIN "$MREF" "$WORK/j.json"; row_is emission FAIL "CH-03 emission(OBSERVED): grade DARK -> FAIL"
  mut "s['emission_grade']='OBSERVED'" "$WORK/j.json"; JOIN "$WORK/m_logonly.yaml" "$WORK/j.json"; row_is emission PASS "CH-03 emission(LOG-ONLY): grade OBSERVED -> PASS"
  mut "s['emission_grade']='LOG-ONLY'" "$WORK/j.json"; JOIN "$WORK/m_logonly.yaml" "$WORK/j.json"; row_is emission PASS "CH-03 emission(LOG-ONLY): grade LOG-ONLY -> PASS"
  mut "s['emission_grade']='DARK'"     "$WORK/j.json"; JOIN "$WORK/m_logonly.yaml" "$WORK/j.json"; row_is emission FAIL "CH-03 emission(LOG-ONLY): grade DARK -> FAIL (DARK never satisfies)"
  # emission severity: DARK on a traced CORE money path -> HIGH (severity-rubric 1.4.0 amendment)
  mut "s['emission_grade']='DARK'"     "$WORK/j.json"; JOIN "$MREF" "$WORK/j.json"
  assert_grep     "$WORK/join.out" '^ROW emission FAIL sev=HIGH'                "CH-03 emission severity: DARK on traced CORE money path -> HIGH"
  assert_not_grep "$WORK/join.out" '^ROW emission FAIL sev=HIGH.*needs-verification' "CH-03: a confirmed HIGH carries NO needs-verification mark (rubric; annotation not inverted)"

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
  assert_grep     "$WORK/cap.out" '^ROW emission FAIL sev=MED .*needs-verification' "CH-08: an untraced/unconfirmed capped MED absence carries needs-verification (rubric)"
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
  git init -q && git config commit.gpgsign false && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
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
  git init -q && git config user.email t@t && git config user.name t && git config commit.gpgsign false
  mkdir -p docs/adr src
  printf 'def transfer_funds(a, b):\n    return a + b\n\ndef keep_me():\n    return 1\n\ndef orphan_helper():\n    return 9\n' > src/billing.py
  printf 'def test_legacy_capture():\n    assert True\n' > src/legacy_test.py
  printf '# ADR 0001: money movement\ntransfer_funds is the money-movement entrypoint; keep_me is a stable helper.\n' > docs/adr/0001-x.md
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
( cd "$ROT" && bash "$SKILL_SCRIPTS/check_memory_rot.sh" "$RBASE" --manifest manifest.yaml --journeys journeys.json ) > "$WORK/rot.out" 2>&1; rot_rc=$?
assert_grep     "$WORK/rot.out" "\[FINDING blocking\] memory-rot-dangling-ref: 'transfer_funds'" "CH-05: deleted symbol still referenced by manifest/journeys/ADR -> memory-rot-dangling-ref (blocking)"
assert_grep     "$WORK/rot.out" "fpsrc=src/billing\.py:transfer_funds:memory-rot-dangling-ref"    "CH-05: finding carries a path:symbol:slug fingerprint (no line number)"
assert_grep     "$WORK/rot.out" "rot-suppressed tombstone. 'test_legacy_capture'"                 "CH-05: lifecycle:withdrawn tombstone suppresses the rot finding (MS §6)"
assert_not_grep "$WORK/rot.out" "memory-rot-dangling-ref: 'test_legacy_capture'"                  "CH-05: tombstoned deletion emits NO dangling-ref finding"
assert_grep     "$WORK/rot.out" "rot-suppressed alias. rename: 'keep_me'"                         "CH-05: renamed/moved symbol (referenced by the ADR) is aliased, not flagged"
assert_not_grep "$WORK/rot.out" "memory-rot-dangling-ref: 'keep_me'"                              "CH-05: renamed symbol emits NO dangling-ref finding (rename is not closure; load-bearing — ADR references keep_me)"
assert_not_grep "$WORK/rot.out" "memory-rot-dangling-ref: 'orphan_helper'"                        "CH-05: cleanly-deleted unreferenced symbol emits NO finding (precision)"
# CH-05 blocking class raises the CI-surface exit (mirrors CH-06/CH-09) so
# pr_gate's aggregate high-water can consult it — not silently exit-0.
if [ "$rot_rc" -eq 1 ]; then ok "CH-05: a dangling-ref finding exits 1 (ADR-0004 blocking; pr_gate aggregates it)"; else fail "CH-05: dangling-ref must exit 1 [rc=$rot_rc]"; fi
( cd "$ROT" && bash "$SKILL_SCRIPTS/check_memory_rot.sh" HEAD --manifest manifest.yaml --journeys journeys.json ) >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then ok "CH-05: no deletions (HEAD==worktree) -> no finding, exit 0"; else fail "CH-05: clean diff must exit 0 [rc=$rc]"; fi

echo "== 20. CH-06 behavior-ID coverage — claimed vs proven (MS §13.11; ADR 0004) =="
# git fixture: a RED commit proves B-pay-001; a real test node proves B-pay-002;
# B-pay-003 is claimed but has neither -> the ADR-0004 blocking finding.
BCOV="$WORK/bcov"; mkdir -p "$BCOV"
( cd "$BCOV"
  git init -q && git config user.email t@t && git config user.name t && git config commit.gpgsign false
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
# PROOF INTEGRITY (adversarial fix): a bare MENTION of the test node (a comment,
# no real def/it/test) must NOT count as proof — else the gate is trivially defeated.
printf '# TODO: someday write test_ghost for the ghost path\n' > "$BCOV/tests/test_ghost.py"
cat >> "$BCOV/manifest.yaml" <<'YAML'
  - id: B-pay-004
YAML
cat > "$BCOV/pr_ghost.md" <<'MD'
# PR
## Behavior coverage
- B-pay-004: tests/test_ghost.py::test_ghost
MD
( cd "$BCOV" && bash "$SKILL_SCRIPTS/check_behavior_coverage.sh" manifest.yaml pr_ghost.md "$BCBASE" ) > "$WORK/bcov_ghost.out" 2>&1; rc=$?
assert_grep     "$WORK/bcov_ghost.out" '\[FINDING blocking\] behavior-claimed-unproven: behavior B-pay-004' "CH-06 proof integrity: a comment-only mention of the test node does NOT prove -> blocking"
assert_not_grep "$WORK/bcov_ghost.out" 'B-pay-004 proven via test-node'                                    "CH-06 proof integrity: no false 'proven via test-node' on a comment-only mention"
if [ "$rc" -eq 1 ]; then ok "CH-06 proof integrity: fabricated coverage claim gates (exit 1)"; else fail "CH-06 proof integrity: fabricated claim must gate [rc=$rc]"; fi

echo "== 21. CH-07 SG-8 provenance + main-lineage ID reservation (spec-gen SG-8; MS §6) =="
# git fixture: main seeds the manifest (reserving B-main-001); a never-merged
# branch hand-edits confirmation/completeness and adds B-branch-001.
PROV="$WORK/prov"; mkdir -p "$PROV"
( cd "$PROV"
  git init -q -b main && git config user.email t@t && git config user.name t && git config commit.gpgsign false
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
  git init -q -b main && git config user.email t@t && git config user.name t && git config commit.gpgsign false
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

# cross-kind guard (adversarial fix): a journey `name` and a behavior `title`
# that share a label must NOT collide in the renumber check. Prior lists the
# BEHAVIOR first (so an unfiltered label lookup would attribute the journey's
# renumber to the behavior). Renumbering only the journey must name the JOURNEY.
HX="$WORK/histx"; mkdir -p "$HX"
( cd "$HX"
  git init -q -b main && git config user.email t@t && git config user.name t && git config commit.gpgsign false
  cat > manifest.yaml <<'YAML'
schema_version: 1
manifest_revision: 1
completeness: incomplete
incomplete_fields: ["spec.spec_hash"]
behaviors:
  - id: B-cap-001
    title: "Capture"
    lifecycle: active
journeys:
  - id: J-cap-001
    name: "Capture"
    lifecycle: active
YAML
  git add -A && git commit -qm base )
HXBASE="$(cd "$HX" && git rev-parse HEAD)"
cat > "$HX/manifest.yaml" <<'YAML'
schema_version: 1
manifest_revision: 2
completeness: incomplete
incomplete_fields: ["spec.spec_hash"]
behaviors:
  - id: B-cap-001
    title: "Capture"
    lifecycle: active
journeys:
  - id: J-cap-002
    name: "Capture"
    lifecycle: active
YAML
( cd "$HX" && bash "$SKILL_SCRIPTS/check_manifest_history.sh" manifest.yaml "$HXBASE" ) > "$WORK/histx.out" 2>&1
assert_grep     "$WORK/histx.out" 'id-renumber: entry .Capture. renumbered J-cap-001 -> J-cap-002' "CH-09 cross-kind: renumber names the JOURNEY (J-cap-001 -> J-cap-002)"
assert_not_grep "$WORK/histx.out" 'renumbered B-cap-001'                                            "CH-09 cross-kind: a shared label does NOT attribute the journey renumber to the behavior"

# non-integer revision (adversarial fix): a schema-defect revision must be said
# out loud and skipped, never routed around with a bogus '[clean] monotonic'.
cat > "$HX/manifest.yaml" <<'YAML'
schema_version: 1
manifest_revision: 1.2
completeness: incomplete
incomplete_fields: ["spec.spec_hash"]
behaviors:
  - id: B-cap-001
    title: "Capture edited"
    lifecycle: active
journeys:
  - id: J-cap-001
    name: "Capture"
    lifecycle: active
YAML
( cd "$HX" && bash "$SKILL_SCRIPTS/check_manifest_history.sh" manifest.yaml "$HXBASE" ) > "$WORK/histni.out" 2>&1
assert_grep     "$WORK/histni.out" 'manifest_revision non-integer' "CH-09: non-integer manifest_revision -> loud note, monotonicity skipped (not routed around)"
assert_not_grep "$WORK/histni.out" '\[clean\] manifest_revision'   "CH-09: a non-integer revision never prints a bogus '[clean] ... monotonic'"

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

echo "== 24. MT-01 mutation adapter map — survivor→file:line resolver (ADR 0016) =="
# Hermetic: canned tool outputs (NO mutation tool is ever run) → normalized
# `<path>:<line>` survivor set. tests/fixtures/mutation/ is the ONE source; the
# autopilot vendored copy of mutation_adapter.sh is byte-pinned by root lint V7.
ADAPTER="$SKILL_SCRIPTS/mutation_adapter.sh"
MUTFIX="$REPO_ROOT/tests/fixtures/mutation"
if [ -x "$ADAPTER" ] && [ -d "$MUTFIX" ]; then
  # normalize each tool's raw output and compare to the expected set, byte-for-byte.
  mt_case() {  # <tool> <raw-file> <expected-file> <label>
    local got; got="$(bash "$ADAPTER" normalize "$1" < "$MUTFIX/$2" 2>/dev/null)"
    if [ "$got" = "$(cat "$MUTFIX/$3")" ]; then ok "$4"; else fail "$4 — got [$got]"; fi
  }
  mt_case stryker       stryker.raw.json stryker.expected.txt "MT-01 stryker: Survived mutants → file:line (Killed/NoCoverage excluded, LINE)"
  mt_case cargo-mutants cargo.raw.txt    cargo.expected.txt   "MT-01 cargo-mutants: missed.txt file:line:col → file:line (LINE)"
  mt_case mutmut        mutmut.raw.txt   mutmut.expected.txt  "MT-01 mutmut: 'mutmut show' unified diff → file:line (post-hoc)"
  mt_case go-mutesting  go.raw.txt       go.expected.txt      "MT-01 go-mutesting: FAIL survivor → file:- (no line resolver degrades to FILE granularity)"
  gogot="$(bash "$ADAPTER" normalize go-mutesting < "$MUTFIX/go.raw.txt" 2>/dev/null)"
  # the degrade acceptance is explicit: EVERY go-mutesting survivor is file-granular.
  if printf '%s\n' "$gogot" | grep -q ':-$' && ! printf '%s\n' "$gogot" | grep -qE ':[0-9]+$'; then
    ok "MT-01 degrade: a tool with no line resolver yields only file-granular '<path>:-' survivors"
  else fail "MT-01 degrade: go-mutesting must yield only '<path>:-' rows [$gogot]"; fi
  # PASS (killed) lines are NOT survivors — precision guard (settled.go is PASS-only).
  if printf '%s\n' "$gogot" | grep -q 'settled\.go'; then
    fail "MT-01 go-mutesting: a PASS (killed) mutant leaked into the survivor set [$gogot]"
  else ok "MT-01 go-mutesting: PASS (killed) mutants are excluded from survivors (precision)"; fi
  # usage contract: unknown tool is a usage error (64), not a silent empty pass.
  bash "$ADAPTER" normalize no-such-tool </dev/null >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 64 ]; then ok "MT-01 usage: unknown tool → exit 64 (never a silent empty survivor set)"; else fail "MT-01 usage: unknown tool must exit 64 [rc=$rc]"; fi
else
  echo "  [skip] mutation_adapter.sh and/or tests/fixtures/mutation absent — MT-01 resolver checks skipped (standalone install)"
fi

echo "== 25. MT-04/05/06 PR-Gate mutation sibling — ingest-only, criticality join (ADR 0016) =="
# git fixture: base + a change adding line 3 to a CORE money file (pay.py) and a
# non-CORE file (util.py); an ingested cargo report with survivors on both changed
# lines plus one OFF-diff survivor. The sibling READS the report, NEVER runs a tool.
SIB="$SKILL_SCRIPTS/check_mutation_survivors.sh"
if [ -x "$SIB" ]; then
  MUT="$WORK/mutsib"; mkdir -p "$MUT/app" "$MUT/audit"
  ( cd "$MUT"
    git init -q && git config user.email t@t && git config user.name t && git config commit.gpgsign false
    printf 'def capture(a):\n    return charge(a)\n' > app/pay.py
    printf 'def fmt(x):\n    return str(x)\n' > app/util.py
    git add -A && git commit -qm base
    printf 'def capture(a):\n    return charge(a)\n    log(a)\n' > app/pay.py
    printf 'def fmt(x):\n    return str(x)\n    trace(x)\n' > app/util.py
    git add -A && git commit -qm change )
  MUTBASE="$(cd "$MUT" && git rev-parse HEAD~1)"
  cat > "$MUT/journeys.json" <<'J'
{ "schema_version": 2, "journeys": [
  { "name": "Payment", "criticality": "CORE", "steps": [ {"path": "app/pay.py", "symbol": "capture", "vital_class": "money"} ] },
  { "name": "Format",  "criticality": "SUPPORTING", "steps": [ {"path": "app/util.py", "symbol": "fmt", "vital_class": "none"} ] }
] }
J
  cat > "$MUT/audit/mutation_cargo_missed.txt" <<'R'
3 mutants tested, 3 missed
app/pay.py:3:5: replace log with ()
app/util.py:3:5: replace trace with ()
app/pay.py:99:1: replace capture with ()
R

  # MT-04/⟨MT-AMEND-A⟩ — soak default: CORE survivor is COMMENT-ONLY (never blocks).
  ( cd "$MUT" && bash "$SIB" "$MUTBASE" --report audit/mutation_cargo_missed.txt --journeys journeys.json ) > "$WORK/mut_soak.out" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then ok "MT-04 soak: CORE survivor never blocks by default (exit 0)"; else fail "MT-04 soak: must not block by default [rc=$rc]"; fi
  assert_grep     "$WORK/mut_soak.out" 'report-only during the ADR-0004 soak' "MT-04 soak: CORE survivor reported comment-only (⟨MT-AMEND-A⟩ report-only-first)"
  assert_grep     "$WORK/mut_soak.out" 'mutant-on-core-path'                  "MT-09 consumer token 'mutant-on-core-path' present in the PR-Gate sibling"
  assert_not_grep "$WORK/mut_soak.out" 'BLOCKED'                              "MT-04 soak: no blocking finding smuggled in (report-only posture)"
  assert_grep     "$WORK/mut_soak.out" 'app/util.py:3 .*NOT traced CORE'      "MT-05: non-CORE survivor on a changed line is comment-only"
  assert_not_grep "$WORK/mut_soak.out" 'app/pay.py:99'                        "MT-05 ratchet: off-diff (inherited) survivor is not a finding (ADR 0004)"

  # MT-04 strictness contract — promotion + strict blocks; both escape hatches release.
  ( cd "$MUT" && bash "$SIB" "$MUTBASE" --report audit/mutation_cargo_missed.txt --journeys journeys.json --promote-core ) > "$WORK/mut_block.out" 2>&1; rc=$?
  if [ "$rc" -eq 1 ]; then ok "MT-04: promoted CORE survivor blocks under strict (exit 1)"; else fail "MT-04: promoted+strict must block [rc=$rc]"; fi
  assert_grep "$WORK/mut_block.out" '\[BLOCKED: mutant-on-core-path\]' "MT-04: blocking finding names the mutant-on-core-path class"
  ( cd "$MUT" && bash "$SIB" "$MUTBASE" --report audit/mutation_cargo_missed.txt --journeys journeys.json --promote-core --no-strict ) >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then ok "MT-04 escape hatch: --no-strict → warn-and-exit-0"; else fail "MT-04: --no-strict must exit 0 [rc=$rc]"; fi
  ( cd "$MUT" && WARN_ONLY=1 bash "$SIB" "$MUTBASE" --report audit/mutation_cargo_missed.txt --journeys journeys.json --promote-core ) >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then ok "MT-04 escape hatch: WARN_ONLY=1 → warn-and-exit-0"; else fail "MT-04: WARN_ONLY=1 must exit 0 [rc=$rc]"; fi

  # MT-06 — journeys absent/degraded → CORE class caps at comment-only even PROMOTED.
  ( cd "$MUT" && bash "$SIB" "$MUTBASE" --report audit/mutation_cargo_missed.txt --promote-core ) > "$WORK/mut_deg.out" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then ok "MT-06: absent journeys → comment-only cap, never blocks (even promoted)"; else fail "MT-06: degraded trace must not block [rc=$rc]"; fi
  assert_grep     "$WORK/mut_deg.out" 'criticality is unknown; capped comment-only .MT-06' "MT-06: unknown criticality → comment-only (agent opinion without deterministic evidence never blocks)"
  assert_not_grep "$WORK/mut_deg.out" 'BLOCKED'                                             "MT-06: no block without a deterministic criticality field"
  # degraded-journeys guard: a malformed journeys.json is degraded, not a crash-block.
  printf '{ not json' > "$MUT/bad.json"
  ( cd "$MUT" && bash "$SIB" "$MUTBASE" --report audit/mutation_cargo_missed.txt --journeys bad.json --promote-core ) > "$WORK/mut_bad.out" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then ok "MT-06: malformed journeys.json degrades to comment-only (exit 0, no crash-block)"; else fail "MT-06: malformed journeys must degrade, not block [rc=$rc]"; fi

  # MT-08 — no ingested report → loud [not-covered], never blocks.
  ( cd "$MUT" && bash "$SIB" "$MUTBASE" --report audit/absent.txt --journeys journeys.json --promote-core ) > "$WORK/mut_none.out" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then ok "MT-08 PR-side: no ingested report → exit 0 (never blocks)"; else fail "MT-08: absent report must not block [rc=$rc]"; fi
  assert_grep "$WORK/mut_none.out" '\[not-covered\] mutation survivors: no ingested' "MT-08 PR-side: absent report → loud Not-covered (never silent)"

  # MT-05 — file-granular survivor (go-mutesting) cannot be pinned to a changed line.
  printf 'FAIL "app/pay.go.1" with checksum\ntotal is 1\n' > "$MUT/audit/mutation_go.txt"
  ( cd "$MUT" && bash "$SIB" "$MUTBASE" --report audit/mutation_go.txt --journeys journeys.json --promote-core ) > "$WORK/mut_fg.out" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then ok "MT-05: file-granular survivor → comment-only, exit 0 (never blocks)"; else fail "MT-05: file-granular must not block [rc=$rc]"; fi
  assert_grep "$WORK/mut_fg.out" 'file-granular .no line resolver' "MT-05: file-granular survivor is comment-only (line filter is post-hoc)"

  # MT-04 — pr_gate.sh aggregates the sibling and STAYS warn-only (exit 0), even when
  # the report is supplied; without a report → mutation facet in Not-covered.
  ( cd "$MUT" && bash "$SKILL_SCRIPTS/pr_gate.sh" "$MUTBASE" --journeys journeys.json \
      --mutation-report audit/mutation_cargo_missed.txt ) > "$WORK/mut_prg.out" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then ok "MT-04: pr_gate stays warn-only (exit 0) with the mutation sibling composed in"; else fail "MT-04: pr_gate must stay warn-only [rc=$rc]"; fi
  assert_grep "$WORK/mut_prg.out" 'check_mutation_survivors.sh' "MT-04: pr_gate composes the mutation sibling (run_sibling pattern)"
  ( cd "$MUT" && bash "$SKILL_SCRIPTS/pr_gate.sh" "$MUTBASE" --journeys journeys.json ) > "$WORK/mut_prg2.out" 2>&1
  assert_grep "$WORK/mut_prg2.out" '\[not-covered\] mutation survivors: no ingested report supplied' "MT-04: pr_gate with no report → mutation facet in Not-covered (degrade)"
else
  echo "  [skip] check_mutation_survivors.sh absent — MT-04/05/06 checks skipped (standalone install)"
fi

# ==============================================================================
# Remediation loop (RL-01..RL-12) — deterministic substrate (ADR 0017/0018).
# The loop is WIRING, not a checker: every assertion below is a deterministic
# script call / grep / fixture, never agent judgment. Report-only/advisory-first
# posture is asserted structurally (no merge, no blocking path). RED-FIRST: the
# RL-0x scripts do not exist until the loop lands, so every assertion here fails
# on two consecutive runs before implementation (invariant 9).
# ==============================================================================
REM="$SKILL_SCRIPTS"
REMFIX="$HARNESS_DIR/test-fixtures/remediation"
AP="$REPO_ROOT/plugins/autopilot/scripts"

echo "== RL-00. loop file set present (non-vacuity gate: a deleted loop script is a RED, never a silent skip) =="
# The whole loop ships as one unit. Assert every file exists so a later section
# gated on `[ -f <script> ]` can never SILENTLY pass by skipping (the mock-hidden
# gap the Marshal-P0 lesson warns about).
for rl in read_findings.sh finding_eligible.sh classify_fix.sh remediation_route.sh \
          remediation_depth.sh already_filed.sh remediation_stamp.sh \
          remediation_scope_guard.sh build_register.sh remediation_state.py remediation_lib.sh \
          slug_provenance.tsv; do
  [ -f "$REM/$rl" ] && ok "RL-00: loop file present: $rl" || fail "RL-00: loop file MISSING: $rl (the loop is one unit)"
done
[ -f "$PLUGIN/skills/cleanup-audit/remediation.config.yaml" ] && ok "RL-00: shipped remediation.config.yaml present" || fail "RL-00: remediation.config.yaml missing"
[ -f "$PLUGIN/commands/remediate.md" ] && ok "RL-00: /remediate command present" || fail "RL-00: /remediate command missing"
[ -f "$PLUGIN/skills/cleanup-audit/references/remediation-loop.md" ] && ok "RL-00: remediation-loop.md reference present" || fail "RL-00: remediation-loop.md reference missing"

echo "== RL-01. finding-stream reader (read_findings.sh; ADR 0017 step 1; invariant 1) =="
if [ -f "$REM/read_findings.sh" ]; then
  bash "$REM/read_findings.sh" "$REMFIX/state_v2.json" > "$WORK/rl_rows.txt" 2>/dev/null
  assert_grep     "$WORK/rl_rows.txt" "bbbb2222dark.*dark-money-movement.*OPEN"  "RL-01: OPEN finding normalized (fp|sev|slug|path|symbol|status|remediation_status)"
  assert_not_grep "$WORK/rl_rows.txt" "ffff6666wont"                            "RL-01: WONTFIX finding is NOT emitted (loop reads OPEN work only)"
  assert_grep     "$WORK/rl_rows.txt" "eeee5555filed.*PR_OPEN"                  "RL-01: an OPEN finding carrying a PR_OPEN remediation record surfaces its remediation_status"
  nf="$(head -1 "$WORK/rl_rows.txt" | awk -F'\t' '{print NF}')"
  if [ "${nf:-0}" = "7" ]; then ok "RL-01: exactly 7 columns — NO fabricated expected_by column (Defect A)"; else fail "RL-01: expected 7 columns, got ${nf:-0} (expected_by must NOT be fabricated)"; fi
  bash "$REM/read_findings.sh" "$REMFIX/state_corrupt.json" > "$WORK/rl_cor.out" 2>"$WORK/rl_cor.err"; rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$WORK/rl_cor.out" ]; then ok "RL-01: corrupt state -> zero rows, exit 0 (invariant 4)"; else fail "RL-01: corrupt state must emit nothing + exit 0 [rc=$rc]"; fi
  assert_grep "$WORK/rl_cor.err" "note.*emitting nothing" "RL-01: corrupt-state degrade emits a loud [note] (never silent, never a guessed row)"
  bash "$REM/read_findings.sh" "$REMFIX/state_badschema.json" > "$WORK/rl_bad.out" 2>/dev/null; rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$WORK/rl_bad.out" ]; then ok "RL-01: unknown schema_version -> zero rows, exit 0"; else fail "RL-01: unknown schema must emit nothing + exit 0 [rc=$rc]"; fi
  bash "$REM/read_findings.sh" "$REMFIX/state_v2.json" --from-pr-gate "$REMFIX/pr_gate_capture.txt" > "$WORK/rl_prg.out" 2>/dev/null
  assert_grep "$WORK/rl_prg.out" "memory-rot-dangling-ref.*src/a.py.*foo.*OPEN" "RL-01: --from-pr-gate ingests a captured FINDING line (blocking->HIGH); never re-runs the gate"
else
  fail "RL-01: read_findings.sh absent (red-first: implement to green)"
fi

echo "== RL-02. eligibility gate (finding_eligible.sh; severity floor ∧ deterministic provenance) =="
if [ -f "$REM/finding_eligible.sh" ]; then
  printf 'severity_floor: MED\n' > "$WORK/rl_floor_med.yaml"
  assert_grep <(bash "$REM/finding_eligible.sh" --severity HIGH --slug dark-money-movement)    "^ELIGIBLE$"                    "RL-02: HIGH + deterministic slug -> ELIGIBLE"
  assert_grep <(bash "$REM/finding_eligible.sh" --severity HIGH --slug non-idempotent-handler) "INELIGIBLE:agent-evidence-only" "RL-02: HIGH + agent-scored slug -> INELIGIBLE(agent-evidence-only) (ADR 0004)"
  assert_grep <(bash "$REM/finding_eligible.sh" --severity MED  --slug giant-file)             "INELIGIBLE:below-floor"        "RL-02: MED + deterministic slug -> INELIGIBLE(below-floor) (default HIGH)"
  assert_grep <(bash "$REM/finding_eligible.sh" --severity MED  --slug giant-file --config "$WORK/rl_floor_med.yaml") "^ELIGIBLE$" "RL-02: config floor=MED flips the MED case -> ELIGIBLE"
  assert_grep <(bash "$REM/finding_eligible.sh" --severity HIGH --slug brand-new-unmapped-slug) "INELIGIBLE:unknown-provenance" "RL-02: unknown slug -> INELIGIBLE(unknown-provenance) (fail-safe toward inaction)"
else
  fail "RL-02: finding_eligible.sh absent (red-first)"
fi

echo "== RL-03. escalate-class routing table (classify_fix.sh; ADR 0002 trilist, lint-pinned V10) =="
if [ -f "$REM/classify_fix.sh" ]; then
  for s in marker dead-code commented-code suppression memory-rot-dangling-ref giant-file test-skip vacuous-test missing-behavior-binding; do
    assert_grep <(bash "$REM/classify_fix.sh" "$s") "^DRAIN$" "RL-03: drain-class slug '$s' -> DRAIN"
  done
  for s in non-idempotent-handler missing-dedup-guard unsafe-retry double-submit-window missing-compensation missing-audit-trail dark-money-movement log-only-refund security/authn; do
    assert_grep <(bash "$REM/classify_fix.sh" "$s") "^ESCALATE$" "RL-03: escalate-class slug '$s' -> ESCALATE"
  done
  assert_grep <(bash "$REM/classify_fix.sh" --brand-new-slug 2>/dev/null || bash "$REM/classify_fix.sh" brand-new-unmapped-slug) "^ESCALATE$" "RL-03: unknown slug -> ESCALATE (fail-safe; never auto-drain an unclassified fix)"
else
  fail "RL-03: classify_fix.sh absent (red-first)"
fi

echo "== RL-04. spec-gen findings-register door (/spec --from-findings; reserved-but-unbuilt) =="
SG_SKILL="$REPO_ROOT/plugins/spec-gen/skills/spec/SKILL.md"
SG_TIER="$REPO_ROOT/docs/specs/spec-gen-tier-v1.md"
if [ -f "$SG_SKILL" ]; then
  assert_grep "$SG_SKILL" 'from-findings.*Fresh|--from-findings' "RL-04: SKILL.md invocation table gains the /spec --from-findings row"
  # Mode is Fresh (reuses the existing draft/fresh code path — no new mode).
  if grep -E '`/spec --from-findings' "$SG_SKILL" | grep -q '| Fresh |'; then ok "RL-04: from-findings row Mode is Fresh (reuses the Fresh path, no new mode)"; else fail "RL-04: from-findings row must be Fresh mode (no new mode)"; fi
  # Input-class name matches the §2 name in spec-gen-tier-v1.md.
  if grep -qi 'Findings register' "$SG_SKILL" && grep -qi 'Findings register' "$SG_TIER"; then ok "RL-04: input-class name 'Findings register' matches spec-gen-tier-v1.md §2"; else fail "RL-04: input-class name must match §2 'Findings register'"; fi
  # No new spec-gen mode/script: the door is prompt-level; scripts carry no from-findings branch.
  if grep -rElq 'from.?findings' "$REPO_ROOT/plugins/spec-gen/scripts" 2>/dev/null; then fail "RL-04: spec-gen scripts must NOT add a from-findings code path (reuse existing, ADR 0017 non-goal)"; else ok "RL-04: no new spec-gen mode/script — the door reuses the Fresh interrogation path"; fi
else
  fail "RL-04: spec-gen SKILL.md not found"
fi

echo "== RL-05. router (remediation_route.sh; deterministic composition, NO LLM) =="
if [ -f "$REM/remediation_route.sh" ]; then
  ST="$REMFIX/state_v2.json"
  printf 'severity_floor: MED\n' > "$WORK/rl_floor_med.yaml"
  assert_grep <(bash "$REM/remediation_route.sh" --fingerprint bbbb2222dark --severity HIGH --slug dark-money-movement --state "$ST")               "^ESCALATE$"          "RL-05: eligible + det-escalate-class + depth0 + unfiled -> ESCALATE"
  assert_grep <(bash "$REM/remediation_route.sh" --fingerprint aaaa1111dead --severity HIGH --slug dead-code --state "$ST")                         "^DRAIN$"             "RL-05: eligible + drain-class + depth0 + unfiled -> DRAIN"
  assert_grep <(bash "$REM/remediation_route.sh" --fingerprint aaaa1111dead --severity HIGH --slug dead-code --state "$ST" --branch remediation/x/story-1) "^ESCALATE$"     "RL-05: eligible + drain-class + depth1 -> ESCALATE (Guard 2 overrides class)"
  assert_grep <(bash "$REM/remediation_route.sh" --fingerprint eeee5555filed --severity HIGH --slug marker --state "$ST")                           "^SKIP:already-filed$" "RL-05: any + already-filed -> SKIP:already-filed (Guard 1 wins)"
  assert_grep <(bash "$REM/remediation_route.sh" --fingerprint cccc3333idem --severity HIGH --slug non-idempotent-handler --state "$ST")            "^SKIP:agent-evidence-only$" "RL-05: agent-scored -> SKIP:agent-evidence-only"
  assert_grep <(bash "$REM/remediation_route.sh" --fingerprint dddd4444giant --severity MED --slug giant-file --state "$ST")                        "^SKIP:below-floor$"  "RL-05: below-floor -> SKIP:below-floor"
else
  fail "RL-05: remediation_route.sh absent (red-first)"
fi

echo "== RL-06. DRAIN path: mode handoff + branch-ns/PR-ref stamp + no-merge + no-single-Story =="
if [ -f "$AP/detect_input_mode.sh" ] && have_validator; then
  bash "$VALIDATE_MANIFEST" "$MANIFEST_FIX/valid-complete.yaml" >/dev/null 2>&1; vc=$?
  assert_grep <(bash "$AP/detect_input_mode.sh" --intent generate --manifest "$MANIFEST_FIX/valid-complete.yaml" --validator-exit "$vc") "MODE=STRAIGHT_THROUGH" "RL-06: complete-manifest register -> STRAIGHT_THROUGH (ADR 0008)"
  bash "$VALIDATE_MANIFEST" "$MANIFEST_FIX/incomplete.yaml" >/dev/null 2>&1; vi=$?
  assert_grep <(bash "$AP/detect_input_mode.sh" --intent generate --manifest "$MANIFEST_FIX/incomplete.yaml" --validator-exit "$vi") "MODE=GENERATE_PAUSE" "RL-06: incomplete-manifest register -> GENERATE_PAUSE (spec-gen refusal degrade, ADR 0008)"
else
  echo "  [skip] detect_input_mode.sh or validator absent — RL-06 mode-handoff skipped (standalone install)"
fi
if [ -f "$REM/remediation_stamp.sh" ] && [ -f "$REM/read_findings.sh" ]; then
  cp "$REMFIX/state_v2.json" "$WORK/rl_stamp.json"
  bash "$REM/remediation_stamp.sh" "$WORK/rl_stamp.json" bbbb2222dark --status SPEC_OPEN --ref remediation/dark/runbook --opened-at 2026-07-07T00:00:00Z >/dev/null 2>&1
  bash "$REM/read_findings.sh" "$WORK/rl_stamp.json" > "$WORK/rl_stamp_rows.txt" 2>/dev/null
  assert_grep "$WORK/rl_stamp_rows.txt" "bbbb2222dark.*SPEC_OPEN" "RL-06: drain stamps the finding SPEC_OPEN with the remediation ref (branch namespace remediation/<slug>/*)"
fi
if [ -f "$REM/build_register.sh" ]; then
  printf 'aaaa1111dead\tHIGH\tdead-code\tsrc/legacy/report.py\tformat_report_rows_old\tno inbound refs\n' >  "$WORK/rl_rows2.tsv"
  printf 'eeee5555filed\tHIGH\tmarker\tsrc/checkout.py\tfinalize\tTODO wire tax\n'                        >> "$WORK/rl_rows2.tsv"
  bash "$REM/build_register.sh" --slug demo --in "$WORK/rl_rows2.tsv" > "$WORK/rl_reg.md" 2>/dev/null
  rmrows="$(grep -cE '^\| RM-[0-9]' "$WORK/rl_reg.md")"
  if [ "${rmrows:-0}" -eq 2 ]; then ok "RL-06: 2-finding register -> 2 acceptance rows (no single-Story presumption, ADR 0007)"; else fail "RL-06: 2-finding register must yield 2 rows, got ${rmrows:-0}"; fi
  assert_grep     "$WORK/rl_reg.md" "one-or-more" "RL-06: register does NOT presume one PR/one Story (Story decomposition is spec-gen's call)"
  assert_not_grep "$WORK/rl_reg.md" "manifest_revision|schema_version" "RL-06: the loop authors a REGISTER (markdown), never a manifest (spec-gen is the only manifest writer, HC3)"
fi
# Guard 3(a): the loop NEVER merges — no merge invocation anywhere in the drain path.
if grep -rnE 'gh pr merge|git merge|pr merge|--merge' \
     "$REM/read_findings.sh" "$REM/finding_eligible.sh" "$REM/classify_fix.sh" "$REM/remediation_route.sh" \
     "$REM/build_register.sh" "$REM/remediation_stamp.sh" "$REM/remediation_depth.sh" "$REM/already_filed.sh" \
     "$REM/remediation_scope_guard.sh" "$REM/remediation_state.py" \
     "$REPO_ROOT/plugins/codebase-health/commands/remediate.md" >/dev/null 2>&1; then
  fail "RL-06/RL-10: a merge invocation exists in the loop drain path (report-only posture violated — the loop NEVER merges, autopilot HC4)"
else
  ok "RL-06/RL-10 Guard 3(a): NO merge invocation in the loop drain path (the loop never merges)"
fi

echo "== RL-07. ESCALATE path: manifest-less -> NOT STRAIGHT_THROUGH; record -> ESCALATED =="
if [ -f "$AP/detect_input_mode.sh" ]; then
  out="$(bash "$AP/detect_input_mode.sh" --intent generate)"     # manifest-LESS
  echo "$out" > "$WORK/rl_esc_mode.txt"
  assert_grep     "$WORK/rl_esc_mode.txt" "MODE=GENERATE_PAUSE"   "RL-07: manifest-less escalate input -> GENERATE_PAUSE"
  assert_not_grep "$WORK/rl_esc_mode.txt" "STRAIGHT_THROUGH"      "RL-07: escalate input is NOT STRAIGHT_THROUGH (no autonomous drain of a values-laden fix)"
else
  echo "  [skip] detect_input_mode.sh absent — RL-07 mode check skipped (standalone install)"
fi
if [ -f "$REM/remediation_stamp.sh" ]; then
  cp "$REMFIX/state_v2.json" "$WORK/rl_esc.json"
  bash "$REM/remediation_stamp.sh" "$WORK/rl_esc.json" bbbb2222dark --status ESCALATED --ref '#exchange-7' >/dev/null 2>&1
  assert_py "import json;assert json.load(open('$WORK/rl_esc.json'))['findings']['bbbb2222dark']['remediation']['status']=='ESCALATED'" "RL-07: escalate stamps the record ESCALATED with an exchange_ref"
fi

echo "== RL-08. Guard 1 (idempotency): already_filed + additive remediation record (schema stays v2) =="
if [ -f "$REM/already_filed.sh" ]; then
  ST="$REMFIX/state_v2.json"
  assert_grep <(bash "$REM/already_filed.sh" eeee5555filed "$ST") "^FILED"   "RL-08: PR_OPEN record -> FILED (skip; never re-file)"
  assert_grep <(bash "$REM/already_filed.sh" ffff6666wont  "$ST") "human-wontfix" "RL-08: human WONTFIX -> FILED (never re-filed by the loop)"
  assert_grep <(bash "$REM/already_filed.sh" bbbb2222dark  "$ST") "^UNFILED" "RL-08: absent record -> UNFILED (loop may file)"
  assert_grep <(bash "$REM/already_filed.sh" bbbb2222dark  "$REMFIX/state_corrupt.json") "state-unreadable" "RL-08: unreadable state -> FILED (fail-safe: never file rework it can't dedup, invariant 4)"
fi
if [ -f "$REM/remediation_stamp.sh" ]; then
  cp "$REMFIX/state_v2.json" "$WORK/rl_g1.json"
  bash "$REM/remediation_stamp.sh" "$WORK/rl_g1.json" aaaa1111dead --status SPEC_OPEN --ref remediation/dead/runbook >/dev/null 2>&1
  assert_py "import json;assert json.load(open('$WORK/rl_g1.json'))['schema_version']==2" "RL-08: schema_version stays 2 after the additive remediation field (no break)"
  assert_py "import json;d=json.load(open('$WORK/rl_g1.json'))['findings']['aaaa1111dead'];assert d.get('remediation',{}).get('status')=='SPEC_OPEN'" "RL-08: remediation sub-object added additively"
  # the loop touches ONLY the remediation sub-object — status/severity/verified_by unchanged.
  assert_py "import json;a=json.load(open('$REMFIX/state_v2.json'))['findings']['aaaa1111dead'];b=json.load(open('$WORK/rl_g1.json'))['findings']['aaaa1111dead'];b2={k:v for k,v in b.items() if k!='remediation'};assert a==b2, 'non-remediation fields changed'" "RL-08: loop touches ONLY remediation (status/severity/verified_by untouched — no false closure)"
fi

echo "== RL-09. Guard 2 (depth ceiling): self-namespace -> depth+1 -> escalate (reuses claim_overlap --self-namespace) =="
if [ -f "$REM/remediation_depth.sh" ] && { [ -f "$AP/claim_overlap.sh" ] || [ -n "${CLAIM_OVERLAP:-}" ]; }; then
  assert_grep <(bash "$REM/remediation_depth.sh" --branch remediation/dark/story-1 --self-namespace remediation/) "^depth=1$" "RL-09: finding on remediation/<slug>/* branch -> depth 1 (parent+1)"
  assert_grep <(bash "$REM/remediation_depth.sh" --branch feature/normal-work --self-namespace remediation/)      "^depth=0$" "RL-09: finding on a normal branch -> depth 0"
  # even a marker (would-DRAIN) on the loop's own namespace escalates (Guard 2 overrides class).
  assert_grep <(bash "$REM/remediation_route.sh" --fingerprint x --severity HIGH --slug marker --state "$REMFIX/state_v2.json" --branch remediation/y/story-1) "^ESCALATE$" "RL-09: depth-1 marker (normally DRAIN) -> ESCALATE (a fix-of-a-fix surfaces to a human)"
else
  echo "  [skip] remediation_depth.sh or claim_overlap.sh absent — RL-09 skipped (standalone install)"
fi

echo "== RL-10. Guard 3 + spec-gen-authored tombstone (CH-05 suppression; loop writes no manifest) =="
if [ -f "$REM/build_register.sh" ]; then
  printf 'aaaa1111dead\tHIGH\tdead-code\tsrc/legacy/report.py\told_exporter\tunused\n' > "$WORK/rl_rm.tsv"
  bash "$REM/build_register.sh" --slug rm --in "$WORK/rl_rm.tsv" > "$WORK/rl_rm.md" 2>/dev/null
  assert_grep "$WORK/rl_rm.md" "lifecycle: withdrawn.*withdrawn_reason|Withdraw symbol .old_exporter." "RL-10: a removal register DECLARES the withdrawal as an acceptance behavior (spec-gen then emits the tombstone)"
  assert_grep "$WORK/rl_rm.md" "spec-gen MUST emit the manifest tombstone; the impl diff carries no tombstone" "RL-10: the tombstone is spec-gen's manifest emission, NOT the impl diff (Defect C)"
fi
# CH-05 reuse: a manifest tombstone (as spec-gen would emit) suppresses the rot on
# the loop's own dead-code removal — the deterministic proof of the wiring.
RLROT="$WORK/rlrot"; mkdir -p "$RLROT"
( cd "$RLROT"
  git init -q && git config user.email t@t && git config user.name t && git config commit.gpgsign false
  mkdir -p docs/adr
  printf 'def old_exporter():\n    return 1\n' > exporter.py
  printf '# ADR: old_exporter was the legacy export entrypoint\nold_exporter is referenced here.\n' > docs/adr/0009-x.md
  cat > manifest.yaml <<'YAML'
schema_version: 1
manifest_revision: 1
behaviors:
  - id: B-rm-001
    title: "Remove legacy exporter"
    lifecycle: withdrawn
    withdrawn_reason: "dead-code removal per remediation register"
    test_name_hint: "old_exporter"
    given: "x"
    when: "y"
    then: "z"
YAML
  git add -A && git commit -qm base
  printf 'def kept():\n    return 2\n' > exporter.py     # delete old_exporter
  git add -A && git commit -qm remove )
RLB="$(cd "$RLROT" && git rev-parse HEAD~1)"
( cd "$RLROT" && bash "$SKILL_SCRIPTS/check_memory_rot.sh" "$RLB" --manifest manifest.yaml ) > "$WORK/rl_rot.out" 2>&1; rc=$?
assert_grep     "$WORK/rl_rot.out" "rot-suppressed tombstone. 'old_exporter'"     "RL-10: spec-gen-authored lifecycle:withdrawn tombstone suppresses CH-05 rot on the loop's cleanup"
assert_not_grep "$WORK/rl_rot.out" "\[FINDING blocking\] memory-rot-dangling-ref: 'old_exporter'" "RL-10: CH-05 emits NO rot finding for the tombstoned removal"

echo "== RL-11. orchestrator + no-new-plugin (V6 exactly-five holds) =="
if [ -f "$REPO_ROOT/plugins/codebase-health/commands/remediate.md" ]; then
  ok "RL-11: /remediate orchestrator homed in codebase-health/commands (not a new plugin)"
  assert_grep "$REPO_ROOT/plugins/codebase-health/commands/remediate.md" "report-only|advisory-first|NEVER merges|no blocking" "RL-11: /remediate declares the report-only / no-merge / no-blocking posture"
else
  fail "RL-11: /remediate command absent (red-first)"
fi
assert_not_grep "$REPO_ROOT/.claude-plugin/marketplace.json" '"name":[[:space:]]*"remediation' "RL-11: NO new marketplace plugin entry — the loop is a codebase-health skill (V6 exactly-five holds)"

echo "== RL-12. scope guard (remediation_scope_guard.sh): no mutation tool, no whole-repo run_audit =="
if [ -f "$REM/remediation_scope_guard.sh" ]; then
  bash "$REM/remediation_scope_guard.sh" > "$WORK/rl_scope.out" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then ok "RL-12: loop code paths invoke no mutation tool and no whole-repo run_audit (clean)"; else fail "RL-12: scope guard must pass on the real loop scripts [rc=$rc]"; fi
  # RED-TEST (non-vacuity): plant a mutation invocation + a run_audit call into copies.
  SB="$WORK/rl_scope_sb"; mkdir -p "$SB"
  cp "$REM/read_findings.sh" "$REM/classify_fix.sh" "$REM/remediation_lib.sh" "$SB/" 2>/dev/null
  printf '\ncargo-mutants --in-place\n' >> "$SB/read_findings.sh"
  printf '\nbash run_audit.sh .\n'      >> "$SB/classify_fix.sh"
  bash "$REM/remediation_scope_guard.sh" --dir "$SB" > "$WORK/rl_scope_red.out" 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then ok "RL-12: planted violations make the scope guard fail (non-vacuous)"; else fail "RL-12: scope guard stayed green on a planted mutation/run_audit invocation (vacuous!)"; fi
  assert_grep "$WORK/rl_scope_red.out" "SCOPE-VIOLATION .mutation-tool." "RL-12: planted mutation-tool invocation is caught"
  assert_grep "$WORK/rl_scope_red.out" "SCOPE-VIOLATION .whole-repo."    "RL-12: planted whole-repo run_audit call is caught"
  # RL-01 reads only: the reader/backend spawn no detector, no mutation tool, no whole-repo scan.
  assert_not_grep "$REM/read_findings.sh"     "run_audit\.sh|mutmut|cosmic-ray|stryker|pitest|cargo-mutants" "RL-12: read_findings.sh spawns no detector (reporter-only, invariant 1)"
  assert_not_grep "$REM/remediation_state.py" "run_audit\.sh|mutmut|cosmic-ray|stryker|pitest|cargo-mutants" "RL-12: remediation_state.py spawns no detector"
else
  fail "RL-12: remediation_scope_guard.sh absent (red-first)"
fi

HL_FIX="$HARNESS_DIR/test-fixtures/health-loop"
HL_SPEC="$HL_FIX/SPEC.md"
SW="$SKILL_SCRIPTS/spec_wave.sh"

echo "== HL-01. spec_wave.sh: deterministic SPEC.md wave parsing (ADR 0024) =="
if [ -f "$SW" ]; then
  bash "$SW" waves "$HL_SPEC" > "$WORK/hl_waves.out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "HL-01: waves exits 0 on a wave-structured spec" || fail "HL-01: waves exits 0 on a wave-structured spec (rc=$rc)"
  [ "$(wc -l < "$WORK/hl_waves.out" | tr -d ' ')" = "4" ] && ok "HL-01: waves enumerates all 4 wave headers" || fail "HL-01: waves enumerates all 4 wave headers"
  assert_grep "$WORK/hl_waves.out" "^1	.*	2$" "HL-01: Wave 1 counted with 2 items"
  assert_grep "$WORK/hl_waves.out" "^4	.*	0$" "HL-01: Wave 4 counted with 0 items"
  bash "$SW" waves "$HL_FIX/pr_body.md" > /dev/null 2>&1; rc=$?
  [ "$rc" -eq 3 ] && ok "HL-01: wave-less doc refused (exit 3, never guessed)" || fail "HL-01: wave-less doc refused (exit 3, got $rc)"

  SLICE="$(bash "$SW" slice "$HL_SPEC" 1 --out "$WORK/hl_waves" 2>"$WORK/hl_slice.err")"; rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$SLICE" ]; then
    ok "HL-01: slice writes wave-1.md and prints its path"
    assert_grep "$SLICE" '^### \[DC-L1\] delete dead helper$' "HL-01: slice carries Wave 1 items byte-preserved"
    assert_grep "$SLICE" '^## Summary$'                       "HL-01: slice carries the Summary section"
    assert_not_grep "$SLICE" 'IL-H1|SEC-H1'                   "HL-01: slice excludes other waves' items"
  else
    fail "HL-01: slice writes wave-1.md and prints its path (rc=$rc)"
  fi
  bash "$SW" slice "$HL_SPEC" 9 --out "$WORK/hl_waves" > /dev/null 2>&1; rc=$?
  [ "$rc" -eq 4 ] && ok "HL-01: absent wave refused (exit 4)" || fail "HL-01: absent wave refused (exit 4, got $rc)"
  bash "$SW" slice "$HL_SPEC" 4 --out "$WORK/hl_waves" > /dev/null 2>&1; rc=$?
  if [ "$rc" -eq 6 ] && [ ! -f "$WORK/hl_waves/wave-4.md" ]; then
    ok "HL-01: zero-item wave refused loudly (exit 6, no empty slice written)"
  else
    fail "HL-01: zero-item wave refused loudly (exit 6, got $rc)"
  fi

  bash "$SW" fingerprints "$HL_SPEC" 1 > "$WORK/hl_fp1.out" 2>&1; rc=$?
  if [ "$rc" -eq 0 ] && [ "$(printf 'aaaa11111111\nbbbb22222222' )" = "$(cat "$WORK/hl_fp1.out")" ]; then
    ok "HL-01: fingerprints emits Wave 1's two fingerprints exactly"
  else
    fail "HL-01: fingerprints emits Wave 1's two fingerprints exactly (rc=$rc: $(tr '\n' ' ' < "$WORK/hl_fp1.out"))"
  fi
  bash "$SW" fingerprints "$HL_FIX/SPEC_missing_fp.md" 1 > "$WORK/hl_fpmiss.out" 2>&1; rc=$?
  [ "$rc" -eq 5 ] && ok "HL-01: fingerprint-less item is a spec defect (exit 5)" || fail "HL-01: fingerprint-less item is a spec defect (exit 5, got $rc)"
  assert_grep "$WORK/hl_fpmiss.out" 'MISSING.*DC-L1' "HL-01: the fingerprint-less item is NAMED (silent truncation is a defect)"

  bash "$SW" forward-deps "$HL_SPEC" 2 > /dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "HL-01: backward dep (Wave 2 -> Wave 1) is fine" || fail "HL-01: backward dep (Wave 2 -> Wave 1) is fine (got $rc)"
  bash "$SW" forward-deps "$HL_FIX/SPEC_forward_dep.md" 1 > "$WORK/hl_fwd.out" 2>&1; rc=$?
  [ "$rc" -eq 1 ] && ok "HL-01: planted forward dep refused (exit 1)" || fail "HL-01: planted forward dep refused (exit 1, got $rc)"
  assert_grep "$WORK/hl_fwd.out" 'IL-H1 wave=2'   "HL-01: forward dep names the offending TAG and its wave"
  assert_grep "$WORK/hl_fwd.out" '2FA-H2 wave=2'  "HL-01: DIGIT-leading forward-dep TAG is caught too"
  assert_grep "$WORK/hl_fwd.out" 'NOPE-X9 unresolved' "HL-01: dep resolving to NO item refuses loudly (never silently dropped)"
  bash "$SW" fingerprints "$HL_SPEC" 9 > /dev/null 2>&1; rc=$?
  [ "$rc" -eq 4 ] && ok "HL-01: fingerprints on absent wave refused (exit 4)" || fail "HL-01: fingerprints on absent wave refused (exit 4, got $rc)"
  bash "$SW" forward-deps "$HL_SPEC" 9 > /dev/null 2>&1; rc=$?
  [ "$rc" -eq 4 ] && ok "HL-01: forward-deps on absent wave refused (exit 4)" || fail "HL-01: forward-deps on absent wave refused (exit 4, got $rc)"
  mkdir -p "$WORK/hl_spec_copy" && cp "$HL_SPEC" "$WORK/hl_spec_copy/SPEC.md"
  DEF="$(bash "$SW" slice "$WORK/hl_spec_copy/SPEC.md" 1 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$DEF" = "$WORK/hl_spec_copy/waves/wave-1.md" ] && [ -f "$DEF" ]; then
    ok "HL-01: slice default --out is <spec-dir>/waves/"
  else
    fail "HL-01: slice default --out is <spec-dir>/waves/ (rc=$rc, got: $DEF)"
  fi
  : > "$WORK/hl_afile"
  bash "$SW" slice "$HL_SPEC" 1 --out "$WORK/hl_afile/waves" > /dev/null 2>&1; rc=$?
  [ "$rc" -eq 7 ] && ok "HL-01: unwritable out dir fails closed (exit 7), never mislabeled" || fail "HL-01: unwritable out dir fails closed (exit 7, got $rc)"
else
  fail "HL-01: spec_wave.sh absent (red-first)"
fi

echo "== HL-02. wave_gate.sh: ADVANCE/INCOMPLETE/REGRESSION/UNREADABLE exit contract =="
WG="$SKILL_SCRIPTS/wave_gate.sh"
if [ -f "$WG" ]; then
  printf 'aaaa11111111\nbbbb22222222\n' > "$WORK/hl_wave1.fps"
  printf 'cccc33333333\n'               > "$WORK/hl_wave2.fps"
  cp "$HL_FIX/state_green.json" "$WORK/hl_state_green.json"

  bash "$WG" "$WORK/hl_state_green.json" "$WORK/hl_wave1.fps" > "$WORK/hl_gate1.out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "HL-02: green wave -> ADVANCE (exit 0)" || fail "HL-02: green wave -> ADVANCE (exit 0, got $rc)"
  assert_grep "$WORK/hl_gate1.out" 'VERDICT=ADVANCE' "HL-02: ADVANCE verdict printed"
  bash "$WG" "$WORK/hl_state_green.json" "$WORK/hl_wave1.fps" > "$WORK/hl_gate1b.out" 2>&1
  cmp -s "$WORK/hl_gate1.out" "$WORK/hl_gate1b.out" && ok "HL-02: gate is idempotent (same output twice)" || fail "HL-02: gate is idempotent (same output twice)"
  cmp -s "$HL_FIX/state_green.json" "$WORK/hl_state_green.json" && ok "HL-02: gate never writes state.json (byte-identical after two runs)" || fail "HL-02: gate never writes state.json (byte-identical after two runs)"

  bash "$WG" "$HL_FIX/state_green.json" "$WORK/hl_wave2.fps" > /dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && ok "HL-02: OPEN finding -> INCOMPLETE (exit 2)" || fail "HL-02: OPEN finding -> INCOMPLETE (exit 2, got $rc)"
  bash "$WG" "$HL_FIX/state_partial.json" "$WORK/hl_wave1.fps" > "$WORK/hl_gatep.out" 2>&1; rc=$?
  [ "$rc" -eq 2 ] && ok "HL-02: PARTIAL never rounds up (exit 2)" || fail "HL-02: PARTIAL never rounds up (exit 2, got $rc)"
  assert_grep "$WORK/hl_gatep.out" 'INCOMPLETE bbbb22222222 PARTIAL' "HL-02: the PARTIAL fingerprint is NAMED"
  bash "$WG" "$HL_FIX/state_regressed_elsewhere.json" "$WORK/hl_wave1.fps" > "$WORK/hl_gater.out" 2>&1; rc=$?
  [ "$rc" -eq 3 ] && ok "HL-02: REGRESSED on a NON-listed fingerprint still halts (global scan, exit 3)" || fail "HL-02: REGRESSED on a NON-listed fingerprint still halts (exit 3, got $rc)"
  assert_grep "$WORK/hl_gater.out" 'REGRESSED cccc33333333' "HL-02: the regressed fingerprint is NAMED"
  bash "$WG" "$HL_FIX/state_regressed_listed.json" "$WORK/hl_wave1.fps" > /dev/null 2>&1; rc=$?
  [ "$rc" -eq 3 ] && ok "HL-02: REGRESSED on a LISTED fingerprint halts (exit 3)" || fail "HL-02: REGRESSED on a LISTED fingerprint halts (exit 3, got $rc)"
  bash "$WG" "$HL_FIX/state_no_verify.json" "$WORK/hl_wave1.fps" > "$WORK/hl_gatenv.out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "HL-02: no verify run yet -> statuses alone govern (exit 0, noted)" || fail "HL-02: no verify run yet -> exit 0 (got $rc)"
  assert_grep "$WORK/hl_gatenv.out" 'no kind=verify run' "HL-02: missing verify run is NOTED, not silent"
  bash "$WG" "$HL_FIX/state_absent_count.json" "$WORK/hl_wave1.fps" > "$WORK/hl_gateab.out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "HL-02: count absent in baseline is never read as 0 (exit 0, noted per count)" || fail "HL-02: absent count never read as 0 (exit 0, got $rc)"
  assert_grep "$WORK/hl_gateab.out" 'flaky_count absent in one run' "HL-02: the absent count is NAMED"
  bash "$WG" "$HL_FIX/state_ratchet_verify_baseline.json" "$WORK/hl_wave1.fps" > "$WORK/hl_gatevb.out" 2>&1; rc=$?
  [ "$rc" -eq 3 ] && ok "HL-02: verify-only target still ratchets against the prior same-target verify (exit 3)" || fail "HL-02: verify-only target still ratchets (exit 3, got $rc)"
  assert_grep "$WORK/hl_gatevb.out" 'baseline is the prior same-target verify run' "HL-02: the fallback baseline is NOTED"
  bash "$WG" "$HL_FIX/state_ratchet_bump.json" "$WORK/hl_wave1.fps" > "$WORK/hl_gaterat.out" 2>&1; rc=$?
  [ "$rc" -eq 3 ] && ok "HL-02: ratchet increase halts (exit 3)" || fail "HL-02: ratchet increase halts (exit 3, got $rc)"
  assert_grep "$WORK/hl_gaterat.out" 'marker_count 5->7' "HL-02: the increased count is NAMED"
  bash "$WG" "$HL_FIX/state_stdout_only_bump.json" "$WORK/hl_wave1.fps" > "$WORK/hl_gateso.out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "HL-02: stdout_logging_count bump is report-only, never gates (exit 0)" || fail "HL-02: stdout_logging_count bump is report-only (exit 0, got $rc)"
  assert_grep "$WORK/hl_gateso.out" 'report-only' "HL-02: report-only bump is still REPORTED"
  bash "$WG" "$HL_FIX/state_corrupt.json" "$WORK/hl_wave1.fps" > /dev/null 2>&1; rc=$?
  [ "$rc" -eq 4 ] && ok "HL-02: corrupt state fails closed (exit 4)" || fail "HL-02: corrupt state fails closed (exit 4, got $rc)"
  printf 'eeee55555555\n' > "$WORK/hl_stray.fps"
  bash "$WG" "$HL_FIX/state_green.json" "$WORK/hl_stray.fps" > /dev/null 2>&1; rc=$?
  [ "$rc" -eq 4 ] && ok "HL-02: spec<->state desync (unknown fingerprint) fails closed (exit 4)" || fail "HL-02: unknown fingerprint fails closed (exit 4, got $rc)"
  : > "$WORK/hl_empty.fps"
  bash "$WG" "$HL_FIX/state_green.json" "$WORK/hl_empty.fps" > /dev/null 2>&1; rc=$?
  [ "$rc" -eq 64 ] && ok "HL-02: empty fingerprint list is a usage error (exit 64)" || fail "HL-02: empty fingerprint list is a usage error (exit 64, got $rc)"
  # Scope guard (RL-12 posture): the gate is a pure reader — no state writes, no detectors.
  assert_not_grep "$SKILL_SCRIPTS/wave_gate.py" 'write_text|json\.dump|run_audit\.sh|mutmut|cosmic-ray|stryker|pitest|cargo-mutants' "HL-02: wave_gate.py has no write path and spawns no detector (invariants 1/7)"
else
  fail "HL-02: wave_gate.sh absent (red-first)"
fi

echo "== HL-03. wave_preauth_check.sh: delegated-approval preconditions (P1-P4) =="
PC="$SKILL_SCRIPTS/wave_preauth_check.sh"
if [ -f "$PC" ]; then
  # Hermetic story repo: base commit on main, Story branch inside + one rogue branch outside the predicted surface.
  R="$WORK/hl_repo"
  git init -q -b main "$R" 2>/dev/null || { git init -q "$R" && git -C "$R" checkout -q -b main; }
  GC="git -C $R -c user.email=hl@test -c user.name=hl -c commit.gpgsign=false"
  mkdir -p "$R/src" "$R/tests" "$R/docs" "$R/.autopilot/runbooks"
  echo 'def old_helper(): pass' > "$R/src/util.py"; echo 'ok' > "$R/tests/test_util.py"
  $GC add -A >/dev/null && $GC commit -qm 'base'
  $GC checkout -qb autopilot/audit-w1/delete-dead-helper
  echo '# cleaned' > "$R/src/util.py"; echo 'assert True' > "$R/tests/test_util.py"
  echo 'tracker delta' > "$R/.autopilot/runbooks/audit-w1.tracker.md"
  $GC add -A >/dev/null && $GC commit -qm 'feat: delete-dead-helper.1 GREEN'
  $GC checkout -qb autopilot/audit-w1/rogue
  echo 'surprise' > "$R/src/rogue.py"
  $GC add -A >/dev/null && $GC commit -qm 'feat: rogue GREEN'
  # patch(1) droppings: FIX_LOG.md itself is allowed (exact), its .orig sibling is NOT
  $GC checkout -q autopilot/audit-w1/delete-dead-helper
  $GC checkout -qb autopilot/audit-w1/patchdroppings
  echo 'DC-L1 fixed, commit 111aaa, 5/5' > "$R/docs/FIX_LOG.md"
  echo 'leftover' > "$R/docs/FIX_LOG.md.orig"
  $GC add -A >/dev/null && $GC commit -qm 'feat: delete-dead-helper.2 GREEN'
  $GC checkout -q main

  pc() { bash "$PC" --repo "$R" --base main --pr-body "$HL_FIX/pr_body.md" "$@"; }
  pc --tracker "$HL_FIX/tracker_drained.md" --story delete-dead-helper --branch autopilot/audit-w1/delete-dead-helper > "$WORK/hl_pc_ok.out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "HL-03: clean drained Story passes all preconditions (exit 0)" || fail "HL-03: clean drained Story passes (exit 0, got $rc: $(cat "$WORK/hl_pc_ok.out"))"
  assert_grep "$WORK/hl_pc_ok.out" '^OK story=delete-dead-helper' "HL-03: OK line names the story"
  pc --tracker "$HL_FIX/tracker_human_needed.md" --story delete-dead-helper --branch autopilot/audit-w1/delete-dead-helper > "$WORK/hl_pc_p1.out" 2>&1; rc=$?
  [ "$rc" -eq 1 ] && assert_grep "$WORK/hl_pc_p1.out" '.refuse. P1' "HL-03: non-DRAINED tracker refused (P1)" || fail "HL-03: non-DRAINED tracker refused (P1, got $rc)"
  pc --tracker "$HL_FIX/tracker_open_subtask.md" --story delete-dead-helper --branch autopilot/audit-w1/delete-dead-helper > "$WORK/hl_pc_p2.out" 2>&1; rc=$?
  [ "$rc" -eq 1 ] && assert_grep "$WORK/hl_pc_p2.out" '.refuse. P2' "HL-03: open Subtask refused (P2)" || fail "HL-03: open Subtask refused (P2, got $rc)"
  pc --tracker "$HL_FIX/tracker_drained.md" --story no-such-story --branch autopilot/audit-w1/delete-dead-helper > "$WORK/hl_pc_p2b.out" 2>&1; rc=$?
  [ "$rc" -eq 1 ] && assert_grep "$WORK/hl_pc_p2b.out" '.refuse. P2.*unknown Story proves nothing' "HL-03: unknown story refused (P2, zero rows)" || fail "HL-03: unknown story refused (P2, got $rc)"
  pc --tracker "$HL_FIX/tracker_resolved_block.md" --story delete-dead-helper --branch autopilot/audit-w1/delete-dead-helper > "$WORK/hl_pc_p3.out" 2>&1; rc=$?
  [ "$rc" -eq 1 ] && assert_grep "$WORK/hl_pc_p3.out" '.refuse. P3' "HL-03: resolved-block history refused (P3 — a human eye, not a delegate)" || fail "HL-03: resolved-block history refused (P3, got $rc)"
  pc --tracker "$HL_FIX/tracker_drained.md" --story delete-dead-helper --branch autopilot/audit-w1/rogue > "$WORK/hl_pc_p4.out" 2>&1; rc=$?
  [ "$rc" -eq 1 ] && assert_grep "$WORK/hl_pc_p4.out" '.refuse. P4.*src/rogue\.py' "HL-03: file outside predicted surface refused and NAMED (P4)" || fail "HL-03: rogue file refused (P4, got $rc)"
  pc --tracker "$HL_FIX/tracker_drained.md" --story delete-dead-helper --branch autopilot/audit-w1/patchdroppings > "$WORK/hl_pc_orig.out" 2>&1; rc=$?
  [ "$rc" -eq 1 ] && assert_grep "$WORK/hl_pc_orig.out" '.refuse. P4.*docs/FIX_LOG\.md\.orig' "HL-03: allow-list is exact-match — FIX_LOG.md.orig does NOT ride the FIX_LOG.md allowance (P4)" || fail "HL-03: FIX_LOG.md.orig refused (P4, got $rc: $(cat "$WORK/hl_pc_orig.out"))"
  pc --tracker "$HL_FIX/tracker_sibling_block.md" --story delete-dead-helper --branch autopilot/audit-w1/delete-dead-helper > "$WORK/hl_pc_sib.out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "HL-03: sibling story's resolved block does not refuse this story (P3 boundary-anchored)" || fail "HL-03: sibling block must not refuse (exit 0, got $rc: $(cat "$WORK/hl_pc_sib.out"))"
  bash "$PC" --repo "$R" --base main --pr-body "$HL_FIX/tracker_drained.md" --tracker "$HL_FIX/tracker_drained.md" --story delete-dead-helper --branch autopilot/audit-w1/delete-dead-helper > /dev/null 2>&1; rc=$?
  [ "$rc" -eq 4 ] && ok "HL-03: PR body without file-surface markers fails closed (exit 4)" || fail "HL-03: markerless PR body fails closed (exit 4, got $rc)"
  bash "$PC" --tracker "$HL_FIX/tracker_drained.md" --story > /dev/null 2>&1; rc=$?
  [ "$rc" -eq 64 ] && ok "HL-03: trailing option with no value exits 64 (never hangs)" || fail "HL-03: trailing option exits 64 (got $rc)"
  pc --tracker "$HL_FIX/tracker_drained.md" --story delete-dead-helper --branch autopilot/audit-w1/delete-dead-helper --allow-prefix "" > /dev/null 2>&1; rc=$?
  [ "$rc" -eq 64 ] && ok "HL-03: empty --allow-prefix exits 64 (an empty prefix would disable P4)" || fail "HL-03: empty --allow-prefix exits 64 (got $rc)"
else
  fail "HL-03: wave_preauth_check.sh absent (red-first)"
fi

echo "== HL-04. loop_e2e.sh: health-loop dispatch composition (ADR 0024) =="
if [ -f "$HARNESS_DIR/loop_e2e.sh" ]; then
  if bash "$HARNESS_DIR/loop_e2e.sh" > "$WORK/hl_e2e.out" 2>&1; then
    ok "HL-04: loop e2e green + red paths pass ($(tail -1 "$WORK/hl_e2e.out" | sed 's/^== //; s/ ==$//'))"
  else
    fail "HL-04: loop e2e failed — output follows"
    sed 's/^/    /' "$WORK/hl_e2e.out" | tail -30
  fi
else
  fail "HL-04: loop_e2e.sh absent (red-first)"
fi

echo
echo "== self-test: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
