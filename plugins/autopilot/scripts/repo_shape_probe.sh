#!/usr/bin/env bash
# repo_shape_probe.sh
#
# G1.5 repo-shape probe (AP-23). Detects trunk name, CI presence, force-push
# permission, and JIRA-hook enforcement by performing minimal probe operations
# against the current origin. Emits KEY=VALUE on stdout, one per line, and
# NOTHING else on stdout (v2.4.0 — GAPS A4: git output leaking into the
# captured values previously corrupted the KEY=VALUE contract).
#
# Emitted keys:
#   TRUNK=<branch>              detected trunk (default: main; falls back to master)
#   CI_PRESENT=true|false|unknown
#   CI_STATUS_REPORTING=true|false|unknown
#       Does the CI that runs actually REPORT to the host build-status API?
#       Sampled over recent trunk commits (not just the tip). `false` means CI
#       config exists but the endpoint never populates — a `ci.skip_wait: false`
#       runbook would poll a void forever, so the dispatcher auto-seeds
#       `ci.skip_wait: true` on CI_PRESENT=true + CI_STATUS_REPORTING=false
#       (degrade the CI gate honestly instead of pretending it is enforceable).
#       `unknown` (no CI, backend unavailable, dry-run) never auto-flips.
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
#   --show-patterns
#                Print the current pattern registry on stdout and exit 0.
#                No network, no git state.
#   --no-auto-seed
#                Reserved for the dispatcher: accepted and ignored here; the
#                dispatcher (not this script) applies auto-seed rules to the
#                runbook.
#   --jira-key <KEY>
#                Prefix probe commit subjects with `[<KEY>] ` so the
#                force-push probe is not rejected by JIRA-enforcing
#                pre-receive hooks before it can test the rewrite. Without
#                it, on such repos the force-push probe reports `unknown`
#                (and the JIRA probe concludes `true` from that rejection).
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
# Force-push probe method (v2.4.0 — GAPS A3): push trunk-tip+A to the temp
# branch, then rewrite the branch to the DIVERGENT sibling trunk-tip+B and
# force-push. The previous implementation force-pushed a fast-forward (which
# every server accepts), so it could never observe a denial and
# `branching.no_force_push` was never auto-set.
#
# Unknown rejections: whenever a push is rejected and no registry pattern
# matches, the probe emits (always-on, stderr):
#   probe: unknown rejection pattern; please add to repo_shape_probe_patterns.sh: <raw>
# This is the corpus-growth seam promised in the v2.3.0 changelog (GAPS B4).
#
# Auth: routes through bitbucket.sh for API calls; git push/delete uses the
# operator's ambient git auth (SSH key or credential helper). If bitbucket.sh
# is unavailable, the probe still runs and CI presence falls back to manifest
# inspection.

set -u
set +x

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# AUTOPILOT_PROBE_BITBUCKET: dependency-injection seam (self-test stubs the
# backend to exercise the build-status sampling paths hermetically; same
# pattern as the gh argv shim). Defaults to the real DC backend.
BITBUCKET="${AUTOPILOT_PROBE_BITBUCKET:-$HERE/bitbucket.sh}"

# Source the pattern registry.
# shellcheck disable=SC1091
. "$HERE/repo_shape_probe_patterns.sh"

DRY_RUN=0
EXPLAIN=0
NO_AUTO_SEED=0
TEMP_PREFIX="autopilot/probe"
PROBE_JIRA_KEY=""     # --jira-key: prefix probe commit subjects so the
                      # force-push probe survives JIRA-enforcing servers
FP_JIRA_BLOCKED=0     # set when the FP probe's initial push was rejected by
                      # a JIRA-hook signal; lets the JIRA probe conclude
                      # without a second rejected push

explain() {
  (( EXPLAIN == 1 )) && echo "probe: $*" >&2 || true
}

die() {
  echo "repo_shape_probe.sh: $*" >&2
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --explain)       EXPLAIN=1; shift ;;
    --show-patterns) printf '%s\n' "${REJECTION_PATTERNS[@]}"; exit 0 ;;
    --no-auto-seed)  NO_AUTO_SEED=1; shift ;;
    --jira-key)      PROBE_JIRA_KEY="$2"; shift 2 ;;
    --temp-prefix)   TEMP_PREFIX="$2"; shift 2 ;;
    -h|--help)
      # Print the header comment block (everything up to the first
      # non-comment, non-shebang line), robust to header length drift.
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
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
  # Under --dry-run nothing was created and NO remote operation may run.
  (( DRY_RUN == 1 )) && return 0
  # Restore original HEAD first (a temp branch cannot be deleted while
  # checked out).
  if [[ -n "${_PROBE_ORIG_HEAD:-}" ]]; then
    git checkout -q "$_PROBE_ORIG_HEAD" >/dev/null 2>&1 || true
  fi
  local b
  for b in "$FP_BRANCH" "$JH_BRANCH"; do
    # Local delete.
    git branch -D "$b" >/dev/null 2>&1 || true
    # Remote delete.
    git push origin --delete "$b" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT INT TERM

