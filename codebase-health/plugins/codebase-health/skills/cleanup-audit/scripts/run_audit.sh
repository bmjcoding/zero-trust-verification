#!/usr/bin/env bash
# Phase 1 deterministic evidence collector — language-agnostic.
# Auto-detects the stack (from manifests in TARGET, falling back to cwd) and runs
# the matching tool pack, writing raw output into ./audit/ for the agent to triage.
# Treats nothing as a verdict.
#
# Usage:   scripts/run_audit.sh [TARGET_DIR]
# Example: scripts/run_audit.sh src/
#
# Tools auto-skip if not installed (install hint printed). See
# references/cross-language-tooling.md for the full per-language pack.
# Safety: the only writes this script makes are under audit/ — with one
# documented exception: the Rust pack runs `cargo build`/`cargo clippy`, which
# write target/ and execute build.rs. Skip the Rust pack if that matters.
set -uo pipefail

TARGET="${1:-.}"
OUT="audit"
mkdir -p "$OUT"
echo "==> Cleanup audit — target: $TARGET  output: $OUT/"

# Directories that must never contribute evidence: vendored deps, build output,
# VCS internals, and — critically — the audit output itself (otherwise run N's
# report poisons run N+1's marker seed).
EXCLUDE_DIRS=(node_modules .venv venv vendor dist build target .git .tox .mypy_cache __pycache__ "$OUT")
GREP_EXCLUDES=()
for d in "${EXCLUDE_DIRS[@]}"; do GREP_EXCLUDES+=(--exclude-dir="$d"); done
# find-based file inventory honoring the SAME exclusions (each excluded
# basename is pruned exactly as --exclude-dir skips it in grep). Feeds the
# test-file probe, the alerting-config find, the size ladder, and the
# commented-code pass below.
FIND_PRUNES=()
for d in "${EXCLUDE_DIRS[@]}"; do FIND_PRUNES+=(-type d -name "$d" -prune -o); done
src_files() { find "$TARGET" "${FIND_PRUNES[@]}" -type f -print 2>/dev/null; }

# --exclude-dir matches directory BASENAMES anywhere in the tree, so a real
# source package named audit/, build/, target/ or vendor/ would be silently
# skipped. Never truncate silently (loop-safety invariant 6): record which
# excluded names actually exist under TARGET so the orchestrator can put them
# in the report's Not-covered section and a human can narrow TARGET or rename.
: > "$OUT/excluded_dirs.txt"
# the tool's own output dir at the target's top level is expected, not a coverage
# gap — match it exactly whether TARGET was given relative or absolute
SELF_OUT_A="$OUT"; SELF_OUT_B="./$OUT"; SELF_OUT_C="${TARGET%/}/$OUT"
for d in "${EXCLUDE_DIRS[@]}"; do
  find "$TARGET" -type d -name "$d" 2>/dev/null \
    | grep -vxF -e "$SELF_OUT_A" -e "$SELF_OUT_B" -e "$SELF_OUT_C" >> "$OUT/excluded_dirs.txt" || true
done
if [ -s "$OUT/excluded_dirs.txt" ]; then
  echo "==> NOTE: these directories are excluded from grep evidence (see $OUT/excluded_dirs.txt):"
  sed 's/^/      /' "$OUT/excluded_dirs.txt"
  echo "      If any of these are real source, they are NOT COVERED by this pass."
fi

have() { command -v "$1" >/dev/null 2>&1; }
miss() { echo "    [skip] $1 not installed — $2"; }

# Shared debt regexes (same definitions the prevention hook uses — see debt_patterns.sh).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=debt_patterns.sh
. "$SCRIPT_DIR/debt_patterns.sh"

# --- Stack detection: manifests under TARGET first, then cwd (monorepo-safe) ---
manifest() { # manifest <file> -> true if it exists in TARGET or cwd
  [ -e "$TARGET/$1" ] || [ -e "$1" ]
}
detected=""
if manifest pyproject.toml || manifest setup.cfg || manifest setup.py; then
  detected="$detected python"
fi
if manifest package.json; then
  detected="$detected node"
fi
if manifest Cargo.toml; then
  detected="$detected rust"
