#!/usr/bin/env bash
# secret_get.sh
#
# Resolve a credential through the chain: sidecar -> OS keychain -> env.
# The resolved token is written to STDOUT and NOTHING ELSE.
#
# Hard rules (enforced here; do not relax):
#   - The token MUST NOT be passed as a positional argument.
#   - The token MUST NOT be echoed to a log.
#   - This script disables xtrace and command-history side effects.
#   - Errors are written to STDERR with a stable code; never include the secret.
#   - The script must never enter Claude Code's tool-arg surface; callers wrap
#     the invocation with `set +x` and capture STDOUT into a local shell var,
#     then pass it on STDIN (or via @file) to the consumer.
#
# Resolver chain:
#   1. SIDECAR: when the caller runs in sidecar mode it MUST export
#      AUTOPILOT_SIDECAR_MODE=1 before invoking this script (bitbucket.sh
#      does); the script then returns an empty string on STDOUT and exit 0 —
#      sidecar consumers send NO Authorization header. (v2.4.0: this caller
#      contract is now explicit; previously nothing set the variable.)
#   2. KEYCHAIN (macOS or Linux): tried against a prioritised list of candidate
#      service names (see below).
#   3. ENV: $AUTOPILOT_<SERVICE>_TOKEN  (uppercased)
#
# Candidate service names, in priority order (v2.4.0 adds #4 and the
# $<SERVICE>_HOST derivation source — both were claimed by the v2.1.0
# changelog but never implemented; see docs/GAPS_SPEC.md B3):
#
#   1. $AUTOPILOT_<SERVICE>_KEYCHAIN_NAME               (operator override)
#   2. autopilot-<service>                              (canonical)
#   3. autopilot-<service>-<host>                       (written by secret_set.sh --as-host)
#   4. <service>-token:<host>                           (community convention, e.g. bitbucket-token:cluster03)
#   5. <service>-token                                  (community convention)
#   6. <service>                                        (bare service name)
#
#   <host> is derived from $<SERVICE>_HOST (e.g. $BITBUCKET_HOST) when set,
#   else from `git remote get-url origin` (if invoked inside a git repo);
#   host-derived candidates are skipped when no host can be derived.
#   Candidate #4 uses the RAW host for the suffix (dots preserved, ports
#   dropped) to match hand-created entries; #3 uses the normalised form
#   that secret_set.sh writes.
#
# Each candidate is probed through the platform-appropriate keychain command
# (`security` on macOS, `secret-tool` on Linux). On macOS a "locked keychain"
# response (rc 36) short-circuits the probe loop and returns exit 3. On Linux
# `secret-tool` does not distinguish locked from missing, so a locked keychain
# falls through the chain (documented limitation; the v2.3.0 header overclaimed
# platform parity here).
#
# Usage: secret_get.sh <service> [--list-candidates]
#   service: lowercase identifier, e.g. "bitbucket"
#   --list-candidates: print the candidate service names (one per line) and
#     exit 0 WITHOUT touching any keychain. Debug/test aid; prints no secrets.
# Exit codes:
#   0  success (STDOUT has token, or empty when sidecar mode)
#   2  no credential found in any tier
#   3  keychain locked / requires unlock (macOS only; see above)
#   4  unsupported platform
#   64 usage error

set -u
set +x  # ensure xtrace is off; tokens must not appear in trace
unset HISTFILE 2>/dev/null || true
# Pipefail intentionally off in this script: we want to silently swallow
# tier-failures and fall through to the next tier.

SERVICE=""
LIST_ONLY=0
while (( $# > 0 )); do
  case "$1" in
    --list-candidates) LIST_ONLY=1; shift ;;
    -*)
      echo "usage: secret_get.sh <service> [--list-candidates]" >&2
      exit 64
      ;;
    *)
      if [[ -n "$SERVICE" ]]; then
        echo "usage: secret_get.sh <service> [--list-candidates]" >&2
        exit 64
      fi
      SERVICE="$1"; shift
      ;;
  esac
done

if [[ -z "$SERVICE" || "$SERVICE" =~ [^a-z0-9-] ]]; then
  echo "usage: secret_get.sh <service>  (lowercase alnum + dash)" >&2
  exit 64
fi

# Tier 1: sidecar short-circuit. The caller detects sidecar mode and exports
# AUTOPILOT_SIDECAR_MODE=1 (see header); consumers in sidecar mode send NO
# Authorization header.
if [[ "${AUTOPILOT_SIDECAR_MODE:-}" == "1" && $LIST_ONLY -eq 0 ]]; then
  exit 0
fi

