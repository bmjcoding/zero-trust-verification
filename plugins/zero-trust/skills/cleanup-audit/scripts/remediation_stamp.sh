#!/usr/bin/env bash
# RL-08 — Guard 1 record writer: the ONE mutation the loop makes to state.json.
#
# Additively stamps a finding's record with
#   remediation: { status, ref, opened_at, remediation_depth }
# and NOTHING else. schema_version stays 2 (additive fields are not a break,
# VERIFIED precedent audit-state-and-verify.md). It NEVER touches status /
# severity / verified_by — those stay /audit- and /verify-owned, so the loop can
# never manufacture a false closure (ADR 0018 Guard 1). Idempotent + diffable
# (invariant 8): re-stamping preserves the original opened_at.
#
# REFUSES to write into a missing/corrupt/unknown-schema state (invariant 4) or
# for a fingerprint that is not already in state (never invents a record).
#
# Usage:
#   remediation_stamp.sh <state.json> <fingerprint> --status <SPEC_OPEN|PR_OPEN|ESCALATED|WONTFIX>
#                        [--ref <pr/exchange ref>] [--depth <n>] [--opened-at <ts>] [--out <path>]
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remediation_lib.sh"

[ $# -ge 2 ] || { echo "usage: remediation_stamp.sh <state.json> <fingerprint> --status <S> [--ref R] [--depth N] [--opened-at T] [--out O]" >&2; exit 64; }
STATE="$1"; FP="$2"; shift 2
rl_pyrun "$RL_STATE_PY" stamp "$STATE" "$FP" "$@"
