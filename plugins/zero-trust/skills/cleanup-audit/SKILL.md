---
name: cleanup-audit
description: "Audit and clean up any large codebase — dead/unused code, deprecated and redundant functions, stale comments/docstrings, AND partially-implemented logic (stubs, placeholders, fake implementations, silent no-ops). Use when auditing codebase health, detecting incomplete logic, or safely deleting dead code. Language-agnostic methodology with per-language tool packs (Python, TypeScript, Rust, Go); deterministic tools paired with LLM judgment."
license: MIT
metadata:
  version: '1.4'
---

# Cleanup Audit

Language-agnostic methodology for cleaning up large codebases. Used directly or invoked by the plugin's commands and agents. It covers four needs no single off-the-shelf tool handles together: **dead/unused code**, **deprecated & redundant code**, **doc/comment hygiene**, and **incomplete logic** — stubs, placeholders, fake implementations, silent no-ops; deterministic tools cannot find these, so LLM judgment is the detector.

## Core Principle

**Tools find evidence. The agent makes the judgment.** Never delete or "complete" anything on tool output alone — especially in a library/SDK, where nothing internal imports a public symbol yet consumers still depend on it.

## Workflow

Detection phases first (cheap/deterministic, then LLM judgment), then safe action. Never mix detection with deletion in the same pass.

### Phase 0 — Orient
Identify the language(s) + package manager, the public API surface, entry points, and dynamic-dispatch points (registries, `getattr`/reflection, self-registering decorators). Record these as **DANGER zones** — tools flag them "unused" but they are NOT safe to delete.

### Phase 1 — Deterministic evidence
Run `scripts/run_audit.sh <package_dir>` — it auto-detects the language and runs the matching tool pack (`references/cross-language-tooling.md`), writing raw evidence into `audit/`: tool results, markers, suppressed diagnostics, test-health candidates, `stdout_logging.txt`, the business-vital/TX seeds (priority inputs, never counted), navigability signals, ratchet counts (`counts.env`), git-history signals, and any existing coverage or mutation report (mutation tools are never run here — pre-existing reports are ingested only). Treat everything as **candidates**, not verdicts.

### Phase 2 — Redundancy & deprecation
Find near-duplicate functions (same logic, different names). Seed from `audit/dup_jscpd.json` when present (absent → a loud `[skip]`; hunt near-dups manually). Flag deprecated-but-still-exported symbols.

### Phase 3 — Incomplete-logic detection (LLM judgment — the key phase)
Read `references/incomplete-logic-taxonomy.md`, then scan (prioritize public API + security/data paths + recently AI-generated code) for each pattern — including **Category LOG** (logging & observability anti-patterns) and **Category TX** (missing transactional integrity). Per finding: `file:line` · category · severity · evidence · suggested fix. Report only — do not auto-fix.

### Phase 3.5 — Architecture & strictness (the "feels clean but isn't" layer)
A codebase can pass strict types + lint with zero dead code and still be **shallow**. Read `references/architecture-and-strictness.md` and apply: the **deletion test**, **"the interface is the test surface"**, **one-adapter-is-hypothetical** seam discipline, and the shallow-module scan. Report shape findings as before/after of the *interface* with **Strong/Worth-exploring/Speculative** strength. A confirmed bug with no correct test seam is itself an architecture finding. (Vocabulary adapted from Matt Pocock's codebase-design skill, MIT.)

### Phase 3.75 — Documented journeys (docs as spec)
Walking a documented workflow end to end is the strongest incomplete-logic detector there is — half-wired integration is nearly invisible file-by-file and obvious traced entry→outcome. The walk is persisted ONCE as `audit/journeys.json` (`references/journey-trace.md`), grading business-vital steps OBSERVED/LOG-ONLY/DARK with an honest alert-seam check (`references/business-vitals.md`) and each journey's branching burden. The plugin's `journey-walker` agent owns this phase.

### Phase 3.8 — Test-suite trustworthiness
A flaky test trains humans to ignore red; a green test that constrains nothing is coverage theater. Read `references/test-health.md` and work from the test-health artifacts as **candidates, not verdicts**, plus any ingested mutation report (survived mutants = top of the queue). The `test-health-auditor` agent owns this phase; ALL test-subject findings live in the `test-health/*` namespace. Severity gates live in `references/severity-rubric.md`.

### Phase 4 — Doc & comment hygiene
Flag docstrings/comments that contradict current code, historical artifacts, commented-out blocks (`audit/commented_code.txt` holds the deterministic slice — judge delete vs. genuine spec-comment). Propose replacements; apply only after review.

### Phase 5 — Safe action (only after report reviewed)
Follow `references/safe-deletion-workflow.md`: grade SAFE/CAUTION/DANGER, green baseline, delete small batches by category, tests between batches, `docs/DELETION_LOG.md`. Public-API symbols get a deprecation cycle, never a direct delete.

### Phase 6 — Verify closure (the loop)
Detection without closure verification is half a loop. Findings get stable fingerprints in `audit/state.json`; after fixes land, `/verify` re-judges every finding with evidence — OPEN / PARTIAL / FIXED / REGRESSED / STALE — and runs the debt ratchet. See `references/audit-state-and-verify.md`. A half-done fix (PARTIAL) is new half-baked code; that verdict is the loop's whole point.

## Completeness discipline
One severity scale for every phase and agent: `references/severity-rubric.md`. Whoever runs phases 3–4 reports a **coverage ledger** (files examined vs. skipped); the orchestrating command re-dispatches over the remainder until nothing is unexamined or two consecutive rounds find nothing new, and the final report carries a mandatory **Not covered** section — "clean" and "unread" must never be conflated. When a real-world defect surfaces that an audit missed, apply the miss-to-fixture rule (`references/audit-state-and-verify.md`): plant it red-first, then fix the detection gap.

## Output
`audit/CLEANUP_REPORT.md` (or `HEALTH_REPORT.md` via the plugin) with sections: Dead Code, Redundancy/Deprecated, Incomplete Logic, Doc Hygiene, and a prioritized SAFE-first action plan. Cite `file:line` for every finding.

When the end-to-end `/audit` command drives this skill, also produce:
- `audit/SPEC.md` — the findings turned into an implementation plan (`references/spec-format.md`).
- `audit/state.json` — fingerprinted findings + run history + ratchet counts (`references/audit-state-and-verify.md`).
- `audit/HEALTH_REPORT.html` — self-contained offline-safe render via `scripts/render_report.py` (pure stdlib; no pip, no CDN).

The loop contracts for routing findings into rework live in `references/remediation-loop.md` (the `/remediate` drip) and `references/health-loop.md` (the `/health-loop` campaign); the audit-side outcome step in `references/outcome-emit.md`; the invariants that keep every loop harmless in `references/loop-safety.md`.

## Scripts
- `scripts/run_audit.sh` — auto-detects language, runs the deterministic pack.
- `scripts/render_report.py` — report markdown → self-contained HTML.
- `scripts/check_new_debt.sh` — prevention ratchet on changed lines. Hook mode always warns and exits 0; the CLI/CI surface gates strict by default (`--no-strict` / `WARN_ONLY=1` escape hatches; stdout never gates).
- `scripts/debt_patterns.sh` — the single source of truth for the shared regexes — sourced by both scripts above and `/verify`'s determinism screen.

## Extending to a new language
Add the tool pack to `references/cross-language-tooling.md` and a detection branch in `scripts/run_audit.sh`. Phases 3–5 are prompt-driven and need no changes.
