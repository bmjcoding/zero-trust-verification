#!/usr/bin/env bash
# claim_overlap.sh
#
# The claim-overlap check (ADR 0009): open-PR file-surface intersection. Given a
# set of Claims — each a (claim-id, file) pair — it reports the files claimed by
# more than one Claim. A Claim is a workstream's visible file surface, derived
# from an open PR (prediction tier: Runbook PR; in-progress: Story draft PR;
# terminal: ready-for-review PR). This kernel is deliberately *pure*: it forms no
# opinion about tiers, actors, or timestamps and it never touches git or a host
# API — the caller derives (claim-id, file) pairs from open PRs and pipes them
# in. That is exactly what makes it reusable by both consumers named in ADR 0009:
#   - autopilot's G4 planner ("does my predicted surface overlap an existing
#     claim?"  -> --for <my-claim-id>)
#   - the Marshal's nudge watcher ("which files are contended across open PRs?"
#     -> default mode)
#
# ┌─ VENDORED — BYTE-IDENTICAL COPY (ADR 0001 manifest-schema pattern, ADR 0009) ─┐
# │ This file is the CANONICAL source. It is authored here first because         │
# │ autopilot has no claim-overlap check on main yet (only hot_file_audit.sh's   │
# │ --subtasks mode, which is a different, within-drain concern). When autopilot │
# │ G4 vendors it, its copy MUST be byte-identical to this one. A packaging lint │
# │ (future) enforces byte-identity across both consumers; keep them in lockstep.│
# └──────────────────────────────────────────────────────────────────────────────┘
#
# Input  (stdin): lines "<claim-id>\t<file>", one file per line. Blank lines and
#                 lines without a TAB are ignored. Duplicate (claim-id, file)
#                 pairs are collapsed — a Claim claiming the same file twice is
#                 still one claimant of that file.
# Modes:
#   (default)      Emit "<distinct-claim-count>\t<file>" for every file claimed
#                  by >= threshold DISTINCT claim-ids, sorted by count desc then
#                  file asc. This is the "contended surface" report.
#   --for <id>     Emit "<file>\t<other-claim-id>" for every file where <id>
#                  collides with a DIFFERENT claim, sorted by file then other-id.
#                  One line per (file, other-claim) collision. This is the
#                  "does my surface overlap someone else's claim?" query.
# Options:
#   --threshold N  (default 2) minimum distinct claimants for the default report.
#                  Ignored in --for mode (a collision is always >= 2 by
#                  definition: <id> plus one other).
#
# Determinism: output is a pure function of the input pair-set (ADR 0011 —
# file-surface intersection, git/API-provable, no agent judgment). Sorting is
# byte-stable via LC_ALL=C so the byte-identical lint and downstream diffs are
# reproducible across platforms.
#
# Exit: 0 always on well-formed input (an empty report is a valid answer — no
# overlap is not an error). 64 on a usage error.
#
# Portability: bash 3.2 (macOS default) + BSD userland safe. Pure awk/sort; no
# GNU-only flags, no process substitution, no associative arrays.

set -u
set +x

export LC_ALL=C

usage() {
  echo "usage: claim_overlap.sh [--threshold N] [--for <claim-id>]  < claims.tsv" >&2
  echo "  claims.tsv: lines '<claim-id>\\t<file>'" >&2
  exit 64
}

THRESHOLD=2
FOR_ID=""
FOR_SET=0
while (( $# > 0 )); do
  case "$1" in
    --threshold) THRESHOLD="${2:-}"; shift 2 || usage ;;
    --for)       FOR_ID="${2:-}"; FOR_SET=1; shift 2 || usage ;;
    -h|--help)   usage ;;
    *) echo "claim_overlap.sh: unknown arg: $1" >&2; usage ;;
  esac
done

# An explicit empty --for is a usage error, not a silent switch to default mode.
if (( FOR_SET )) && [[ -z "$FOR_ID" ]]; then
  echo "claim_overlap.sh: --for requires a non-empty claim-id" >&2; usage
fi

case "$THRESHOLD" in
  ''|*[!0-9]*) echo "claim_overlap.sh: --threshold must be a non-negative integer" >&2; usage ;;
esac

if [[ -n "$FOR_ID" ]]; then
  # --for mode: report every (file, other-claim) collision involving FOR_ID.
  # First collapse to distinct (claim,file) pairs, then for each file that
  # FOR_ID claims, emit the OTHER distinct claim-ids that also claim it.
  awk -F'\t' -v me="$FOR_ID" '
    NF >= 2 && $1 != "" && $2 != "" {
      pair = $1 SUBSEP $2
      if (!(pair in seen)) { seen[pair] = 1; claims[$2] = claims[$2] SUBSEP $1 }
      if ($1 == me) { mine[$2] = 1 }
    }
    END {
      for (f in mine) {
        n = split(claims[f], arr, SUBSEP)
        for (i = 1; i <= n; i++) {
          c = arr[i]
          if (c != "" && c != me) print f "\t" c
        }
      }
    }
  ' \
  | sort -t"$(printf '\t')" -k1,1 -k2,2
else
  # default mode: distinct-claimant count per file, threshold-filtered.
  awk -F'\t' -v thr="$THRESHOLD" '
    NF >= 2 && $1 != "" && $2 != "" {
      pair = $1 SUBSEP $2
      if (!(pair in seen)) { seen[pair] = 1; count[$2]++ }
    }
    END { for (f in count) if (count[f] >= thr) print count[f] "\t" f }
  ' \
  | sort -t"$(printf '\t')" -k1,1nr -k2,2
fi
