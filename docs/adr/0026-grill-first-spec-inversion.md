# ADR 0026 — Grill-first inversion of /spec: the human conversation is the front door

- **Status:** Accepted (operator approved 2026-07-12)
- **Date:** 2026-07-12
- **Amends:** ADR 0025 wave scope (this is the campaign's highest-stakes semantic wave);
  `docs/specs/spec-gen-tier-v1.md` §2/§3/§5 S-step *content* (S1–S7 numbering and every
  hard contract are kept — see the frozen list below). ADR 0009's Spec lifecycle
  (product approval → merge → Pickup) is untouched; the supersession scope is the
  *ordering of interrogation inside one /spec session*, nothing downstream of S7.

## Context

An operator field session (field-session-v1, 60+ minutes on a real feature — the
payment-processing workflow platform) rejected the current /spec interaction shape. The
evidence, from the session's own committed artifacts
(`spec/field-session-v1:docs/specs/field-session-v1.manifest.yaml` interrogation.log):

1. **~50 minutes of agent work before the FIRST human question.** S2 domain pass,
   S3 skeleton (7 journeys, 15 behaviors), S4 two-attacker round — 33 findings
   adjudicated agent-vs-agent (DL-001..DL-018 alone are 18 multi-paragraph
   agent resolutions) — all before the human was asked anything.
2. **~10 minutes of background work between questions.** Each S5 answer triggered
   bookkeeping, re-runs, and log-writing before the next question appeared; the
   human sat idle inside their own interview.
3. **Dissent-as-dialogue.** Every S5 question reached the human wrapped in
   summary + dissent paragraphs (see DL-019/DL-020: multi-sentence summaries plus
   multi-clause dissent blocks read as prose). The operator verdict: questions so
   long that focus was lost halfway — "AWS professional certification" style.

The root cause is architectural, not stylistic: the pipeline front-loads synthesis
and adversarial attack, so by the time the human is consulted, the session has a
large standing edifice to *defend* — every question arrives as an appeal against 33
prior adjudications rather than as a design conversation. The imported counter-pattern
is mattpocock/skills' `grilling` (13 lines, field-tested): interview relentlessly,
one question at a time with a recommended answer, look FACTS up and ask only
DECISIONS, and do not build until shared understanding is confirmed.

## Decision

Invert the session: **the human conversation becomes the front door; synthesis and
adversarial attack move AFTER it.** S1–S7 numbering is KEPT with redefined content:

| Step | Was | Becomes |
|---|---|---|
| S1 Hydrate | hydrate + subagent-feeding prep | unchanged reads, time-boxed framing: quick (CONTEXT.md, ADR index, profile, ID reservation); **no subagent dispatch** |
| S2 | agent domain pass | **GRILL** — the human interview starts within a couple of minutes of invocation; the completeness rules (manifest §10) are the AGENDA walked as a question tree; domain-term + draft-ADR capture happens inline (the grill-with-docs move); ends at the confirmation gate: the human confirms shared understanding |
| S3 | agent skeleton from raw intent | **SYNTHESIZE** — Spec + manifest built FROM the conversation (same s3-proposer schema/output rules, re-aimed at conversation-as-input); draft presented to the human for review |
| S4 | adversarial round on the pre-human skeleton | same two attackers, same prompts re-targeted **at the draft, in background while the human reads it**; resolutions recorded with recommendation + dissent + escalation_check in interrogation.log — WRITTEN, never read aloud |
| S5 | escalation ceremony (first human contact) | **Residue grill** — ONLY decisions the attackers surfaced that the S2 conversation did not already answer, under the same question-style contract |
| S6 Finalize gate | validator exit-0 + GWT judgment gate | UNTOUCHED |
| S7 Emit | emission_check + one-branch-one-PR | UNTOUCHED |

**Question-style contract (hard rules, shared by S2 and S5 — one reference,
`skills/spec/references/grill-contract.md`, cited by both):** one decision per
question; ≤3 sentences of setup; the recommendation in one line; dissent/trade-off
detail only on request; FACTS are looked up (codebase, CONTEXT.md, org-memory),
never asked; DECISIONS are the human's — ask and WAIT; NO background work while a
question is pending — the answer is recorded, the next question follows
immediately; bookkeeping (log entries, commits) batches at checkpoints.

**Machine doors map cleanly:** `--resume` = re-enter S2 grilling with the agenda =
the validator's remaining unmet rules via `resume_projection.py`; `--from-findings`
enters S2 with the register as the conversation seed; `--amend` re-enters S2 scoped
to the amendment intent. HC4's one-at-a-time-with-recommendation — same words —
now governs the grill (S2) as well as the residue (S5).

## What this ADR explicitly protects (frozen — no semantic change)

- The seven §4 hard contracts (HC1–HC7). HC4 gains scope (governs S2 + S5), not words.
- The completeness checker (manifest §10 rules) and ALL `scripts/`:
  `validate_manifest.{sh,py}`, `id_alloc.py`, `resume_projection.py`,
  `profile_resolve.py`, `emission_check.py` — byte-untouched.
- The escalation-criterion pointer block (ADR 0002) — byte-identical, unedited.
- Criticality-scoped rigor (§5): CORE human-only confirmation, the rules 1–2 floor,
  re-scoped-never-grandfathered.
- The machine doors: `--from-findings` / `--resume` / `--amend` still work, mode
  table unchanged (Fresh/Resume/Amend).
- Per-boundary session-branch commits (HC5) — batched at checkpoints, never
  mid-question.
- No manifest schema change; no validator exit-code change; no assertion-count drop
  in any harness.

## Consequences

- A /spec session reaches its first human question in minutes, not ~50; the human's
  answers *precede* and *feed* synthesis, so S4 attacks a draft the human already
  shaped and S5 shrinks to genuine residue.
- S2 human answers land as `resolved_by: human` interrogation.log entries at
  checkpoints; rule-4/rule-8 confirmations reference them (`confirmed_by`) without
  re-asking — re-asking an S2-answered decision at S5 is a contract violation.
- The Config-Profile fall-through question (previously S5's mandated first
  escalation) becomes an early S2 question — same question, same recording; S5
  raises it first only if S2 somehow never did (tier spec §2 amended accordingly).
- s4 attacker prompts survive nearly as-is (re-targeted at the draft; told the
  S2-answered decision set is settled); s5-presenter survives as the residue-round
  specialization of the shared grill contract, because the residue round carries
  manifest bookkeeping (DL entries, `confirmed_by`, restructuring re-entry,
  deferral bounds) the generic contract must not.
- Suite version: 2.1.0-rc — minor bump; breaking only in interaction shape, not in
  any artifact, gate, or door.
- Risk: a chatty grill can recreate the old ceremony inside S2. Mitigation: the
  question-style contract is hard rules in a linted reference, and the field-run
  gate (ADR 0025 mitigation) applies before the next wave.
