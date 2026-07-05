#!/usr/bin/env bash
# CH-06 — Behavior-ID coverage check: claimed vs proven (MS §13.11; ADR 0004).
#
# The PR Gate's answer to "who checks the checker". A PR that touches
# behavior-bearing code carries a `## Behavior coverage` section (behavior ID ->
# test node IDs) — the AV3-05 documented grep-able format. This CONSUMER verifies
# the CLAIM against PROOF; it never re-implements the AV3-05 producer.
#
#   Claimed  — behavior IDs in the PR body's `## Behavior coverage` section.
#   Proven   — a RED commit in the range naming the behavior (the AV3-05
#              audit_behavior_binding.sh git-log convention) AND/OR the test node
#              existing. Evidence is git-log + test-node existence — NEVER the
#              implementer's self-report (ADR 0003).
#   Verdict  — a claimed behavior with no proving test/commit is the ADR-0004
#              BLOCKING class "manifest behavior-IDs claimed but unproven"
#              (deterministic — git-log/grep-provable — so it may gate).
#   Degrade  — manifest absent -> skip, loud [note] (MS §11 PR-Gate row). The
#              coverage check NEVER blocks a manifest-less PR.
#
# The grep-able `## Behavior coverage` format (`- <B-id>: <path>::<node>`) is the
# ONE datum the AV3-05 producer and this consumer must agree on — pinned by the
# repo-level consistency lint (CH-10), not restated here.
#
# Loop-safety: REPORTER. Reads the manifest, PR body, and git log; mutates
# nothing. Exit code mirrors the finding for a human-wired CI step; the ratchet
# reports.
#
# Usage:  check_behavior_coverage.sh <manifest> <pr-body-file> <git-range|base-ref>
set -uo pipefail

MANIFEST="${1:-}"; PR_BODY="${2:-}"; RANGE="${3:-}"
[ -n "$MANIFEST" ] && [ -n "$PR_BODY" ] && [ -n "$RANGE" ] || {
  echo "usage: check_behavior_coverage.sh <manifest> <pr-body-file> <git-range|base-ref>" >&2; exit 64; }

SLUG="behavior-claimed-unproven"

# Degrade (MS §11): no manifest -> skip, loud note, never block a manifest-less PR.
if [ ! -f "$MANIFEST" ]; then
  echo "[note] no manifest at '$MANIFEST' — behavior-ID coverage check skipped; a manifest-less PR is never blocked by this facet (MS §11 PR-Gate row)"
  echo "[not-covered] behavior-ID coverage: manifest absent"
  exit 0
fi
if [ ! -f "$PR_BODY" ]; then
  echo "[note] no PR body at '$PR_BODY' — no '## Behavior coverage' claims to verify (nothing to gate)"
  echo "[not-covered] behavior-ID coverage: PR body absent"
  exit 0
fi

# Git range: accept a full `a..b` or a bare base ref (-> base..HEAD).
case "$RANGE" in
  *..*) LOGRANGE="$RANGE" ;;
  *)    LOGRANGE="$RANGE..HEAD" ;;
esac
GITLOG=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GITLOG="$(git log --format='%H%x09%s%x09%b' "$LOGRANGE" 2>/dev/null || true)"
fi

# Extract the `## Behavior coverage` section claims: lines `- <B-id>: <node>`.
# Bounded to the section (stops at the next `## ` header).
claims="$(awk '
  /^##[[:space:]]+[Bb]ehavior[[:space:]]+coverage/ { insec=1; next }
  /^##[[:space:]]/ { insec=0 }
  insec && /^[[:space:]]*-[[:space:]]/ { print }
' "$PR_BODY")"

if [ -z "$claims" ]; then
  echo "[note] PR body has no '## Behavior coverage' section — no behavior IDs claimed; nothing to verify"
  echo "[not-covered] behavior-ID coverage: no coverage section in PR body"
  exit 0
fi

findings=0
echo "==> behavior-ID coverage — range=$LOGRANGE"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  bid="$(printf '%s' "$line" | grep -oE 'B-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{3}' | head -1)"
  [ -n "$bid" ] || continue
  node="$(printf '%s' "$line" | grep -oE '[A-Za-z0-9_./-]+::[A-Za-z0-9_]+' | head -1)"

  # cross-check: a claimed ID should be an ACTIVE behavior in the manifest.
  if ! grep -qE "id:[[:space:]]*$bid\b" "$MANIFEST"; then
    echo "[note] claimed behavior $bid is not present in the manifest — claim may be stale (informational)"
  fi

  proven=""
  # RED-commit evidence: a commit in range whose subject/body marks RED + names the behavior.
  if [ -n "$GITLOG" ] && printf '%s\n' "$GITLOG" | grep -E "RED" | grep -qE "(^|[^A-Za-z0-9_])$bid([^A-Za-z0-9_]|$)"; then
    proven="RED-commit"
  fi
  # test-node evidence: the node's file exists AND actually DEFINES the named
  # test — a def/func/fn, or an it()/test()/describe() declaration. A bare
  # mention (a comment, a TODO, a string) must NOT count as proof, or the
  # "who checks the checker" gate is trivially defeated by claiming a test that
  # was never written (evidence, not self-report — ADR 0003).
  if [ -z "$proven" ] && [ -n "$node" ]; then
    nf="${node%%::*}"; nn="${node##*::}"
    if [ -f "$nf" ] && grep -qE "(^|[^A-Za-z0-9_])(def|func|fn)[[:space:]]+$nn\b|(^|[^A-Za-z0-9_])(it|test|describe)[[:space:]]*\([^)]*$nn" "$nf" 2>/dev/null; then
      proven="test-node"
    fi
  fi

  if [ -n "$proven" ]; then
    echo "[coverage] $bid proven via $proven (${node:-no-node})"
  else
    echo "[FINDING blocking] $SLUG: behavior $bid claimed in the PR body but UNPROVEN — no RED commit in range, no existing test node (${node:-none}); ADR-0004 blocking class 'manifest behavior-IDs claimed but unproven' (evidence = git-log/test-node, not self-report) fpsrc=$MANIFEST:$bid:$SLUG"
    findings=$((findings+1))
  fi
done <<< "$claims"

echo "==> behavior-ID coverage done — $findings unproven claim(s)."
[ "$findings" -eq 0 ] && exit 0 || exit 1
