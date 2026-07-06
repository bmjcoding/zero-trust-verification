#!/usr/bin/env bash
# runbook_pr.sh
#
# Runbook-PR helpers (AV3-08). G7 opens the Runbook PR immediately at Pickup on
# branch `autopilot/<slug>/runbook`, carrying the runbook + tracker and — in its
# body — the drain's PREDICTED FILE SURFACE as a grep-able block, so foreign
# planners can consult one bookkeeping home instead of a rolling tracker PR.
#
# This script owns the block's machine-readable contract:
#
#   file-surface <body-file>   Extract the predicted file-surface entries from a
#          Runbook PR body. The block is delimited by literal HTML-comment markers
#          so it is greppable regardless of surrounding prose:
#              <!-- autopilot:file-surface:begin -->
#              - `path/one.py`
#              - `path/two.py`
#              <!-- autopilot:file-surface:end -->
#          Prints one repo-relative path per line (backticks/`- ` stripped).
#            exit 0 + entries · exit 1 markers missing/unbalanced · 64 usage.
#
# Portability: bash 3.2 + BSD userland safe.

set -u

BEGIN='<!-- autopilot:file-surface:begin -->'
END='<!-- autopilot:file-surface:end -->'

usage() { echo "usage: runbook_pr.sh file-surface <runbook-pr-body-file>" >&2; exit 64; }

SUB="${1:-}"; shift || usage
case "$SUB" in
  file-surface)
    BODY="${1:-}"
    [[ -n "$BODY" ]] || usage
    [[ -f "$BODY" ]] || { echo "runbook_pr: body not found: $BODY" >&2; exit 64; }
    nb=$(grep -cF -- "$BEGIN" "$BODY"); ne=$(grep -cF -- "$END" "$BODY")
    if [[ "$nb" != "1" || "$ne" != "1" ]]; then
      echo "runbook_pr: file-surface markers missing or unbalanced (begin=$nb end=$ne)" >&2
      exit 1
    fi
    # Print the lines strictly between the two markers; strip "- " and backticks.
    awk -v b="$BEGIN" -v e="$END" '
      index($0,b){inb=1; next}
      index($0,e){inb=0}
      inb {
        line=$0
        sub(/^[[:space:]]*-[[:space:]]*/,"",line)
        gsub(/`/,"",line)
        sub(/^[[:space:]]+/,"",line); sub(/[[:space:]]+$/,"",line)
        if (line != "") print line
      }
    ' "$BODY"
    ;;
  *) usage ;;
esac
