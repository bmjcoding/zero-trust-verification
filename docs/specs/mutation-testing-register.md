# Mutation Testing as a First-Class Gate — Build Register (MT-01..MT-11)

> Status: DRAFT r2 (design proposed + adversarially critiqued in the future-scope design
> pass; 7 hardening edits applied) · 2026-07-06
> Governing: ADR 0016 (this capability), ADR 0003 (PR Gate), ADR 0004 (ratcheted blocking),
> ADR 0015 (substrate/uv). Reuses: determinism_gate.sh, repo_shape_probe.sh trap discipline,
> pr_gate.sh run_sibling composition, run_audit.sh ingestion, the root vendored-lint pattern.
> **Shipped posture (Bailey 2026-07-06): report-only first; the CORE-survivor blocking class
> ships comment-only during the ADR-0004 soak and is promoted to blocking per-repo (⟨MT-AMEND-A⟩).**
> Acceptance tags: `[det]` = hermetic self_test/lint assertion; `[drain]` = measured in real drains.

## Dependencies and landing order
Everything it needs is merged (autopilot D6, codebase-health pr_gate.sh, run_audit ingestion,
root lint). Order: MT-01 (adapters) → MT-02 (isolated gate script) → MT-03 (D6.5) →
MT-05/MT-06 (join + cap) → MT-04 (PR-Gate sibling) → MT-07/MT-08 (budget + degrade) →
MT-09 (lint) → MT-10 (reconcile) → MT-11 (self-test).

## Register

### MT-01 — Per-language adapter map: changed-FILES invocation + survivor→location resolver
The cross-language-tooling.md table (mutmut/cosmic-ray · StrykerJS · cargo-mutants · go-mutesting)
gains, per tool: the changed-FILES invocation (all four support a file list) and the
survivor→`file:line` resolver (mutmut needs `mutmut show`, not just `mutmut results`). Honest
tool-capability note: only cargo-mutants (`--in-diff`) and Stryker (`--incremental`) scope at
line/diff level; mutmut + go-mutesting are FILE-granular (the line filter is applied post-hoc, MT-05).
**Acceptance:** `[det]` adapter-map fixture per tool (invocation + a sample tool-output → normalized `file:line` survivor set); a tool with no line resolver degrades to file granularity.

### MT-02 — `scripts/mutation_gate.sh`: runner-agnostic, throwaway-worktree isolated
Modeled on determinism_gate.sh. Takes a resolved tool command + a changed-file list; runs the tool
inside an explicit `git worktree add <throwaway> HEAD` with an EXIT/INT/TERM trap that
`git worktree remove --force`s it; gated behind a clean-index precheck. The live checkout is NEVER
mutated (autopilot loop-safety invariant 1). Emits the normalized survivor set.
**Acceptance:** `[det]` the throwaway worktree is created and torn down even on injected mid-run
failure (trap fires; no leftover worktree, live tree unmodified); clean-index precheck refuses a dirty tree.

