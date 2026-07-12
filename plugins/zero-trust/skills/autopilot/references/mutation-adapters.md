# Mutation adapters (D6.5 drain-side, ADR 0016 / MT-01)

D6.5 (the anti-vacuous gate, `scripts/mutation_gate.sh`) is the ONLY place in the
suite a mutation tool RUNS — trap-isolated in a throwaway `git worktree` so the
live Story checkout is never mutated (loop-safety invariant 1). To resolve the
tool's survivors to `file:line` it calls the CANONICAL resolver
`skills/cleanup-audit/scripts/mutation_adapter.sh` (ADR 0025: one copy — the
old byte-identical vendored sibling and its V7 lint are retired; MT-09/MT-10
sole source). The map itself lives with the resolver:

<!-- vendored:mutation-adapter-map:begin -->
**Mutation adapter map (ADR 0016/0025 — the ONE copy).** Load the canonical map
from `skills/cleanup-audit/references/cross-language-tooling.md` (section
"Mutation adapter map") at the zero-trust plugin root — per tool it gives the
changed-FILES invocation, the survivor→`file:line` resolver, the honest
tool-scoping capability, and the executable resolver
`skills/cleanup-audit/scripts/mutation_adapter.sh` that D6.5 calls.
<!-- vendored:mutation-adapter-map:end -->

See `references/lifecycle.md` §D6.5 for how D6.5 consumes this map, and
`docs/adr/0016-mutation-testing-first-class-gate.md` for the rationale.
