#!/usr/bin/env bash
# repo_shape_probe.sh
#
# G1.5 repo-shape probe (AP-23). Detects trunk name, CI presence, force-push
# permission, and JIRA-hook enforcement by performing minimal probe operations
# against the current origin. Emits KEY=VALUE on stdout, one per line.
#
# Emitted keys:
#   TRUNK=<branch>              detected trunk (default: main; falls back to master)
#   CI_PRESENT=true|false|unknown
#   FORCE_PUSH_ALLOWED=true|false|unknown
#   JIRA_HOOK_ENFORCED=true|false|unknown
#
# Flags:
#   --dry-run    Do not create temp branches or push. Emit `unknown` for every
#                signal that requires a live probe. Useful for CI dry-runs and
#                for verifying the script is wired up before committing to a
#                real probe cycle.
#   --explain    Print (to stderr) the reasoning for each emitted value,
#                including which pattern from repo_shape_probe_patterns.sh
#                matched (if any) and which temp branch was used. Never prints
#                credentials.
#   --no-auto-seed
#                Reserved for future use. Currently accepted and ignored; the
#                dispatcher (not this script) applies auto-seed rules to the
#                runbook.
#   --temp-prefix <p>
#                Prefix for temp branches. Default: `autopilot/probe`.
#
# Temp branches used (created and deleted within the probe):
#   <prefix>-force-push-<PID>
#   <prefix>-jira-hook-<PID>
#
# Cleanup: registered via `trap` on EXIT so the branches are deleted from
# both the local repo and origin even on error paths. Probe never touches
# operator-visible branches.
#
# Auth: routes through bitbucket.sh for API calls; git push/delete uses the
# operator's ambient git auth (SSH key or credential helper). If bitbucket.sh
# is unavailable, the probe still runs but CI_PRESENT falls back to `unknown`.

set -u
set +x

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BITBUCKET="$HERE/bitbucket.sh"

# Source the pattern registry.
# shellcheck disable=SC1091
. "$HERE/repo_shape_probe_patterns.sh"

DRY_RUN=0
EXPLAIN=0
NO_AUTO_SEED=0
TEMP_PREFIX="autopilot/probe"

explain() {
  (( EXPLAIN == 1 )) && echo "probe: $*" >&2 || true
}

die() {
  echo "repo_shape_probe.sh: $*" >&2
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)      DRY_RUN=1; shift ;;
    --explain)      EXPLAIN=1; shift ;;
    --no-auto-seed) NO_AUTO_SEED=1; shift ;;
    --temp-prefix)  TEMP_PREFIX="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,45p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown arg: $1" ;;
  esac
done

# Repo sanity.
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repo"
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
[[ -n "$ORIGIN_URL" ]] || die "no origin remote"

PID=$$
FP_BRANCH="${TEMP_PREFIX}-force-push-${PID}"
JH_BRANCH="${TEMP_PREFIX}-jira-hook-${PID}"

# --- Cleanup trap -------------------------------------------------------------

cleanup() {
  # Best-effort. Never fail the script from cleanup itself.
  local b
  for b in "$FP_BRANCH" "$JH_BRANCH"; do
    # Local delete.
    git branch -D "$b" >/dev/null 2>&1 || true
    # Remote delete.
    git push origin --delete "$b" >/dev/null 2>&1 || true
  done
  # Restore original HEAD if we detached.
  if [[ -n "${_PROBE_ORIG_HEAD:-}" ]]; then
    git checkout -q "$_PROBE_ORIG_HEAD" 2>/dev/null || true
  fi
}
trap cleanup EXIT

_PROBE_ORIG_HEAD="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

# --- Trunk detection ----------------------------------------------------------

detect_trunk() {
  # Prefer origin/HEAD symbolic ref if set.
  local h
  h=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)
  if [[ -n "$h" ]]; then
    printf '%s' "$h"
    return 0
  fi
  # Ask remote directly.
  h=$(git ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/ { sub("refs/heads/","",$2); print $2; exit }')
  if [[ -n "$h" ]]; then
    printf '%s' "$h"
    return 0
  fi
  # Fallback: probe common names.
  for candidate in main master trunk develop; do
    if git ls-remote --exit-code --heads origin "$candidate" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  printf '%s' "main"
  return 0
}

