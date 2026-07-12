#!/usr/bin/env bash
# host.sh
#
# The single PR/build surface for autopilot (ADR 0013, Hard Contract 11).
# Autopilot is git-host agnostic BY CONTRACT: every PR / build-status
# operation is issued as `host.sh <subcommand>`, never against a named host.
# host.sh detects the backend from the `origin` remote and dispatches to it:
#
#   BITBUCKET_DC -> scripts/bitbucket.sh   (Bitbucket Data Center REST)
#   GITHUB       -> scripts/github.sh       (gh CLI)
#
# Both backends implement a byte-identical observable contract (the T01-class
# mock matrix runs against both), so callers never branch on host. A new host
# (GitLab, Gitea, …) is a new backend passing the same matrix — never a new
# caller path.
#
# Subcommand surface (delegated verbatim to the backend):
#   pr-open [--draft]  pr-ready  pr-state  pr-comment  pr-merge
#   pr-approve  pr-decline  pr-merge-strategies  build-status
#   pr-list-ready      -> enumerate the ready+approval-tagged merge queue as TSV
#                         (the Merge Marshal's queue primitive; see
#                          plugins/zero-trust/references/host-contract.md)
#
# Plus one introspection subcommand, host-local (not delegated):
#   backend            -> prints the detected backend id (BITBUCKET_DC | GITHUB)
#
# Backend detection (first match wins):
#   1. $AUTOPILOT_HOST_BACKEND, if set, is authoritative (BITBUCKET_DC | GITHUB).
#      Use it for GitHub Enterprise / self-managed hosts whose origin URL the
#      heuristics below don't recognise.
#   2. origin host github.com            -> GITHUB
#   3. origin path contains /scm/        -> BITBUCKET_DC  (the DC git-URL shape)
#   4. otherwise: refuse with a message pointing at $AUTOPILOT_HOST_BACKEND.
#
# Secret handling and loop-safety are per-backend properties behind this
# surface (ADR 0013); host.sh itself touches no credentials.
#
# Portability: bash 3.2 (macOS default) + BSD userland safe.

set -u
set +x

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<EOF
usage: host.sh <subcommand> [args]
subcommands: backend pr-open pr-ready pr-state pr-comment pr-approve pr-decline pr-merge pr-merge-strategies build-status pr-list-ready
EOF
  exit 64
}

die_state() {
  local state="$1"; shift
  echo "LAST_STATE=${state}" >&2
  echo "host.sh: $*" >&2
  exit 1
}

detect_backend() {
  local override="${AUTOPILOT_HOST_BACKEND:-}"
  if [[ -n "$override" ]]; then
    case "$override" in
      BITBUCKET_DC|GITHUB) printf '%s' "$override"; return 0 ;;
      *) die_state "backend-override-invalid" "AUTOPILOT_HOST_BACKEND must be BITBUCKET_DC or GITHUB, got: $override" ;;
    esac
  fi
  local url
  url="$(git remote get-url origin 2>/dev/null || true)"
  [[ -n "$url" ]] || die_state "no-origin" "no origin remote configured (or set AUTOPILOT_HOST_BACKEND)"
  case "$url" in
    *github.com/*|*github.com:*) printf '%s' "GITHUB" ;;
    */scm/*)                     printf '%s' "BITBUCKET_DC" ;;
    *) die_state "backend-undetected" "cannot detect host backend from origin ($url); set AUTOPILOT_HOST_BACKEND=BITBUCKET_DC|GITHUB" ;;
  esac
}

backend_script() {  # <backend-id> -> echoes the backend script path
  case "$1" in
    BITBUCKET_DC) printf '%s' "$HERE/bitbucket.sh" ;;
    GITHUB)       printf '%s' "$HERE/github.sh" ;;
    *) die_state "backend-unknown" "no backend script for: $1" ;;
  esac
}

(( $# >= 1 )) || usage
SUB="$1"; shift

case "$SUB" in
  backend)
    detect_backend; echo
    ;;
  pr-open|pr-ready|pr-state|pr-comment|pr-approve|pr-decline|pr-merge|pr-merge-strategies|build-status|pr-list-ready)
    BACKEND="$(detect_backend)"
    SCRIPT="$(backend_script "$BACKEND")"
    [[ -f "$SCRIPT" ]] || die_state "backend-missing" "backend script not found: $SCRIPT"
    # exec so the backend's stdout / exit code become host.sh's verbatim —
    # the surface is a pass-through, never a re-interpretation.
    exec bash "$SCRIPT" "$SUB" "$@"
    ;;
  *)
    usage
    ;;
esac
