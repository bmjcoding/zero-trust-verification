# Remediation Loop — wiring, not a fifth checker (ADR 0017 / ADR 0018)

The remediation loop turns ALREADY-DETECTED findings into rework. It is **thin
wiring over the three existing tiers** (ADR 0017): one `/remediate` skill (homed
here in codebase-health) plus a handful of deterministic bridge scripts. It adds
no detector, no severity judgment, no second implementation of anything a tier
owns. It **holds no quality opinion** — every judgment is a deterministic script
call or the vendored ADR-0002 rule applied verbatim.

Home: `plugins/zero-trust/skills/cleanup-audit/scripts/` (sibling of
`pr_gate.sh`). NOT a new plugin (ADR 0017, boundary collapsed by ADR 0025): the
loop is part of the cleanup-audit skill inside the single zero-trust plugin.

## Shipping posture: report-only / advisory-first

The loop files rework PRs for **human review** and **never merges** (autopilot
HC4). There is **no blocking CI path** and **no auto-merge path**. Autonomous
emit-to-drain and any blocking are **per-repo opt-ins after a soak**
(`remediation.config.yaml`: `blocking: false`, `autonomous_emit_to_drain: false`
by default). A wrong loop must cost wrong *reports*, never damaged code
(the canonical loop-safety guarantee — `references/loop-safety.md`,
invariant 1).

## The pipeline (each seam already exists)

1. **Producer — codebase-health.** The ambient audit (CI cron) and the PR Gate
   already emit findings with a stable fingerprint and a severity from the one
   rubric. The loop READS this stream (`read_findings.sh`, RL-01); it authors no
   emission and re-runs no audit.
2. **Selector — deterministic bridges.** A finding becomes work ONLY when it is
   BOTH at/above the `severity_floor` (default HIGH = confirmed/traced) AND
   **deterministically-scored** (`finding_eligible.sh` + `slug_provenance.tsv`,
   RL-02). This applies ADR 0004: an agent opinion without deterministic evidence
   never blocks a human's merge, and by the same principle never auto-files
   autonomous rework.
3. **Formatter — spec-gen's findings-register input class.** Selected findings are
   bundled into a GAPS_SPEC-shape register (`build_register.sh`, RL-06) fed to
   `/spec --from-findings` (RL-04). spec-gen interrogates it like any Draft-Spec
   input and REFUSES to finalize an incomplete manifest (HC1).
4. **Drainer — autopilot.** A complete-manifest register drains via GENERATE:
   Pickup opens the **Runbook PR**, and the drain files **one-or-more Story PRs**
   (ADR 0007/0009 — not necessarily one). A human reviews once, at the end.

## Escalate-instead-of-drain (ADR 0002, vendored + lint-pinned)

