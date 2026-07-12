---
description: Review codebase shape — find shallow modules, leaky seams, speculative abstractions, and tests that pass while bugs hide in how code is called.
argument-hint: "[subdir or module]"
---

# /architecture

`$ARGUMENTS`: an optional subdir or module narrows scope.

Review the **shape** of the codebase, not just its correctness — the layer
that catches what strict types + lint + zero dead code still miss.

## Steps
1. If present, read `CONTEXT.md` (domain glossary) and `docs/adr/` first —
   use domain names for modules and don't re-litigate recorded decisions.
2. Invoke the `architecture-reviewer` agent; its file carries the strictness
   tests, the Fowler smell baseline, and the output contract (severity per
   the `cleanup-audit` skill's `references/severity-rubric.md`, strength
   labels, interface before/after).
3. Relay the findings. Optionally render a visual before/after HTML report if
   the user wants it. Detection only — propose, don't refactor.
