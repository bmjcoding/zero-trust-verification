#!/usr/bin/env bash
# mock_host.sh — a hermetic stand-in for the suite host adapter (host.sh) used by
# the triage self-test ONLY. It implements the exact observable contract of the
# subcommands the triage tier drives — `pr-state`, `pr-list-ready`, `pr-open
# --draft` — with NO network, NO credentials, NO gh/curl. Behaviour is steered by
# env vars so one binary serves every loop-guard / handoff assertion:
#
#   pr-state --num <N>   -> echoes $MOCK_PR_STATE (default OPEN); vocabulary is the
#                           real contract's: OPEN|DRAFT|MERGED|DECLINED|NONE.
#   pr-list-ready        -> cats $MOCK_PR_LIST_READY (a TSV fixture) or nothing.
#   pr-open [--draft] …  -> echoes a fake PR URL ending in $MOCK_PR_NUM (default
#                           4242); appends the full argv to $MOCK_PR_OPEN_LOG so a
#                           test can prove --draft was passed (report-only posture).
#
# Portability: bash 3.2 + BSD safe.
set -u
SUB="${1:-}"; shift || true
case "$SUB" in
  pr-state)
    echo "${MOCK_PR_STATE:-OPEN}"
    ;;
  pr-list-ready)
    if [ -n "${MOCK_PR_LIST_READY:-}" ] && [ -f "$MOCK_PR_LIST_READY" ]; then
      cat "$MOCK_PR_LIST_READY"
    fi
    ;;
  pr-open)
    [ -n "${MOCK_PR_OPEN_LOG:-}" ] && printf 'pr-open %s\n' "$*" >> "$MOCK_PR_OPEN_LOG"
    echo "https://example.invalid/pull/${MOCK_PR_NUM:-4242}"
    ;;
  *)
    echo "mock_host.sh: unsupported subcommand: $SUB" >&2
    exit 64
    ;;
esac
