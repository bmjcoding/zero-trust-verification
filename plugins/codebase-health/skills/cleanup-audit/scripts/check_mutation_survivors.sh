#!/usr/bin/env bash
# check_mutation_survivors.sh — PR-Gate mutation sibling (ADR 0016 / MT-04,05,06).
#
# A diff-scoped sibling composed into pr_gate.sh via the run_sibling + [ -x ] +
# [not-covered] pattern (beside check_new_debt.sh / check_memory_rot.sh). It READS
# the INGESTED mutation report (run_audit.sh copies mutmut/Stryker/cargo-mutants/
# go-mutesting output into audit/) and NEVER runs the tool — THIS side IS the audit
# (codebase-health invariant 1: the audit must never mutate the working tree). The
# ONLY place a mutation tool RUNS is autopilot D6.5, trap-isolated (ADR 0016).
#
# It joins survived mutants against (a) the diff's changed lines (BASE..worktree,
# the same added-lines-only scope as check_new_debt.sh — inherited survivors are
# structurally invisible, ADR 0004 ratchet) AND (b) the journeys.json trace
# criticality. A NEW survivor on a changed line the trace grades CORE money/auth is
# the ADR-0004 `mutant-on-core-path` deterministic-evidence class.
#
# POSTURE (ADR 0016 ⟨MT-AMEND-A⟩, answered report-only-first):
#   * The CORE-survivor class ships COMMENT-ONLY during the ADR-0004 soak. It
#     BLOCKS (exit 1) only under BOTH strict (the default) AND an explicit per-repo
#     promotion (--promote-core / MUTATION_PROMOTE_CORE=1). Absent promotion → the
#     finding is reported comment-only, exit 0. No merge is ever blocked by default.
#   * MT-06 cap: whenever journeys.json is absent / degraded / a survivor's file is
#     untraced (criticality unknown), the survivor caps at COMMENT-ONLY — an
#     agent-derived criticality without deterministic evidence never blocks (ADR
#     0004). The gate never guesses criticality.
#   * A file-granular survivor (`<path>:-`, a tool with no line resolver) cannot be
#     pinned to a changed line → comment-only (MT-05).
#   * No ingested report → loud [not-covered], mutation facet skipped, never blocks
#     (MT-08 PR-side).
#
# THE STRICTNESS CONTRACT (mirrors check_new_debt.sh — a sibling owns its exit code;
# pr_gate.sh stays warn-only): strict by DEFAULT on the CLI/CI surface; the escape
# hatches are --no-strict (flag) and WARN_ONLY=1 (env) → warn-and-exit-0.
#
# Usage:
#   check_mutation_survivors.sh <BASE_REF> --report <path> [--tool <name>]
#       [--journeys <path>] [--env <name>] [--promote-core] [--no-strict]
# Exit 0 = no NEW blocking finding (or report-only / degraded). Exit 1 = a promoted
# CORE-survivor block under strict. Exit 64 = usage.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=py_run.sh
. "$SCRIPT_DIR/py_run.sh"   # pyrun: uv-first Python (ADR 0015), python3 fallback
ADAPTER="$SCRIPT_DIR/mutation_adapter.sh"

BASE=""; REPORT=""; TOOL=""; JOURNEYS=""; ENVSEL="default"
STRICT=1; PROMOTE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --report)       REPORT="${2:-}"; shift 2 ;;
    --tool)         TOOL="${2:-}"; shift 2 ;;
    --journeys)     JOURNEYS="${2:-}"; shift 2 ;;
    --env)          ENVSEL="${2:-}"; shift 2 ;;
    --promote-core) PROMOTE=1; shift ;;
    --no-strict)    STRICT=0; shift ;;
    --strict)       shift ;;                 # accepted, now-redundant (strict is the default)
    -*)             echo "[mutation-survivors] unknown flag: $1" >&2; shift ;;
    *)              BASE="$1"; shift ;;
  esac
done
[ "${WARN_ONLY:-0}" = "1" ] && STRICT=0                        # documented CI escape hatch (env form)
[ "${MUTATION_PROMOTE_CORE:-0}" = "1" ] && PROMOTE=1           # per-repo promotion (env form)

[ -n "$BASE" ] || { echo "usage: check_mutation_survivors.sh <BASE_REF> --report <path> [--tool <name>] [--journeys <path>] [--env <name>] [--promote-core] [--no-strict]" >&2; exit 64; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "[mutation-survivors] not a git repo — nothing to gate." >&2; exit 0; }
[ -x "$ADAPTER" ] || { echo "[not-covered] mutation survivors: mutation_adapter.sh missing — mutation facet skipped (never blocks)"; exit 0; }

# ── MT-08 PR-side degrade: no ingested report → loud [not-covered], never blocks ─
if [ -z "$REPORT" ] || [ ! -f "$REPORT" ]; then
  echo "[not-covered] mutation survivors: no ingested mutation report (run mutation testing out-of-band; run_audit.sh copies it into audit/) — mutation facet in Not-covered, never blocks (MT-08)"
  exit 0
fi

