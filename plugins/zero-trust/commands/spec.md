---
description: Interrogate raw intent (or a draft Spec / Jira / meeting notes) into a product-approvable Spec plus a complete Verification Manifest — walking the manifest schema as a question tree and refusing to finalize while any completeness rule fails. An interrogator, not a generator.
argument-hint: "<intent...> | @draft.md — pipeline re-entry: --from-findings @<register> | --resume @<manifest> | --amend @<manifest> <intent...>"
---

# /spec

Load the `spec` skill (`skills/spec/SKILL.md`) and run it on `$ARGUMENTS`,
following the S1–S7 lifecycle and its seven §4 hard contracts exactly. Mode
is inferred from the arguments per the skill's invocation table: `--resume` /
`--amend` / `--from-findings` / `@draft.md` or bare intent (Fresh; `--profile
<name>` overrides Config-Profile resolution). Use the deterministic
`scripts/` (validator, ID allocator, resume projection, profile resolver,
emission-shape gate) rather than reasoning their logic out by hand.
