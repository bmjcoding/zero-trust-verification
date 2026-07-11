---
name: cleanup-audit
description: "Audit and clean up any large codebase: find dead/unused code, deprecated and redundant functions, messy historical comments and docstrings, AND partially-implemented logic (stubs, placeholders, fake implementations, silent no-ops). Use when cleaning up a codebase, finding unused/deprecated code, detecting incomplete logic, reducing redundancy, or safely deleting dead code. Language-agnostic methodology with per-language tool packs (Python, TypeScript, Rust, Go). Pairs deterministic tools with LLM judgment for what tools cannot catch."
license: MIT
metadata:
  version: '1.4'
---

# Cleanup Audit

Language-agnostic methodology for cleaning up large codebases. Used directly or invoked by the `codebase-health` plugin's commands and agents.

## When to Use This Skill

Cleaning up any codebase that has grown over time. Covers four needs no single off-the-shelf tool handles together:

1. **Dead / unused code** — modules, functions, classes, exports never referenced.
2. **Deprecated & redundant** — superseded code, duplicate implementations of the same logic.
3. **Doc/comment hygiene** — stale docstrings/comments, historical "we used to..." notes, correction trails.
4. **Incomplete logic** (the hard one) — stubs, placeholders, fake implementations, silent no-ops, `NotImplementedError`, unhandled cases. Deterministic tools cannot find these; this requires LLM judgment.

## Core Principle

**Tools find evidence. The agent makes the judgment.** Never delete or "complete" anything on tool output alone — especially in a library/SDK, where the public API surface means nothing internal imports a symbol yet consumers still depend on it.

## Workflow

Four detection phases (cheap/deterministic first, then LLM judgment), then safe action. Never mix detection with deletion in the same pass.

### Phase 0 — Orient
Identify the language(s) + package manager, the public API surface (exports/`__all__`/`pub`/documented API), entry points (console scripts, `bin`, plugin registrations), and dynamic-dispatch points (registries, `getattr`/reflection, decorators that register). Record these as **DANGER zones** — tools flag them "unused" but they are NOT safe to delete.

### Phase 1 — Deterministic evidence (run in parallel)
Run `scripts/run_audit.sh <package_dir>` — it auto-detects the language and runs the matching tool pack (see `references/cross-language-tooling.md`), writing raw output into `audit/`: tool results, incompleteness markers, **suppressed diagnostics** (`suppressions.txt`), test-health candidates (`test_flakiness.txt`, `test_vacuity.txt`, `test_skips.txt`), stdout-as-log-channel candidates (`stdout_logging.txt`), business-vital/transaction seeds (`vital_candidates.txt`, `telemetry.txt`, `tx_guards.txt`, `tx_retries.txt`, `alerting_config.txt` — priority inputs, never counted), navigability signals (`giant_files.txt`, `commented_code.txt`, `dup_jscpd.json` when jscpd is installed), ratchet counts (`counts.env`), git-history signals (WIP commits, churn), and any existing coverage or mutation report (mutation tools are never run here — pre-existing reports are ingested only). Treat everything as **candidates**, not verdicts. Python: vulture, ruff (incl. `C901` complexity), deptry, bandit (deadcode/radon optional). TS: knip, ts-prune, depcheck. Rust: cargo udeps, cargo machete, clippy. Go: deadcode, staticcheck.

### Phase 2 — Redundancy & deprecation
Find near-duplicate functions (same logic, different names — common as code accretes). Seed the hunt from `audit/dup_jscpd.json` when present (jscpd is optional on target repos; a loud `[skip]` in the Phase 1 output means hunt near-dups manually). Flag deprecated-but-still-exported symbols (`@deprecated`, `DeprecationWarning`, "legacy"/"use X instead" docs).

