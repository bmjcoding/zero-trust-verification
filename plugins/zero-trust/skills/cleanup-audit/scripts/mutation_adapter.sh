#!/usr/bin/env bash
# mutation_adapter.sh — MT-01 per-language mutation adapter (the ONE map).
#
# The suite first-classes mutation testing at THREE consumers (ADR 0016, MT-10):
#   * autopilot D6.5 (mutation_gate.sh) — PRODUCES a fresh survivor set drain-side
#     (the only place a tool RUNS, trap-isolated in a throwaway worktree),
#   * the PR-Gate sibling (check_mutation_survivors.sh) — CONSUMES the ingested
#     report scoped to the diff,
#   * run_audit.sh ingestion — CONSUMES the whole-repo report.
# To keep one tool family / one map / no drift (MT-10, pinned by root lint V7),
# the survivor->location RESOLVER lives HERE and is vendored BYTE-IDENTICAL into
# autopilot (plugins/autopilot/scripts/mutation_adapter.sh). Both consumers
# normalize identically; the doc form of this map is the vendored block in
# references/cross-language-tooling.md.
#
# This is a REPORTER (codebase-health invariant 1 / autopilot loop-safety
# invariant 1): it reads tool output on stdin and PRINTS a normalized survivor
# set. It NEVER runs a mutation tool and NEVER mutates any tree.
#
# Subcommands:
#   normalize <tool>          read raw tool output on STDIN, print the normalized
#                             survivor set on STDOUT — one `<path>:<line>` per
#                             line (sorted, unique). A survivor a tool yields with
#                             NO line degrades to `<path>:-` (file granularity,
#                             MT-01/MT-05). Notes go to STDERR; STDOUT is the set.
#   count <tool>              read raw tool output on STDIN, print the TOTAL mutant
#                             count (best-effort) — the D6.5 mutant-budget backstop
#                             (MT-07). A lower-bound count only makes the budget more
#                             conservative; never a false block (budget = exit 0).
#   invocation <tool> [file…] print the documented changed-FILES invocation.
#   tools                     list the supported tools (one per line).
#
# Tools + honest line/diff capability (ADR 0016 — stated, not laundered):
#   stryker        StrykerJS      LINE (mutation-report.json, --incremental/--mutate ranges)
#   cargo-mutants  cargo-mutants  LINE (missed.txt, --in-diff)
#   mutmut         mutmut         FILE at invocation; survivor->file:line resolved
#                                 POST-HOC via `mutmut show` (NOT `mutmut results`)
#   go-mutesting   go-mutesting   FILE (no line; every survivor degrades to `<path>:-`)
#
# Portability: bash 3.2 + BSD userland. Stryker's report is JSON, parsed with an
# stdlib-only Python (uv-first per ADR 0015, python3 fallback); the other three
# are line-oriented text parsed with awk. No third-party Python deps.

set -u

usage() {
  echo "usage: mutation_adapter.sh {normalize <tool>|count <tool>|invocation <tool> [file…]|tools}" >&2
  echo "       tools: stryker cargo-mutants mutmut go-mutesting" >&2
  exit 64
}

# uv-first (ADR 0015: `uv run --no-project`), python3 fallback. stdlib-only, so
# the fallback interpreter needs no packages. Code in $1, extra argv after.
_mut_py() {
  local code="$1"; shift
  if command -v uv >/dev/null 2>&1; then
    uv run --no-project --quiet python -c "$code" "$@"
  else
    python3 -c "$code" "$@"
  fi
}

# ── normalizers: raw tool output (stdin) -> `<path>:<line>` / `<path>:-` ───────

# StrykerJS mutation-report.json: files{}.<path>.mutants[] with status "Survived"
# carry a start line. LINE. Only "Survived" is counted — a survived mutant is the
# precise "a test executed this line and constrained nothing" signal; "NoCoverage"
# (no test executes the line) is a DIFFERENT class the coverage gate (CH-06) owns,
# deliberately excluded here so the vacuity signal stays high-precision.
_norm_stryker() {
  _mut_py '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write("[note] mutation-adapter: unparseable Stryker JSON (%s)\n" % e)
    sys.exit(0)
out = set()
for path, entry in (d.get("files") or {}).items():
    for m in (entry.get("mutants") or []):
        if m.get("status") == "Survived":
            loc = ((m.get("location") or {}).get("start") or {})
            ln = loc.get("line")
            out.add("%s:%s" % (path, ln if isinstance(ln, int) else "-"))
for line in sorted(out):
    print(line)
'
}

# cargo-mutants missed.txt: `<file>:<line>:<col>: <mutation description>`. LINE.
_norm_cargo() {
  awk '
    /^[^:]+:[0-9]+:[0-9]+:/ {
      n = split($1, a, ":")            # $1 is file:line:col: up to first space
      # reconstruct file (fields before the last two numeric) — paths are colon-
      # free on Unix, so a[1]=file, a[2]=line.
      if (a[2] ~ /^[0-9]+$/) print a[1] ":" a[2]
    }
  ' | LC_ALL=C sort -u
}