fi
if manifest go.mod; then
  detected="$detected go"
fi
[ -z "$detected" ] && detected=" unknown"
echo "==> Detected stack:$detected"

# ---------------- Python ----------------
if [[ "$detected" == *python* ]]; then
  echo "== Python pack =="
  # vulture is the primary dead-code finder (covers far more than ruff's unused-import/local rules).
  have vulture  && { echo "-> vulture";  vulture "$TARGET" --min-confidence 60 > "$OUT/py_vulture.txt"  2>&1 || true; } || miss vulture  "pip install vulture"
  # ruff: F covers unused imports/locals/redefs; C901 = McCabe complexity (replaces radon, no extra dep).
  have ruff     && { echo "-> ruff (F + C901 complexity)"; ruff check "$TARGET" --select F,C901 --output-format concise > "$OUT/py_ruff.txt" 2>&1 || true; } || miss ruff "pip install ruff"
  have deptry   && { echo "-> deptry";   deptry "$TARGET"                       > "$OUT/py_deptry.txt"   2>&1 || true; } || miss deptry   "pip install deptry"
  have bandit   && { echo "-> bandit";   bandit -r "$TARGET" -q                 > "$OUT/py_bandit.txt"   2>&1 || true; } || miss bandit   "pip install bandit"
  # Coverage ingestion (DY1): never RUN the suite here (read-only pass) — but if a
  # coverage data file already exists, render it. Uncovered public-API branches are
  # the cheapest incomplete-logic signal there is.
  COV_DATA=""
  [ -e .coverage ] && COV_DATA=".coverage"
  [ -z "$COV_DATA" ] && [ -e "$TARGET/.coverage" ] && COV_DATA="$TARGET/.coverage"
  if [ -n "$COV_DATA" ]; then
    have coverage && { echo "-> coverage report (existing data: $COV_DATA)"; coverage report -m --data-file="$COV_DATA" > "$OUT/py_coverage.txt" 2>&1 || true; }
  else
    echo "    [note] no coverage data found — run the test suite with coverage before the audit for uncovered-branch evidence"
  fi
  # Optional, only if your internal index carries them:
  have deadcode && { echo "-> deadcode (optional cross-check)"; deadcode "$TARGET" > "$OUT/py_deadcode.txt" 2>&1 || true; }
  have radon    && { echo "-> radon (optional)";                radon cc "$TARGET" -nc -s > "$OUT/py_radon.txt" 2>&1 || true; }
fi

# ---------------- TypeScript / JS ----------------
if [[ "$detected" == *node* ]]; then
  echo "== TS/JS pack =="
  # stderr goes to a sidecar file so the JSON stays parseable.
  have knip     && { echo "-> knip";     knip --no-exit-code --reporter json    > "$OUT/ts_knip.json"   2> "$OUT/ts_knip.err" || true; } || miss knip     "npm i -D knip"
  have ts-prune && { echo "-> ts-prune"; ts-prune                               > "$OUT/ts_prune.txt"   2>&1 || true; } || miss ts-prune "npm i -D ts-prune"
  have depcheck && { echo "-> depcheck"; depcheck                               > "$OUT/ts_depcheck.txt" 2>&1 || true; } || miss depcheck "npm i -D depcheck"
  [ -e coverage/lcov.info ] && { echo "-> coverage (existing lcov)"; cp coverage/lcov.info "$OUT/ts_lcov.info"; }
fi

# ---------------- Rust ----------------
if [[ "$detected" == *rust* ]]; then
  echo "== Rust pack =="
  have cargo && { echo "-> cargo build (dead_code/unused warnings)"; cargo build 2> "$OUT/rust_warnings.txt" || true; }
  have cargo-machete && { echo "-> cargo machete"; cargo machete > "$OUT/rust_machete.txt" 2>&1 || true; } || miss cargo-machete "cargo install cargo-machete"
  if have cargo && cargo +nightly udeps --version >/dev/null 2>&1; then
    echo "-> cargo udeps"; cargo +nightly udeps > "$OUT/rust_udeps.txt" 2>&1 || true
  else
    miss "cargo-udeps" "cargo install cargo-udeps (nightly)"
  fi
  have cargo && { echo "-> clippy"; cargo clippy 2> "$OUT/rust_clippy.txt" || true; }
  [ -e lcov.info ] && { echo "-> coverage (existing lcov)"; cp lcov.info "$OUT/rust_lcov.info"; }
