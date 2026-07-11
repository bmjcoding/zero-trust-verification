---
description: Find and (with approval) safely remove dead, unused, and redundant code using tool evidence plus a graded deletion workflow.
argument-hint: "[subdir] [--remove]"
---

# /dead-code

`$ARGUMENTS`: an optional subdir narrows scope; `--remove` requests the removal
workflow (otherwise report-only).

Find dead/unused/redundant code, then optionally remove it safely.

## Steps

1. Detect stack and load the matching tool pack (`cleanup-audit` skill → `references/cross-language-tooling.md`).
2. Run the deterministic evidence pass (Phase 1). Treat all output as **candidates**.
3. Invoke the `dead-code-cleanup` agent to triage candidates against the public API surface and dynamic-dispatch points.
4. If the user asks to remove (not just report): follow `cleanup-audit` skill → `references/safe-deletion-workflow.md` — grade SAFE/CAUTION/DANGER, ensure a green baseline, delete in small SAFE-first batches, run tests/build between batches, and write `docs/DELETION_LOG.md`.

Severity for any implied defect follows the skill's `references/severity-rubric.md` (deletion grades SAFE/CAUTION/DANGER are a separate axis).

Never delete public-API symbols without an explicit deprecation cycle. Never mix deletion with behavior refactors in one batch.
