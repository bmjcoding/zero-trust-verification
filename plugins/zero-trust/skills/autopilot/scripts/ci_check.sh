#!/usr/bin/env bash
# ci_check.sh
#
# Reports CI build status for a given commit and PR, returning a normalized
# verdict the dispatcher consumes at D7.5.
#
# v2.4.0 (GAPS A6/A7):
#   - NEW `--once` mode: take ONE observation and exit immediately. This is
#     what the DRAIN D7.5 dispatch consumes — the drain design is cross-fire
#     (one observation per fire, cron re-arms at */10), so a blocking poll
#     loop inside a fire was never dispatchable. The canonical dispatcher
#     invocation is:
#         ci_check.sh --sha <sha> --pr <N> --once
#   - `--once` reports VERDICT=PENDING (exit 5) for both INPROGRESS and
#     UNKNOWN observations — a single observation cannot distinguish
#     "not started yet" from "will never report"; the dispatcher's
#     ci_check_count cap owns that distinction. Grace/timeout windows
#     apply to blocking mode only.
#   - LAST_STATE on stderr now carries the ACTUAL last observed build state
#     (SUCCESSFUL|FAILED|INPROGRESS|UNKNOWN|<none>), not a constant, so the
#     tracker entry can cite it as the v2.2.0 changelog promised.
#   - Blocking mode (no --once) is retained for interactive operator use.
#
# Usage:
#   ci_check.sh --sha <sha> --pr <N> [--once] [--timeout-sec 1800] [--poll-sec 30] [--grace-sec 120]
#
# Output (single line on stdout): VERDICT=<value>
#   GREEN       - build SUCCESSFUL
#   RED         - build FAILED
#   PENDING     - (--once only) build INPROGRESS, or no statuses within grace
#   STUCK       - (blocking mode) poll loop hit timeout while INPROGRESS
#   UNDETERMINED- no build statuses reported for the SHA after grace window
#   PR_DECLINED - PR state is DECLINED (no further build polling)
#
# Exit codes: 0 GREEN, 1 RED, 2 STUCK, 3 UNDETERMINED, 4 PR_DECLINED,
#             5 PENDING (--once only), 64 usage.
#
# LAST_STATE=<value> is emitted on stderr immediately before every exit so the
# dispatcher (lifecycle.md D7.5 dispatch) can classify the terminal state
# without re-parsing preceding stderr lines.

set -u
set +x

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Build-status and PR state are read through the host adapter (host.sh), never
# a named backend, so the D7.5 CI poll is host-agnostic (ADR 0013, Hard
# Contract 11). host.sh dispatches to the Bitbucket DC or GitHub backend.
HOST="$HERE/host.sh"

SHA=""
PR=""
ONCE=0
TIMEOUT=1800
POLL=30
GRACE=120  # window during which "no build statuses" counts as still-pending

while (( $# > 0 )); do
  case "$1" in
    --sha) SHA="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --timeout-sec) TIMEOUT="$2"; shift 2 ;;
    --poll-sec) POLL="$2"; shift 2 ;;
    --grace-sec) GRACE="$2"; shift 2 ;;
    *) echo "LAST_STATE=usage-error" >&2; echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

[[ -n "$SHA" && -n "$PR" ]] || { echo "LAST_STATE=usage-error" >&2; echo "usage: ci_check.sh --sha <sha> --pr <N> [--once] [--timeout-sec N] [--poll-sec N]" >&2; exit 64; }
[[ -x "$HOST" ]] || { echo "LAST_STATE=usage-error" >&2; echo "missing host.sh next to ci_check.sh" >&2; exit 64; }

START=$(date -u +%s)
LAST_STATE="<none>"

emit() {
  echo "VERDICT=$1"
}

finish() {
  # finish <verdict> <exit-code> — LAST_STATE carries the last OBSERVED
  # build state (GAPS A7), independent of the verdict name.
  emit "$1"
  echo "LAST_STATE=${LAST_STATE}" >&2
  exit "$2"
}

while :; do
  NOW=$(date -u +%s)
  ELAPSED=$(( NOW - START ))

  # First, check PR state. If declined, stop polling builds.
  PR_STATE=$("$HOST" pr-state --num "$PR" 2>/dev/null || echo UNKNOWN)
  case "$PR_STATE" in
    DECLINED) finish PR_DECLINED 4 ;;
    # DRAFT is a still-open PR (a Story mid-drain); keep polling its build like OPEN.
    MERGED|OPEN|DRAFT|UNKNOWN) : ;;
  esac

  BUILD_STATE=$("$HOST" build-status --sha "$SHA" 2>/dev/null || echo UNKNOWN)
  LAST_STATE="$BUILD_STATE"
  case "$BUILD_STATE" in
    SUCCESSFUL) finish GREEN 0 ;;
    FAILED)     finish RED 1 ;;
    INPROGRESS)
      if (( ONCE == 1 )); then
        finish PENDING 5
      fi
      ;;  # blocking mode: keep polling
    UNKNOWN)
      if (( ONCE == 1 )); then
        # Single observation: no statuses at all. Within the grace window
        # after the push this is normal (CI hasn't picked the SHA up yet) —
        # the dispatcher supplies elapsed context by counting fires, so we
        # report PENDING and let ci_check_count cap the retries.
        finish PENDING 5
      fi
      # Blocking mode: if we've been in UNKNOWN longer than grace, UNDETERMINED.
      if (( ELAPSED > GRACE )); then
        finish UNDETERMINED 3
      fi
      ;;
  esac

  if (( ELAPSED > TIMEOUT )); then
    finish STUCK 2
  fi

  sleep "$POLL"
done
