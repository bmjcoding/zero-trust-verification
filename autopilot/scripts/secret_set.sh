#!/usr/bin/env bash
# secret_set.sh
#
# One-time interactive setup that stores a credential in the OS keychain.
# Reads the token from STDIN (NOT from argv) so it never appears in shell
# history, process listings, or trace output.
#
# Usage:
#   echo -n "<token>" | secret_set.sh <service> [--as-host] [--force]
#   # or:
#   secret_set.sh <service>              # prompts on TTY with hidden input
#
# Flags (v2.3.0, AP-23):
#   --as-host    Append the current git origin host to the keychain service
#                name so the entry is scoped to this repo host. The stored
#                name becomes `autopilot-<service>-<host-suffix>`, matching
#                candidate #3 in secret_get.sh's resolver. Requires being
#                inside a git repo with an `origin` remote.
#   --force      Bypass the "operator-owned credential detected" abort. Use
#                only when you understand you may be overwriting a keychain
#                entry that another tool or another operator populated.
#
# Hard rules:
#   - Token NEVER on argv.
#   - Token NEVER echoed back.
#   - On macOS: stored via `security add-generic-password -U` (update if exists).
#   - On Linux: stored via `secret-tool store`.
#   - Windows VDIs: not supported; operator uses sidecar mode.
#
# Operator-owned credential detection (v2.3.0):
#   Before writing, secret_set.sh probes the target service name in the
#   keychain. If an entry already exists AND its account/label does not match
#   the expected autopilot-owned pattern (`autopilot ${SERVICE}` label on
#   Linux, `$USER` account on macOS with a comment that includes the string
#   `autopilot-managed`), the script aborts with exit 5 unless `--force` is
#   passed. This prevents autopilot from silently overwriting personal or
#   team-shared credentials that happen to share a name.

set -u
set +x
unset HISTFILE 2>/dev/null || true

die() { echo "secret_set.sh: $*" >&2; exit 1; }

SERVICE=""
AS_HOST=0
FORCE=0

while (( $# > 0 )); do
  case "$1" in
    --as-host) AS_HOST=1; shift ;;
    --force)   FORCE=1;   shift ;;
    -h|--help)
      cat >&2 <<EOF
usage: secret_set.sh <service> [--as-host] [--force]
  service: lowercase alnum + dash, e.g. bitbucket
  --as-host: scope keychain name to current git origin host
  --force:   bypass operator-owned credential detection
  token is read from STDIN, never from argv
EOF
      exit 64
      ;;
    -*) die "unknown flag: $1" ;;
    *)
      if [[ -n "$SERVICE" ]]; then
        die "unexpected positional arg: $1"
      fi
      SERVICE="$1"; shift
      ;;
  esac
done

if [[ -z "$SERVICE" || "$SERVICE" =~ [^a-z0-9-] ]]; then
  echo "usage: secret_set.sh <service> [--as-host] [--force]  (lowercase alnum + dash)" >&2
  echo "       token is read from STDIN, never from argv" >&2
  exit 64
fi

KEY_NAME="autopilot-${SERVICE}"