TRUNK="$(detect_trunk)"
explain "TRUNK=$TRUNK (from symbolic-ref/ls-remote/fallback)"

# --- CI presence probe --------------------------------------------------------

detect_ci() {
  if (( DRY_RUN == 1 )); then
    explain "CI_PRESENT=unknown (dry-run)"
    printf 'unknown'
    return 0
  fi
  # Strategy: fetch trunk HEAD sha, then call bitbucket.sh build-status.
  # UNKNOWN response with no historical builds => CI_PRESENT=false.
  # SUCCESSFUL / FAILED / INPROGRESS => CI_PRESENT=true.
  # bitbucket.sh unavailable => unknown.
  if [[ ! -x "$BITBUCKET" ]]; then
    explain "CI_PRESENT=unknown (bitbucket.sh not executable)"
    printf 'unknown'
    return 0
  fi
  local trunk_sha bs
  trunk_sha=$(git ls-remote origin "refs/heads/${TRUNK}" 2>/dev/null | awk '{print $1; exit}')
  if [[ -z "$trunk_sha" ]]; then
    explain "CI_PRESENT=unknown (cannot resolve trunk sha)"
    printf 'unknown'
    return 0
  fi
  bs=$("$BITBUCKET" build-status --sha "$trunk_sha" 2>/dev/null || echo UNKNOWN)
  case "$bs" in
    SUCCESSFUL|FAILED|INPROGRESS)
      explain "CI_PRESENT=true (build-status=$bs on trunk sha=$trunk_sha)"
      printf 'true'
      ;;
    UNKNOWN)
      # Second heuristic: look for well-known CI config files at trunk.
      local ci_files
      ci_files=$(git ls-tree --name-only "origin/${TRUNK}" 2>/dev/null \
        | grep -E '^(bitbucket-pipelines\.yml|Jenkinsfile|\.gitlab-ci\.yml|azure-pipelines\.yml|\.github/workflows|\.drone\.yml)$' || true)
      if [[ -n "$ci_files" ]]; then
        explain "CI_PRESENT=true (config files present: $ci_files)"
        printf 'true'
      else
        explain "CI_PRESENT=false (no build-status, no CI config files)"
        printf 'false'
      fi
      ;;
    *)
      explain "CI_PRESENT=unknown (build-status=$bs)"
      printf 'unknown'
      ;;
  esac
}

CI_PRESENT="$(detect_ci)"

# --- Force-push probe ---------------------------------------------------------

detect_force_push() {
  if (( DRY_RUN == 1 )); then
    explain "FORCE_PUSH_ALLOWED=unknown (dry-run)"
    printf 'unknown'
    return 0
  fi

  local logfile
  logfile=$(mktemp)

  # Create a benign temp branch at trunk, push, then attempt to force-push
  # a rewritten history. Any rejection signals `false`; success signals `true`.
  #
  # We rewrite the branch to an amend of the trunk tip commit (no functional
  # change), then attempt a force-push. This avoids introducing any real
  # diff content while still triggering history-rewrite policies.

  if ! git fetch --quiet origin "$TRUNK" 2>>"$logfile"; then
    explain "FORCE_PUSH_ALLOWED=unknown (cannot fetch trunk)"
    rm -f "$logfile"
    printf 'unknown'
    return 0
  fi

  if ! git branch -f "$FP_BRANCH" "origin/${TRUNK}" 2>>"$logfile"; then
    explain "FORCE_PUSH_ALLOWED=unknown (cannot create temp branch)"
    rm -f "$logfile"
    printf 'unknown'
    return 0
  fi

  # Initial push (fast-forward, no force).
  if ! git push --quiet origin "$FP_BRANCH:$FP_BRANCH" 2>>"$logfile"; then
    # Cannot even push a fresh branch; may indicate strict permissions.
    explain "FORCE_PUSH_ALLOWED=unknown (initial push failed; may be branch-perm-denied)"
    rm -f "$logfile"
    printf 'unknown'
    return 0
  fi

  # Rewrite: amend a trivial commit metadata change locally (no content edit).
  # We use --allow-empty to add an empty commit on top, then rewind and
  # attempt to force-push over the previous tip.
  if ! (
      git checkout --quiet "$FP_BRANCH" &&
      git commit --allow-empty --quiet -m "autopilot probe: empty" &&
      git reset --hard --quiet HEAD~1 &&
      git commit --allow-empty --quiet -m "autopilot probe: rewritten"
  ) 2>>"$logfile"; then
    explain "FORCE_PUSH_ALLOWED=unknown (local rewrite failed)"
    rm -f "$logfile"
    printf 'unknown'
    return 0
  fi

  # Attempt the force-push. Capture stderr for pattern matching.
  if git push --force --quiet origin "$FP_BRANCH:$FP_BRANCH" 2>>"$logfile"; then
    explain "FORCE_PUSH_ALLOWED=true (force-push accepted)"
    rm -f "$logfile"
    printf 'true'
    return 0
  fi

  # Push failed. Match against the rejection pattern registry.
  local signal=""
  if match_rejection "$logfile" signal; then
    case "$signal" in
      FORCE_PUSH_DENIED_BRANCH_PERM|FORCE_PUSH_DENIED_HOOK|FORCE_PUSH_DENIED_PROTECTED)
        explain "FORCE_PUSH_ALLOWED=false (signal=$signal)"
        rm -f "$logfile"
        printf 'false'
        return 0
        ;;
      *)
        explain "FORCE_PUSH_ALLOWED=unknown (unrecognised signal=$signal)"
        rm -f "$logfile"
        printf 'unknown'
        return 0
        ;;
    esac
  fi

  # Failure with no matching pattern: transient network, missing perms on a
  # non-history-rewrite path, etc. Cannot conclude.
  explain "FORCE_PUSH_ALLOWED=unknown (push failed, no pattern match; log head: $(head -c 200 "$logfile" | tr '\n' ' '))"
  rm -f "$logfile"
  printf 'unknown'
}

