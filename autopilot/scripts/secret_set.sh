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
#                only when you understand you may be overwriting (or
#                shadowing) a keychain entry that another tool or another
#                operator populated.
#
# Hard rules:
#   - Token NEVER on argv.
#   - Token NEVER echoed back.
#   - On macOS: stored via `security add-generic-password -U` (update if exists).
#   - On Linux: stored via `secret-tool store`.
#   - Windows VDIs: not supported; operator uses sidecar mode.
#
# Operator-owned credential detection (v2.4.0 — GAPS B3; the v2.2.0 changelog
# claimed cross-candidate probing but only the exact target name was checked):
#   Before writing, secret_set.sh probes EVERY candidate name in
#   secret_get.sh's resolver chain (via `secret_get.sh <service>
#   --list-candidates`):
#   - The TARGET name: if an entry exists and its metadata does not match the
#     autopilot-managed pattern (`autopilot ${SERVICE}` label + owner attribute
#     on Linux, `$USER` account + `autopilot-managed` comment on macOS), abort
#     with exit 5 — you would overwrite a foreign credential.
#   - Every OTHER candidate: if a non-empty entry exists, abort with exit 5 —
#     writing the autopilot-namespaced copy would create a silent two-copy
#     state where the resolver may pick a different token than the one you
#     just stored (which of the two wins depends on candidate order).
#   `--force` bypasses both aborts.

set -u
set +x
unset HISTFILE 2>/dev/null || true

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# $USER is not guaranteed (containers/CI under set -u): fall back to id.
# Without this, the storage pipeline's printf died on the unbound expansion
# and `security -i` saw EOF — the script reported success while storing
# nothing (caught by self_test T30).
RUN_USER="${USER:-$(id -un)}"

die() { echo "secret_set.sh: $*" >&2; exit 1; }

SERVICE=""
AS_HOST=0
FORCE=0

while (( $# > 0 )); do
  case "$1" in
    --as-host) AS_HOST=1; shift ;;
    --force)   FORCE=1;   shift ;;
    -h|--help)
      cat <<EOF
usage: secret_set.sh <service> [--as-host] [--force]
  service: lowercase alnum + dash, e.g. bitbucket
  --as-host: scope keychain name to current git origin host
  --force:   bypass operator-owned credential detection
  token is read from STDIN, never from argv
EOF
      exit 0
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

# Existence probe for an arbitrary keychain service name. Returns 0 when a
# non-empty entry exists, 1 otherwise. Never prints the secret.
entry_exists() {
  local name="$1"
  case "$(uname -s)" in
    Darwin)
      command -v security >/dev/null 2>&1 || return 1
      [[ -n "$(security find-generic-password -s "$name" -w 2>/dev/null)" ]]
      ;;
    Linux)
      command -v secret-tool >/dev/null 2>&1 || return 1
      [[ -n "$(secret-tool lookup service "$name" 2>/dev/null)" ]]
      ;;
    *) return 1 ;;
  esac
}

# Operator-owned credential detection on the TARGET name: if it exists and
# does not look autopilot-managed, refuse to overwrite unless --force.
probe_ownership() {
  case "$(uname -s)" in
    Darwin)
      command -v security >/dev/null 2>&1 || return 0
      # Existence check FIRST, by exit code (44 = item not found). The
      # previous implementation parsed the -g stderr and treated the
      # "could not be found" message as an existing entry — every
      # first-ever secret_set on macOS aborted with exit 5. It also
      # fetched the stored password (-g prints it) just to read metadata;
      # the attribute dump (no -g) carries acct/icmt without the secret.
      local attrs rc
      attrs=$(security find-generic-password -s "$KEY_NAME" 2>/dev/null); rc=$?
      if (( rc != 0 )); then
        return 0  # no existing (readable) entry — nothing to guard
      fi
      local acct icmt
      acct=$(echo "$attrs" | awk -F'"' '/"acct"/ {print $4; exit}')
      icmt=$(echo "$attrs" | awk -F'"' '/"icmt"/ {print $4; exit}')
      # Autopilot-managed if account matches the invoking user AND comment includes marker.
      if [[ "$acct" == "$RUN_USER" && "$icmt" == *"autopilot-managed"* ]]; then
        return 0
      fi
      echo "operator-owned credential detected at ${KEY_NAME} (acct=${acct:-unknown})" >&2
      return 5
      ;;
    Linux)
      command -v secret-tool >/dev/null 2>&1 || return 0
      if secret-tool lookup service "$KEY_NAME" >/dev/null 2>&1; then
        # Autopilot always stores with `owner=autopilot`; probe for it.
        local marker
        marker=$(secret-tool search --unlock service "$KEY_NAME" 2>/dev/null | awk -F' = ' '/^attribute\.owner/ {print $2; exit}')
        if [[ "$marker" == "autopilot" ]]; then
          return 0
        fi
        echo "operator-owned credential detected at ${KEY_NAME} (no autopilot owner marker)" >&2
        return 5
      fi
      return 0
      ;;
  esac
  return 0
}

# Cross-candidate collision probe (GAPS B3): abort when any OTHER resolver
# candidate already has a non-empty entry — prevents the silent two-copy
# state (e.g. operator has `bitbucket-token:cluster03`, then runs
# `secret_set.sh bitbucket` and ends up with both).
probe_candidates() {
  local rc=0 name
  while IFS= read -r name; do
    [[ -n "$name" && "$name" != "$KEY_NAME" ]] || continue
    if entry_exists "$name"; then
      echo "operator-owned credential detected at ${name}" >&2
      rc=5
    fi
  done < <("$HERE/secret_get.sh" "$SERVICE" --list-candidates 2>/dev/null || true)
  return $rc
}

if (( FORCE == 0 )); then
  probe_ownership; rc=$?
  if (( rc != 5 )); then
    probe_candidates; rc=$?
  fi
  if (( rc == 5 )); then
    echo "hint: pass --force to write anyway; you may be clobbering or shadowing a personal or team credential" >&2
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
    # -U: update if exists. We use the invoking user as account and stamp
    # `autopilot-managed` in the comment so probe_ownership can detect us
    # on the next --force-less run.
    #
    # The command is fed to `security -i` on STDIN — passing the token as
    # a `-w` argv value would expose it in the process table while
    # `security` runs, violating "Token NEVER on argv". Backslashes and
    # double quotes in the token are escaped for security's line parser.
    TOK_ESC=${TOKEN//\\/\\\\}
    TOK_ESC=${TOK_ESC//\"/\\\"}
    if ! printf 'add-generic-password -U -s "%s" -a "%s" -j "autopilot-managed" -w "%s"\n' \
        "$KEY_NAME" "$RUN_USER" "$TOK_ESC" | security -i >/dev/null 2>&1; then
      echo "keychain-store-failed" >&2
      unset TOKEN TOK_ESC
      exit 1
    fi
    unset TOK_ESC
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
