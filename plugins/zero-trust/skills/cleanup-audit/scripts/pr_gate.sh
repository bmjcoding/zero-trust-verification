#!/usr/bin/env bash
# CH-04 — PR Gate diff-scoped mode (ADR 0003; MS §13.10).
#
# The PR Gate is a diff-scoped MODE of this plugin, not a fourth checker. It
# composes the diff-scoped surface from the EXISTING positional-BASE_REF
# `check_new_debt.sh` plus the new per-diff sibling scripts — it does NOT grow
# check_new_debt.sh (whose arg parser routes any non-flag token to BASE, so a
# `--diff` flag would be swallowed as a base ref; no such flag is added).
#
# Per-diff siblings run against the diff range (all reuse the same <BASE_REF>):
#   check_new_debt.sh      deterministic debt classes (markers/suppressions/…)
#   check_memory_rot.sh    CH-05 deterministic memory-rot layer
#   check_behavior_coverage.sh  CH-06 behavior-ID claim-vs-proof (needs manifest + PR body)
#   check_provenance.sh    CH-07 SG-8 provenance (needs branch metadata) — comment-only
#   check_manifest_history.sh   CH-09 spec_hash / monotonicity / ID-reuse
#
# Manifest-coverage (§12 join, ADR 0029): a present manifest is ingested through
# CH-01 (MODE token) and, on COMPLETE/INCOMPLETE plus a parseable prior
# journeys.json, dispatched to the CH-03 comparator (manifest_join.sh — a
# reporter). Every non-dispatch branch prints an honest [not-covered] line.
#
# Whole-repo-only facets (journey walk + journeys.json write, vitals/tx/complexity,
# jscpd, size ladder, coverage ingestion) are NOT re-run per diff — they belong to
# the scheduled ambient audit (ADR 0003 point 2). This script NEVER invokes
# run_audit.sh and NEVER writes journeys.json. It reads a PRIOR journeys.json /
# state.json / manifest if present and says so when absent (degrade, invariant 4)
# — it never triggers a full walk on a PR.
#
# Loop-safety: warn-only orchestrator. Individual gated siblings own their exit
# codes on the CI surface (ADR 0004 ratchet: NEW debt only — check_new_debt.sh
# computes added-lines-only, so inherited debt is structurally invisible). This
# dispatcher aggregates and reports; it mutates nothing.
#
# Usage:
#   pr_gate.sh <BASE_REF> [--manifest P] [--journeys P] [--pr-body P]
#              [--branch-meta P] [--env NAME]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE=""
MANIFEST=""; JOURNEYS=""; PR_BODY=""; BRANCH_META=""; ENVSEL=""
MUTATION_REPORT=""; MUTATION_TOOL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)        MANIFEST="${2:-}"; shift 2 ;;
    --journeys)        JOURNEYS="${2:-}"; shift 2 ;;
    --pr-body)         PR_BODY="${2:-}"; shift 2 ;;
    --branch-meta)     BRANCH_META="${2:-}"; shift 2 ;;
    --env)             ENVSEL="${2:-}"; shift 2 ;;
    --mutation-report) MUTATION_REPORT="${2:-}"; shift 2 ;;
    --mutation-tool)   MUTATION_TOOL="${2:-}"; shift 2 ;;
    -*)                echo "[pr-gate] unknown flag: $1" >&2; shift ;;
    *)                 BASE="$1"; shift ;;
  esac
done

if [ -z "$BASE" ]; then
  echo "usage: pr_gate.sh <BASE_REF> [--manifest P] [--journeys P] [--pr-body P] [--branch-meta P] [--env NAME] [--mutation-report P] [--mutation-tool T]" >&2
  exit 64
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "[pr-gate] not a git repo — nothing to gate." >&2; exit 0; }

echo "==> PR Gate — diff-scoped mode (ADR 0003). base=$BASE"
echo "    Whole-repo walk is NOT triggered on a PR: journeys.json is never written here (ADR 0003 point 2)."

