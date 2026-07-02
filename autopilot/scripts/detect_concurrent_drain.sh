#!/usr/bin/env bash
# detect_concurrent_drain.sh
#
# Detects whether more than one autopilot session is currently active against
# the same runbook. The dispatcher calls this at D0 (init) and at every
# step boundary as part of the AP-6 heartbeat check.
#
# Mechanism: read the tracker frontmatter's session_id + lock_acquired_at +
# last_heartbeat_at, compare against the current CLAUDE_SESSION_ID and current
# time. The lock has two failure modes:
#
#   1. lock-held-by-other: session_id differs from CLAUDE_SESSION_ID AND
#      lock_acquired_at is less than 30 minutes old AND
#      last_heartbeat_at is less than 5 minutes old.
#      -> exit 2, print "lock-held-by-other:<other-session-id>"
#
#   2. lock-held-stale: session_id differs from CLAUDE_SESSION_ID AND
#      (lock_acquired_at is >= 30 min old OR last_heartbeat_at is >= 5 min old).
#      -> exit 3, print "lock-stale:<other-session-id>"
#      Caller may overwrite the lock.
#
# Clean cases:
#   - No tracker file exists OR session_id matches CLAUDE_SESSION_ID -> exit 0
#
# Usage: detect_concurrent_drain.sh <tracker-path>
# Env:   CLAUDE_SESSION_ID must be set.

set -euo pipefail

TRACKER="${1:?usage: detect_concurrent_drain.sh <tracker-path>}"
: "${CLAUDE_SESSION_ID:?CLAUDE_SESSION_ID env var required}"

if [[ ! -f "$TRACKER" ]]; then
  exit 0
fi

# Extract YAML frontmatter (between first two --- lines).
FM=$(awk '/^---$/{c++; next} c==1{print} c==2{exit}' "$TRACKER")

get() {
  echo "$FM" | awk -v k="$1" '$1==k":"{ $1=""; sub(/^ /, ""); print; exit }'
}

OTHER_SID=$(get session_id)
LOCK_AT=$(get lock_acquired_at)
HB_AT=$(get last_heartbeat_at)

if [[ -z "$OTHER_SID" ]]; then
  exit 0
fi

if [[ "$OTHER_SID" == "$CLAUDE_SESSION_ID" ]]; then
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

LOCK_EPOCH=$(iso_to_epoch "$LOCK_AT" || echo 0)
HB_EPOCH=$(iso_to_epoch "$HB_AT" || echo 0)

LOCK_AGE=$(( NOW_EPOCH - LOCK_EPOCH ))
HB_AGE=$(( NOW_EPOCH - HB_EPOCH ))

# 30 min lock window, 5 min heartbeat window.
if (( LOCK_AGE < 1800 )) && (( HB_AGE < 300 )); then
  echo "lock-held-by-other:${OTHER_SID}"
  exit 2
fi

echo "lock-stale:${OTHER_SID}"
exit 3