# --dry-run plan: print (to STDERR — stdout stays KEY=VALUE-pure) every
# operation a live probe would perform and the temp branch names.
if (( DRY_RUN == 1 )); then
  {
    echo "probe[dry-run]: would fetch origin <trunk>"
    echo "probe[dry-run]: would create + push temp branch $FP_BRANCH (commit A), rewrite to divergent commit B, force-push, then delete local+remote"
    echo "probe[dry-run]: would create + push temp branch $JH_BRANCH (one commit without a JIRA key), then delete local+remote"
    echo "probe[dry-run]: would sample the host build-status API over recent trunk commits (CI presence + status-reporting)"
    echo "probe[dry-run]: no network or git-state operation is performed in this mode"
  } >&2
fi

_PROBE_ORIG_HEAD="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

# Emit the always-on corpus-growth message for an unmatched rejection. (GAPS B4)
# Credentialed URLs are redacted: git error text can embed the origin URL,
# and `https://user:token@host/...` must never reach the orchestrator context.
report_unknown_rejection() {
  local logfile="$1"
  echo "probe: unknown rejection pattern; please add to repo_shape_probe_patterns.sh: $(tr '\n' ' ' < "$logfile" | sed -E 's#(https?://)[^/@[:space:]]+@#\1[redacted]@#g' | head -c 500)" >&2
}

# --- Trunk detection ----------------------------------------------------------

detect_trunk() {
  # Prefer origin/HEAD symbolic ref if set (local, no network).
  local h
  h=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)
  if [[ -n "$h" ]]; then
    printf '%s' "$h"
    return 0
  fi
  # Under --dry-run stop here: the remaining strategies are remote calls.
  if (( DRY_RUN == 1 )); then
    printf '%s' "main"
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

# --- Build-status sampling (feeds the CI presence + reporting probes) ---------
# BS_SAMPLE classifies the host build-status API over recent trunk commits:
#   definite     — at least one sampled commit returned SUCCESSFUL|FAILED|INPROGRESS
#   silent       — every sampled commit returned UNKNOWN: the endpoint is reachable
#                  but never populated (CI may run — e.g. an external pipeline —
#                  without ever posting to the host build-status API)
#   unavailable  — backend missing/unusable, trunk sha unresolvable, or --dry-run
# The sample deliberately goes BEYOND the tip: the tip's build may simply not
# have reported yet, and one commit is too small a base to declare an endpoint
# silent.
sample_build_status() {
  if (( DRY_RUN == 1 )); then printf 'unavailable'; return 0; fi
  [[ -x "$BITBUCKET" ]] || { printf 'unavailable'; return 0; }
  local trunk_sha shas sha bs rc
  trunk_sha=$(git ls-remote origin "refs/heads/${TRUNK}" 2>/dev/null | awk '{print $1; exit}')
  [[ -n "$trunk_sha" ]] || { printf 'unavailable'; return 0; }
  if ! git rev-parse --verify -q "origin/${TRUNK}" >/dev/null 2>&1; then
    git fetch --quiet origin "$TRUNK" >/dev/null 2>&1 || true
  fi
  shas=$(git rev-list "origin/${TRUNK}" -5 2>/dev/null || true)
  [[ -n "$shas" ]] || shas="$trunk_sha"
  for sha in $shas; do
    bs=$("$BITBUCKET" build-status --sha "$sha" 2>/dev/null); rc=$?
    # Backend error (auth, origin-parse, transport) is UNAVAILABLE, never
    # SILENT — only a successful read of an empty status set counts as silence.
    if (( rc != 0 )); then printf 'unavailable'; return 0; fi
    case "$bs" in SUCCESSFUL|FAILED|INPROGRESS) printf 'definite'; return 0 ;; esac
  done
  printf 'silent'
}

# --- CI presence probe --------------------------------------------------------

