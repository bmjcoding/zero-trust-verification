---
description: Find and (with approval) safely remove dead, unused, and redundant code using tool evidence plus a graded deletion workflow.
argument-hint: "[subdir] [--remove]"
---

# /dead-code

`$ARGUMENTS`: an optional subdir narrows scope; `--remove` requests the
removal workflow (otherwise report-only).

## Steps

1. Detect the stack and load the matching tool pack (`cleanup-audit` skill →
   `references/cross-language-tooling.md`).
2. Run the deterministic evidence pass (Phase 1). All output is
   **candidates**.
3. Invoke the `dead-code-cleanup` agent to triage candidates against the
   public API surface and dynamic-dispatch points.
4. Only if the user asked to remove: follow `cleanup-audit` skill →
   `references/safe-deletion-workflow.md` — grade SAFE/CAUTION/DANGER, green
   baseline, small SAFE-first batches, tests between batches,
   `docs/DELETION_LOG.md`.

Severity for any implied defect follows the skill's
`references/severity-rubric.md` (deletion grades are a separate axis). Never
delete public-API symbols without a deprecation cycle. Never mix deletion
with behavior refactors in one batch.
