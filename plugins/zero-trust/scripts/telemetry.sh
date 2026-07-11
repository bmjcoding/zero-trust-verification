#!/usr/bin/env bash
# telemetry.sh
#
# The single vendor-neutral telemetry surface for the triage tier (TR-01;
# ADR 0006 vendor-neutral / agent-first, ADR 0013 host-adapter precedent).
# Callers NEVER name a vendor: every ingest is `telemetry.sh <subcommand>`,
# dispatched to a backend detected host-locally. CloudWatch/Dynatrace are backend
# SELECTIONS behind this surface, never a caller-path branch — the exact discipline
# host.sh applies to Bitbucket-vs-GitHub.
#
# Subcommand surface:
#   backend                      -> prints the detected backend id (host-local; not delegated)
#   probe                        -> reachability/auth of the selected backend (exit 0 / non-zero+reason)
#   window --since <ts> --until <ts> [--service S] [--event E]
#                                -> normalized TR-02 incident-window NDJSON on stdout
#
# Backend detection (first match wins) — mirrors host.sh's detect matrix but with
# NO origin heuristic (there is no origin-equivalent for a telemetry vendor, so
# absence is an ADR 0002 external-fact escalation, never a guessed default):
#   1. $TRIAGE_TELEMETRY_BACKEND   authoritative  (OTEL_FILE | CLOUDWATCH | DYNATRACE)
#   2. committed triage.config.yaml  telemetry.backend:
#   3. else REFUSE, pointing at $TRIAGE_TELEMETRY_BACKEND.
#
# BOUNDED-WINDOW-ONLY cost invariant (the mutation-testing analog, made mechanical):
# `window` REFUSES when --since/--until are absent, when the span exceeds
# window.max_span (default 24h), or when neither --service nor --event scopes a
# backend whose retention is unbounded. No implicit "scan everything".
#
# Secret handling is a per-backend property behind this surface (ADR 0013) — the
# live CloudWatch/Dynatrace query resolves tokens through secret_get.sh; the
# default OTEL_FILE backend and every self-test path are hermetic and touch none.
#
# Portability: bash 3.2 (macOS default) + BSD userland safe.

set -u
set +x

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
CONFIG="${TRIAGE_CONFIG:-$PLUGIN_ROOT/triage.config.yaml}"

usage() {
  cat >&2 <<EOF
usage: telemetry.sh <subcommand> [args]
subcommands: backend probe window
  window --since <ts> --until <ts> [--service S] [--event E]
EOF
  exit 64
}

die() {  # <reason...> — refuse with a stable, greppable REFUSE line
  echo "telemetry.sh: REFUSE: $*" >&2
  exit 1
}

# ── minimal, targeted YAML scalar reader (committed config has a fixed shape) ──
# Reads a nested `section.key` scalar. Not a general YAML parser — deliberately
# narrow so backend detection stays mechanical/greppable (host.sh precedent).
yaml_scalar() {  # <file> <section> <key>
  [ -f "$1" ] || return 1
  awk -v sec="$2:" -v key="$3:" '
    /^[A-Za-z_]/ { insec = ($1 == sec) }
    insec && $1 == key {
      sub(/^[[:space:]]*[A-Za-z_0-9]+:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      gsub(/^"|"$/, "")
      print; exit
    }
  ' "$1"
}

# ── backend detection (the [det] matrix) ──────────────────────────────────────
detect_backend() {
  local override="${TRIAGE_TELEMETRY_BACKEND:-}"
  if [ -n "$override" ]; then
    case "$override" in
      OTEL_FILE|CLOUDWATCH|DYNATRACE) printf '%s' "$override"; return 0 ;;
      *) die "TRIAGE_TELEMETRY_BACKEND must be OTEL_FILE|CLOUDWATCH|DYNATRACE, got: $override" ;;
    esac
  fi
  local cfg
  cfg="$(yaml_scalar "$CONFIG" telemetry backend 2>/dev/null || true)"
  if [ -n "$cfg" ]; then
    case "$cfg" in
      OTEL_FILE|CLOUDWATCH|DYNATRACE) printf '%s' "$cfg"; return 0 ;;
      *) die "triage.config.yaml telemetry.backend must be OTEL_FILE|CLOUDWATCH|DYNATRACE, got: $cfg" ;;
    esac
  fi
  # No origin-sniff analog for a telemetry vendor (ADR 0002 external fact).
  die "no telemetry backend selected — set \$TRIAGE_TELEMETRY_BACKEND=OTEL_FILE|CLOUDWATCH|DYNATRACE (or triage.config.yaml telemetry.backend). A telemetry vendor is an external fact; the tier will not guess one."
}