detect_ci() {
  if (( DRY_RUN == 1 )); then
    explain "CI_PRESENT=unknown (dry-run)"
    printf 'unknown'
    return 0
  fi
  # Strategy: a definite build-status sample proves CI. Otherwise fall through
  # to the manifest check (backend unavailable or endpoint silent).
  if [[ "$BS_SAMPLE" == "definite" ]]; then
    explain "CI_PRESENT=true (definite build-status on a recent trunk commit)"
    printf 'true'
    return 0
  fi
  # Second heuristic: look for well-known CI config files at trunk.
  # v2.4.0 (GAPS A10): recursive listing — the previous non-recursive ls-tree
  # showed `.github`, never `.github/workflows/...`, so GitHub-workflow
  # manifests were undetectable.
  if ! git rev-parse --verify -q "origin/${TRUNK}" >/dev/null 2>&1; then
    git fetch --quiet origin "$TRUNK" >/dev/null 2>&1 || true
  fi
  local ci_files
  ci_files=$(git ls-tree -r --name-only "origin/${TRUNK}" 2>/dev/null \
    | grep -E '^(bitbucket-pipelines\.yml|Jenkinsfile|\.gitlab-ci\.yml|azure-pipelines\.yml|\.drone\.yml|\.github/workflows/[^/]+\.ya?ml)$' || true)
  if [[ -n "$ci_files" ]]; then
    explain "CI_PRESENT=true (config files present: $(tr '\n' ' ' <<<"$ci_files"))"
    printf 'true'
  elif git rev-parse --verify -q "origin/${TRUNK}" >/dev/null 2>&1; then
    explain "CI_PRESENT=false (no build-status, no CI config files at origin/${TRUNK})"
    printf 'false'
  else
    explain "CI_PRESENT=unknown (cannot inspect origin/${TRUNK} tree)"
    printf 'unknown'
  fi
}

BS_SAMPLE="$(sample_build_status)"
CI_PRESENT="$(detect_ci)"

# --- CI status-reporting probe --------------------------------------------------
# CI_STATUS_REPORTING: does the CI that runs actually report to the host
# build-status API? A runbook with `ci.skip_wait: false` polls that API (D7.5);
# when CI exists but never posts there, the poll can never resolve and the CI
# gate is unenforceable. Detect it at probe time and degrade honestly.
if [[ "$BS_SAMPLE" == "definite" ]]; then
  CI_STATUS_REPORTING="true"
  explain "CI_STATUS_REPORTING=true (definite build state on a recent trunk commit)"
elif [[ "$CI_PRESENT" == "true" && "$BS_SAMPLE" == "silent" ]]; then
  CI_STATUS_REPORTING="false"
  explain "CI_STATUS_REPORTING=false (CI config present, but no build state on any sampled trunk commit — the endpoint never populates)"
else
  CI_STATUS_REPORTING="unknown"
  explain "CI_STATUS_REPORTING=unknown (no CI detected, backend unavailable, or dry-run)"
fi

# --- Force-push probe ---------------------------------------------------------