A deterministic finding names a real defect, but its *remediation* may be
values-laden ("silent-dedupe vs reject-and-alert on a duplicate" is risk
appetite — ADR 0002's own cut). `classify_fix.sh` (RL-03) classifies the FIX
against the ADR-0002 trilist:

- **drain-class** — reversible-at-low-cost AND verifiable downstream by the
  suite's own gates (`marker, dead-code, commented-code, suppression,
  memory-rot-dangling-ref, giant-file, test-skip, vacuous-test,
  missing-behavior-binding`) → route to a drain.
- **escalate-class** — values-laden / irreversible / external-fact: the money/auth
  Category-TX slugs VERBATIM from `audit-state-and-verify.md`
  (`non-idempotent-handler, missing-dedup-guard, unsafe-retry,
  double-submit-window, missing-compensation, missing-audit-trail`) + any
  `security/*` slug + wire-format / public-API-shape / alert-seam slugs → a
  manifest-LESS GENERATE+pause to spec-gen's S5, one question at a time.
- **unknown slug → ESCALATE** (fail-safe: never auto-drain an unclassified fix).

Root lint **V10** pins this table: it cites ADR 0002 and its money/auth
membership is a SUPERSET of `audit-state-and-verify.md`'s TX catalog (drift → red).

### Honest scope (Defect H) and the `log-only-refund` reconciliation

Because RL-02 filters agent-scored slugs to INELIGIBLE, several escalate-class TX
slugs that are agent-scored in SPEC_1.4.0 §12 (`non-idempotent-handler,
unsafe-retry, missing-compensation`) never reach the classifier at all — for those
the loop's real behavior is **comment-only** (ADR 0004-correct), NOT
loop-escalation. The escalate-class table stays a superset as a fail-safe, but the
loop does NOT claim to autonomously escalate agent-scored money-path fixes; only
deterministically-scored escalate-class slugs (e.g. `dark-money-movement`) route
to the loop's S5.

`log-only-refund` (§12 J5) is likewise **agent**-scored — the LOG-ONLY-vs-DARK
distinction is a semantic emission judgment; only its seed half is deterministic.
The register's example list called it "deterministic (-seed)"; we follow §12
(which V10 pins) and keep it agent, so the loop leaves it comment-only. See
`slug_provenance.tsv` for the recorded decision.

## The three-guard ratchet (ADR 0018)

- **Guard 1 — never re-file (idempotency by fingerprint).** Before filing, the
  loop stamps the finding's record with an ADDITIVE
  `remediation: {status, ref, opened_at, remediation_depth}` (`remediation_stamp.sh`);
  schema stays v2. A fingerprint already carrying an open record
  (`SPEC_OPEN|PR_OPEN|ESCALATED|WONTFIX`) or a human `WONTFIX` status is
  **skipped, loudly** (`already_filed.sh`). This is the ONE mutation the loop
  makes; it never touches `status`/`severity`/`verified_by`.
- **Guard 2 — never remediate a remediation forever (depth ceiling).** A finding
  on the loop's own `remediation/<slug>/*` namespace inherits
  `remediation_depth = parent+1` (`remediation_depth.sh`, reusing
  `claim_overlap.sh --self-namespace`), and `depth ≥ 1 → ESCALATE` regardless of
  slug class. Recursion is bounded at depth 1 by construction.
- **Guard 3 — never chase its own tail.** The loop never merges (grep-provable in
  the drain path). When a drain-class removal deletes a symbol, the
  `lifecycle: withdrawn` + `withdrawn_reason` tombstone that CH-05 depends on is
  authored by **spec-gen in the register session's manifest** — NOT by the
  autopilot Story PR — because spec-gen is the manifest's only writer (HC3). The
  removal register DECLARES the withdrawal as an acceptance behavior; spec-gen
  emits the tombstone; CH-05 then cannot flag the loop's own cleanup as rot. Each
  cron fire is stateless and idempotent, so a missed/overlapping fire is harmless.

## Loop-safety invariant 1 (the scope guard, RL-12)

The loop runs **no mutation-testing tool** (`mutmut|cosmic-ray|stryker|pitest|
cargo-mutants`) under any code path — mutation findings enter ONLY as pre-existing
ingested reports via the normal audit stream, exactly like coverage — and runs
**no whole-repo scan** of its own (it never calls `run_audit.sh`). Its only compute
is deterministic string routing over an already-computed state file.
`remediation_scope_guard.sh` grep-asserts both, red-tested by planting a violation.

## Non-goals (v1)

- A fifth plugin / new marketplace entry (the loop is a codebase-health skill).
- New detectors or a new severity scale.
- RUNNING mutation testing (scoped or whole-repo) or any whole-repo scan.
- Auto-merging; blocking. A Runbook PR + one-or-more Story PRs always await review.
- Auto-escalating agent-scored money-path findings (they stay comment-only).
- The loop writing manifest tombstones (spec-gen authors them).
- Depth > 1 auto-remediation (a fix-of-a-fix always escalates).
- Reordering / prioritizing findings by agent judgment (routing is deterministic).