fi

# ---------------- Go ----------------
if [[ "$detected" == *go* ]]; then
  echo "== Go pack =="
  have deadcode    && { echo "-> deadcode";    deadcode ./...    > "$OUT/go_deadcode.txt"    2>&1 || true; } || miss deadcode    "go install golang.org/x/tools/cmd/deadcode@latest"
  have staticcheck && { echo "-> staticcheck"; staticcheck ./... > "$OUT/go_staticcheck.txt" 2>&1 || true; } || miss staticcheck "go install honnef.co/go/tools/cmd/staticcheck@latest"
  have go          && { echo "-> go vet";      go vet ./...      > "$OUT/go_vet.txt"         2>&1 || true; }
  for prof in coverage.out cover.out; do
    [ -e "$prof" ] && { echo "-> coverage (existing profile: $prof)"; cp "$prof" "$OUT/go_coverage.out"; break; }
  done
fi

# ---------------- Cross-language: markers, suppressions, secrets, history ----------------
echo "== Cross-language =="

# Incompleteness markers (seed for Phase 3). Case-insensitive; includes every
# marker the taxonomy lists ("for now" included). Excludes vendored/build/audit dirs.
echo "-> grep incompleteness markers (seed for Phase 3)"
grep -riEn "${GREP_EXCLUDES[@]}" "$MARKER_RE" \
  "$TARGET" 2>/dev/null > "$OUT/markers.txt" || true

# Suppressed diagnostics (taxonomy Category G): every suppression is a diagnostic
# someone chose to hide — institutionalized debt. Surface them all.
echo "-> grep suppressed diagnostics (Category G)"
grep -rEn "${GREP_EXCLUDES[@]}" "$SUPPRESS_RE" \
  "$TARGET" 2>/dev/null > "$OUT/suppressions.txt" || true

# Test-health deterministic layer (references/test-health.md): nondeterminism,
# vacuity, and suite-shrinker candidates for test-health-auditor, gated INTO
# test paths via TEST_PATH_RE (it matches the grep file:line: prefixes).
# Candidates, not verdicts — the agent runs bounded probes before any HIGH.
echo "-> grep test-health signals (flaky/vacuous/skipped, gated into test paths)"
grep -rEn "${GREP_EXCLUDES[@]}" "$FLAKY_RE" \
  "$TARGET" 2>/dev/null | grep -E "$TEST_PATH_RE" > "$OUT/test_flakiness.txt" || true
grep -rEn "${GREP_EXCLUDES[@]}" "$TEST_VACUOUS_RE" \
  "$TARGET" 2>/dev/null | grep -E "$TEST_PATH_RE" > "$OUT/test_vacuity.txt" || true
grep -rEn "${GREP_EXCLUDES[@]}" "$TEST_SKIP_RE" \
  "$TARGET" 2>/dev/null | grep -E "$TEST_PATH_RE" > "$OUT/test_skips.txt" || true
# Empty-because-clean vs empty-because-no-tests must stay distinguishable.
if [ -z "$(src_files | grep -E "$TEST_PATH_RE" | head -1)" ]; then
  echo "    [note] no test files detected under $TARGET — empty test-health artifacts mean no tests, not a clean suite"
fi

# Stdout-as-log-channel (taxonomy Category LOG). Candidates, not verdicts:
# print-as-CLI-output is legitimate — the agent judges. Test files are out of
# scope for this lens (gated OUT via TEST_PATH_RE), and the count below is
# report-only: it never gates any strict surface.
echo "-> grep stdout-as-log-channel candidates (Category LOG, non-test paths)"
grep -rEn "${GREP_EXCLUDES[@]}" "$LOGGING_RE" \
  "$TARGET" 2>/dev/null | grep -vE "$TEST_PATH_RE" > "$OUT/stdout_logging.txt" || true