### Phase 3 — Incomplete-logic detection (LLM judgment — the key phase)
The piece off-the-shelf tools miss. Read `references/incomplete-logic-taxonomy.md`, then scan (prioritize public API + security/data paths + recently AI-generated code) for each pattern. The taxonomy includes **Category LOG** (logging & observability anti-patterns — stdout as log channel, log-and-swallow, missing structured logging/correlation IDs; `audit/stdout_logging.txt` supplies candidates, not verdicts) and **Category TX** (missing transactional integrity — idempotency/dedup guards, unsafe retries, compensation, audit trails; seeded from `vital_candidates.txt ∩ tx_retries.txt − tx_guards.txt`). Per finding: `file:line` · category · severity · evidence · suggested fix. Report only — do not auto-fix.

### Phase 3.5 — Architecture & strictness (the "feels clean but isn't" layer)
The phase for skeptics. A codebase can pass strict types + lint with zero dead code and still be **shallow**. Read `references/architecture-and-strictness.md` and apply: the **deletion test** (does removing this concentrate complexity or just move it?), **"the interface is the test surface"** (flag pure functions extracted only for testability where bugs hide in how they're called), **one-adapter-is-hypothetical** seam discipline, and the shallow-module scan. Report shape findings as before/after of the *interface* with **Strong/Worth-exploring/Speculative** strength. Where a confirmed bug has no correct test seam, that absence is itself an architecture finding. (Vocabulary adapted from Matt Pocock's codebase-design skill, MIT.)

### Phase 3.75 — Documented journeys (docs as spec)
Walking a documented workflow end to end is the strongest incomplete-logic detector there is — half-wired integration is nearly invisible file-by-file and obvious traced entry→outcome. Inventory every journey the docs promise (README quickstart, guides, examples, docstring examples), trace each through the code, execute the safe ones, and diff docs against the actual API surface. The walk is persisted ONCE as `audit/journeys.json` (`references/journey-trace.md` — schema, CORE/SUPPORTING/DEV criticality ladder, degrade rules), and the same walk grades each business-vital step OBSERVED/LOG-ONLY/DARK with an honest alert-seam check (`references/business-vitals.md`) and each journey's branching burden (`journey/path-complexity` — severity weighted by journey criticality, never by raw metric value). The plugin's `journey-walker` agent owns this phase.

### Phase 3.8 — Test-suite trustworthiness (the safety net as its own subject)
A flaky test trains humans to ignore red; a green test that constrains nothing is coverage theater. Read `references/test-health.md` (nondeterminism T1–T7, vacuity T8–T12) and work from `audit/test_flakiness.txt`, `test_vacuity.txt`, `test_skips.txt` as **candidates, not verdicts**, plus any ingested mutation report (survived mutants = top of the queue; mutation tools are owner-run, never run by this workflow). The plugin's `test-health-auditor` agent owns this phase; ALL test-subject findings live in the `test-health/*` namespace (incomplete-logic Category B stays scoped to non-test code). Severity caps: never CRITICAL; HIGH requires demonstrated nondeterminism (bounded read-only probe — single test, ≤10 repeats, never destructive) or vacuity-by-construction plus sole coverage of a public-API/security/data-write symbol; everything else caps at MED needs-verification.

### Phase 4 — Doc & comment hygiene
Flag docstrings/comments that contradict current code, historical artifacts ("previously...", old-ticket TODOs), commented-out blocks (`audit/commented_code.txt` holds the deterministic slice — judge delete vs. genuine spec-comment), correction trails. Propose replacements; apply only after review.

### Phase 5 — Safe action (only after report reviewed)
Follow `references/safe-deletion-workflow.md`: grade SAFE/CAUTION/DANGER, ensure a green baseline, delete small batches by category (SAFE first), run the full test+build between batches, keep `docs/DELETION_LOG.md`. Public-API symbols go through a deprecation cycle, never a direct delete.

### Phase 6 — Verify closure (the loop)
Detection without closure verification is half a loop. Findings get stable fingerprints in `audit/state.json`; after fixes land, `/verify` re-judges every finding with evidence — OPEN / PARTIAL / FIXED / REGRESSED / STALE — and runs the debt ratchet (marker/suppression counts must not creep). See `references/audit-state-and-verify.md`. A half-done fix (PARTIAL) is new half-baked code; that verdict is the loop's whole point.

