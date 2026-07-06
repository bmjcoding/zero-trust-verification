---
description: Review codebase shape — find shallow modules, leaky seams, speculative abstractions, and tests that pass while bugs hide in how code is called.
argument-hint: "[subdir or module]"
---

# /architecture

`$ARGUMENTS`: an optional subdir or module narrows scope.

Review the **shape** of the codebase, not just its correctness. For the skeptical engineer whose code passes strict types + lint + has no dead code but still feels off — this is the layer that catches what those miss.

## Steps
1. Read `cleanup-audit` skill → `references/architecture-and-strictness.md` and adopt its vocabulary exactly (module, interface, depth, seam, adapter, leverage, locality).
2. If present, read `CONTEXT.md` (domain glossary) and `docs/adr/` first — use domain names for modules and don't re-litigate recorded decisions.
3. Invoke the `architecture-reviewer` agent to explore organically and apply the strictness tests: deletion test, "interface is the test surface", "one adapter = hypothetical seam / two = real", shallow-module scan, accept-deps-return-results.
4. Report each finding as a before/after of the **interface** with severity (per the skill's `references/severity-rubric.md`) + a **Strong / Worth exploring / Speculative** strength label, tied to locality, leverage, and testability.

Optionally render the findings as a visual before/after HTML report (Pocock's improve-codebase-architecture style) if the user wants it. Detection only — propose, don't refactor.