# Business-vital / transactional-integrity SEEDS — priority inputs, not debt:
# never counted, never ratcheted, and the prevention hook must never fire on
# legitimate new business code, so these regexes live HERE (single consumer),
# not in debt_patterns.sh. Change together with references/business-vitals.md
# (VITAL_RE, TELEMETRY_RE) and the incomplete-logic taxonomy Category TX
# (TX_GUARD_RE, TX_RETRY_RE). The tx priority queue downstream is
# vital_candidates ∩ tx_retries − tx_guards.
#
# VITAL_RE merges the vitals and TX money-verb lists into one superset,
# call/def-site anchored: a verb matches only as a whole underscore-delimited
# identifier segment with an open paren after the identifier, and the
# identifier may not start with an underscore (_charge is out by design).
# recharge/turbocharged/credits_remaining/AUTHORED_BY never match, and bare
# 'wire' is excluded (precision WONTFIX — 'transfer' covers wire_transfer).
# Precision fixture: planted_pkg/ui.py (N2).
VITAL_RE='(^|[^A-Za-z0-9_])([A-Za-z0-9]+_)*(transfer|refund|charge|payout|payment|pay|deposit|withdraw|disburse|settle|invoice|billing|loan|approve|credit|debit|auth|authorize|subscribe|checkout)(_[A-Za-z0-9]+)*\('
# Emissions: a structured business event with a stable dot-namespaced name.
# A prose log line is NOT an emission (fixture: billing.py _LOG.info, J5 pin).
TELEMETRY_RE='\b(emit_event|emit|track_event|track|publish_event|publish|log_event|record_event|send_event|capture_event|increment|incr|gauge|histogram|observe|timing|count|counter|start_span|span|statsd\.[a-z_]+|metrics\.[a-z_]+)\(["'\''"][A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+["'\''"]'
# Idempotency/dedupe guards (already-processed checks before a side effect):
# presence is corroboration (N8); absence on a path is the agent's TX call.
TX_GUARD_RE='\bin _?[A-Za-z_]*(PROCESSED|SEEN|HANDLED|DEDUP|processed|seen|handled|dedup)[A-Za-z_]*|[Ii]dempoten|Idempotency-Key|ON CONFLICT|INSERT OR IGNORE|\b[Ss][Ee][Tt][Nn][Xx]\b'
# Attempt-counting retry shapes around writes. Bounded poll-with-timeout loops
# (planted_pkg/poller.py, N4) deliberately do not match.
TX_RETRY_RE='\bfor [A-Za-z_]*(attempt|retr)[A-Za-z_]* in range\(|\bwhile [A-Za-z_]*(attempt|retr)|@retry\b|\bretrying\.|tenacity|backoff\.on_exception|max_retries|jest\.retryTimes\('
echo "-> grep business-vital / tx-integrity seeds (candidates, not counted)"
grep -riEn "${GREP_EXCLUDES[@]}" "$VITAL_RE" \
  "$TARGET" 2>/dev/null > "$OUT/vital_candidates.txt" || true
grep -rEn "${GREP_EXCLUDES[@]}" "$TELEMETRY_RE" \
  "$TARGET" 2>/dev/null > "$OUT/telemetry.txt" || true
grep -rEn "${GREP_EXCLUDES[@]}" "$TX_GUARD_RE" \
  "$TARGET" 2>/dev/null > "$OUT/tx_guards.txt" || true
grep -rEn "${GREP_EXCLUDES[@]}" "$TX_RETRY_RE" \
  "$TARGET" 2>/dev/null > "$OUT/tx_retries.txt" || true
# Alerting seam: alert/monitor/prometheus/SLO-named config files (minus
# EXCLUDE_DIRS). Empty = honest "unknown — no alert config in repo".
src_files | grep -iE '(^|/)[^/]*(alert|monitor|slo)[^/]*\.(ya?ml|json|toml|ini|cfg|conf|rules)$|(^|/)prometheus[^/]*$' \
  > "$OUT/alerting_config.txt" || true

