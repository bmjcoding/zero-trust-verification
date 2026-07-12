#!/usr/bin/env bash
# claim_loss_attribution.sh
#
# DRAIN Step D7.0 divergence-routing predicate (ADR 0009 / AV3-10). When the
# pre-push rebase budget trips (`[BLOCKED: rebase-too-large]`), the divergence is
# either (a) a genuine planning failure that needs a human, or (b) a claim
# collision — a foreign PR the drain was told overlapped (AV3-09) merged first and
# rewrote the very files we conflict on. Case (b) is recoverable by re-planning
# against the new trunk (route to D3), NOT by burning an impl-block.
#
# This predicate makes that call deterministically: it intersects the
# claim-overlap file list (the files claim_overlap.sh flagged for this Subtask)
# with the rebase's conflicting-hunk file list. A non-empty intersection ATTRIBUTES
# the divergence to a claim collision. Re-plan is BOUNDED — 2 per Subtask
# (`--max-replans`), after which it falls back to normal escalation.
#
# Usage:
#   claim_loss_attribution.sh --overlap-files <f1,f2,...> \
#       --conflict-files <f1,f2,...> [--replans-so-far <n>] [--max-replans <n>]
#
# Output (stdout):
#   REPLAN files=<intersection>        -> route to D3 re-plan; record
#                                         `replanned-after-claim-loss` (exit 0)
#   NOT-ATTRIBUTED                     -> normal impl-block escalation (exit 1)
#   REPLAN-BUDGET-EXHAUSTED files=...  -> attributed but 2 re-plans already spent;
#                                         fall back to normal escalation (exit 2)
# Exit 64 usage.
#
# Portability: bash 3.2 + BSD userland safe.

set -u

OVERLAP=""
CONFLICT=""
REPLANS=0
MAXREPLANS=2

usage() {
  echo "usage: claim_loss_attribution.sh --overlap-files <csv> --conflict-files <csv> [--replans-so-far <n>] [--max-replans <n>]" >&2
  exit 64
}

while (( $# )); do
  case "$1" in
    --overlap-files)   OVERLAP="${2:-}"; shift 2 || usage ;;
    --conflict-files)  CONFLICT="${2:-}"; shift 2 || usage ;;
    --replans-so-far)  REPLANS="${2:-}"; shift 2 || usage ;;
    --max-replans)     MAXREPLANS="${2:-}"; shift 2 || usage ;;
    *) usage ;;
  esac
done

# --conflict-files is required (there must be a divergence to attribute); an empty
# --overlap-files is legal (means "no claim overlap was recorded" -> not attributed).
[[ -n "$CONFLICT" ]] || usage
case "$REPLANS" in ''|*[!0-9]*) usage ;; esac
case "$MAXREPLANS" in ''|*[!0-9]*) usage ;; esac

# Normalize the overlap list into a space-delimited membership set.
overlap_set=" $(printf '%s' "$OVERLAP" | tr ',' ' ') "

# Intersect: every conflict file that also appears in the overlap set.
inter=""
oldIFS="$IFS"; IFS=','
for cf in $CONFLICT; do
  cf="${cf# }"; cf="${cf% }"
  [[ -z "$cf" ]] && continue
  case "$overlap_set" in *" $cf "*) inter="${inter:+$inter,}$cf" ;; esac
done
IFS="$oldIFS"

if [[ -z "$inter" ]]; then
  echo "NOT-ATTRIBUTED"
  exit 1
fi

if (( REPLANS >= MAXREPLANS )); then
  echo "REPLAN-BUDGET-EXHAUSTED files=$inter"
  exit 2
fi

echo "REPLAN files=$inter"
exit 0
