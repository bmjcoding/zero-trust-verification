#!/usr/bin/env bash
# RL-08 — Guard 1 (idempotency by fingerprint). The fingerprint IS the loop's
# idempotency key. Before filing, the loop asks: is this finding already filed?
#
#   FILED   — an open remediation record (SPEC_OPEN|PR_OPEN|ESCALATED|WONTFIX) OR
#             a human WONTFIX status exists → SKIP LOUDLY (invariant 6, into
#             Not-covered / [skip]). A human WONTFIX (existing /verify --wontfix)
#             permanently silences it for the loop too.
#   UNFILED — no open record → the loop may file.
#
# Degrade (invariant 4): an unreadable state cannot be idempotency-checked, so it
# fails SAFE to FILED (do nothing) — the loop never files rework it can't dedup.
#
# READER: mutates nothing (the stamp is remediation_stamp.sh's job).
#
# Usage:  already_filed.sh <fingerprint> <state.json>
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remediation_lib.sh"

FP="${1:-}"; STATE="${2:-}"
[ -n "$FP" ] && [ -n "$STATE" ] || { echo "usage: already_filed.sh <fingerprint> <state.json>" >&2; exit 64; }

rl_pyrun "$RL_STATE_PY" already-filed "$FP" "$STATE"
