#!/usr/bin/env bash
# outcome_digest.sh — the scheduled outcome digest (ADR 0023; OM-08). An ADDED
# per-fire step on the Marshal's EXISTING operator-wired single-fire cron entry
# (the SAME entry that runs the merge pass) — NOT a new scheduler (ADR 0003/0010).
#
# One fire runs, in order, each guarded so a degrade never aborts the digest:
#   1. outcome-capture (OM-03): DORA, Class-D, via the host adapter.
#   2. outcome-emit (OM-04) IF the LAST audit left a journeys.json — it only READS
#      that file; it NEVER triggers a fresh audit / walker (H6).
#   3. outcome_report.sh (OM-07): render the digest.
# The digest is POSTED via the Marshal's host write scope (host.sh pr-comment,
# --post-pr N) OR written as an artifact (--artifact). The audit-side outcome-emit
# posts NOTHING (H5). No status check is ever created. Exits 0 ALWAYS (ADR 0004).
#
# Usage:
#   marshal.sh outcome-digest --store PATH [--repo P] [--trunk main]
#       [--weeks N | --since E --until E] [--now E]
#       [--host HOST --host-repo GITDIR --host-state STATE]
#       [--journeys audit/journeys.json] [--artifact outcome/DIGEST.md] [--post-pr N]
#
# Portability: bash 3.2 (macOS) + BSD userland safe.
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(cd "$HERE/../../.." && pwd)"
CAPTURE="$HERE/outcome_capture.sh"
EMIT="$SUITE_ROOT/plugins/zero-trust/skills/cleanup-audit/scripts/outcome_emit.sh"
REPORT_SH="$SUITE_ROOT/scripts/outcome_report.sh"
HOST_DEFAULT="${MARSHAL_HOST:-$HERE/../skills/autopilot/scripts/host.sh}"

STORE="${OUTCOME_STORE:-}"; REPO="."; TRUNK="${MARSHAL_MAIN:-main}"; WEEKS="8"
SINCE=""; UNTIL=""; NOW=""; HOST="$HOST_DEFAULT"; HOST_REPO=""; HOST_STATE=""
JOURNEYS=""; ARTIFACT=""; POST_PR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --store) STORE="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --trunk) TRUNK="$2"; shift 2;;
    --weeks) WEEKS="$2"; shift 2;;
    --since) SINCE="$2"; shift 2;;
    --until) UNTIL="$2"; shift 2;;
    --now) NOW="$2"; shift 2;;
    --host) HOST="$2"; shift 2;;
    --host-repo) HOST_REPO="$2"; shift 2;;
    --host-state) HOST_STATE="$2"; shift 2;;
    --journeys) JOURNEYS="$2"; shift 2;;
    --artifact) ARTIFACT="$2"; shift 2;;
    --post-pr) POST_PR="$2"; shift 2;;
    --no-host) HOST=""; shift;;
    *) echo "outcome_digest: unknown arg: $1" >&2; shift;;
  esac
done
[ -n "$STORE" ] || { echo "outcome_digest: --store PATH (or \$OUTCOME_STORE) required" >&2; exit 0; }
[ -n "$JOURNEYS" ] || JOURNEYS="$REPO/audit/journeys.json"

log() { echo "outcome_digest: $*"; }

# --- 1. outcome-capture (DORA) — guarded ------------------------------------------
cap_args=(--store "$STORE" --repo "$REPO" --trunk "$TRUNK" --weeks "$WEEKS")
[ -n "$SINCE" ] && cap_args+=(--since "$SINCE")
[ -n "$UNTIL" ] && cap_args+=(--until "$UNTIL")
[ -n "$NOW" ]   && cap_args+=(--now "$NOW")
if [ -n "$HOST" ] && [ -f "$HOST" ]; then
  cap_args+=(--host "$HOST")
  [ -n "$HOST_REPO" ]  && cap_args+=(--host-repo "$HOST_REPO")
  [ -n "$HOST_STATE" ] && cap_args+=(--host-state "$HOST_STATE")
else
  cap_args+=(--no-host)
  log "host unreachable — DORA build-status SKIPPED (deploy/lead still derived); digest still renders"
fi
if bash "$CAPTURE" "${cap_args[@]}"; then log "step 1 outcome-capture ok"; else log "step 1 outcome-capture degraded (continuing)"; fi

# --- 2. outcome-emit (emission share) IF a journeys.json exists — READ-ONLY -------
if [ -f "$JOURNEYS" ] && [ -f "$EMIT" ]; then
  emit_args=(--store "$STORE" --journeys "$JOURNEYS" --repo "$REPO")
  [ -n "$NOW" ] && emit_args+=(--now "$NOW")
  # NO fresh audit is spawned — outcome_emit.sh only READS the file (H6).
  if bash "$EMIT" "${emit_args[@]}"; then log "step 2 outcome-emit ok (read-only; no fresh audit)"; else log "step 2 outcome-emit degraded (continuing)"; fi
else
  log "step 2 outcome-emit SKIPPED — no journeys.json at $JOURNEYS (never triggers a fresh audit to make one)"
fi

# --- 3. render the digest + post via the Marshal's host write scope ---------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM
DIGEST="$TMP/digest.md"
bash "$REPORT_SH" --store "$STORE" --json "$TMP/artifact.json" > "$DIGEST" 2>/dev/null || true
cat "$DIGEST"

if [ -n "$ARTIFACT" ]; then
  mkdir -p "$(dirname "$ARTIFACT")" 2>/dev/null || true
  cp "$DIGEST" "$ARTIFACT" 2>/dev/null && log "digest written to artifact $ARTIFACT"
fi

if [ -n "$POST_PR" ] && [ -n "$HOST" ] && [ -f "$HOST" ]; then
  # the Marshal already holds host write scope; post the digest as a PR comment.
  if MARSHAL_MOCK_STATE="${HOST_STATE:-${MARSHAL_MOCK_STATE:-}}" MARSHAL_MOCK_REPO="${HOST_REPO:-${MARSHAL_MOCK_REPO:-}}" \
       bash "$HOST" pr-comment --num "$POST_PR" --body-file "$DIGEST" >/dev/null 2>&1; then
    log "digest posted to PR #$POST_PR via the Marshal host write scope"
  else
    log "digest post to PR #$POST_PR degraded (host write failed) — artifact still available"
  fi
fi

log "done (report-only; opened no PR, filed no finding, created no status check)"
exit 0
