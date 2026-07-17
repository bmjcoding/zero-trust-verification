#!/usr/bin/env bash
# test_harness.sh — the suite's ONE sourced assertion library (ADR 0025 Wave 4).
#
# Seven self-tests previously re-declared the same pass/fail/assert_* helpers in
# two dialects; this file is the single copy. It is SOURCED, never executed:
#
#   . "<repo-root>/scripts/test_harness.sh"
#   th_init <dialect> <summary-style> [summary-prefix]
#
# Dialect A ("ok   [id] msg" / "FAIL [id] msg"-to-stderr; id-cited assertions):
#   pass fail skip assert_eq assert_contains assert_not_contains assert_absent
#   assert_rc assert_rc_nonzero + PASS/FAIL/SKIP counters.
#   Used by: self_test_marshal.sh, self_test_org_memory.sh, self_test_triage.sh,
#   outcome_self_test.sh, autopilot self_test.sh.
#
# Dialect B ("  ok  - msg" / "  FAIL - msg"; label-only assertions):
#   ok fail assert_grep assert_not_grep assert_py + PASS/FAIL counters.
#   (assert_py runs "${PYRUN[@]}" — the sourcing file defines PYRUN.)
#   Used by: sd_self_test.sh, tests/codebase-health/self_test.sh.
#
# th_summary emits each file's pre-Wave-4 summary line BYTE-IDENTICALLY (the
# suite orchestrator's run_ok greps these; humans diff them) and returns 0 iff
# FAIL==0 — callable as a script's last command to keep the exit contract.
#   style banner      : blank, ===, "<prefix>PASS=N FAIL=M", ===
#   style plain       : blank, "<prefix>PASS=N FAIL=M"
#   style worded      : blank, "== self-test: N passed, M failed =="
#   style worded-skip : blank, "self_test: N passed, M failed, K skipped"
#
# SKIP-HONESTY CONTRACT (suite_self_test.sh component_skips): on a NON-skip path
# this library never prints uppercase "SKIPPED", a counter matching
# '[1-9][0-9]* skipped', or a line starting '[skip]'. skip() prints the
# lowercase "skip [id] msg" shape (not detector-matched); a run with SKIP>0
# surfaces honestly through the worded-skip summary's "K skipped".
#
# Portability: bash 3.2 (macOS default) + BSD userland safe — no `declare -A`,
# no `\b` in sed, printf over echo -e, pure-bash case-glob matching (no
# subprocess per assertion).
if [ -n "${TH_LOADED:-}" ]; then return 0; fi
TH_LOADED=1

th_init() {  # <dialect A|B> <summary-style banner|plain|worded|worded-skip> [summary-prefix]
  TH_DIALECT="$1"
  TH_STYLE="$2"
  TH_PREFIX="${3:-}"
  PASS=0
  FAIL=0
  SKIP=0
  case "$TH_DIALECT" in
    A)
      pass() { printf 'ok   [%s] %s\n' "$1" "$2"; PASS=$((PASS+1)); }
      fail() { printf 'FAIL [%s] %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }
      skip() { printf 'skip [%s] %s\n' "$1" "$2"; SKIP=$((SKIP+1)); }
      assert_eq()           { if [ "$3" = "$4" ]; then pass "$1" "$2"; else fail "$1" "$2 — expected [$3], got [$4]"; fi; }
      assert_contains()     { case "$4" in *"$3"*) pass "$1" "$2";; *) fail "$1" "$2 — missing [$3]";; esac; }
      assert_not_contains() { case "$4" in *"$3"*) fail "$1" "$2 — found forbidden [$3]";; *) pass "$1" "$2";; esac; }
      assert_absent()       { assert_not_contains "$@"; }
      assert_rc()           { if [ "$3" -eq "$4" ]; then pass "$1" "$2"; else fail "$1" "$2 — expected rc $3 got $4"; fi; }
      assert_rc_nonzero()   { if [ "$3" -ne 0 ]; then pass "$1" "$2"; else fail "$1" "$2 — expected non-zero rc, got 0"; fi; }
      ;;
    B)
      ok()   { PASS=$((PASS+1)); printf '  ok  - %s\n' "$1"; }
      fail() { FAIL=$((FAIL+1)); printf '  FAIL - %s\n' "$1"; }
      assert_grep()     { if grep -qiE "$2" "$1" 2>/dev/null; then ok "$3"; else fail "$3"; fi; }
      assert_not_grep() { if grep -qiE "$2" "$1" 2>/dev/null; then fail "$3"; else ok "$3"; fi; }
      # assert_py CODE MSG — CODE is Python that exits 0 on pass, non-zero on fail.
      assert_py()       { if "${PYRUN[@]}" -c "$1" >/dev/null 2>&1; then ok "$2"; else fail "$2"; fi; }
      ;;
    *)
      printf 'test_harness: unknown dialect [%s]\n' "$TH_DIALECT" >&2
      return 64
      ;;
  esac
}

th_summary() {  # emit the sourcing file's summary shape; status 0 iff FAIL==0
  printf '\n'
  case "$TH_STYLE" in
    banner)
      printf '===============================\n'
      printf '%sPASS=%s FAIL=%s\n' "$TH_PREFIX" "$PASS" "$FAIL"
      printf '===============================\n'
      ;;
    plain)
      printf '%sPASS=%s FAIL=%s\n' "$TH_PREFIX" "$PASS" "$FAIL"
      ;;
    worded)
      printf '== self-test: %s passed, %s failed ==\n' "$PASS" "$FAIL"
      ;;
    worded-skip)
      printf 'self_test: %s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
      ;;
  esac
  [ "$FAIL" -eq 0 ]
}