# mutmut `mutmut show` unified diff: `+++ <path>` sets the file, each `@@ -<n>`
# hunk header is a survivor line. FILE at invocation; file:line resolved post-hoc.
# (`mutmut results` — bare survivor IDs — carries NO location; the map documents
# that `mutmut show` is required, and an id-only stream yields nothing here.)
_norm_mutmut() {
  awk '
    /^\+\+\+ / {
      f = $2
      sub(/^b\//, "", f)              # strip git-style b/ prefix if present
      next
    }
    /^@@ / {
      # @@ -<oldstart>[,<oldlen>] +<newstart>[,<newlen>] @@
      s = $2                          # -<oldstart>[,<oldlen>]
      sub(/^-/, "", s)
      sub(/,.*$/, "", s)
      if (f != "" && s ~ /^[0-9]+$/) print f ":" s
    }
  ' | LC_ALL=C sort -u
}

# go-mutesting: `FAIL "<path>[.<idx>]" with checksum …` is a SURVIVED mutant (the
# suite did NOT fail on the mutant). No line is emitted -> `<path>:-` (FILE
# granularity; the changed-LINE filter is applied post-hoc in the join, MT-05).
_norm_go() {
  awk '
    /^FAIL[[:space:]]+"/ {
      s = $0
      sub(/^FAIL[[:space:]]+"/, "", s)
      sub(/".*$/, "", s)                          # keep the quoted path only
      sub(/^.*\/go-mutesting-[0-9]+\//, "", s)    # drop a /tmp/go-mutesting-NNN/ prefix if present
      sub(/\.[0-9]+$/, "", s)                     # drop the trailing .<mutation-index>
      if (s != "") print s ":-"
    }
  ' | LC_ALL=C sort -u
}

# ── total-mutant count (for the D6.5 affordability budget, MT-07) ─────────────
# Best-effort TOTAL mutants tested (not just survivors), for the mutant-cap
# backstop. Each has a summary/entry fallback; a count is a lower bound at worst,
# which only ever makes the budget MORE conservative (never a false block: budget
# exhaustion is exit-0 report-only).
_count_stryker() {
  _mut_py '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); sys.exit(0)
n = 0
for entry in (d.get("files") or {}).values():
    n += len(entry.get("mutants") or [])
print(n)
'
}
# BSD/macOS awk lacks gawk's 3-arg match(); use grep -oE (portable) for totals.
_count_cargo() {
  local raw n; raw="$(cat)"
  n="$(printf '%s\n' "$raw" | grep -oE '[0-9]+ mutants (tested|generated)' | head -1 | grep -oE '^[0-9]+')"
  if [ -n "$n" ]; then printf '%s\n' "$n"
  else printf '%s\n' "$(printf '%s\n' "$raw" | grep -cE '^[^:]+:[0-9]+:[0-9]+:')"; fi
}
_count_mutmut() { grep -c '^@@ ' 2>/dev/null | head -1; }
_count_go() {
  local raw n; raw="$(cat)"
  n="$(printf '%s\n' "$raw" | grep -oE 'total is [0-9]+' | head -1 | grep -oE '[0-9]+$')"
  if [ -n "$n" ]; then printf '%s\n' "$n"
  else printf '%s\n' "$(printf '%s\n' "$raw" | grep -cE '^(PASS|FAIL)[[:space:]]+"')"; fi
}

# ── invocation strings (documented; the orchestrator resolves gates.test_mutation)

_inv_stryker()  { echo "npx stryker run --incremental --mutate ${*:-<changed-files>}"; }
_inv_cargo()    { local f o=""; for f in "$@"; do o="$o -f $f"; done; echo "cargo mutants --in-diff HEAD^..HEAD${o:- -f <changed-files>}"; }
_inv_mutmut()   { local j; j="$(IFS=,; echo "${*:-<changed-files>}")"; echo "mutmut run --paths-to-mutate \"$j\" ; mutmut show"; }
_inv_go()       { echo "go-mutesting ${*:-<changed-packages>}"; }

# ── dispatch ──────────────────────────────────────────────────────────────────

[ $# -ge 1 ] || usage
cmd="$1"; shift

case "$cmd" in
  tools)
    printf '%s\n' stryker cargo-mutants mutmut go-mutesting
    ;;
  normalize)
    [ $# -ge 1 ] || usage
    case "$1" in
      stryker)       _norm_stryker ;;
      cargo-mutants) _norm_cargo ;;
      mutmut)        _norm_mutmut ;;
      go-mutesting)  _norm_go ;;
      *) echo "[note] mutation-adapter: no resolver for tool '$1' (supported: stryker cargo-mutants mutmut go-mutesting)" >&2; exit 64 ;;
    esac
    ;;
  count)
    [ $# -ge 1 ] || usage
    case "$1" in
      stryker)       _count_stryker ;;
      cargo-mutants) _count_cargo ;;
      mutmut)        _count_mutmut ;;
      go-mutesting)  _count_go ;;
      *) echo "[note] mutation-adapter: no counter for tool '$1'" >&2; exit 64 ;;
    esac
    ;;
  invocation)
    [ $# -ge 1 ] || usage
    tool="$1"; shift
    case "$tool" in
      stryker)       _inv_stryker "$@" ;;
      cargo-mutants) _inv_cargo "$@" ;;
      mutmut)        _inv_mutmut "$@" ;;
      go-mutesting)  _inv_go "$@" ;;
      *) echo "[note] mutation-adapter: no invocation for tool '$tool'" >&2; exit 64 ;;
    esac
    ;;
  *) usage ;;
esac
