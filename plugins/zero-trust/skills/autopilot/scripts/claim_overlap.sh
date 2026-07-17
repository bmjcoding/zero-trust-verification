#!/usr/bin/env bash
# claim_overlap.sh
#
# ============================================================================
# SHARED PRIMITIVE (ADR 0009 / AV3-09) — the ONE canonical copy (ADR 0025).
# Every consumer that consults claim overlap (autopilot G4/D2, the marshal
# staleness sweep, the remediation loop's depth guard) resolves to THIS file;
# the Marshal-plugin-era byte-identical vendoring and its byte-parity lint are
# retired.
# ============================================================================
#
# Open-PR file-surface intersection: given the files a Subtask wants to own,
# classify every OTHER in-flight PR whose declared file surface overlaps them.
# Two consumers (ADR 0009):
#   G4 (plan-time): a BINDING/TERMINAL overlap becomes a `blocked_by_pr` edge on
#                   the Subtask (D2-evaluable).
#   D2 (fire-time): the `eligibility` subcommand gates a claimed Subtask on its
#                   blocked_by_pr PR state.
#
# The open-PR inventory (each PR's branch, state, age, and declared file surface)
# is gathered in PRODUCTION via the host adapter — `host.sh pr-state` for state +
# `runbook_pr.sh file-surface` on each open Runbook/Story PR body for the surface.
# For deterministic use/testing it is INJECTED via `--inventory <file>` so this
# primitive stays a pure decision function (no host, no clock).
#
# Overlap classification (per overlapping foreign PR):
#   EXCLUDED  branch under this drain's own `--self-namespace` -> never a foreign
#             claim (closes the re-GENERATE self-deadlock).
#   ADVISORY  age_bd > 2 (stale beyond two business days) -> non-blocking note.
#   BINDING   a foreign DRAFT PR -> actively-worked claim; block and wait.
#   TERMINAL  a foreign ready (non-draft OPEN) PR -> about to merge; hard block.
# BINDING/TERMINAL each emit a `blocked_by_pr=<ref>` line and make the call exit 2.
#
# Usage:
#   claim_overlap.sh --self-namespace <prefix> --inventory <file> <owned-file>...
#   claim_overlap.sh eligibility --pr-state <MERGED|DECLINED|NONE|OPEN|DRAFT>
#
# Inventory line (TAB-separated): <pr-ref>\t<branch>\t<state>\t<age_bd>\t<f1,f2,...>
#   state: DRAFT | OPEN (ready).  age_bd: integer business days since the PR opened.
#
# Exit: 0 no blocking claim (clean or advisory-only) · 2 >=1 BINDING/TERMINAL
#       claim (or an ineligible eligibility check) · 64 usage.
#
# Portability: bash 3.2 + BSD userland safe. No associative arrays.

set -u

usage() {
  cat >&2 <<EOF
usage: claim_overlap.sh --self-namespace <prefix> --inventory <file> <owned-file>...
       claim_overlap.sh eligibility --pr-state <MERGED|DECLINED|NONE|OPEN|DRAFT>
EOF
  exit 64
}

# --- D2 eligibility subcommand ------------------------------------------------
if [[ "${1:-}" == "eligibility" ]]; then
  shift
  STATE=""
  while (( $# )); do
    case "$1" in --pr-state) STATE="${2:-}"; shift 2 || usage ;; *) usage ;; esac
  done
  [[ -n "$STATE" ]] || usage
  case "$STATE" in
    MERGED|DECLINED|NONE) echo "ELIGIBLE"; exit 0 ;;   # the claim resolved -> Subtask may run
    OPEN|DRAFT)           echo "INELIGIBLE $STATE"; exit 2 ;;  # claim still open -> wait
    *) echo "claim_overlap: unknown pr-state: $STATE" >&2; exit 64 ;;
  esac
fi

# --- overlap classification (the primitive) -----------------------------------
SELF_NS=""
INVENTORY=""
FILES=""
while (( $# )); do
  case "$1" in
    --self-namespace) SELF_NS="${2:-}"; shift 2 || usage ;;
    --inventory)      INVENTORY="${2:-}"; shift 2 || usage ;;
    -*) usage ;;
    *)  FILES="$FILES $1"; shift ;;
  esac
done

[[ -n "$INVENTORY" ]] || usage
[[ -f "$INVENTORY" ]] || { echo "claim_overlap: inventory not found: $INVENTORY" >&2; exit 64; }
[[ -n "${FILES// }" ]] || usage

# Is <needle> among the space-separated owned FILES?
owns() { case " $FILES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

blocking=0
while IFS="$(printf '\t')" read -r ref branch state age_bd csv; do
  [[ -z "$ref" ]] && continue

  # Intersection of this PR's declared surface with the Subtask's owned files.
  overlap=""
  oldIFS="$IFS"; IFS=','
  for pf in $csv; do
    pf="${pf# }"; pf="${pf% }"
    [[ -z "$pf" ]] && continue
    if owns "$pf"; then overlap="${overlap:+$overlap,}$pf"; fi
  done
  IFS="$oldIFS"
  [[ -z "$overlap" ]] && continue     # no shared files -> not a claim on us

  # Self-claim exclusion: our own drain's branches are never foreign claims.
  if [[ -n "$SELF_NS" ]]; then
    case "$branch" in "$SELF_NS"*) echo "excluded=$ref files=$overlap"; continue ;; esac
  fi

  # Stale beyond two business days -> advisory only.
  case "$age_bd" in ''|*[!0-9]*) age_bd=0 ;; esac
  if (( age_bd > 2 )); then
    echo "advisory=$ref files=$overlap"
    continue
  fi

  # Fresh foreign claim: draft is binding, ready is terminal. Both block.
  if [[ "$state" == "DRAFT" ]]; then
    echo "blocked_by_pr=$ref class=BINDING files=$overlap"
  else
    echo "blocked_by_pr=$ref class=TERMINAL files=$overlap"
  fi
  blocking=1
done < "$INVENTORY"

(( blocking == 0 )) || exit 2
exit 0
