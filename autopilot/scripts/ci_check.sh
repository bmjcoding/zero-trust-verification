#!/usr/bin/env bash
# ci_check.sh
#
# Polls CI build status for a given commit and PR, returning a normalized
# verdict the dispatcher consumes at D7.5.
#
# v2 changes:
#   - gh CLI removed. All Bitbucket interaction goes through bitbucket.sh.
#   - Resolver chain (sidecar -> keychain -> env) is handled inside bitbucket.sh.
#   - No tokens enter argv or trace logs here.
#   - PR-declined check uses bitbucket.sh pr-state.
#
# Usage:
#   ci_check.sh --sha <sha> --pr <N> [--timeout-sec 1800] [--poll-sec 30]
#
# Output (single line on stdout): VERDICT=<value>
#   GREEN       - build SUCCESSFUL
#   RED         - build FAILED
#   STUCK       - poll loop hit timeout while INPROGRESS
#   UNDETERMINED- no build statuses reported for the SHA after grace window
#   PR_DECLINED - PR state is DECLINED (no further build polling)
#
# Exit codes mirror verdict: 0 GREEN, 1 RED, 2 STUCK, 3 UNDETERMINED, 4 PR_DECLINED, 64 usage.
#
# v2.3.0 (AP-23):
#   - Emits LAST_STATE=<value> on stderr immediately before every non-zero
#     exit so the dispatcher (drain-lifecycle D7.5 poll dispatch) can classify
#     the terminal state without re-parsing preceding stderr lines.
#     Emitted values:
#       LAST_STATE=green           (exit 0)
#       LAST_STATE=red             (exit 1)
#       LAST_STATE=stuck-timeout   (exit 2)
#       LAST_STATE=undetermined    (exit 3)
#       LAST_STATE=pr-declined     (exit 4)
#       LAST_STATE=usage-error     (exit 64)

set -u
set +x

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BITBUCKET="$HERE/bitbucket.sh"

SHA=""
PR=""
TIMEOUT=1800
POLL=30
GRACE=120  # window during which "no build statuses" counts as still-pending

while (( $# > 0 )); do
  case "$1" in
    --sha) SHA="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --timeout-sec) TIMEOUT="$2"; shift 2 ;;
    --poll-sec) POLL="$2"; shift 2 ;;
    --grace-sec) GRACE="$2"; shift 2 ;;
    *) echo "LAST_STATE=usage-error" >&2; echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

[[ -n "$SHA" && -n "$PR" ]] || { echo "LAST_STATE=usage-error" >&2; echo "usage: ci_check.sh --sha <sha> --pr <N> [--timeout-sec N] [--poll-sec N]" >&2; exit 64; }
[[ -x "$BITBUCKET" ]] || { echo "LAST_STATE=usage-error" >&2; echo "missing bitbucket.sh next to ci_check.sh" >&2; exit 64; }

START=$(date -u +%s)
LAST_STATE=""

emit() {
  echo "VERDICT=$1"
}

while :; do
  NOW=$(date -u +%s)
  ELAPSED=$(( NOW - START ))

  # First, check PR state. If declined, stop polling builds.
  PR_STATE=$("$BITBUCKET" pr-state --num "$PR" 2>/dev/null || echo UNKNOWN)
  case "$PR_STATE" in
    DECLINED) emit PR_DECLINED; echo "LAST_STATE=pr-declined" >&2; exit 4 ;;
    MERGED|OPEN|UNKNOWN) : ;;
  esac

  BUILD_STATE=$("$BITBUCKET" build-status --sha "$SHA" 2>/dev/null || echo UNKNOWN)
  LAST_STATE="$BUILD_STATE"
  case "$BUILD_STATE" in
    SUCCESSFUL) emit GREEN; echo "LAST_STATE=green" >&2; exit 0 ;;
    FAILED)     emit RED;   echo "LAST_STATE=red" >&2;   exit 1 ;;
    INPROGRESS) : ;;  # keep polling
    UNKNOWN)
      # If we've been in UNKNOWN for longer than the grace window, treat as UNDETERMINED.
      if (( ELAPSED > GRACE )); then
        # AP-23: emit LAST_STATE=undetermined on stderr before exit 3 so
        # drain-lifecycle D7.5 can dispatch without re-parsing prior output.
        echo "LAST_STATE=undetermined" >&2
        emit UNDETERMINED
        exit 3
      fi
      ;;
  esac

  if (( ELAPSED > TIMEOUT )); then
    # AP-23: emit LAST_STATE=stuck-timeout on stderr before exit 2.
    echo "LAST_STATE=stuck-timeout" >&2
    emit STUCK
    exit 2
  fi

  sleep "$POLL"
done