# Navigability: non-blank-line size ladder — 400 [attention] / 800 [warn] /
# 1600 [god-file], sorted descending. Triage input for architecture-reviewer.
echo "-> file-size ladder (non-blank lines: 400/800/1600 rungs)"
src_files | while IFS= read -r f; do
  n=$(awk 'NF { n++ } END { print n + 0 }' "$f" 2>/dev/null)
  [ -n "$n" ] || continue
  if   [ "$n" -ge 1600 ]; then echo "$n [god-file] $f"
  elif [ "$n" -ge 800  ]; then echo "$n [warn] $f"
  elif [ "$n" -ge 400  ]; then echo "$n [attention] $f"
  fi
done | sort -rn > "$OUT/giant_files.txt"

# Commented-out code blocks: runs of >= CO_MIN_RUN consecutive comment lines
# with >= CO_MIN_CODE code-shaped ones. CODE_COMMENT_RE is leader-anchored, so
# prose with mid-sentence code words never matches (metrics.py N11 fixture).
# The regexes ride in via ENVIRON — awk -v would mangle the backslashes.
echo "-> commented-out code blocks (>= $CO_MIN_RUN comment lines, >= $CO_MIN_CODE code-shaped)"
src_files | while IFS= read -r f; do
  COMMENT_LINE_RE="$COMMENT_LINE_RE" CODE_COMMENT_RE="$CODE_COMMENT_RE" \
    awk -v minrun="$CO_MIN_RUN" -v mincode="$CO_MIN_CODE" '
      function flush(end) {
        if (run >= minrun && code >= mincode)
          printf "%s:%d-%d: commented-out code block (%d lines, %d code-shaped)\n", FILENAME, start, end, run, code
        run = 0; code = 0
      }
      $0 ~ ENVIRON["COMMENT_LINE_RE"] {
        if (run == 0) start = NR
        run += 1
        if ($0 ~ ENVIRON["CODE_COMMENT_RE"]) code += 1
        next
      }
      { flush(NR - 1) }
      END { flush(NR) }
    ' "$f" 2>/dev/null
done > "$OUT/commented_code.txt"

# Near-duplicates: REAL jscpd when installed; loud [skip] degrade on target
# repos, never a silent pass (the suite's own self_test.sh hard-requires jscpd
# instead). All writes stay under $OUT/: raw report in $OUT/dup/, stderr in a
# sidecar (knip precedent), and dup_jscpd.json normalized to the duplicates
# list only — the raw report's statistics block can name clean files, which
# would poison downstream absence checks.
if have jscpd; then
  echo "-> jscpd (near-duplicates, --min-tokens 50)"
  JSCPD_IGNORE=""
  for d in "${EXCLUDE_DIRS[@]}"; do JSCPD_IGNORE="$JSCPD_IGNORE,**/$d/**"; done
  jscpd "$TARGET" --min-tokens 50 --reporters json --output "$OUT/dup" \
    --ignore "${JSCPD_IGNORE#,}" --silent >/dev/null 2> "$OUT/dup_jscpd.err" || true
  if [ -e "$OUT/dup/jscpd-report.json" ]; then
    if have python3; then
      python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); json.dump({"duplicates": r.get("duplicates", [])}, open(sys.argv[2], "w"), indent=1)' \
        "$OUT/dup/jscpd-report.json" "$OUT/dup_jscpd.json" 2>> "$OUT/dup_jscpd.err" \
        || cp "$OUT/dup/jscpd-report.json" "$OUT/dup_jscpd.json"
    else
      cp "$OUT/dup/jscpd-report.json" "$OUT/dup_jscpd.json"
    fi
  fi
else
  miss jscpd "npm i -g jscpd (optional — agents still hunt near-dups manually)"
fi

# Mutation-report INGESTION (never run here — owner-run only). Survived
# mutants are the gold-standard vacuity evidence; test-health-auditor puts
# them at the top of its queue.
mutation_found=""
for f in "$TARGET/reports/mutation/mutation-report.json" "reports/mutation/mutation-report.json" \
         "$TARGET/mutation-report.json" "mutation-report.json"; do
  [ -e "$f" ] && { echo "-> mutation report (Stryker): $f"; cp "$f" "$OUT/mutation_stryker.json"; mutation_found=1; break; }