FORCE_PUSH_ALLOWED="$(detect_force_push)"

# --- JIRA-hook probe ----------------------------------------------------------

detect_jira_hook() {
  if (( DRY_RUN == 1 )); then
    explain "JIRA_HOOK_ENFORCED=unknown (dry-run)"
    printf 'unknown'
    return 0
  fi

  local logfile
  logfile=$(mktemp)

  # Create a temp branch at trunk with a single commit whose message
  # deliberately omits any JIRA key. If the server rejects, the hook is
  # enforced; if it accepts, the hook is not enforced (or is warn-only).

  if ! git branch -f "$JH_BRANCH" "origin/${TRUNK}" 2>>"$logfile"; then
    explain "JIRA_HOOK_ENFORCED=unknown (cannot create temp branch)"
    rm -f "$logfile"
    printf 'unknown'
    return 0
  fi

  if ! (
      git checkout --quiet "$JH_BRANCH" &&
      git commit --allow-empty --quiet -m "autopilot probe: no jira key on purpose"
  ) 2>>"$logfile"; then
    explain "JIRA_HOOK_ENFORCED=unknown (local commit failed)"
    rm -f "$logfile"
    printf 'unknown'
    return 0
  fi

  if git push --quiet origin "$JH_BRANCH:$JH_BRANCH" 2>>"$logfile"; then
    explain "JIRA_HOOK_ENFORCED=false (push without JIRA key accepted)"
    rm -f "$logfile"
    printf 'false'
    return 0
  fi

  local signal=""
  if match_rejection "$logfile" signal; then
    case "$signal" in
      JIRA_HOOK_MISSING_KEY|JIRA_HOOK_INVALID_KEY)
        explain "JIRA_HOOK_ENFORCED=true (signal=$signal)"
        rm -f "$logfile"
        printf 'true'
        return 0
        ;;
      *)
        explain "JIRA_HOOK_ENFORCED=unknown (unrelated signal=$signal)"
        rm -f "$logfile"
        printf 'unknown'
        return 0
        ;;
    esac
  fi

  explain "JIRA_HOOK_ENFORCED=unknown (push rejected, no JIRA pattern match)"
  rm -f "$logfile"
  printf 'unknown'
}

JIRA_HOOK_ENFORCED="$(detect_jira_hook)"

# --- Emit ---------------------------------------------------------------------

printf 'TRUNK=%s\n' "$TRUNK"
printf 'CI_PRESENT=%s\n' "$CI_PRESENT"
printf 'FORCE_PUSH_ALLOWED=%s\n' "$FORCE_PUSH_ALLOWED"
printf 'JIRA_HOOK_ENFORCED=%s\n' "$JIRA_HOOK_ENFORCED"

exit 0
