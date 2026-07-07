---
description: Route ALREADY-DETECTED audit findings into rework — DRAIN eligible low-risk fixes through spec-gen→autopilot (Runbook + Story PRs for human review, none merged) or ESCALATE values-laden ones to spec-gen S5. Report-only/advisory-first; holds no quality opinion.
argument-hint: "[--dry-run] [--floor <CRITICAL|HIGH|MED|LOW>] [--state <state.json>] [--config <remediation.config.yaml>] [--slug <loop-slug>]"
---

# /remediate

The **wiring** that closes the ADLC loop: audit/PR-Gate findings → Spec → drain →
Story PR(s) awaiting human review. It is **not a fifth checker** (ADR 0017) — it
authors no emission, runs no detector, runs no mutation tool, runs no whole-repo
scan. **It holds no quality opinion: every judgment is a deterministic script call
or the vendored ADR-0002 rule.** It reads the EXISTING finding stream
(`audit/state.json` v2) that `/audit` and the PR Gate already wrote.

Read the `cleanup-audit` skill → `references/remediation-loop.md` first (the loop's
contract, the three ratchet guards, and the escalate-instead-of-drain rule), plus
ADR 0017 (wiring) and ADR 0018 (ratchet guards).

## Posture (read first) — REPORT-ONLY / ADVISORY-FIRST

- The loop files **rework PRs for human review** and **NEVER merges** (autopilot
  HC4). There is **no blocking CI path** and **no auto-merge path** — by design and
  by `remediation.config.yaml` (`blocking: false`, `autonomous_emit_to_drain:
  false`). Autonomous emit-to-drain and any blocking are **per-repo opt-ins after a
  soak**, never the default.
- The loop makes exactly **one** additive mutation to `state.json` — the
  `remediation` sub-object (Guard 1) — and never touches `status`/`severity`/
  `verified_by`.

## Modes

| Invocation | Behavior |
|---|---|
| `/remediate` | One pass over eligible OPEN findings: route each, then file the DRAIN register / ESCALATE intents and stamp records. |
| `/remediate --dry-run` | Route + report only. Files nothing, stamps nothing. The safe default for a first look. |
| `/remediate --floor <SEV>` | Override the `severity_floor` for this pass (else `remediation.config.yaml`, else HIGH). |

## What one pass does (the deterministic substrate does the deciding)

Each step is a script under `skills/cleanup-audit/scripts/`; the command orchestrates,
it never re-derives their logic:

1. **Read** the finding stream — `read_findings.sh <state.json>` (RL-01). Pure
   reader; degrades to nothing on corrupt/unknown-schema state (invariant 4).
2. **Route** each OPEN finding — `remediation_route.sh` (RL-05) composes:
   - Guard 1 `already_filed.sh` (RL-08) → `SKIP:already-filed` (never re-file; a
     human WONTFIX silences it for the loop too);
   - RL-02 `finding_eligible.sh` → `SKIP:<reason>` unless severity ≥ floor AND the
     slug is deterministically-scored (`slug_provenance.tsv`); agent-scored slugs
     stay comment-only (ADR 0004);
   - Guard 2 `remediation_depth.sh` (RL-09, reuses `claim_overlap.sh
     --self-namespace`) → `depth ≥ 1 → ESCALATE` regardless of class;
   - RL-03 `classify_fix.sh` → `DRAIN` (reversible + gate-verifiable) or `ESCALATE`
     (values / irreversible / external-fact per the ADR-0002 trilist).
3. **DRAIN** (RL-06): bundle the DRAIN verdicts into ONE findings register
   (`build_register.sh`), run `/spec --from-findings @<register>`. spec-gen
   interrogates it and REFUSES an incomplete manifest (HC1); a drain-classed
   finding that turns out to touch a vital/CORE path degrades to spec-gen's own S5
   escalation (ADR 0008). GENERATE at Pickup opens the **Runbook PR**; the drain
   files **one-or-more Story PRs** (ADR 0007 — NOT necessarily one). A removal
   register DECLARES the withdrawal so spec-gen emits the `lifecycle: withdrawn`
   tombstone into the manifest it owns (the loop writes no tombstone). Stamp each
   finding `SPEC_OPEN → PR_OPEN` with the host PR ref. Branch namespace
   `remediation/<slug>/*`.
4. **ESCALATE** (RL-07): file each as raw, manifest-LESS intent to
   `/spec` (→ `detect_input_mode.sh` returns GENERATE_PAUSE, not STRAIGHT_THROUGH),
   routed to S5 — one at a time, finding as the recommendation, dissent attached.
   No code is written until the human answers. Stamp the record `ESCALATED` with
   the `exchange_ref`.

## Cadence and statelessness

Unattended runs fire on the shared CI-cron pattern (the Marshal/ambient-audit
precedent). Each fire is **stateless and idempotent** — it re-derives eligible
findings from `state.json` and open remediation PRs from the host adapter
(`pr-list-ready`, ADR 0009) — so a missed or overlapping fire is harmless (Guard 3).

## Non-goals (v1)

No new detector, no new severity scale, no mutation-testing run (scoped or
whole-repo), no whole-repo scan, no auto-merge, no blocking, no reordering findings
by agent judgment, no auto-escalation of agent-scored money-path slugs (they stay
comment-only, ADR 0004). See `references/remediation-loop.md` for the full list.
