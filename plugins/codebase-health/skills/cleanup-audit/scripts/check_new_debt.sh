#!/usr/bin/env bash
# Prevention ratchet: flag NEWLY INTRODUCED debt in changed lines — incompleteness
# markers, suppressed diagnostics, nondeterminism/vacuity/skips in new test lines,
# stdout-as-log-channel candidates, and commented-out code blocks.
#
# Usage:
#   check_new_debt.sh [BASE_REF]      # scan added lines since BASE_REF (default: uncommitted vs HEAD)
#   check_new_debt.sh --hook          # Claude Code PostToolUse hook mode: reads tool JSON on stdin,
#                                     #   checks the edited file (untracked files are scanned whole);
#                                     #   emits hookSpecificOutput.additionalContext JSON so the
#                                     #   warning actually reaches the model (plain stdout would not)
#   check_new_debt.sh --no-strict     # CLI escape hatch: warn-and-exit-0 (WARN_ONLY=1 env is equivalent)
#   check_new_debt.sh --strict [REF]  # accepted, now-redundant back-compat flag (strict is the CLI default)
#
# THE ONE STRICTNESS CONTRACT (SPEC_1.4.0 §4.3, Decision 1 — citing loop-safety.md):
#   WHAT gates: exit 1 triggers on new markers, suppressions, flaky-in-test-lines,
#   vacuous/skip-in-test-lines, and commented-out code blocks (high-precision,
#   fixture-locked classes). It deliberately does NOT trigger on stdout-logging
#   hits (legitimate-use-heavy; a gate that is often wrong gets disabled) —
#   stdout stays report-only on every surface.
#   CI/script surface — strict by DEFAULT: CLI mode (the documented CI-step
#   usage) exits 1 on the gated classes with no flag needed. --strict is
#   retained as an accepted, now-redundant flag for backward compatibility.
#   Escape hatches: --no-strict flag or WARN_ONLY=1 env → warn-and-exit-0.
#   Unresolvable BASE under the strict default stays loud + exit 1 — a CI gate
#   that silently passes is worse than no gate.
#   Hook surface — warn-only, UNCONDITIONALLY: --hook always exits 0 and ignores
#   --strict/--no-strict/WARN_ONLY entirely. This is loop-safety invariant 3
#   (hooks warn; they never block or fix) — an invariant, not a default, and NOT
#   overturned by the strict-by-default decision.
#
# Loop-safety invariant (references/loop-safety.md): this is a REPORTER. Exit
# codes signal; nothing is ever modified, reverted, or auto-fixed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=debt_patterns.sh
. "$SCRIPT_DIR/debt_patterns.sh"
# shellcheck source=py_run.sh
. "$SCRIPT_DIR/py_run.sh"   # pyrun: uv-first Python (ADR 0015), python3 fallback

STRICT=1   # Decision 1: strict is the DEFAULT on the CLI/CI surface
HOOK=0
BASE="HEAD"
for arg in "$@"; do
  case "$arg" in
    --strict)    : ;;          # accepted, now-redundant no-op (strict is already the default)
    --no-strict) STRICT=0 ;;   # documented CI escape hatch (flag form)
    --hook)      HOOK=1 ;;
    *)           BASE="$arg" ;;
  esac
done
[ "${WARN_ONLY:-0}" = "1" ] && STRICT=0   # documented CI escape hatch (env form)

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0  # not a repo: nothing to compare against

# An unresolvable BASE (typo, shallow CI clone, unborn HEAD) must never look
# like a clean pass — loop-safety invariant 6 (no silent truncation). Under the
# strict default this stays loud + exit 1 (SPEC_1.4.0 §4.3, unchanged behavior).
if ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1; then
  if [ "$HOOK" = 1 ]; then
    BASE=""  # brand-new repo: treat every tracked line as added? No — hook falls back to whole-file scan below.
  else
    echo "[codebase-health] cannot resolve base ref '$BASE' — nothing was checked." >&2
    [ "$STRICT" = 1 ] && exit 1
    exit 0
  fi
fi

diff_added() { # added lines only, with file:line prefixes
  git diff -U0 "$BASE" -- "$@" 2>/dev/null \
    | awk '/^\+\+\+ b\//{f=substr($0,7)} /^@@/{split($3,a,","); ln=substr(a[1],2)} /^\+[^+]/{printf "%s:%s:%s\n", f, ln, substr($0,2); ln++}'
}

emit_hook_context() { # $1 = message; JSON-escape newlines/quotes without jq
  # uv-first (ADR 0015); on any Python failure, a valid generic JSON string is
  # emitted so the warn-only hook still reaches the model (invariant 3).
  py_escaped=$(printf '%s' "$1" | pyrun -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null) || py_escaped='"[codebase-health] new debt introduced (see check_new_debt.sh)"'
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":%s}}\n' "$py_escaped"
}

