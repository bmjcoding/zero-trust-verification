#!/usr/bin/env bash
# RL-03 — Escalate-class routing table (ADR 0017 / ADR 0002; single copy, lint-pinned).
#
# Maps an ELIGIBLE finding's slug → DRAIN | ESCALATE. This classifies the FIX, not
# the finding: a deterministic finding names a real defect, but its *remediation*
# may be values-laden (ADR 0002's own cut — "silent-dedupe vs reject-and-alert on a
# duplicate" is risk appetite). The table encodes the ADR 0002 trilist; the loop
# consults it, never re-derives it (root lint V10 pins membership).
#
# drain-class — reversible-at-low-cost AND verifiable downstream by the suite's
#               own gates → route to a drain (Runbook PR + Story PR(s), none merged).
# escalate-class — values-laden / irreversible / external-fact → manifest-less
#               GENERATE+pause to spec-gen S5, one question at a time. Membership is
#               a SUPERSET (fail-safe) of audit-state-and-verify.md's Category-TX
#               money/auth slug catalog + any security/* slug + wire-format /
#               public-API-shape / alert-seam slugs.
#
# Unknown slug → ESCALATE (fail-safe: never auto-drain an unclassified fix).
#
# HARDENED (Defect H): RL-02 (finding_eligible.sh) already filters agent-scored
# slugs to INELIGIBLE, so several escalate-class TX slugs (non-idempotent-handler,
# unsafe-retry, missing-compensation — agent per §12) never reach this classifier;
# the loop's real behavior for those is comment-only, NOT loop-escalation. This
# table stays a superset so a future deterministic reclassification is caught safe.
#
# Usage:  classify_fix.sh <slug>   →   prints DRAIN or ESCALATE (exit 0)
set -uo pipefail

SLUG="${1:-}"
[ -n "$SLUG" ] || { echo "usage: classify_fix.sh <slug>" >&2; exit 64; }

# ── drain-class (reversible + gate-verifiable) ────────────────────────────────
case "$SLUG" in
  marker|dead-code|commented-code|suppression|memory-rot-dangling-ref|giant-file|test-skip|vacuous-test|missing-behavior-binding)
    echo DRAIN; exit 0 ;;
esac

# ── escalate-class (ADR 0002 trilist: values / irreversible / external-fact) ──
# The money/auth/tx catalog is VERBATIM from audit-state-and-verify.md (Category
# TX) — a SUPERSET pinned by root lint V10 — plus the deterministically-scored
# money slugs, plus any security/* slug and wire-format / public-API / alert-seam.
case "$SLUG" in
  # Category-TX (audit-state-and-verify.md, byte-verbatim; superset per V10):
  non-idempotent-handler|missing-dedup-guard|unsafe-retry|double-submit-window|missing-compensation|missing-audit-trail)
    echo ESCALATE; exit 0 ;;
  # dark-money-movement is deterministically scored (slug_provenance.tsv) and DOES
  # route to the loop's S5. log-only-refund is AGENT-provenance (§12 J5 — see the
  # slug_provenance.tsv reconciliation note), so RL-02 filters it INELIGIBLE and it
  # never reaches this classifier; its row here is the fail-safe superset only:
  dark-money-movement|log-only-refund)
    echo ESCALATE; exit 0 ;;
  # any security/* slug, and outward-facing wire/API/alert-seam shapes:
  security/*|*wire-format*|*wire_format*|*public-api*|*public_api*|*alert-seam*|*alert_seam*)
    echo ESCALATE; exit 0 ;;
esac

# ── unknown → ESCALATE (fail-safe; never auto-drain an unclassified fix) ───────
echo ESCALATE
exit 0