# --as-host: derive host suffix from git origin.
if (( AS_HOST == 1 )); then
  origin=$(git remote get-url origin 2>/dev/null || true)
  [[ -n "$origin" ]] || die "--as-host requires a git repo with an origin remote"
  host=""
  if [[ "$origin" =~ https?://([^/]+)/ ]]; then
    host="${BASH_REMATCH[1]}"
  elif [[ "$origin" =~ @([^:/]+)[:/] ]]; then
    host="${BASH_REMATCH[1]}"
  fi
  [[ -n "$host" ]] || die "--as-host: cannot parse host from origin URL"
  host=$(echo "$host" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/^-*//; s/-*$//')
  [[ -n "$host" ]] || die "--as-host: normalised host is empty"
  KEY_NAME="autopilot-${SERVICE}-${host}"
fi

# Operator-owned credential detection.
# Probe the target name; if it exists and does not look autopilot-managed,
# refuse to overwrite unless --force.
probe_ownership() {
  case "$(uname -s)" in
    Darwin)
      command -v security >/dev/null 2>&1 || return 0
      # Query with -g so we get metadata including comment/account.
      local meta
      meta=$(security find-generic-password -s "$KEY_NAME" -g 2>&1 >/dev/null || true)
      # `security -g` prints the password on stderr in a specific format.
      # We only need to check for existence + metadata; extract acct and icmt.
      if [[ -z "$meta" ]]; then
        return 0  # no existing entry
      fi
      local acct icmt
      acct=$(echo "$meta" | awk -F'"' '/"acct"/ {print $4; exit}')
      icmt=$(echo "$meta" | awk -F'"' '/"icmt"/ {print $4; exit}')
      # Autopilot-managed if account matches $USER AND comment includes marker.
      if [[ "$acct" == "$USER" && "$icmt" == *"autopilot-managed"* ]]; then
        return 0
      fi
      echo "operator-owned-credential-detected: service=${KEY_NAME} acct=${acct:-unknown}" >&2
      return 5
      ;;
    Linux)
      command -v secret-tool >/dev/null 2>&1 || return 0
      # Existence check via lookup; no metadata API on secret-tool.
      if secret-tool lookup service "$KEY_NAME" >/dev/null 2>&1; then
        # We can't reliably distinguish autopilot-managed from operator-owned
        # on Linux without a distinct attribute. Use a marker attribute:
        # autopilot always stores with `owner=autopilot`; probe for it.
        local marker
        marker=$(secret-tool search --unlock service "$KEY_NAME" 2>/dev/null | awk -F' = ' '/^attribute\.owner/ {print $2; exit}')
        if [[ "$marker" == "autopilot" ]]; then
          return 0
        fi
        echo "operator-owned-credential-detected: service=${KEY_NAME} (no autopilot owner marker)" >&2
        return 5
      fi
      return 0
      ;;
  esac
  return 0
}

if (( FORCE == 0 )); then
  probe_ownership; rc=$?
  if (( rc == 5 )); then
    echo "hint: pass --force to overwrite anyway; you may be clobbering a personal or team credential" >&2
    exit 5
  fi
fi

# Read token. If STDIN is a TTY, prompt with hidden input.
if [[ -t 0 ]]; then
  printf 'Token for service=%s (input hidden): ' "$KEY_NAME" >&2
  IFS= read -rs TOKEN
  echo >&2
else
  IFS= read -r TOKEN
fi

if [[ -z "${TOKEN:-}" ]]; then
  echo "empty-token: refusing to store" >&2
  exit 65
fi

case "$(uname -s)" in
  Darwin)
    if ! command -v security >/dev/null 2>&1; then
      echo "macos-security-cli-missing" >&2
      unset TOKEN
      exit 4
    fi
    # -U: update if exists. We use $USER as account and stamp
    # `autopilot-managed` in the comment so probe_ownership can detect us
    # on the next --force-less run.
    if ! security add-generic-password \
        -U \
        -s "$KEY_NAME" \
        -a "$USER" \
        -j "autopilot-managed" \
        -w "$TOKEN" >/dev/null 2>&1; then
      echo "keychain-store-failed" >&2
      unset TOKEN
      exit 1
    fi
    ;;
  Linux)
    if ! command -v secret-tool >/dev/null 2>&1; then
      echo "linux-secret-tool-missing: install libsecret-tools" >&2
      unset TOKEN
      exit 4
    fi
    # Store an owner=autopilot attribute so probe_ownership can tell us apart
    # from operator-populated entries on subsequent runs.
    if ! printf '%s' "$TOKEN" | secret-tool store \
        --label="autopilot ${SERVICE}" \
        service "$KEY_NAME" \
        owner "autopilot"; then
      echo "secret-tool-store-failed" >&2
      unset TOKEN
      exit 1
    fi
    ;;
  *)
    echo "unsupported-platform: $(uname -s); use sidecar mode" >&2
    unset TOKEN
    exit 4
    ;;
esac

unset TOKEN
echo "stored: service=${KEY_NAME}" >&2
exit 0