## Completeness discipline
Severity requirements live in `references/severity-rubric.md` — one scale for every phase and agent. Whoever runs phases 3–4 must report a **coverage ledger** (files examined vs. skipped); the orchestrating command re-dispatches over the remainder until nothing is unexamined or two consecutive rounds find nothing new, and the final report carries a mandatory **Not covered** section. "Clean" and "unread" must never be conflated. When a real-world defect surfaces that an audit missed, apply the miss-to-fixture rule (`references/audit-state-and-verify.md`): plant it in `test-fixtures/` red-first, then fix the detection gap.

## Output
`audit/CLEANUP_REPORT.md` (or `HEALTH_REPORT.md` when run via the plugin) with sections: Dead Code, Redundancy/Deprecated, Incomplete Logic, Doc Hygiene, and a prioritized SAFE-first action plan. Cite `file:line` for every finding.

When the end-to-end `/audit` command drives this skill, also produce:
- `audit/SPEC.md` — the findings turned into an implementation plan. Read `references/spec-format.md`: SAFE-first waves, one revertable change per item, a Status field, and a mandatory regression-test seam (a missing seam is itself an architecture finding, not an excuse for an untestable patch).
- `audit/state.json` — fingerprinted findings + run history + ratchet counts (`references/audit-state-and-verify.md`).
- `audit/HEALTH_REPORT.html` — a self-contained visual view via `scripts/render_report.py` (pure stdlib; no pip, no CDN — safe offline). Reading HTML beats reading markdown for human review.

## Reference files
- `references/incomplete-logic-taxonomy.md` — the Phase 3 detection catalog (language-agnostic, per-language example tables).
- `references/architecture-and-strictness.md` — Phase 3.5 deep-module vocabulary + deletion test + seam discipline (Pocock-adapted, MIT).
- `references/journey-trace.md` — the Phase 3.75 shared trace: `audit/journeys.json` schema, criticality ladder, degrade rules.
- `references/business-vitals.md` — vital classes, OBSERVED/LOG-ONLY/DARK emission grading, alerting-seam checklist.
- `references/test-health.md` — the Phase 3.8 catalog: nondeterminism T1–T7 + vacuity T8–T12, bounded-probe protocol, closure rules.
- `references/feedback-loop-diagnosis.md` — turning a suspected bug into a verified, regression-tested fix (Pocock-adapted, MIT).
- `references/safe-deletion-workflow.md` — Phase 5 grading + DELETION_LOG discipline.
- `references/audit-state-and-verify.md` — Phase 6: fingerprints, `state.json` schema, status lifecycle, ratchet, miss-to-fixture rule.
- `references/severity-rubric.md` — the single severity scale + confirmation gates for every agent and phase.
- `references/loop-safety.md` — the invariants that keep an automated audit loop from ever damaging a codebase.
- `references/cross-language-tooling.md` — per-language tool packs (Python/TS/Rust/Go) + notes on porting trade-offs.
- `references/spec-format.md` — the findings→implementation-spec template used by `/audit` to generate `SPEC.md`, plus the FIX_LOG discipline.

## Scripts
- `scripts/run_audit.sh` — auto-detects language and runs the matching deterministic tool pack.
- `scripts/render_report.py` — renders a report markdown into a self-contained, offline-safe HTML view (`python3 render_report.py audit/HEALTH_REPORT.md -o audit/HEALTH_REPORT.html`).
- `scripts/check_new_debt.sh` — prevention ratchet: flags newly introduced debt in changed lines — markers, suppressions, flaky/vacuous/skipped test lines, stdout logging, commented-out blocks. Hook mode always warns and exits 0; the CLI/CI surface gates strict by default (`--no-strict` / `WARN_ONLY=1` escape hatches; stdout never gates).
- `scripts/debt_patterns.sh` — the single source of truth for the shared regexes (markers, suppressions, `TEST_PATH_RE`, flaky/vacuous/skip, stdout-logging, commented-block) — sourced by both scripts above and `/verify`'s determinism screen.

## Extending to a new language
Add the deterministic tool pack to `references/cross-language-tooling.md` and a detection branch in `scripts/run_audit.sh`. Phases 3–5 (incomplete logic, doc hygiene, safe deletion) are prompt-driven and need no changes — they work the same in every language.