# infer the tool from the ingested report's canonical basename when --tool is omitted.
if [ -z "$TOOL" ]; then
  case "$(basename "$REPORT")" in
    mutation_stryker.json)     TOOL=stryker ;;
    mutation_cargo_missed.txt) TOOL=cargo-mutants ;;
    mutation_go.txt)           TOOL=go-mutesting ;;
    mutation_mutmut.txt)       TOOL=mutmut ;;
    *) echo "[not-covered] mutation survivors: cannot infer tool from report name '$(basename "$REPORT")' — pass --tool; mutation facet skipped (never blocks)"; exit 0 ;;
  esac
fi

# ── survivor set (the ONE adapter; never runs the tool) ───────────────────────
survivors="$(bash "$ADAPTER" normalize "$TOOL" < "$REPORT" 2>/dev/null)"
if [ -z "$survivors" ]; then
  echo "[note] mutation survivors: ingested $TOOL report has no survived mutants — nothing to join."
  exit 0
fi

# ── changed lines (added-lines-only; inherited survivors are invisible) ───────
if ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1; then
  echo "[mutation-survivors] cannot resolve base ref '$BASE' — mutation facet skipped (never blocks)." >&2
  exit 0
fi
changed_set="$(git diff -U0 "$BASE" -- . 2>/dev/null \
  | awk '/^\+\+\+ b\//{f=substr($0,7)} /^@@/{split($3,a,","); ln=substr(a[1],2)+0} /^\+[^+]/{printf "%s:%s\n", f, ln; ln++}')"

# ── CORE money/auth files from the journeys trace (MT-05/MT-06 criticality) ────
# The set of files hosting a CORE-criticality money/auth step. Absent/degraded
# journeys → empty set + TRACE_DEGRADED=1 → the CORE class caps at comment-only.
CORE_FILES=""; TRACE_DEGRADED=0
if [ -n "$JOURNEYS" ] && [ -f "$JOURNEYS" ]; then
  CORE_FILES="$(pyrun - "$JOURNEYS" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(2)  # degraded → caller caps at comment-only
core = set()
for j in (d.get("journeys") or []):
    if j.get("criticality") != "CORE":
        continue
    for s in (j.get("steps") or []):
        if s.get("vital_class") in ("money", "auth") and s.get("path"):
            core.add(s["path"])
for p in sorted(core):
    print(p)
PY
)"
  [ $? -eq 0 ] || TRACE_DEGRADED=1
else
  TRACE_DEGRADED=1
fi

is_core_file() {  # $1 = path -> 0 iff journeys grades it CORE money/auth
  [ "$TRACE_DEGRADED" -eq 0 ] || return 1
  printf '%s\n' "$CORE_FILES" | grep -qxF "$1"
}

# ── join each survivor ────────────────────────────────────────────────────────
core_block=""     # CORE money/auth survivors on changed lines (the promotable class)
comment=""        # everything else (report-only)
while IFS= read -r s; do
  [ -n "$s" ] || continue
  file="${s%:*}"; loc="${s##*:}"
  if [ "$loc" = "-" ]; then
    comment="${comment}[comment] mutant-survivor: ${s} — file-granular (no line resolver); cannot pin to a changed line, comment-only (MT-05)
"
    continue
  fi
  # ratchet: only survivors on the diff's CHANGED lines are in scope (ADR 0004).
  printf '%s\n' "$changed_set" | grep -qxF "$s" || continue
  if is_core_file "$file"; then
    core_block="${core_block}[FINDING mutant-on-core-path] ${s} — survived mutant on a CORE money/auth changed line (ADR-0004 deterministic-evidence class)
"
  elif [ "$TRACE_DEGRADED" -eq 1 ]; then
    comment="${comment}[comment] mutant-on-core-path: ${s} — on a changed line, but journeys.json absent/degraded so criticality is unknown; capped comment-only (MT-06: agent-derived criticality without deterministic evidence never blocks)
"
  else
    comment="${comment}[comment] mutant-survivor: ${s} — on a changed line but NOT traced CORE money/auth (SUPPORTING/DEV/untraced); comment-only (ADR 0004)
"
  fi
done <<SURV
$survivors
SURV

# ── report ────────────────────────────────────────────────────────────────────
[ -n "$comment" ] && printf '%s' "$comment"

if [ -z "$core_block" ]; then
  echo "[note] mutation survivors ($TOOL): no NEW survivor on a CORE money/auth changed line (blocking class empty)."
  exit 0
fi

# There IS a CORE-survivor. It BLOCKS only under strict AND explicit promotion.
if [ "$PROMOTE" -eq 1 ]; then
  printf '%s' "$core_block"
  if [ "$STRICT" -eq 1 ]; then
    echo "[BLOCKED: mutant-on-core-path] a NEW survived mutant on a CORE money/auth changed line (promoted per-repo; ADR-0004 blocking class)."
    exit 1
  fi
  echo "[note] mutant-on-core-path finding present but --no-strict/WARN_ONLY → warn-and-exit-0."
  exit 0
fi

# Soak default (⟨MT-AMEND-A⟩): the CORE-survivor class is COMMENT-ONLY.
printf '%s' "$core_block" | sed 's/^\[FINDING /[comment] soak: /'
echo "[note] mutant-on-core-path finding(s) present but report-only during the ADR-0004 soak — promote per-repo with --promote-core (or MUTATION_PROMOTE_CORE=1) to block. Never blocks by default (⟨MT-AMEND-A⟩)."
exit 0