OS_KIND=""
case "$(uname -s)" in
  Darwin) OS_KIND="macos" ;;
  Linux)  OS_KIND="linux" ;;
  *)      OS_KIND="other" ;;
esac

SERVICE_UP="$(echo "$SERVICE" | tr '[:lower:]-' '[:upper:]_')"
ENV_VAR="AUTOPILOT_${SERVICE_UP}_TOKEN"
OVERRIDE_VAR="AUTOPILOT_${SERVICE_UP}_KEYCHAIN_NAME"
HOST_VAR="${SERVICE_UP}_HOST"

# Derive the repo/service host (best-effort). Prefers $<SERVICE>_HOST, falls
# back to the origin remote URL. Prints the RAW hostname (port stripped).
derive_host_raw() {
  local host=""
  if [[ -n "${!HOST_VAR:-}" ]]; then
    host="${!HOST_VAR}"
    host="${host#*://}"; host="${host%%/*}"; host="${host%%:*}"
  else
    local origin
    origin=$(git remote get-url origin 2>/dev/null || true)
    [[ -n "$origin" ]] || return 1
    if [[ "$origin" =~ https?://([^/]+)/ ]]; then
      host="${BASH_REMATCH[1]}"
    elif [[ "$origin" =~ @([^:/]+)[:/] ]]; then
      host="${BASH_REMATCH[1]}"
    else
      return 1
    fi
    host="${host%%:*}"
  fi
  [[ -n "$host" ]] || return 1
  printf '%s' "$host"
}

# Normalised form used by secret_set.sh --as-host names: lowercase,
# non-alnum -> '-', trimmed.
normalise_host() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/^-*//; s/-*$//'
}

# Build the candidate list in priority order.
declare -a CANDIDATES=()
if [[ -n "${!OVERRIDE_VAR:-}" ]]; then
  CANDIDATES+=("${!OVERRIDE_VAR}")
fi
CANDIDATES+=("autopilot-${SERVICE}")
HOST_RAW=$(derive_host_raw 2>/dev/null || true)
if [[ -n "$HOST_RAW" ]]; then
  HOST_NORM=$(normalise_host "$HOST_RAW")
  [[ -n "$HOST_NORM" ]] && CANDIDATES+=("autopilot-${SERVICE}-${HOST_NORM}")
  CANDIDATES+=("${SERVICE}-token:${HOST_RAW}")
fi
CANDIDATES+=("${SERVICE}-token")
CANDIDATES+=("${SERVICE}")

if (( LIST_ONLY == 1 )); then
  printf '%s\n' "${CANDIDATES[@]}"
  exit 0
fi

# Probe helpers. Each returns 0 with the token on stdout, 1 if not found,
# 3 if the keychain is locked (short-circuits the caller loop).

probe_macos() {
  local name="$1"
  local out rc
  out=$(security find-generic-password -s "$name" -w 2>/dev/null)
  rc=$?
  if [[ -n "$out" ]]; then
    printf '%s' "$out"
    return 0
  fi
  # 36 = keychain locked, 44 = item not found.
  if [[ "$rc" -eq 36 ]]; then
    return 3
  fi
  return 1
}

probe_linux() {
  local name="$1"
  local out
  out=$(secret-tool lookup service "$name" 2>/dev/null) || out=""
  if [[ -n "$out" ]]; then
    printf '%s' "$out"
    return 0
  fi
  return 1
}

# Tier 2: keychain, iterating candidates.
case "$OS_KIND" in
  macos)
    if command -v security >/dev/null 2>&1; then
      for name in "${CANDIDATES[@]}"; do
        [[ -n "$name" ]] || continue
        out=$(probe_macos "$name"); rc=$?
        if (( rc == 0 )); then
          printf '%s' "$out"
          exit 0
        fi
        if (( rc == 3 )); then
          echo "keychain-locked" >&2
          exit 3
        fi
      done
    fi
    ;;
  linux)
    if command -v secret-tool >/dev/null 2>&1; then
      for name in "${CANDIDATES[@]}"; do
        [[ -n "$name" ]] || continue
        out=$(probe_linux "$name"); rc=$?
        if (( rc == 0 )); then
          printf '%s' "$out"
          exit 0
        fi
      done
    fi
    ;;
  *)
    # Windows VDIs in v0 use sidecar mode only.
    echo "unsupported-platform: $(uname -s)" >&2
    exit 4
    ;;
esac

# Tier 3: env var. Dereference indirectly without echoing.
if [[ -n "${!ENV_VAR:-}" ]]; then
  printf '%s' "${!ENV_VAR}"
  exit 0
fi

echo "no-credential-found: service=${SERVICE} candidates=${#CANDIDATES[@]}" >&2
exit 2
