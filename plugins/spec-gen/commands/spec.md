---
description: Interrogate raw intent (or a draft Spec / Jira / meeting notes) into a product-approvable Spec plus a complete Verification Manifest — walking the manifest schema as a question tree and refusing to finalize while any completeness rule fails. An interrogator, not a generator.
argument-hint: "[--profile <name>] <intent...> | @draft.md | --resume @<spec>.manifest.yaml | --amend @<spec>.manifest.yaml <intent...>"
---

# /spec

Run the Spec Generation tier's `spec` skill on `$ARGUMENTS`.

Mode is inferred from the arguments (spec skill §2):

- `--resume @<spec>.manifest.yaml` → **Resume** a prior (possibly crashed)
  session: re-validate FIRST, project the validator's exit-3 output into work
  slots, continue the interrogation.
- `--amend @<spec>.manifest.yaml <intent...>` → **Amend** a merged Spec, producing
  `manifest_revision` N+1.
- `@draft.md` or bare `<intent...>` → **Fresh** session. `--profile <name>`
  overrides Config-Profile resolution (flag → `spec-gen.config.yaml` → default).

Then follow the S1–S7 lifecycle in the `spec` skill (`skills/spec/SKILL.md`)
exactly, honouring its §4 hard contracts — refuse-to-finalize, no agent path to
confirmed-CORE, one-writer, one-at-a-time escalations. Use the deterministic
`scripts/` (validator, ID allocator, resume projection, profile resolver,
emission-shape gate) rather than reasoning their logic out by hand.
