#!/usr/bin/env bash
# repo_shape_probe_patterns.sh
#
# Regex registry sourced by repo_shape_probe.sh (G1.5, AP-23).
#
# This file is NOT executed directly. It defines the REJECTION_PATTERNS array
# and the `match_rejection` helper function. The probe script sources this
# file at startup so pattern maintenance is decoupled from probe logic.
#
# Format: each entry is `<extended-regex>|<signal-name>`. The SIGNAL is the
# text after the LAST `|` in the entry; everything before it is the regex.
# Regexes may therefore contain `|` alternations freely, but signal names must
# never contain `|`. (v2.4.0 — GAPS A2: the previous parser split on the FIRST
# pipe, truncating every alternation-bearing regex into an unbalanced pattern
# that grep silently errored on; 5 of 6 realistic Bitbucket DC rejection
# strings failed to match.)
#
# The regex is matched with `grep -Eqi` against captured push-reject stderr.
# On match, the signal name is written to the caller-supplied output variable
# and the helper returns 0. On no match, the helper returns 1 and does not
# touch the variable; the PROBE then emits the corpus-growth message
#   probe: unknown rejection pattern; please add to repo_shape_probe_patterns.sh: <raw>
# on stderr (always-on, not --explain-gated) so unrecognized server strings
# become candidate new rows.
#
# Adding a new pattern:
#   1. Append `<extended-regex>|<signal-name>` to REJECTION_PATTERNS below,
#      with a comment citing an observed example message.
#   2. Register the signal name in repo_shape_probe.sh's dispatch switch.
#   3. Add a CHANGELOG entry citing the self_test.sh assertion that covers it
#      (T08 is table-driven; add the example message there).

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_PROBE_PATTERNS_LOADED:-}" ]] && return 0 || true
_AUTOPILOT_PROBE_PATTERNS_LOADED=1

# Signal names emitted by this registry. Keep in sync with the dispatch table
# in repo_shape_probe.sh; unrecognised signals are treated as `unknown`.
#
# Force-push signals:
#   FORCE_PUSH_DENIED_BRANCH_PERM   Bitbucket DC branch permissions blocked it
#   FORCE_PUSH_DENIED_HOOK          Server-side hook rejected the update
#   FORCE_PUSH_DENIED_PROTECTED     Generic "protected branch" / denyNonFastForwards rejection
#
# JIRA hook signals:
#   JIRA_HOOK_MISSING_KEY           Commit message lacked required JIRA key
#   JIRA_HOOK_INVALID_KEY           Commit message had a JIRA key but rejected
#
# RESERVED (defined for side-band parsing; not currently dispatched by the
# probe — detect_ci uses build-status + manifest presence instead):
#   CI_PIPELINE_NOT_CONFIGURED      Explicit "no pipeline" response
#   CI_PIPELINE_TRIGGERED           Explicit build-triggered acknowledgement

declare -a REJECTION_PATTERNS=(
  # --- Force-push (branch permissions) ---
  # e.g. "You are not permitted to force-push to this branch"
  "you are not permitted to (force[- ]push|rewrite history)|FORCE_PUSH_DENIED_BRANCH_PERM"
  # e.g. "protected branch hook declined"
  "protected branch hook declined|FORCE_PUSH_DENIED_BRANCH_PERM"
  # e.g. "branch permissions deny the force-push"
  "branch permissions? (denied|deny|forbid|prevent).*(force|rewrite)|FORCE_PUSH_DENIED_BRANCH_PERM"
  # e.g. "! [remote rejected] b -> b (non-fast-forward)" / denyNonFastForwards
  "rejected.*non[- ]fast[- ]forward|FORCE_PUSH_DENIED_PROTECTED"
  # e.g. "denying non-fast-forward refs/heads/x (you should pull first)"
  "denying non[- ]fast[- ]forward|FORCE_PUSH_DENIED_PROTECTED"
  # e.g. "cannot force-push to protected branch"
  "cannot force[- ]push to protected branch|FORCE_PUSH_DENIED_PROTECTED"

  # --- Force-push (server hook) ---
  # e.g. "hook declined: force-push rejected"
  "hook declined.*(force|rewrite|non-fast-forward)|FORCE_PUSH_DENIED_HOOK"
  # e.g. "pre-receive hook declined: history rewrite not allowed"
  "pre-receive hook declined.*history|FORCE_PUSH_DENIED_HOOK"
  # e.g. "server-side hook rejected the force-push"
  "server-side hook rejected .*force[- ]?push|FORCE_PUSH_DENIED_HOOK"

  # --- JIRA hook (missing key) ---
  # e.g. "commit message must contain a valid JIRA issue key"
  "commit message (must|does not) (contain|include) (a )?(valid )?jira (issue )?key|JIRA_HOOK_MISSING_KEY"
  # e.g. "no JIRA issue found in commit message"
  "no jira (issue|key) (found|referenced) in commit message|JIRA_HOOK_MISSING_KEY"
  # e.g. YACC plugin: "yacc: JIRA key missing in commit"
  "yacc.*jira.*key.*missing|JIRA_HOOK_MISSING_KEY"

  # --- JIRA hook (invalid key) ---
  # e.g. "JIRA issue ABC-1 is closed"
  "jira (issue|key) .* (is closed|does not exist|is invalid)|JIRA_HOOK_INVALID_KEY"
  # e.g. "JIRA issue ABC-1 not found in project ABC"
  "jira issue .* not found in project|JIRA_HOOK_INVALID_KEY"

  # --- CI (reserved; see note above) ---
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
  # Locals are _mr_-prefixed: `printf -v` writes into the CALLER's variable
  # via dynamic scoping, so any local here sharing the caller's outvar name
  # (e.g. `signal`) would shadow it and the caller would read an empty
  # string. (Found by self_test T08/T09 — the probe passes outvar `signal`.)
  local _mr_logfile="$1"
  local _mr_outvar="$2"
  [[ -f "$_mr_logfile" ]] || return 1
  local _mr_entry _mr_regex _mr_signal
  for _mr_entry in "${REJECTION_PATTERNS[@]}"; do
    # Signal = after the LAST pipe; regex = everything before it, so regexes
    # may contain alternations. (GAPS A2)
    _mr_regex="${_mr_entry%|*}"
    _mr_signal="${_mr_entry##*|}"
    if grep -Eqi -- "$_mr_regex" "$_mr_logfile" 2>/dev/null; then
      printf -v "$_mr_outvar" '%s' "$_mr_signal"
      return 0
    fi
  done
  return 1
}
