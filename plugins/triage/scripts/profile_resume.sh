#!/usr/bin/env bash
# profile_resume.sh — TR-04: resume the Config Profile the way spec-gen does, with
# ZERO new resolver code (ADR 0006). The incident's manifest carries
# `observability.profile` (copied from the source manifest by TR-05), so there is
# no re-escalation — this reuses the VENDORED profile_resolve.py verbatim.
#
# Per codebase-health CH-08 the profile PAYLOAD (taxonomy/vocabulary/seams) is NOT
# vendored today: the deterministic layer reads the bare NAME and degrades on
# unknown -> `default` + a loud note. The profile decides WHICH vitals matter
# (steers severity as a FLOOR), never HOW severe past the ladder cap (a ceiling).
#
# Subcommands:
#   resolve --manifest <incident.manifest.yaml>
#       -> the vendored resolver's JSON ({profile,source,escalate,...}); a manifest
#          missing observability.profile is malformed resume input (resolver exit 3).
#   severity --base <lvl> [--floor <lvl>] --cap <lvl>
#       -> the effective severity = min(max(base, profile-floor), ladder-cap). The
#          profile can RAISE toward its floor but NEVER past the cap (floor-not-
#          ceiling; mirrors CH-08). Ladder: info < warn < error < critical.
#
# Portability: bash 3.2 + BSD safe.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_triage_run.sh"
RESOLVER="$HERE/profile_resolve.py"   # vendored byte-identical from spec-gen

die() { echo "profile_resume.sh: REFUSE: $*" >&2; exit 1; }

sev_rank() {  # <level> -> 0..3 ; unknown -> empty + rc1
  case "$1" in
    info) echo 0 ;; warn) echo 1 ;; error) echo 2 ;; critical) echo 3 ;;
    *) return 1 ;;
  esac
}
sev_name() { case "$1" in 0) echo info ;; 1) echo warn ;; 2) echo error ;; 3) echo critical ;; esac; }

SUB="${1:-}"; shift || true
case "$SUB" in
  resolve)
    MANIFEST=""
    while (( $# > 0 )); do
      case "$1" in
        --manifest) MANIFEST="${2:-}"; shift 2 ;;
        *) die "unknown resolve argument: $1" ;;
      esac
    done
    [ -n "$MANIFEST" ] || die "resolve requires --manifest"
    [ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
    # Pure reuse: no new resolver code. profile_resolve.py --mode resume reads
    # observability.profile from the manifest (already resolved upstream).
    triage_py "$RESOLVER" --mode resume --manifest "$MANIFEST"
    ;;
  severity)
    BASE=""; FLOOR="info"; CAP=""
    while (( $# > 0 )); do
      case "$1" in
        --base)  BASE="${2:-}"; shift 2 ;;
        --floor) FLOOR="${2:-}"; shift 2 ;;
        --cap)   CAP="${2:-}"; shift 2 ;;
        *) die "unknown severity argument: $1" ;;
      esac
    done
    br="$(sev_rank "$BASE")"  || die "unknown --base severity: $BASE (info|warn|error|critical)"
    fr="$(sev_rank "$FLOOR")" || die "unknown --floor severity: $FLOOR"
    cr="$(sev_rank "$CAP")"   || die "unknown --cap severity: $CAP"
    # profile floor RAISES the base; the ladder cap then CLAMPS it (never exceeded).
    eff="$br"; [ "$fr" -gt "$eff" ] && eff="$fr"
    [ "$eff" -gt "$cr" ] && eff="$cr"
    sev_name "$eff"
    ;;
  *)
    die "usage: profile_resume.sh resolve --manifest <m> | severity --base <l> [--floor <l>] --cap <l>"
    ;;
esac