worst=0
run_sibling() { # name + command; tracks worst exit; never aborts the gate
  local name="$1"; shift
  echo "--> $name"
  "$@"
  local rc=$?
  [ "$rc" -gt "$worst" ] && worst=$rc
  return 0
}

# ── per-diff: deterministic debt classes (the existing positional surface) ────
if [ -x "$SCRIPT_DIR/check_new_debt.sh" ]; then
  run_sibling "check_new_debt.sh (deterministic debt classes)" bash "$SCRIPT_DIR/check_new_debt.sh" "$BASE"
fi

# ── per-diff: CH-05 deterministic memory-rot layer ───────────────────────────
if [ -x "$SCRIPT_DIR/check_memory_rot.sh" ]; then
  rot_args=("$BASE")
  [ -n "$MANIFEST" ] && rot_args+=(--manifest "$MANIFEST")
  [ -n "$JOURNEYS" ] && rot_args+=(--journeys "$JOURNEYS")
  run_sibling "check_memory_rot.sh (CH-05 dangling-ref rot)" bash "$SCRIPT_DIR/check_memory_rot.sh" "${rot_args[@]}"
fi

# ── per-diff: CH-06 behavior-ID coverage (needs a manifest + PR body) ─────────
if [ -x "$SCRIPT_DIR/check_behavior_coverage.sh" ]; then
  if [ -n "$MANIFEST" ] && [ -n "$PR_BODY" ]; then
    run_sibling "check_behavior_coverage.sh (CH-06 claim-vs-proof)" bash "$SCRIPT_DIR/check_behavior_coverage.sh" "$MANIFEST" "$PR_BODY" "$BASE"
  else
    echo "--> check_behavior_coverage.sh"
    echo "[not-covered] behavior-ID coverage: no manifest and/or PR body supplied — check skipped (never blocks a manifest-less PR, MS §11)"
  fi
fi

# ── per-diff: CH-07 SG-8 provenance (needs branch metadata) — comment-only ────
if [ -x "$SCRIPT_DIR/check_provenance.sh" ]; then
  if [ -n "$BRANCH_META" ]; then
    run_sibling "check_provenance.sh (CH-07 provenance — comment-only)" bash "$SCRIPT_DIR/check_provenance.sh" "$BASE" "$BRANCH_META"
  else
    echo "--> check_provenance.sh"
    echo "[not-covered] SG-8 provenance: no branch metadata supplied — check skipped"
  fi
fi

# ── per-diff: CH-09 history checks (needs a manifest + a base ref) ────────────
if [ -x "$SCRIPT_DIR/check_manifest_history.sh" ]; then
  if [ -n "$MANIFEST" ]; then
    run_sibling "check_manifest_history.sh (CH-09 spec_hash/monotonicity/ID-reuse)" bash "$SCRIPT_DIR/check_manifest_history.sh" "$MANIFEST" "$BASE"
  else
    echo "--> check_manifest_history.sh"
    echo "[not-covered] manifest history checks: no manifest supplied — check skipped"
  fi
fi

# ── per-diff: ADR 0016 mutation survivors (ingest-only; comment-only in soak) ─
if [ -x "$SCRIPT_DIR/check_mutation_survivors.sh" ]; then
  if [ -n "$MUTATION_REPORT" ]; then
    mut_args=("$BASE" --report "$MUTATION_REPORT")
    [ -n "$MUTATION_TOOL" ] && mut_args+=(--tool "$MUTATION_TOOL")
    [ -n "$JOURNEYS" ] && mut_args+=(--journeys "$JOURNEYS")
    [ -n "$ENVSEL" ] && mut_args+=(--env "$ENVSEL")
    # No --promote-core here: the CORE-survivor class ships comment-only during the
    # ADR-0004 soak (⟨MT-AMEND-A⟩); promotion is a per-repo/async decision. pr_gate
    # stays warn-only regardless (it aggregates the sibling exit; it never blocks).
    run_sibling "check_mutation_survivors.sh (ADR 0016 mutation survivors — comment-only in soak)" \
      bash "$SCRIPT_DIR/check_mutation_survivors.sh" "${mut_args[@]}"
  else
    echo "--> check_mutation_survivors.sh"
    echo "[not-covered] mutation survivors: no ingested report supplied (--mutation-report) — mutation facet in Not-covered, never blocks (ADR 0016 / MT-08)"
  fi