added=""
if [ "$HOOK" = 1 ]; then
  # PostToolUse hook: stdin carries the tool-call JSON; extract file_path without jq.
  input=$(cat 2>/dev/null || true)
  fp=$(printf '%s' "$input" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"file_path"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
  [ -z "$fp" ] && exit 0
  [ -f "$fp" ] || exit 0
  if [ -n "$BASE" ] && git ls-files --error-unmatch -- "$fp" >/dev/null 2>&1; then
    added=$(diff_added "$fp")
  else
    # Untracked (newly created) file — the most common "just introduced debt"
    # case. No diff exists yet; scan the whole file.
    added=$(grep -nE ".*" "$fp" 2>/dev/null | sed "s|^|$fp:|" | head -500)
  fi
else
  added=$(diff_added)
fi
[ -z "$added" ] && exit 0

# ── SPEC_1.4.0 §4.2 (pre-flight fix C): gather ALL six new-debt classes FIRST,
# then ONE combined emptiness check. A literal "append after the old
# markers/suppressions early exit" is WRONG — it would report nothing on a
# flaky-only diff (the section-5 self-test pins exactly that mistake).
new_markers=$(printf '%s\n' "$added" | grep -iE "$MARKER_RE" || true)
new_suppress=$(printf '%s\n' "$added" | grep -E "$SUPPRESS_RE" || true)
# flaky/vacuous/skip are TEST_PATH_RE-scoped: a sleep in prod code is agent
# territory, and .skip tokens on non-test paths are noise, not suite shrinkage.
new_flaky=$(printf '%s\n' "$added" | grep -E "$TEST_PATH_RE" | grep -E "$FLAKY_RE" || true)
new_testvac=$(printf '%s\n' "$added" | grep -E "$TEST_PATH_RE" | grep -E "$TEST_VACUOUS_RE|$TEST_SKIP_RE" || true)
# stdout-as-log candidates on NON-test lines. Report-only on every surface —
# never a gate (print-as-CLI-output is legitimate; see LOGGING_RE's N6 fixture).
new_stdout=$(printf '%s\n' "$added" | grep -vE "$TEST_PATH_RE" | grep -E "$LOGGING_RE" || true)
# Commented-out code blocks: >= CO_MIN_RUN same-file ADJACENT added comment
# lines of which >= CO_MIN_CODE are code-shaped. Prose comment runs never trip
# this (CODE_COMMENT_RE anchors the code token right after the comment leader).
# Regexes travel via the environment: awk -v would mangle their backslashes.
new_commented=$(printf '%s\n' "$added" | COMMENT_RE="$COMMENT_LINE_RE" CODE_RE="$CODE_COMMENT_RE" awk -v minrun="$CO_MIN_RUN" -v mincode="$CO_MIN_CODE" '
  function flush() {
    if (run >= minrun && code >= mincode)
      printf "%s:%d-%d: commented-out code block (%d comment lines, %d code-shaped)\n", rf, rs, rl, run, code
    run = 0; code = 0
  }
  BEGIN { cre = ENVIRON["COMMENT_RE"]; kre = ENVIRON["CODE_RE"] }
  {
    i = index($0, ":"); f = substr($0, 1, i - 1); rest = substr($0, i + 1)
    j = index(rest, ":"); ln = substr(rest, 1, j - 1) + 0; c = substr(rest, j + 1)
    if (c ~ cre) {
      if (run > 0 && f == rf && ln == rl + 1) { run++; rl = ln }
      else { flush(); rf = f; rs = ln; rl = ln; run = 1 }
      if (c ~ kre) code++
    } else flush()
  }
  END { flush() }' || true)

# ONE combined emptiness check across all six classes (pre-flight fix C).
[ -z "$new_markers$new_suppress$new_flaky$new_testvac$new_stdout$new_commented" ] && exit 0

msg="[codebase-health] newly introduced debt in changed lines:"
[ -n "$new_markers" ]  && msg="$msg
  incompleteness markers:
$(printf '%s\n' "$new_markers"  | sed 's/^/    /' | head -20)"
[ -n "$new_suppress" ] && msg="$msg
  suppressed diagnostics:
$(printf '%s\n' "$new_suppress" | sed 's/^/    /' | head -20)"
[ -n "$new_flaky" ]    && msg="$msg
  nondeterminism in new test lines:
$(printf '%s\n' "$new_flaky"    | sed 's/^/    /' | head -20)
    a flaky test cannot serve as closure evidence — seed it, inject the clock,
    fake the transport; /verify reruns closing tests 5x."
[ -n "$new_testvac" ]  && msg="$msg
  vacuous/skipped tests (a green test that asserts nothing is coverage theater):
$(printf '%s\n' "$new_testvac"  | sed 's/^/    /' | head -20)"
[ -n "$new_stdout" ]   && msg="$msg
  stdout logging in new non-test lines (report-only; print-as-CLI-output can be
  legitimate — this class never gates, on any surface):
$(printf '%s\n' "$new_stdout"   | sed 's/^/    /' | head -20)"
[ -n "$new_commented" ] && msg="$msg
  newly introduced commented-out code block(s):
$(printf '%s\n' "$new_commented" | sed 's/^/    /' | head -20)"
msg="$msg
  If intentional, fine — but each of these is a future audit finding.
  (see cleanup-audit references/loop-safety.md)"

if [ "$HOOK" = 1 ]; then
  # Hook surface: JSON on stdout is the only channel that reaches the model,
  # and the exit code is UNCONDITIONALLY 0 — loop-safety invariant 3 (hooks
  # warn; they never block or fix). All strictness flags were ignored above.
  emit_hook_context "$msg"
  exit 0
fi

echo "$msg"
# CLI/CI gate (strict by default): markers, suppressions, flaky, vacuous/skip,
# commented blocks. new_stdout is deliberately absent — stdout never gates.
if [ "$STRICT" = 1 ] && [ -n "$new_markers$new_suppress$new_flaky$new_testvac$new_commented" ]; then
  exit 1
fi
exit 0
