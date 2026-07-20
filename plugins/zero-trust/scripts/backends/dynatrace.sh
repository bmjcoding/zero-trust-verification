#!/usr/bin/env bash
# dynatrace.sh — Dynatrace Grail/DQL telemetry backend (TR-01). A backend
# SELECTION behind telemetry.sh, never a caller branch (ADR 0006/0013).
#
# Two source paths (identical discipline to cloudwatch.sh):
#   - HERMETIC (the [det] proof): $TRIAGE_DYNATRACE_FIXTURE points at a canned DQL
#     response; normalize.py --format dynatrace turns it into SCHEMA-VALID TR-02
#     NDJSON. "works on Dynatrace" == that jsonschema assertion over a real canned
#     response — no live call, no credentials.
#   - LIVE (the [drain] residual): a real DQL query resolves its token through
#     secret_get.sh (tokens never enter agent context, ADR 0013). This build makes
#     NO live call: absent a fixture, we REFUSE rather than fabricate.
#
# Portability: bash 3.2 + BSD safe.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
PY="${TRIAGE_PYTHON:-python3}"
SECRET_GET="${TRIAGE_SECRET_GET:-$SCRIPTS/../skills/autopilot/scripts/secret_get.sh}"

die() { echo "dynatrace.sh: REFUSE: $*" >&2; exit 1; }

SUB="${1:-}"; shift || true
case "$SUB" in
  probe)
    if [ -n "${TRIAGE_DYNATRACE_FIXTURE:-}" ]; then
      [ -f "$TRIAGE_DYNATRACE_FIXTURE" ] || die "canned fixture not readable: $TRIAGE_DYNATRACE_FIXTURE"
      echo "dynatrace: ok (canned fixture $TRIAGE_DYNATRACE_FIXTURE)"
    else
      die "no fixture and no live query in this build — set \$TRIAGE_DYNATRACE_FIXTURE (hermetic) or run the live [drain] path (secret_get: $SECRET_GET)"
    fi
    ;;
  window)
    SINCE=""; UNTIL=""; SERVICE=""; EVENT=""
    while (( $# > 0 )); do
      case "$1" in
        --since)   SINCE="${2:-}"; shift 2 ;;
        --until)   UNTIL="${2:-}"; shift 2 ;;
        --service) SERVICE="${2:-}"; shift 2 ;;
        --event)   EVENT="${2:-}"; shift 2 ;;
        *) die "unknown window argument: $1" ;;
      esac
    done
    [ -n "${TRIAGE_DYNATRACE_FIXTURE:-}" ] || \
      die "live Dynatrace query is the [drain] path (not exercised in this build); set \$TRIAGE_DYNATRACE_FIXTURE for a hermetic window"
    [ -f "$TRIAGE_DYNATRACE_FIXTURE" ] || die "canned fixture not readable: $TRIAGE_DYNATRACE_FIXTURE"
    exec "$PY" "$SCRIPTS/normalize.py" --format dynatrace --source "$TRIAGE_DYNATRACE_FIXTURE" \
      --since "$SINCE" --until "$UNTIL" \
      ${SERVICE:+--service "$SERVICE"} ${EVENT:+--event "$EVENT"}
    ;;
  *)
    die "usage: dynatrace.sh probe | window --since <e> --until <e> [--service S] [--event E]"
    ;;
esac
