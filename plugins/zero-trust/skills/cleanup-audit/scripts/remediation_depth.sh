#!/usr/bin/env bash
# RL-09 — Guard 2 (depth ceiling). A finding discovered *in* a remediation-authored
# branch is detectable deterministically: its branch is under the loop's own
# `remediation/<slug>/*` namespace. Such a finding inherits
# remediation_depth = parent+1, and RL-05 forces `depth >= 1 → ESCALATE`
# regardless of slug class — a fix-of-a-fix always surfaces to a human. This
# bounds recursion at depth 1 by construction (ADR 0018 Guard 2).
#
# HARDENED (Defect G — citation): the own-namespace detection REUSES the VERIFIED
# `claim_overlap.sh --self-namespace <prefix>` → EXCLUDED primitive
# (claim_overlap.sh:34/76/107), NOT a vaguely-cited "AV3-09". We feed the primitive
# a one-row synthetic inventory for the finding's branch and read its EXCLUDED
# classification — the exact `case "$branch" in "$SELF_NS"*` mechanism ADR 0018
# points at.
#
# Output: `depth=<n>` on stdout (n = 0 off-namespace, parent+1 on-namespace, or
# `unknown` when the primitive cannot be located — the router treats unknown as
# ESCALATE, fail-safe). Exit 0.
#
# Usage:
#   remediation_depth.sh --branch <branch> --self-namespace <prefix> [--parent-depth <n>]
set -uo pipefail

RL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BRANCH=""; SELF_NS="remediation/"; PARENT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --branch)         BRANCH="${2:-}"; shift 2 ;;
    --self-namespace) SELF_NS="${2:-}"; shift 2 ;;
    --parent-depth)   PARENT="${2:-0}"; shift 2 ;;
    *) echo "remediation_depth: unknown arg: $1" >&2; exit 64 ;;
  esac
done
[ -n "$BRANCH" ] || { echo "usage: remediation_depth.sh --branch <branch> --self-namespace <prefix> [--parent-depth <n>]" >&2; exit 64; }
case "$PARENT" in ''|*[!0-9]*) PARENT=0 ;; esac

# Locate the VERIFIED claim_overlap primitive. The loop drains THROUGH autopilot
# + spec-gen, so autopilot's canonical copy is present wherever the loop operates;
# $CLAIM_OVERLAP overrides for hermetic tests / standalone vendoring.
resolve_claim_overlap() {
  if [ -n "${CLAIM_OVERLAP:-}" ] && [ -f "${CLAIM_OVERLAP}" ]; then echo "$CLAIM_OVERLAP"; return 0; fi
  local sib="$RL_DIR/claim_overlap.sh"
  [ -f "$sib" ] && { echo "$sib"; return 0; }
  local root; root="$(cd "$RL_DIR/../../../../.." 2>/dev/null && pwd)"
  local canon="$root/plugins/zero-trust/skills/autopilot/scripts/claim_overlap.sh"
  [ -f "$canon" ] && { echo "$canon"; return 0; }
  local found; found="$(find "$root" -path "$root/.git" -prune -o -name claim_overlap.sh -print 2>/dev/null | head -1)"
  [ -n "$found" ] && { echo "$found"; return 0; }
  return 1
}

CO="$(resolve_claim_overlap || true)"
if [ -z "$CO" ]; then
  echo "[note] remediation_depth: claim_overlap.sh not locatable — depth undetermined (router will ESCALATE, fail-safe)" >&2
  echo "depth=unknown"; exit 0
fi

# Synthetic one-row inventory: <ref>\t<branch>\t<state>\t<age_bd>\t<files>. The
# owned-file is a sentinel so the row always "overlaps" and the classifier reaches
# the self-namespace test (the ONLY thing we're probing).
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
TAB="$(printf '\t')"
printf 'SELF%s%s%sDRAFT%s0%s.remediation-depth-probe\n' "$TAB" "$BRANCH" "$TAB" "$TAB" "$TAB" > "$TMP"

out="$(bash "$CO" --self-namespace "$SELF_NS" --inventory "$TMP" .remediation-depth-probe 2>/dev/null || true)"
case "$out" in
  *"excluded=SELF"*)
    echo "depth=$((PARENT + 1))" ;;   # own-namespace → parent+1 (>=1) → ESCALATE
  *)
    echo "depth=0" ;;                  # normal branch → depth 0 → normal routing
esac
exit 0
