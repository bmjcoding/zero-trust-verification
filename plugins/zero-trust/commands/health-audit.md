---
description: Run a full codebase health audit — dead code, redundancy, doc hygiene, incomplete logic, test-suite health, security, performance, architecture, and documented journeys — seven specialist agents producing a prioritized report with measured coverage.
argument-hint: "[subdir] [--focus <area>]"
---

# /health-audit

Run a comprehensive, read-only health audit of the current codebase and produce
`audit/HEALTH_REPORT.md`. Detection only — never delete or modify code in this
command. (For the full pipeline including `SPEC.md`, `state.json`, and the HTML
render, use `/audit`; this command is the report-only subset.)

Parse `$ARGUMENTS`: an optional subdir narrows scope; `--focus <area>` runs a
subset of agents.

## Steps

1. **Detect the stack.** Identify language(s) and package manager from manifests
   (`pyproject.toml`/`setup.cfg`, `package.json`, `Cargo.toml`, `go.mod`) — in the
   target directory for monorepos. Load the matching tool pack from the
   `cleanup-audit` skill's `references/cross-language-tooling.md`.
2. **Orient.** Map the public API surface, entry points, and dynamic-dispatch
   points. Record these as DANGER zones (tools will falsely flag them as unused).
3. **Run the deterministic pass** via the `cleanup-audit` skill (Phase 1) to
   collect raw evidence into `audit/` — including marker/suppression greps,
   git-history signals, the test-health candidates (`test_flakiness.txt`,
   `test_vacuity.txt`, `test_skips.txt`), `stdout_logging.txt` (Category LOG
   candidates), the vitals/TX seeds (`vital_candidates.txt`, `telemetry.txt`,
   `tx_guards.txt`, `tx_retries.txt`, `alerting_config.txt` — priority input,
   never counted), the navigability artifacts (`giant_files.txt`,
   `commented_code.txt`, `dup_jscpd.json`), and any pre-existing coverage or
   mutation report (ingested, never run).
4. **Build the coverage inventory** (`git ls-files` minus vendored paths) — the
   denominator for what "audited" means.
5. **Dispatch the seven specialist agents — journey-walker first.** Dispatch
   `journey-walker` FIRST, as one serialized stage: it writes
   `audit/journeys.json` (schema: `references/journey-trace.md`), the single
   shared trace. Then dispatch the remaining six in parallel.

   **Proceed-on-failure rule:** journey-walker's head start is one dispatch
   turn, not a blocking join — if it errors, or `audit/journeys.json` is
   missing or fails schema validation when its turn completes, dispatch the
   remaining six anyway WITHOUT the trace; consumers apply
   `references/journey-trace.md`'s documented degrade rules (no trace → say so,
   skip journey-scoped facets or cap at MED needs-verification, never guess
   criticality), and journey-walker's own failure goes in the **Not covered**
   section. The other six never wait indefinitely on the trace.

   - `journey-walker` — documented user journeys traced end to end; docs-vs-API drift. Writes `audit/journeys.json`; in the same walk grades business-vital steps OBSERVED/LOG-ONLY/DARK (`references/business-vitals.md`), asks the taxonomy Category TX questions at critical steps (trace-only — never submit twice), and grades branching burden (`journey/path-complexity`).
   - `dead-code-cleanup` — dead/unused/redundant code + doc hygiene (incl. the deletion test for shallow pass-throughs). Consumes `dup_jscpd.json` + `commented_code.txt` as duty-5/6 candidates.
   - `incomplete-logic-detector` — stubs, placeholders, fake implementations, silent no-ops (HIGH only when confirmed reachable), logging anti-patterns (taxonomy Category LOG) — fed `stdout_logging.txt` (candidates, not verdicts).
   - `test-health-auditor` — the test suite audited as its own subject (`references/test-health.md`; all findings `test-health/*`) — fed `test_flakiness.txt` / `test_vacuity.txt` / `test_skips.txt` + any ingested mutation report.
   - `security-auditor` — vulnerabilities, unsafe patterns, secret handling, transactional integrity (taxonomy Category TX) — fed `vital_candidates.txt` / `tx_guards.txt` / `tx_retries.txt`.
   - `performance-analyzer` — hot paths, complexity, allocation/IO issues — measured where possible. Consumes `journeys.json` CORE journeys as confirmed hot paths (missing trace → say so, fall back to heuristics).
   - `architecture-reviewer` — shape: shallow modules, leaky seams, speculative abstractions, extracted-for-testability. Triages `giant_files.txt`.

   Focus mapping: `--focus tests` → test-health-auditor; `--focus transactions`
   → security-auditor + journey-walker; `--focus journeys` unchanged
   (journey-walker).

   Each agent returns a **coverage ledger** (files examined / skipped). Diff the
   union against the inventory and re-dispatch over the remainder until empty or
   two consecutive rounds find nothing new.
6. **Consolidate** all findings into `audit/HEALTH_REPORT.md` with sections per
   agent — including the **Test Health** section (the test-health-auditor's
   `test-health/*` findings on the suite itself) — each finding tagged
   `file:line` · severity (per the skill's
   `references/severity-rubric.md`) · evidence · suggested fix, deduped by
   fingerprint where two agents flag the same symbol (category picked by the
   precedence chain in the skill's `references/audit-state-and-verify.md` —
   defined there and only there, cite it, never restate it). Include the mandatory
   **Not covered** section. Cross-link: where a confirmed bug has no correct test
   seam, note it in BOTH the correctness and architecture sections. End with a
   prioritized, SAFE-first action plan. For confirmed HIGH correctness bugs,
   recommend `/diagnose-bug` to verify + lock down with a regression test before
   fixing — and `/verify` after fixes land to grade closure.
