---
description: Grill the human about their intent (or a draft Spec / Jira / meeting notes) into a product-approvable Spec plus a complete Verification Manifest — the interview is the front door (one question at a time, recommendation attached), synthesis and adversarial attack follow it, and finalization is refused while any completeness rule fails. An interrogator, not a generator.
argument-hint: "<intent...> | @draft.md — pipeline re-entry: --from-findings @<register> | --resume @<manifest> | --amend @<manifest> <intent...>"
---

# /spec

Load the `spec` skill (`skills/spec/SKILL.md`) and run it on `$ARGUMENTS`,
following the S1–S7 lifecycle and its seven §4 hard contracts exactly.
Grill-first (ADR 0026): hydrate quickly and start the S2 human interview
within a couple of minutes — no subagent dispatch before the conversation.
Mode is inferred from the arguments per the skill's invocation table:
`--resume` / `--amend` / `--from-findings` / `@draft.md` or bare intent
(Fresh). Use the deterministic `scripts/` (validator, ID allocator, resume
projection, emission-shape gate) rather than reasoning their logic out by
hand.