### MT-03 — D6.5 anti-vacuous gate (autopilot drain)
New D6.5 after D6.4 (N=5 anti-flaky): runs MT-02 over the Subtask's changed product FILES, filters
survivors to changed LINES (`prev_pushed_sha..HEAD`). A survivor on a changed line →
`[BLOCKED: vacuous-test]` (impl-block counter, `*/30` re-arm, escalate at `max_impl_blocks=3` —
dispatch identical to D6.4's flaky-test). **Self-remediation closure:** the fix MUST be a
strengthened assertion re-verified by D6.5 on the SAME lines; deleting product code at the mutation
point trips D6.2 tdd-scope-leak; editing `gates.test_mutation` is outside the implementer's `owned_files[]`.
**Acceptance:** `[det]` a planted vacuous test (asserts nothing on a changed line a mutant survives) →
`[BLOCKED: vacuous-test]` exit non-zero; a genuinely-constraining test → pass. `[drain]` the fix loop.

### MT-04 — PR-Gate sibling `check_mutation_survivors.sh`
A diff-scoped sibling composed into `pr_gate.sh` via the existing `run_sibling`+`[ -x ]`+`[not-covered]`
pattern. READS the INGESTED report (never runs the tool — this side IS the audit, invariant 1).
Owns its OWN strictness contract (strict-default + `--no-strict`/`WARN_ONLY=1`, mirroring
check_new_debt.sh); pr_gate.sh stays warn-only (exit 0).
**Acceptance:** `[det]` strict-default + both escape hatches on the sibling; aggregation into pr_gate.sh;
no ingested report → adds to Not-covered, never blocks.

### MT-05 — Survivor→changed-line filter + manifest/journeys criticality join
Joins survived mutants against `git diff` changed lines AND the journeys.json trace criticality
(reusing the CH-03 §12 join machinery). A survivor unlocatable to a line degrades to file granularity.
**Acceptance:** `[det]` fixture: survivor on a changed CORE line → flagged; survivor off-diff or on
SUPPORTING/DEV → comment-only; unlocatable survivor → file-granular comment-only.

### MT-06 — Comment-only cap when the trace is absent/degraded (ADR 0004 invariant)
The CORE-survivor class is deterministic *in the join*, but criticality is agent-DERIVED upstream.
Per ADR 0004 (*agent opinion without deterministic evidence never blocks*), this class CAPS AT
COMMENT-ONLY whenever journeys.json is absent, degraded, or criticality is `unknown`. Never guesses criticality.
**Acceptance:** `[det]` absent/degraded/unknown journeys.json → the survivor finding is comment-only
regardless of ADR-0004 soak state.

### MT-07 — Budget caps (affordability backstop for file-granular tools)
D6.5 honors `budget.max_mutants_per_subtask` (default 40) + `budget.max_mutation_seconds` (default 120);
exceeding either → `[note] mutation-budget-exhausted — partial (N of M)`, exit 0, NEVER a false
`[BLOCKED]` (inconclusive ≠ survivor). Defaults are agent-decided (reversible, downstream-verifiable).
**Acceptance:** `[det]` a run exceeding the mutant cap emits the partial `[note]` and exits 0 (no false block).

### MT-08 — Graceful degrade: loud [note], never silent
No tool for the language, or `gates.test_mutation` omitted → D6.5 SKIPS with a loud stderr
`[note] no mutation tool for <lang> — D6.5 anti-vacuous gate skipped (optional)`, exit 0 (like D6.4
skipping the order-randomized round). PR-Gate side: no report → loud `[note]`, mutation facet in
Not-covered, never blocks.
**Acceptance:** `[det]` missing tool → skip `[note]` on stderr, exit 0; the skip is visible, never silent.

### MT-09 — Root lint V7: pin the adapter map + producer/consumer tokens
`lint_consistency.sh` V7 pins the adapter map via a delimited vendored block
(`<!-- vendored:mutation-adapter-map:begin/end -->`, the V5 mechanism) and grep-pins the
`[BLOCKED: vacuous-test]` producer token (autopilot) and the `mutant-on-core-path` consumer token
(PR Gate) so producer and consumer cannot drift.
**Acceptance:** `[det]` V7 red-tested — drift the vendored map, or the token, → V7 fails; revert → green.

### MT-10 — Reconciliation with the ingest-only audit path (no parallel infra)
The audit's whole-repo ingest-only path is unchanged and authoritative for the ambient picture.
One tool family, one adapter map (MT-01, pinned by MT-09), three consumers: D6.5 (produces, drain-side,
trap-isolated), the PR-Gate sibling (consumes the diff scope), run_audit ingestion (whole-repo).
**Acceptance:** `[det]` doc/lint check that no second mutation-runner wrapper exists; MT-01 map is the sole source.

### MT-11 — Self-test + suite wiring
All MT `[det]` assertions land in the relevant plugin self_tests + root `suite_self_test.sh`; the mutation
adapter fixtures are hermetic (sample tool outputs, no real tool run in CI).
**Acceptance:** `[det]` suite_self_test green with the MT assertions; graceful-degrade path covered.

## Escalated to Bailey (per ADR 0002)
- **⟨MT-AMEND-A⟩ (answered 2026-07-06: report-only first)** — the CORE-survivor class ships
  comment-only during the soak; promotion to ADR-0004 blocking is per-repo, async.
- **⟨MT-AMEND-B⟩ (answered 2026-07-06: no score gate)** — no repo-wide or per-diff mutation-SCORE
  threshold gates; the design computes no score (a repo-wide score contradicts the changed-lines
  scoping law and the ADR-0004 new-debt ratchet).

## Non-goals
Whole-repo mutation as a gate (stays owner-run + ingest-only); a standalone mutation plugin (rejected
per ADR 0003 — no fourth checker); running the tool on the live checkout (rejected — invariant 1).
