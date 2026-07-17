# Single source of truth for debt-detection regexes.
# Sourced by run_audit.sh (full-tree scan), check_new_debt.sh (diff scan), and
# /verify's closing-test screen — one definition so detection, prevention, and
# verification can never drift.
# Extended-regex (grep -E) syntax.
#
# Every token is \b-anchored: without boundaries, on_swipe/wipe_cache match WIP,
# HACKATHON matches HACK, XXXL matches XXX, stubborn matches STUB — and the
# ratchet counts the whole loop trusts become noise. Precision fixtures for
# these live in test-fixtures/planted/planted_pkg/ui.py (must_not_flag).

# Incompleteness markers — every marker the incomplete-logic taxonomy lists.
# Case-insensitive use expected (grep -i).
MARKER_RE='\bTODO\b|\bFIXME\b|\bXXX\b|\bHACK\b|\bSTUB\b|\bWIP\b|\bTBD\b|\bPLACEHOLDER\b|@todo\b|\bNotImplementedError\b|\bunimplemented!?\(|\btodo!\(|panic!\("not|\bfix later\b|\bimplement later\b|\bfor now\b|\bstopgap\b|\btemporary (hack|fix|workaround|solution|implementation)\b'

# Suppressed diagnostics (taxonomy Category G) — case-sensitive (these are exact
# tool directives). File-level forms (@ts-nocheck, mypy: ignore-errors) matter
# most: they hide every diagnostic in the file.
SUPPRESS_RE='# ?noqa|# ?type: ?ignore|# ?mypy: ?ignore-errors|@ts-ignore|@ts-expect-error|@ts-nocheck|eslint-disable|biome-ignore|#\[allow\(|# ?nosec|//nolint|# pylint: ?disable|# pragma: no cover'

# What counts as a test file. Matches bare paths AND grep file:line prefixes.
# Consumers: run_audit.sh (gates flaky/vacuity/skip IN, stdout-logging OUT),
# check_new_debt.sh, /verify determinism screen, self_test.sh unit cases,
# sd_seeds.sh (production-only tz gating; env from run_audit or sourced here).
# Precision fixture: planted_pkg/poller.py (N4) must never match.
TEST_PATH_RE='(^|/)(tests?|__tests__|spec)/|(^|/)test_[^/:]*\.py(:|$)|(^|/)conftest\.py(:|$)|_test\.(py|go)(:|$)|\.(test|spec)\.(ts|tsx|js|jsx|mjs|cjs)(:|$)'

# Test nondeterminism (test-health T1-T7). Case-SENSITIVE (exact API names).
# asyncio.sleep deliberately EXCLUDED (await asyncio.sleep(0) is a cooperative
# yield — precision-hostile; agents still judge long asyncio sleeps). Seeded
# instance calls (RNG.shuffle) and random.Random( constructor never match.
# new Date()/Date.now() require empty parens (new Date(2020,1,1) is deterministic).
# reruns= anchored as \breruns=[1-9]: reruns=0 (retries disabled), prose, and
# kwargs like dryruns= never match; a reruns=0 line in tests/conftest.py (N3)
# pins the exclusion. DOCUMENTED RESIDUAL (same status as the console.warn/error
# exclusions in LOGGING_RE): fetch\(["']https?:// requires a literal string URL —
# template-literal (fetch(`https://...`)) and variable-URL forms are deliberately
# unmatched (precision-hostile); agents still judge them (T5 stays agent-caught
# for those forms).
# Precision fixtures: tests/conftest.py (N3), planted_pkg/poller.py (N4).
FLAKY_RE='\btime\.sleep\(|\bsetTimeout\(|thread::sleep|\btime\.Sleep\(|\brandom\.(random|randint|choice|shuffle|sample|uniform)\(|\bMath\.random\(|\brand\.(Int|Intn|Int31|Float64|Perm)\(|rand::random|\bdatetime\.(now|utcnow|today)\(|\bdate\.today\(|\btime\.time\(|\bDate\.now\(\)|\bnew Date\(\)|Instant::now\(|\btime\.Now\(|@pytest\.mark\.flaky|\breruns=[1-9]|jest\.retryTimes\(|pytest-rerunfailures|\brequests\.(get|post|put|delete|head)\(|\burllib\.request|\bfetch\(["'\''"]https?://|\baxios\.(get|post|put|delete)\(|\bhttp\.Get\(|net\.Dial\('

# Literal test tautologies (test-health T9 greppable slice). Identity forms
# (expect(x).toBe(x)) need backreferences ERE lacks — agent-owned.
TEST_VACUOUS_RE='expect\((true|1)\)\.toBe\((true|1)\)|expect\(true\)\.toBeTruthy\(\)|\bassert True\b|assertTrue\(True\)|\bassert 1 ?== ?1\b|assert!\(true\)|assert\.ok\(true\)'

# Suite shrinkers (test-health T12 — the Category G analog for tests).
TEST_SKIP_RE='\b(it|test|describe|xit)\.(skip|only)\(|\bxit\(|\bxdescribe\(|@pytest\.mark\.skip|@unittest\.skip|\bt\.Skip\(|#\[ignore\]'

# Stdout-as-log-channel (IL taxonomy Category LOG). Case-sensitive, \b-anchored
# (blueprint/imprint/game_console fixtures: N2, N7). bare `echo` and
# console.warn/error deliberately excluded (documented residuals).
# Candidates, not verdicts: print-as-CLI-output is legitimate (N6 fixture).
LOGGING_RE='\bprint(ln)?!?\(|\beprintln!\(|\bdbg!\(|\bsys\.stdout\.write\(|\bconsole\.(log|info|debug|trace)\(|\bSystem\.(out|err)\.print|\bfmt\.Print(ln|f)?\('

# Commented-out code blocks (navigability). Code token anchored IMMEDIATELY
# after the comment leader so prose ("# We return early...") never matches
# (fixture: planted_pkg/metrics.py, N11).
COMMENT_LINE_RE='^[[:space:]]*(#|//)'
CODE_COMMENT_RE='^[[:space:]]*(#|//)[[:space:]]*(def |class |if |elif |else:|for |while |return( |$)|import |from [A-Za-z_.]+ import |try:|except|raise |with |function |const |let |var |export |await |[A-Za-z_][A-Za-z0-9_.]*\(.*\);?[[:space:]]*$|[A-Za-z_][A-Za-z0-9_.\[\]]* ?= ?[^=])'
CO_MIN_RUN=3   # consecutive comment lines
CO_MIN_CODE=2  # of which code-shaped