fi

# ── prior-artifact degrade (invariant 4): read, never full-walk ──────────────
if [ -n "$JOURNEYS" ] && [ -f "$JOURNEYS" ]; then
  echo "    prior journeys.json present ($JOURNEYS) — read for rot-vs-journeys joins (not re-walked)."
else
  echo "[not-covered] rot-vs-journeys: no prior journeys.json — diff mode reads a prior trace, never triggers a full walk (degrade, invariant 4)"
fi
if [ -z "$MANIFEST" ] || [ ! -f "$MANIFEST" ]; then
  echo "[not-covered] manifest-coverage (§12 join): no manifest colocated with the diff — manifest facets skipped (never blocks a manifest-less PR)"
elif [ -x "$SCRIPT_DIR/ingest_manifest.sh" ] && [ -x "$SCRIPT_DIR/manifest_join.sh" ]; then
  # ── §12 join dispatch (ADR 0029): CH-01's MODE token gates the CH-03 join. ──
  # CH-01 is the schema gate (manifest_join.py never validates — MS §11's
  # schema-invalid-is-a-DEFECT row lives in the ingest); the join fires only on
  # a COMPLETE/INCOMPLETE manifest AND a present, parseable journeys.json. Every
  # non-dispatch branch says so loudly ([not-covered], invariant 6). The join is
  # a reporter (always exit 0), so the gate's warn-only posture is untouched.
  echo "--> ingest_manifest.sh (CH-01 manifest MODE gate for the §12 join — ADR 0029)"
  ING_OUT="$(bash "$SCRIPT_DIR/ingest_manifest.sh" "$MANIFEST" 2>&1)"
  printf '%s\n' "$ING_OUT"
  MODE="$(printf '%s\n' "$ING_OUT" | sed -n 's/^MODE=//p' | head -1)"
  case "$MODE" in
    COMPLETE|INCOMPLETE)
      if [ -n "$JOURNEYS" ] && [ -f "$JOURNEYS" ]; then
        if command -v python3 >/dev/null 2>&1 \
           && ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$JOURNEYS" >/dev/null 2>&1; then
          # Malformed journeys.json DEGRADES LOUDLY, never crashes the gate
          # (the MT-06 precedent: a broken artifact is a fact to report, not a
          # traceback) — manifest_join.py would raise on unparseable JSON.
          echo "[not-covered] manifest-coverage (§12 join): malformed journeys.json ('$JOURNEYS' is not parseable JSON) — join not run; fix the artifact (loud degrade, MT-06 precedent)"
        else
          join_args=("$MANIFEST" "$JOURNEYS")
          [ -n "$ENVSEL" ] && join_args+=("--env=$ENVSEL")
          run_sibling "manifest_join.sh (CH-03 §12 intended↔discovered join — reporter, ADR 0029)" \
            bash "$SCRIPT_DIR/manifest_join.sh" "${join_args[@]}"
        fi
      else
        echo "[not-covered] manifest-coverage (§12 join): manifest present (MODE=$MODE) but no prior journeys.json — the join needs both sides (degrade, invariant 4)"
      fi
      ;;
    *)
      # SCHEMA-INVALID / UNSUPPORTED / ABSENT-tooling: CH-01's own output above
      # already carries the honest [not-covered]/defect lines — nothing to add.
      : ;;
  esac
else
  echo "[not-covered] manifest-coverage (§12 join): ingest_manifest.sh/manifest_join.sh not colocated — join tooling absent (loud degrade, invariant 4)"
fi

echo "==> PR Gate done (diff-scoped). Aggregated sibling exit high-water: $worst"
# The dispatcher itself is a reporter (warn-only): it surfaces the worst sibling
# exit for a human-wired CI step to consult, but never blocks here.
exit 0
