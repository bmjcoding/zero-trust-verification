#!/usr/bin/env bash
# detect_concurrent_drain.sh
#
# Detects whether another autopilot session holds a live lock on a tracker.
# The dispatcher calls this at GENERATE Step G1 and at DRAIN Step D1, passing
# the TRACKER PATH (v2.4.0: G1 previously documented passing a bare slug,
# which always exited 0 — see docs/GAPS_SPEC.md A5a; callers derive the path
# as .autopilot/runbooks/<slug>.tracker.md).
#
# Mechanism (v2.4.0, aligned with the canonical G7 tracker schema and the
# D1.0 dispatch table — GAPS A5b/A5c): read the tracker frontmatter's
# `session_lock` + `session_lock_expires_at` and compare against
# CLAUDE_SESSION_ID and the current time. Staleness is defined ONLY by
# `session_lock_expires_at` (which every fire refreshes to now+30min);
# there is no heartbeat-age window here — heartbeats age legitimately
# between */30-cadence fires, and using them would let a second session
# steal the lock of a healthy drain.
#
# Exit codes (fail-closed — GAPS A5d):
#   0  no tracker file, no lock, or lock held by THIS session
#   2  lock-held-by-other:<sid>   live foreign lock (expires_at > now)
#   3  lock-stale:<sid>           foreign lock past expiry (caller may reclaim)
#   4  tracker-unreadable         frontmatter present but lock fields
#                                 unparseable — caller MUST refuse, not proceed
#   64 usage error
#
# Usage: detect_concurrent_drain.sh <tracker-path>
# Env:   CLAUDE_SESSION_ID must be set.

set -euo pipefail

TRACKER="${1:?usage: detect_concurrent_drain.sh <tracker-path>}"
: "${CLAUDE_SESSION_ID:?CLAUDE_SESSION_ID env var required}"

if [[ ! -e "$TRACKER" ]]; then
  # No tracker at that path: nothing to collide with. Callers that expected a
  # tracker to exist must check existence themselves; this script only judges
  # locks. (Passing a bare slug lands here — that caller bug is now caught by
  # the .md suffix guard below.)
  case "$TRACKER" in
    *.md) exit 0 ;;
    *) echo "tracker-path-suspect: '$TRACKER' does not look like a tracker path (want .../<slug>.tracker.md)" >&2; exit 64 ;;
  esac
fi

if [[ ! -r "$TRACKER" ]]; then
  echo "tracker-unreadable" >&2
  exit 4
fi

# Extract YAML frontmatter (between first two --- lines).
FM=$(awk '/^---$/{c++; next} c==1{print} c==2{exit}' "$TRACKER")

if [[ -z "$FM" ]]; then
  echo "tracker-unreadable: no frontmatter" >&2
  exit 4
fi

get() {
  echo "$FM" | awk -v k="$1" '$1==k":"{ $1=""; sub(/^ /, ""); print; exit }'
}

LOCK_SID=$(get session_lock)
LOCK_EXPIRES=$(get session_lock_expires_at)

# Normalise YAML nulls.
[[ "$LOCK_SID" == "null" || "$LOCK_SID" == "~" ]] && LOCK_SID=""
[[ "$LOCK_EXPIRES" == "null" || "$LOCK_EXPIRES" == "~" ]] && LOCK_EXPIRES=""

if [[ -z "$LOCK_SID" ]]; then
  exit 0
fi

if [[ "$LOCK_SID" == "$CLAUDE_SESSION_ID" ]]; then
  exit 0
fi

NOW_EPOCH=$(date -u +%s)

# Portable ISO8601 -> epoch (BSD date on macOS uses -j -f; GNU date uses -d).
iso_to_epoch() {
  local iso="$1"
  if date -u -d "$iso" +%s 2>/dev/null; then
    return 0
  fi
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null
}

if [[ -z "$LOCK_EXPIRES" ]]; then
  # A foreign lock with no expiry is corrupt state: fail closed.
  echo "tracker-unreadable: session_lock set but session_lock_expires_at missing" >&2
  exit 4
fi

EXPIRES_EPOCH=$(iso_to_epoch "$LOCK_EXPIRES" || true)
if [[ -z "${EXPIRES_EPOCH:-}" ]]; then
  echo "tracker-unreadable: cannot parse session_lock_expires_at='$LOCK_EXPIRES'" >&2
  exit 4
fi

if (( EXPIRES_EPOCH > NOW_EPOCH )); then
  echo "lock-held-by-other:${LOCK_SID}"
  exit 2
fi

echo "lock-stale:${LOCK_SID}"
exit 3