done
for f in "$TARGET/mutants.out/missed.txt" "mutants.out/missed.txt"; do
  [ -e "$f" ] && { echo "-> mutation report (cargo-mutants): $f"; cp "$f" "$OUT/mutation_cargo_missed.txt"; mutation_found=1; break; }
done
for f in "$TARGET/go-mutesting.report" "go-mutesting.report"; do
  [ -e "$f" ] && { echo "-> mutation report (go-mutesting): $f"; cp "$f" "$OUT/mutation_go.txt"; mutation_found=1; break; }
done
if { [ -e .mutmut-cache ] || [ -e "$TARGET/.mutmut-cache" ]; } && have mutmut; then
  echo "-> mutation report (mutmut cache query — no tests executed)"
  mutmut results > "$OUT/mutation_mutmut.txt" 2>&1 || true
  mutation_found=1
fi
[ -n "$mutation_found" ] || echo "    [note] no mutation report found — run mutation testing out-of-band (optional)"

# Machine-readable counts for the ratchet (see references/audit-state-and-verify.md):
# /verify compares these against the previous run's state.json. EXACTLY the 8
# ratcheted keys live here — vitals/telemetry/tx seeds are priority inputs and
# are deliberately never counted; stdout_logging_count is report-only and
# never gates any strict surface (loop-safety: a gate that is often wrong gets
# disabled).
marker_count=$(wc -l < "$OUT/markers.txt" | tr -d ' ')
suppression_count=$(wc -l < "$OUT/suppressions.txt" | tr -d ' ')
flaky_count=$(wc -l < "$OUT/test_flakiness.txt" | tr -d ' ')
test_vacuity_count=$(wc -l < "$OUT/test_vacuity.txt" | tr -d ' ')
test_skip_count=$(wc -l < "$OUT/test_skips.txt" | tr -d ' ')
stdout_logging_count=$(wc -l < "$OUT/stdout_logging.txt" | tr -d ' ')
giant_file_count=$(wc -l < "$OUT/giant_files.txt" | tr -d ' ')
commented_code_count=$(wc -l < "$OUT/commented_code.txt" | tr -d ' ')
{
  echo "marker_count=$marker_count"
  echo "suppression_count=$suppression_count"
  echo "flaky_count=$flaky_count"
  echo "test_vacuity_count=$test_vacuity_count"
  echo "test_skip_count=$test_skip_count"
  echo "stdout_logging_count=$stdout_logging_count"
  echo "giant_file_count=$giant_file_count"
  echo "commented_code_count=$commented_code_count"
} > "$OUT/counts.env"
echo "-> counts: markers=$marker_count suppressions=$suppression_count flaky=$flaky_count vacuous=$test_vacuity_count skips=$test_skip_count stdout=$stdout_logging_count giant=$giant_file_count commented=$commented_code_count (audit/counts.env)"

# Git-history evidence (DT5): WIP-ish commits and churn hotspots — cheap signal
# for "recently rushed" code the agents should prioritize.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "-> git history signals"
  git log --oneline -100 -i --grep 'wip\|temporary\|hack\|stopgap\|quick fix\|for now' > "$OUT/git_wip_commits.txt" 2>/dev/null || true
  git log --format= --name-only -200 2>/dev/null | grep -v '^$' | sort | uniq -c | sort -rn | head -25 > "$OUT/git_churn.txt" || true
fi

have gitleaks && { echo "-> gitleaks (secrets)"; gitleaks detect --source "$TARGET" --report-path "$OUT/secrets.json" --no-banner 2>/dev/null || true; } || miss gitleaks "https://github.com/gitleaks/gitleaks"

echo
echo "==> Done. Raw evidence in $OUT/."
echo "    These are CANDIDATES. Next: agents run Phase 3 (incomplete-logic taxonomy),"
echo "    security, performance, architecture, and journey review by READING (and where"
echo "    safe, RUNNING) the code — tools cannot find stubs, fake implementations,"
echo "    logic-level vulns, or broken documented workflows."
echo "    Do NOT delete on tool output alone. See references/safe-deletion-workflow.md."
