#!/usr/bin/env bash
# resume_handoff.sh — TR-07: hand the incident-Spec into spec-gen's EXISTING resume
# path and land it as a DRAFT PR Claim. NO new spec-gen code, NO new host code.
#
#   1. Prove the emitted <incident>.manifest.yaml is RESUMABLE-INCOMPLETE by running
#      the VENDORED resume_projection.py (which runs the vendored validator): it must
#      report validator_exit == 3 (§10 — an incomplete manifest is consumable only by
#      a resumed spec-tier session). Not 3 -> REFUSE.
#   2. Open a DRAFT PR through the VENDORED host adapter (host.sh pr-open --draft):
#      report-only first (ADR 0020) — the Spec is a PROPOSAL for human review, never
#      merge-blocking, never auto-merged. $TRIAGE_HOST defaults to the sibling
#      autopilot host.sh; a deployment/standalone install or the self-test overrides it.
#   3. Append the incident-key -> PR number to the loop-guard ledger so a re-fire of
#      the same incident is deduped (TR-loop-guard) while this proposal is still open.
#
# Honest loop statement: prod telemetry -> incident-Spec -> spec-gen resume ->
# autopilot -> audit -> marshal. A new SOURCE feeding the left edge; NOT a magic ring.
#
#   resume_handoff.sh --manifest <m> --prose <md> --incident-id <id> --key <key>
#       --branch <src-branch> [--dest <trunk>] [--host <host.sh>] [--ledger <f>]
#       [--no-open]   # skip the PR open (projection-only dry run)
#
# Portability: bash 3.2 + BSD safe.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_triage_run.sh"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
PROJECTOR="$HERE/resume_projection.py"   # vendored byte-identical from spec-gen
HOST="${TRIAGE_HOST:-$PLUGIN_ROOT/../autopilot/scripts/host.sh}"

die() { echo "resume_handoff.sh: REFUSE: $*" >&2; exit 1; }

MANIFEST=""; PROSE=""; INCIDENT_ID=""; KEY=""; BRANCH=""; DEST="${AUTOPILOT_TRUNK:-main}"; LEDGER=""; NO_OPEN=0
while (( $# > 0 )); do
  case "$1" in
    --manifest)    MANIFEST="${2:-}"; shift 2 ;;
    --prose)       PROSE="${2:-}"; shift 2 ;;
    --incident-id) INCIDENT_ID="${2:-}"; shift 2 ;;
    --key)         KEY="${2:-}"; shift 2 ;;
    --branch)      BRANCH="${2:-}"; shift 2 ;;
    --dest)        DEST="${2:-}"; shift 2 ;;
    --host)        HOST="${2:-}"; shift 2 ;;
    --ledger)      LEDGER="${2:-}"; shift 2 ;;
    --no-open)     NO_OPEN=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$MANIFEST" ] || die "--manifest required"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
[ -n "$INCIDENT_ID" ] || die "--incident-id required"

# ── ledger path: default from triage.config.yaml loop_guard.ledger (SYMMETRY with
#    loop_guard.py's READ path). Without this, the documented handoff (no --ledger)
#    would open a PR but record nothing, and the next incident's dedupe would read an
#    empty ledger and emit a DUPLICATE incident-Spec — defeating TR-loop-guard. ──
CONFIG="${TRIAGE_CONFIG:-$PLUGIN_ROOT/triage.config.yaml}"
if [ -z "$LEDGER" ]; then
  LEDGER="$(awk '
    /^[A-Za-z_]/ { insec = ($1 == "loop_guard:") }
    insec && $1 == "ledger:" { sub(/^[[:space:]]*ledger:[[:space:]]*/,""); sub(/[[:space:]]*#.*$/,""); gsub(/^"|"$/,""); print; exit }
  ' "$CONFIG" 2>/dev/null)"
  [ -n "$LEDGER" ] || LEDGER="triage/open-incidents.tsv"
fi

# ── 1. RESUMABLE-INCOMPLETE proof via the vendored resume projector (exit 3) ──
PROJ="$(triage_py "$PROJECTOR" "$MANIFEST")" || die "resume_projection.py failed"
VEXIT="$(printf '%s' "$PROJ" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("validator_exit"))' 2>/dev/null || true)"
[ "$VEXIT" = "3" ] || die "incident manifest is not resumable-incomplete (resume_projection validator_exit=$VEXIT, expected 3); spec-gen resume accepts ONLY an incomplete manifest (§10)"
echo "[ok] incident manifest accepted as resumable input by the vendored spec-gen projector (validator_exit=3)"

if [ "$NO_OPEN" -eq 1 ]; then
  echo "[note] --no-open: projection-only; no PR opened."
  exit 0
fi

# ── 2. DRAFT PR via the vendored host adapter (report-only first, ADR 0020) ──
[ -n "$BRANCH" ] || die "--branch required to open the incident-Spec PR"
# --key is REQUIRED to open a PR: without it the loop-guard ledger cannot record the
# open incident, and a re-fire would emit a DUPLICATE incident-Spec (TR-loop-guard).
[ -n "$KEY" ] || die "--key required to open the incident-Spec PR (the loop-guard ledger cannot dedupe a re-fire without it)"
[ -f "$HOST" ] || die "host adapter not found: $HOST (set \$TRIAGE_HOST)"
TITLE="[incident-spec] ${INCIDENT_ID} (proposal — read-only triage; not a fix)"
OPEN_ARGS=(pr-open --draft --title "$TITLE" --src "$BRANCH" --dest "$DEST")
[ -n "$PROSE" ] && [ -f "$PROSE" ] && OPEN_ARGS+=(--body-file "$PROSE")
OPEN_OUT="$(bash "$HOST" "${OPEN_ARGS[@]}")" || die "host pr-open --draft failed"
# Extract the PR number: the last run of digits in the host's stdout (works for a
# bare number or a .../pull/<n> URL — GitHub and Bitbucket alike).
PR_NUM="$(printf '%s' "$OPEN_OUT" | grep -oE '[0-9]+' | tail -1)"
[ -n "$PR_NUM" ] || die "could not parse a PR number from host pr-open output: $OPEN_OUT"
echo "[ok] opened DRAFT incident-Spec PR #$PR_NUM (proposal for human review; report-only, never auto-merged)"

# ── 3. record the open incident in the loop-guard ledger (dedupe a re-fire) ──
# LEDGER is always set now (explicit --ledger or the config default), and KEY is
# required above, so every opened incident-Spec is recorded — the READ path
# (loop_guard.py is-open) will find it on a re-fire and suppress the duplicate.
mkdir -p "$(dirname "$LEDGER")"
printf '%s\t%s\n' "$KEY" "$PR_NUM" >> "$LEDGER"
echo "[ok] recorded incident-key -> PR #$PR_NUM in the loop-guard ledger ($LEDGER)"