backend_script() {  # <backend-id> -> path
  case "$1" in
    OTEL_FILE)  printf '%s' "$HERE/backends/otel_file.sh" ;;
    CLOUDWATCH) printf '%s' "$HERE/backends/cloudwatch.sh" ;;
    DYNATRACE)  printf '%s' "$HERE/backends/dynatrace.sh" ;;
    *) die "no backend script for: $1" ;;
  esac
}

# ── window.max_span (default 24h) -> seconds ──────────────────────────────────
span_to_seconds() {  # <"24h"|"90m"|"3600"|"1d"> -> seconds
  local s="$1" num unit
  case "$s" in
    *[!0-9]*)
      num="${s%[a-zA-Z]}"; unit="${s##*[0-9]}" ;;
    *)
      num="$s"; unit="s" ;;
  esac
  [ -n "$num" ] || return 1
  case "$unit" in
    s|"") echo "$num" ;;
    m)    echo $(( num * 60 )) ;;
    h)    echo $(( num * 3600 )) ;;
    d)    echo $(( num * 86400 )) ;;
    *) return 1 ;;
  esac
}

# ── ts (epoch int OR RFC3339) -> epoch seconds. python3 is the ADR 0015 substrate.
ts_epoch() {  # <ts> -> epoch on stdout; rc 1 on parse failure
  python3 - "$1" <<'PY' 2>/dev/null
import sys, datetime
s = sys.argv[1].strip()
if s.isdigit():
    print(s); raise SystemExit(0)
for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%S%z"):
    try:
        dt = datetime.datetime.strptime(s, fmt)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        print(int(dt.timestamp())); raise SystemExit(0)
    except ValueError:
        pass
raise SystemExit(1)
PY
}

is_unbounded_backend() {  # <backend-id> -> 0 if listed under window.unbounded_retention_backends
  local bk="$1" line
  line="$(grep -E '^[[:space:]]*unbounded_retention_backends:' "$CONFIG" 2>/dev/null || true)"
  case "$line" in
    *"$bk"*) return 0 ;;
    *) return 1 ;;
  esac
}

(( $# >= 1 )) || usage
SUB="$1"; shift

case "$SUB" in
  backend)
    detect_backend; echo
    ;;

  probe)
    BACKEND="$(detect_backend)"
    SCRIPT="$(backend_script "$BACKEND")"
    [ -f "$SCRIPT" ] || die "backend script not found: $SCRIPT"
    exec bash "$SCRIPT" probe
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

    BACKEND="$(detect_backend)"

    # ── the bounded-window guard (the never-whole-fleet teeth) ────────────────
    [ -n "$SINCE" ] && [ -n "$UNTIL" ] || \
      die "bounded-window guard: --since and --until are BOTH required (no unbounded/full-retention scan; the mutation-testing cost analog)"

    S_EPOCH="$(ts_epoch "$SINCE")" || die "bounded-window guard: --since is not epoch-seconds or RFC3339: $SINCE"
    U_EPOCH="$(ts_epoch "$UNTIL")" || die "bounded-window guard: --until is not epoch-seconds or RFC3339: $UNTIL"
    [ "$U_EPOCH" -ge "$S_EPOCH" ] || die "bounded-window guard: --until ($UNTIL) precedes --since ($SINCE)"

    MAXSPAN_RAW="$(yaml_scalar "$CONFIG" window max_span 2>/dev/null || true)"
    [ -n "$MAXSPAN_RAW" ] || MAXSPAN_RAW="24h"
    MAXSPAN="$(span_to_seconds "$MAXSPAN_RAW")" || die "bounded-window guard: unparseable window.max_span: $MAXSPAN_RAW"
    SPAN=$(( U_EPOCH - S_EPOCH ))
    [ "$SPAN" -le "$MAXSPAN" ] || \
      die "bounded-window guard: span ${SPAN}s exceeds window.max_span ${MAXSPAN}s ($MAXSPAN_RAW) — narrow --since/--until"

    if is_unbounded_backend "$BACKEND"; then
      [ -n "$SERVICE" ] || [ -n "$EVENT" ] || \
        die "bounded-window guard: backend $BACKEND has unbounded retention — one of --service/--event is required to scope (never a whole-fleet scan)"
    fi

    SCRIPT="$(backend_script "$BACKEND")"
    [ -f "$SCRIPT" ] || die "backend script not found: $SCRIPT"
    # Delegate to the backend, forwarding the validated, bounded window. The
    # backend emits TR-02 NDJSON on stdout; the surface is a pass-through.
    exec bash "$SCRIPT" window \
      --since "$S_EPOCH" --until "$U_EPOCH" \
      ${SERVICE:+--service "$SERVICE"} ${EVENT:+--event "$EVENT"}
    ;;

  *)
    usage
    ;;
esac
