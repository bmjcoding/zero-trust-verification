#!/usr/bin/env bash
# repo_shape_probe_patterns.sh
#
# Regex registry sourced by repo_shape_probe.sh (G1.5, AP-23).
#
# This file is NOT executed directly. It defines the REJECTION_PATTERNS array
# and the `match_rejection` helper function. The probe script sources this
# file at startup so pattern maintenance is decoupled from probe logic.
#
# Format: each entry is `<extended-regex>|<signal-name>`. The regex is matched
# with `grep -Eqi` against captured push-reject stderr. On match, the signal
# name is emitted to the caller-supplied output variable, and the helper
# returns 0. On no match, the helper returns 1 and does not touch the variable.
#
# Adding a new pattern:
#   1. Append `<extended-regex>|<signal-name>` to REJECTION_PATTERNS below.
#   2. Register the signal name in repo_shape_probe.sh's dispatch switch.
#   3. Add a CHANGELOG entry and bump the probe minor version.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_PROBE_PATTERNS_LOADED:-}" ]] && return 0 || true
_AUTOPILOT_PROBE_PATTERNS_LOADED=1

# Signal names emitted by this registry. Keep in sync with the dispatch table
# in repo_shape_probe.sh; unrecognised signals are treated as `unknown`.
#
# Force-push signals:
#   FORCE_PUSH_DENIED_BRANCH_PERM   Bitbucket DC branch permissions blocked it
#   FORCE_PUSH_DENIED_HOOK          Server-side hook rejected the update
#   FORCE_PUSH_DENIED_PROTECTED     Generic "protected branch" rejection
#
# JIRA hook signals:
#   JIRA_HOOK_MISSING_KEY           Commit message lacked required JIRA key
#   JIRA_HOOK_INVALID_KEY           Commit message had a JIRA key but rejected
#
# CI signals (matched against push side-band messages or webhook responses):
#   CI_PIPELINE_NOT_CONFIGURED      Explicit "no pipeline" response
#   CI_PIPELINE_TRIGGERED           Explicit build-triggered acknowledgement

declare -a REJECTION_PATTERNS=(
  # --- Force-push (branch permissions) ---
  "you are not permitted to (force[- ]push|rewrite history)|FORCE_PUSH_DENIED_BRANCH_PERM"
  "protected branch hook declined|FORCE_PUSH_DENIED_BRANCH_PERM"
  "branch permissions? (denied|forbid|prevent).*(force|rewrite)|FORCE_PUSH_DENIED_BRANCH_PERM"
  "rejected.*non[- ]fast[- ]forward|FORCE_PUSH_DENIED_PROTECTED"
  "cannot force[- ]push to protected branch|FORCE_PUSH_DENIED_PROTECTED"

  # --- Force-push (server hook) ---
  "hook declined.*(force|rewrite|non-fast-forward)|FORCE_PUSH_DENIED_HOOK"
  "pre-receive hook declined.*history|FORCE_PUSH_DENIED_HOOK"
  "server-side hook rejected .*force[- ]?push|FORCE_PUSH_DENIED_HOOK"

  # --- JIRA hook (missing key) ---
  "commit message (must|does not) (contain|include) (a )?(valid )?jira (issue )?key|JIRA_HOOK_MISSING_KEY"
  "no jira (issue|key) (found|referenced) in commit message|JIRA_HOOK_MISSING_KEY"
  "yaccc.*jira.*key.*missing|JIRA_HOOK_MISSING_KEY"

  # --- JIRA hook (invalid key) ---
  "jira (issue|key) .* (is closed|does not exist|is invalid)|JIRA_HOOK_INVALID_KEY"
  "jira issue .* not found in project|JIRA_HOOK_INVALID_KEY"

  # --- CI ---
  "no build (pipeline|configuration) (defined|found) for (this repo|this branch)|CI_PIPELINE_NOT_CONFIGURED"
  "build (triggered|queued|started).*build-?id|CI_PIPELINE_TRIGGERED"
)

# match_rejection <logfile> <outvar>
#
# Scans <logfile> for the first pattern in REJECTION_PATTERNS that matches.
# On match: sets <outvar> to the corresponding signal name and returns 0.
# On no match: returns 1 without modifying <outvar>.
#
# Usage:
#   local signal=""
#   if match_rejection "$LOG" signal; then
#     handle_signal "$signal"
#   fi
match_rejection() {
  local logfile="$1"
  local outvar="$2"
  [[ -f "$logfile" ]] || return 1
  local entry regex signal
  for entry in "${REJECTION_PATTERNS[@]}"; do
    regex="${entry%%|*}"
    signal="${entry##*|}"
    if grep -Eqi -- "$regex" "$logfile" 2>/dev/null; then
      # shellcheck disable=SC2086
      printf -v "$outvar" '%s' "$signal"
      return 0
    fi
  done
  return 1
}
