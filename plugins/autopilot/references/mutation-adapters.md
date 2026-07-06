# Mutation adapters (D6.5 drain-side, ADR 0016 / MT-01)

D6.5 (the anti-vacuous gate, `scripts/mutation_gate.sh`) is the ONLY place in the
suite a mutation tool RUNS — trap-isolated in a throwaway `git worktree` so the
live Story checkout is never mutated (loop-safety invariant 1). To resolve the
tool's survivors to `file:line` it uses `scripts/mutation_adapter.sh`, whose map
is vendored BYTE-IDENTICAL from the codebase-health canonical
(`skills/cleanup-audit/references/cross-language-tooling.md`) and pinned by root
lint V7 (MT-09/MT-10) so the drain PRODUCER and the PR-Gate CONSUMER never drift.

This is the drain-side copy of that map:

<!-- vendored:mutation-adapter-map:begin -->
| tool | lang | changed-FILES invocation | survivor→`file:line` resolver | tool scoping |
|---|---|---|---|---|
| StrykerJS | TS/JS | `npx stryker run --incremental --mutate <files>` | `mutation-report.json`: `files{}.<path>.mutants[]` with `status=="Survived"` → `<path>:<location.start.line>` | LINE (`--incremental`/`--mutate` ranges) |
| cargo-mutants | Rust | `cargo mutants --in-diff <diff>` (or `-f <file>` per changed file) | `mutants.out/missed.txt` line `<file>:<line>:<col>: …` → `<file>:<line>` | LINE (`--in-diff`) |
| mutmut | Python | `mutmut run --paths-to-mutate "<files>"` then `mutmut show` | `mutmut show` unified diff: `+++ <path>` + `@@ -<line>` → `<file>:<line>` (NOT `mutmut results` — IDs only, unlocatable) | FILE at invocation; line POST-HOC |
| go-mutesting | Go | `go-mutesting <changed-packages>` | report `FAIL "<path>[.<idx>]"` (a survived mutant) → `<path>:-` (no line emitted) | FILE (no incremental mode) |

Honest capability (ADR 0016, not laundered): only cargo-mutants (`--in-diff`) and
StrykerJS (`--incremental`) scope at line/diff level at the TOOL. mutmut and
go-mutesting scope to changed FILES; the survivor→changed-LINE filter is applied
POST-HOC in the join (MT-05). A tool that yields no line (go-mutesting) degrades
every survivor to `<path>:-` (file granularity) and caps at comment-only on the
PR side (MT-05/MT-06).

The executable form of this map is `mutation_adapter.sh` (`normalize <tool>` reads
raw tool output on stdin → the normalized `<path>:<line>` survivor set; `invocation
<tool> <files…>`), vendored byte-identical beside every consumer — autopilot D6.5
(produces) and the codebase-health PR-Gate sibling (consumes) — and pinned, with
this block and the `[BLOCKED: vacuous-test]` producer / `mutant-on-core-path`
consumer tokens, by root lint V7 so producer and consumer cannot drift (MT-09).
<!-- vendored:mutation-adapter-map:end -->

See `references/drain-lifecycle.md` §D6.5 for how D6.5 consumes this map, and
`docs/adr/0016-mutation-testing-first-class-gate.md` for the rationale.