detect_force_push() {
  if (( DRY_RUN == 1 )); then
    explain "FORCE_PUSH_ALLOWED=unknown (dry-run)"
    printf 'unknown'
    return 0
  fi

  local logfile
  logfile=$(mktemp)

  # Method (GAPS A3): establish remote tip at T+A, rewrite the local branch to
  # the divergent sibling T+B, and force-push. T+A -> T+B is a genuine
  # non-fast-forward update, which is what history-rewrite policies reject.
  # All git output goes to the logfile: stdout must stay KEY=VALUE-pure (A4).

  if ! git fetch --quiet origin "$TRUNK" >>"$logfile" 2>&1; then
    explain "FORCE_PUSH_ALLOWED=unknown (cannot fetch trunk)"
    rm -f "$logfile"
    printf 'unknown'
    return 0
  fi

  if ! git branch -f "$FP_BRANCH" "origin/${TRUNK}" >>"$logfile" 2>&1; then
    explain "FORCE_PUSH_ALLOWED=unknown (cannot create temp branch)"
    rm -f "$logfile"
    printf 'unknown'
    return 0
  fi

  # Probe commit subjects carry the operator-supplied JIRA key when given
  # (--jira-key), so the probe is not blinded by JIRA-enforcing servers —
  # exactly the strict repos AP-23 exists for.
  local subj_prefix=""
  [[ -n "$PROBE_JIRA_KEY" ]] && subj_prefix="[${PROBE_JIRA_KEY}] "

  # Build T+A and push it (fast-forward, no force).
  if ! (
      git checkout --quiet "$FP_BRANCH" &&
      git commit --allow-empty --quiet -m "${subj_prefix}autopilot probe: A" &&
      git push --quiet origin "$FP_BRANCH:$FP_BRANCH"
  ) >>"$logfile" 2>&1; then
    # Cannot even push a fresh branch. If the rejection is a JIRA-hook
    # signal, record that fact — the JIRA probe can conclude from it
    # without a second rejected push, and the operator learns to re-run
    # with --jira-key to get a force-push verdict.
    local pre_signal=""
    if match_rejection "$logfile" pre_signal && [[ "$pre_signal" == JIRA_HOOK_* ]]; then
      FP_JIRA_BLOCKED=1
      explain "FORCE_PUSH_ALLOWED=unknown (initial push rejected by JIRA hook — re-run with --jira-key <KEY> for a force-push verdict)"
    else
      explain "FORCE_PUSH_ALLOWED=unknown (initial push failed; may be branch-perm-denied)"
    fi
    rm -f "$logfile"
    printf 'unknown'
    return 0
  fi

  # Rewrite: rewind to T and commit the divergent sibling B.
  if ! (
      git reset --hard --quiet HEAD~1 &&
      git commit --allow-empty --quiet -m "${subj_prefix}autopilot probe: B (rewritten)"
  ) >>"$logfile" 2>&1; then
    explain "FORCE_PUSH_ALLOWED=unknown (local rewrite failed)"
    rm -f "$logfile"
    printf 'unknown'
    return 0
  fi

  # Attempt the force-push of the rewritten history. Capture stderr for
  # pattern matching.
  if git push --force --quiet origin "$FP_BRANCH:$FP_BRANCH" >>"$logfile" 2>&1; then
    explain "FORCE_PUSH_ALLOWED=true (non-fast-forward force-push accepted)"
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
        explain "FORCE_PUSH_ALLOWED=unknown (unrelated signal=$signal)"
        rm -f "$logfile"
        printf 'unknown'
        return 0
        ;;
    esac
  fi

  # Rejection with no matching pattern: surface it for registry growth (B4),
  # then report unknown — transient network and unrecognized policies are
  # indistinguishable here.
  report_unknown_rejection "$logfile"
  explain "FORCE_PUSH_ALLOWED=unknown (push failed, no pattern match)"
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

  # The force-push probe's initial push may already have produced the
  # ground truth (a JIRA-hook rejection); no need for a second push.
  if (( FP_JIRA_BLOCKED == 1 )); then
    explain "JIRA_HOOK_ENFORCED=true (force-push probe's initial push was rejected by the JIRA hook)"
    printf 'true'
    return 0
  fi

  local logfile
  logfile=$(mktemp)

  # Create a temp branch at trunk with a single commit whose message
  # deliberately omits any JIRA key. If the server rejects, the hook is
  # enforced; if it accepts, the hook is not enforced (or is warn-only).

  if ! git branch -f "$JH_BRANCH" "origin/${TRUNK}" >>"$logfile" 2>&1; then
    explain "JIRA_HOOK_ENFORCED=unknown (cannot create temp branch)"
    rm -f "$logfile"
    printf 'unknown'
    return 0
  fi

  if ! (
      git checkout --quiet "$JH_BRANCH" &&
      git commit --allow-empty --quiet -m "autopilot probe: no jira key on purpose"
  ) >>"$logfile" 2>&1; then
    explain "JIRA_HOOK_ENFORCED=unknown (local commit failed)"
    rm -f "$logfile"
    printf 'unknown'
    return 0
  fi

  if git push --quiet origin "$JH_BRANCH:$JH_BRANCH" >>"$logfile" 2>&1; then
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

  report_unknown_rejection "$logfile"
  explain "JIRA_HOOK_ENFORCED=unknown (push rejected, no JIRA pattern match)"
  rm -f "$logfile"
  printf 'unknown'
}

JIRA_HOOK_ENFORCED="$(detect_jira_hook)"

# --- Emit ---------------------------------------------------------------------

printf 'TRUNK=%s\n' "$TRUNK"
printf 'CI_PRESENT=%s\n' "$CI_PRESENT"
printf 'CI_STATUS_REPORTING=%s\n' "$CI_STATUS_REPORTING"
printf 'FORCE_PUSH_ALLOWED=%s\n' "$FORCE_PUSH_ALLOWED"
printf 'JIRA_HOOK_ENFORCED=%s\n' "$JIRA_HOOK_ENFORCED"

exit 0
