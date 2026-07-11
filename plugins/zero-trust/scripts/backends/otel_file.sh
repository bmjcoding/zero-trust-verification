#!/usr/bin/env bash
# otel_file.sh — the DEFAULT telemetry backend (TR-01): an OTLP/OTEL-JSON logs
# file (ADR 0006). Hermetic + community: no cloud, no credentials, no live call —
# this is the backend the self-test runs on, so "the default IS the test backend".
#
# Source resolution: $TRIAGE_OTEL_FILE, else triage.config.yaml telemetry.otel_file.
# Emits TR-02 incident-window NDJSON on stdout via the shared normalize.py.
#
# Portability: bash 3.2 + BSD safe.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPTS/.." && pwd)"
CONFIG="${TRIAGE_CONFIG:-$PLUGIN_ROOT/triage.config.yaml}"
PY="${TRIAGE_PYTHON:-python3}"

die() { echo "otel_file.sh: REFUSE: $*" >&2; exit 1; }

cfg_otel_file() {
  awk '
    /^[A-Za-z_]/ { insec = ($1 == "telemetry:") }
    insec && $1 == "otel_file:" {
      sub(/^[[:space:]]*otel_file:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, "")
      gsub(/^"|"$/, ""); print; exit
    }
  ' "$CONFIG" 2>/dev/null
}

resolve_source() {
  local src="${TRIAGE_OTEL_FILE:-}"
  [ -n "$src" ] || src="$(cfg_otel_file)"
  [ -n "$src" ] || die "no OTLP-JSON logs file — set \$TRIAGE_OTEL_FILE or triage.config.yaml telemetry.otel_file"
  printf '%s' "$src"
}

SUB="${1:-}"; shift || true
case "$SUB" in
  probe)
    SRC="$(resolve_source)" || exit 1
    [ -f "$SRC" ] || die "OTLP-JSON logs file not readable: $SRC"
    echo "otel_file: ok ($SRC)"
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
    SRC="$(resolve_source)" || exit 1
    [ -f "$SRC" ] || die "OTLP-JSON logs file not readable: $SRC"
    exec "$PY" "$SCRIPTS/normalize.py" --format otlp --source "$SRC" \
      --since "$SINCE" --until "$UNTIL" \
      ${SERVICE:+--service "$SERVICE"} ${EVENT:+--event "$EVENT"}
    ;;
  *)
    die "usage: otel_file.sh probe | window --since <e> --until <e> [--service S] [--event E]"
    ;;
esac
