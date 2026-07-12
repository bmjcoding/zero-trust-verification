#!/usr/bin/env bash
# RL-02 — Eligibility gate (ADR 0017 step 2; ADR 0004): a finding is drain/
# escalate-eligible ONLY when BOTH
#   (a) severity >= floor (default HIGH — and HIGH already means CONFIRMED/traced
#       per severity-rubric.md, so this is a confirmed-defect floor, not a
#       suspicion floor); floor overridable via remediation.config.yaml
#       `severity_floor:`; AND
#   (b) the slug is DETERMINISTICALLY-scored, looked up in the lint-pinned
#       slug_provenance.tsv (HARDENED Defect A — provenance is NOT a state field).
#
# Verdict on stdout, exit 0 always (a classifier the router composes):
#   ELIGIBLE
#   INELIGIBLE:agent-evidence-only   slug is agent-scored (ADR 0004: no agent
#                                    opinion auto-files autonomous rework)
#   INELIGIBLE:below-floor           deterministic but severity < floor
#   INELIGIBLE:unknown-provenance    slug not in the table — fail SAFE toward
#                                    inaction (invariant 4)
#
# Usage:  finding_eligible.sh --severity <SEV> --slug <slug> [--config <cfg.yaml>]
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remediation_lib.sh"

SEV=""; SLUG=""; CONFIG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --severity) SEV="${2:-}"; shift 2 ;;
    --slug)     SLUG="${2:-}"; shift 2 ;;
    --config)   CONFIG="${2:-}"; shift 2 ;;
    *) echo "finding_eligible: unknown arg: $1" >&2; exit 64 ;;
  esac
done
[ -n "$SEV" ] && [ -n "$SLUG" ] || { echo "usage: finding_eligible.sh --severity <SEV> --slug <slug> [--config <cfg>]" >&2; exit 64; }

# Provenance lookup from the lint-pinned table (exact col-1 match; TAB-separated;
# comments (#) and blank lines ignored). Unknown slug => empty => fail-safe.
provenance=""
if [ -f "$RL_PROVENANCE_TSV" ]; then
  provenance="$(awk -F'\t' -v s="$SLUG" '
    /^[[:space:]]*#/ {next} NF<2 {next}
    $1==s {print $2; exit}' "$RL_PROVENANCE_TSV")"
fi

if [ -z "$provenance" ]; then
  echo "INELIGIBLE:unknown-provenance"; exit 0
fi
if [ "$provenance" = "agent" ]; then
  echo "INELIGIBLE:agent-evidence-only"; exit 0
fi
if [ "$provenance" != "deterministic" ]; then
  # a malformed provenance value is not "deterministic" — fail safe.
  echo "INELIGIBLE:unknown-provenance"; exit 0
fi

floor="$(rl_severity_floor "$CONFIG")"
if [ "$(rl_sev_rank "$SEV")" -ge "$(rl_sev_rank "$floor")" ]; then
  echo "ELIGIBLE"
else
  echo "INELIGIBLE:below-floor"
fi
exit 0
