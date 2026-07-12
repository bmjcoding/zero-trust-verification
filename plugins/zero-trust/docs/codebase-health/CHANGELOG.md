# Changelog

## Unreleased — /health-loop attended wave drain (ADR 0024, register HL-01..HL-03)

The audit tier gains its campaign mode: `/health-loop` drains a whole
`audit/SPEC.md` wave by wave — per-wave autopilot drain, merge (operator-
approved, or delegated for auto-class waves under the double-keyed
`merge: preauthorized` hatch), `/verify --strict` + `wave_gate.sh` at every
boundary — until the original audit is drained. Merge-before-verify is a
correctness rule (`/verify` grades the checkout); depth 0 (the loop never
re-fixes); stateless position (SPEC.md × state.json × tracker STATUS) with an
append-only `audit/loop_log.md` journal. No changes to `/verify`, autopilot,
or the Marshal.

- **`spec_wave.sh`** (HL-01) — deterministic SPEC.md wave parser:
  `waves` / `slice` (byte-preserving, `audit/waves/wave-<N>.md`) /
  `fingerprints` / `forward-deps` (refuses forward AND unresolvable deps,
  digit-leading TAGs caught); exits 3 wave-less / 4 absent / 5 fingerprint-less
  / 6 empty / 7 unwritable — all loud, never guessed.
- **`wave_gate.sh` + `wave_gate.py`** (HL-02) — pure-reader advance gate over
  `state.json`: 0 ADVANCE / 2 INCOMPLETE / 3 REGRESSION-or-RATCHET (REGRESSED
  scanned globally, never wave-scoped) / 4 UNREADABLE incl. spec↔state desync /
  64 usage. Ratchet mirrors `/verify`: prior same-target baseline preferring
  the last audit run (falling back to a prior verify), absent counts never read
  as 0, `stdout_logging_count` report-only. Never writes state (grep-pinned).
- **`wave_preauth_check.sh`** (HL-03) — the P1–P4 evidence bar a Story PR must
  clear before the loop may exercise delegated approval: tracker DRAINED, every
  Story Subtask `[x]`, no `[BLOCKED:]` history for the story, changed files ⊆
  the Runbook PR's predicted file surface (exact-match allow-list — patch
  droppings like `FIX_LOG.md.orig` never ride an allowance). Disk evidence
  only; never calls the host. D6.2 commit-shape deliberately NOT re-run
  (per-Subtask ranges; a whole-Story re-audit would false-flag tdd-scope-leak).
- **`/health-loop` command** + `references/health-loop.md` +
  `loop.config.yaml` — posture, dispatch table, merge step, gate routing,
  failure ownership, `/remediate` "Which loop?" boundary (drip vs drain,
  Guard-1 stamping with `health-loop:` ref prefix; unattended firing stays
  behind `/remediate`'s ADR-0004 eligibility path).

## Unreleased — PR Gate + Verification-Manifest integration (register CH-01..CH-10)

The audit tier gains its step-4-checker deltas: a diff-scoped **PR Gate mode**
and **Verification-Manifest** consumption. All read-only, warn-only, degrade-to-
less; the 1.4.0 posture and the eight ratchets are untouched. Manifest artifacts
(validator + schema) are CONSUMED, never re-authored (ADR 0001).

- **Manifest ingestion + consumer degrade** (CH-01) — `ingest_manifest.sh` emits a
  `MODE` token (COMPLETE/INCOMPLETE/ABSENT/SCHEMA-INVALID/UNSUPPORTED) off the
  vendored `validate_manifest.sh` exit code; the MS §11 degrade table is verbatim
  (schema-invalid is a defect, never degraded to manifest-less; every non-complete
  MODE surfaces both manifest facets in Not-covered — no silent skip).
- **`journeys.json` v2** (CH-02) — additive `manifest_journey_id` (journey) +
  `event_name` (step), the MS §12 join keys; a v1 file still parses (missing field
  ≠ corrupt). `references/journey-trace.md` bumped to schema v2.
- **§12 intended↔discovered comparator** (CH-03) — `manifest_join.sh`/`.py` joins
  intent to discovery every MS §12 row, full truth tables (OBSERVED/LOG-ONLY/DARK
  + paged←paged seam lattices, env-collapse, idempotency, criticality drift).
  Two fingerprint scopes: step `path:symbol:slug` and journey-scoped
  `<source-no-line>:<name>:slug` (⟨CH-AMEND-A⟩).
- **PR Gate diff-scoped mode** (CH-04) — `pr_gate.sh` composes the diff surface
  from the existing positional-BASE_REF `check_new_debt.sh` plus new sibling
  scripts; never runs a whole-repo walk or writes `journeys.json`; no `--diff`
  flag added (the arg-parser contract is asserted).
- **Memory-rot facet, deterministic layer** (CH-05) — `check_memory_rot.sh` flags a
  deleted symbol still referenced by manifest/journeys/docs/ADRs
  (`memory-rot-dangling-ref`, ADR-0004 blocking); `lifecycle:withdrawn` tombstones
  suppress; renames are aliased, not flagged.
- **Behavior-ID coverage** (CH-06) — `check_behavior_coverage.sh` verifies PR-body
  `## Behavior coverage` claims against RED-commit + test-node proof (evidence, not
  self-report); unproven → ADR-0004 blocking; manifest-absent → skip + `[note]`.
- **SG-8 provenance + main-lineage ID reservation** (CH-07) — `check_provenance.sh`
  flags manifest single-writer edits from non-spec branches (comment-only,
  ⟨CH-AMEND-C⟩) and reserves IDs on main's lineage only (⟨MS-AMEND-3⟩).
- **Config-profile absence-severity** (CH-08) — the join reads
  `observability.profile` by name, degrades unknown → `default` + `[note]`, and the
  1.4.0 severity cap holds regardless of profile (a profile never lifts the ceiling).
- **History checks** (CH-09) — `check_manifest_history.sh`: `spec_hash` recompute
  (comment-only rot, MS §9), `manifest_revision` monotonicity, and ID
  reuse/renumber/tombstone-reuse (MS §11 blocking) vs prior main-lineage revisions.
- **Consistency-lint host + self-test growth** (CH-10) — repo-level
  `scripts/lint_consistency.sh` (schema byte-identity + the shared `## Behavior
  coverage` format, one canonical `docs/specs/behavior-coverage-format.md`);
  self-test 138 → 255 assertions (23 sections; manifest-reading ones `[skip]`
  loudly without the validator); `pr_gate_expected` register added to
  `EXPECTED_FINDINGS.yaml`.
- **uv migration** (ADR 0015) — the plugin's Python (`run_audit.sh`,
  `check_new_debt.sh`, `self_test.sh`) routes through a uv-first `pyrun`/`PYRUN`
  helper against a minimal plugin `pyproject.toml`, python3 fallback preserved.

## 1.4.0 — the test-health & observability release

Driven by five verified gaps: no mechanism audited target test suites for nondeterminism or vacuity (the taxonomy actively exempted tests); a flaky closing test could round a finding up to FIXED; stdout-as-log-channel, missing business-event instrumentation, and missing idempotency guards were invisible; journeys were traced for correctness only; and slop (giant files, clones, commented-out blocks, lying names) taxed the highest-volume maintainer — the coding agent — unmeasured. Accepted spec: `docs/SPEC_1.4.0.md`.

- **Seventh agent: `test-health-auditor`** — the test suite audited as its own subject. New `references/test-health.md` (nondeterminism T1–T7, vacuity/coverage-theater T8–T12); shared `TEST_PATH_RE`/`FLAKY_RE`/`TEST_VACUOUS_RE`/`TEST_SKIP_RE` in `debt_patterns.sh` (detector, hook, and `/verify` cannot drift); `audit/test_flakiness.txt`/`test_vacuity.txt`/`test_skips.txt` + three ratchet counts; bounded-probe confirmation gate (single tests, N≤10, never destructive — and snapshot/golden runners probed only in no-write mode, the runner's own writes count); mutation reports ingested (never run) as the gold-standard vacuity evidence. Category B stays scoped to non-test code — test findings now have one owner.
- **Closing-test determinism gate in `/verify`** — closing tests rerun 5× in fresh processes (order-randomized once) + `FLAKY_RE` screen; any red, unrunnable test, or unmitigated hit grades PARTIAL, never FIXED; `verified_by` records the rerun count. Loop-safety **invariant 9**: a flaky gate is no gate — deterministic planted assertions must fail red on two consecutive self-test runs before detector work (agent-scored plants are covered by the blind-eval recurrence rule). Phase-5 anti-flakiness checklist in `feedback-loop-diagnosis.md`.
- **Observability lens** — taxonomy **Category LOG** (word-key — letters freeze at A–G because H is the severity letter in tags like `IL-H1`): stdout-as-log-channel, log-and-swallow, sensitive-data-in-logs CWE-532, missing structured logging/correlation IDs — absence findings HARD-capped MED needs-verification by an explicit rubric amendment, with `journey/uninstrumented` reaching HIGH only via a traced CORE money-movement/auth path; `LOGGING_RE` + `audit/stdout_logging.txt` + ratchet count (report-only, never gates strict); security-auditor Logging bullet (CWE-532/778).
- **Transactional integrity** — taxonomy **Category TX** (idempotency/dedup guards, unsafe retries, double-submit, compensation, audit trails); vital/guard/retry seed greps (candidates — never counted, never hooked); security-auditor + journey-walker shared ownership; CRITICAL still requires naming who delivers the duplicate.
- **One journey trace, three facets** — journey-walker dispatched first, persists `audit/journeys.json` (`references/journey-trace.md`: schema, CORE/SUPPORTING/DEV criticality ladder, degrade-to-no-trace rule); in a single walk it grades business-vital steps OBSERVED/LOG-ONLY/DARK with an honest alert-seam check (`references/business-vitals.md`), asks the arrives-twice/dies-between-steps questions at critical steps (trace-only, never submitted twice), and grades branching burden (`journey/path-complexity`, criticality-weighted — a C901 on the order path outranks the same metric in a debug helper). performance-analyzer consumes the trace as its hot-path source.
- **AI-navigability slop pack** — file-size ladder (400/800/1600) → `giant_files.txt`; commented-out-block detector (leader-anchored, shared via `debt_patterns.sh`) → `commented_code.txt`; jscpd clone row (optional on target repos with a loud `[skip]` degrade; REQUIRED dev dependency for the suite's own self-test) → `dup_jscpd.json`; token-burn/missed-edit/hallucinated-context/definition-of-done reframe in `architecture-and-strictness.md`; two new ratchet counts.
- **Prevention hook** gains flaky/vacuity/skip/stdout/commented-block warn sections — the hook surface still exits 0 always (loop-safety invariant 3, untouched); the CLI/CI surface of `check_new_debt.sh` is now strict by DEFAULT on the fixture-locked classes (stdout never gates), with documented `--no-strict`/`WARN_ONLY=1` escape hatches.
- **All agents inherit the session model** — the `model:` frontmatter pins (one `opus`, five `sonnet`) are removed from every agent; the seventh ships without one. No downgrades: the roster runs on whatever frontier model the session runs on.
- **Blind-corpus generator fixed** — `make_blind_corpus.sh`'s strip is now case-sensitive and word-bounded (`\bPLANTS?\b` etc.); it no longer deletes lines containing `planted_pkg`, so blind copies keep their imports and the J1 README journey is scoreable blind for the first time since it was planted.
- **Ground truth grew red-first, and more of it is machine-scored**: fixtures TF1–TF10, TQ1–TQ8, LG1–LG5, SEC3, TX1–TX3, J3–J5, V1–V3, JC1–JC2, GF1, ND1, CO1, MN1 + must_not_flag N3–N11 (+ N2/X1 extensions) + expected_noise EN1–EN4; self-test 38 → 128 assertions (+3 ruff-conditional, 131 with ruff installed). The determinism sweep (spec §12) flipped ND1, J3, and J4 to deterministic primary scoring; the remaining 17 agent-scored plants are scored by the manual blind-corpus eval (`make_blind_corpus.sh`), never claimed as self-test coverage, and re-running that eval after any agent-prompt/taxonomy/reference change is a hard release-checklist item. Full register: `docs/GAPS_SPEC.md` → 1.3.0 → 1.4.0.

## 1.3.0 — the closed-loop release

Driven by a real-world escape: a first audit's findings were "addressed," yet
manual documentation work later surfaced missed stubs, TODOs, and perf debt.
Root cause: the suite was a one-shot detector — no coverage accounting, no fix
verification, no journey dimension, no prevention. Full gap register with
acceptance criteria: `docs/GAPS_SPEC.md`.

- **`/verify` — fix verification (the back half of the loop).** Findings get stable
  fingerprints (`path:symbol:slug`; category is metadata) persisted in `audit/state.json`
  (schema-versioned, corrupt→first-run). `/verify` re-judges each: OPEN / PARTIAL /
  FIXED / REGRESSED / STALE — FIXED requires evidence (`verified_by`), and
  "looks fixed, no test" is PARTIAL by definition. Debt ratchet on
  marker/suppression counts. New reference: `audit-state-and-verify.md`.
- **Coverage ledger + loop-until-dry.** Every agent reports files examined vs
  skipped; `/audit` diffs against a `git ls-files` inventory and re-dispatches
  over the remainder until dry. Mandatory **Not covered** report section —
  "clean" and "unread" are never conflated. Sharding guidance for large repos.
- **New `journey-walker` agent (the sixth).** Docs/README/examples are treated as
  the spec: every documented workflow traced (and where safe, executed)
  entry→outcome; docs-vs-API drift. Broken quickstart = HIGH by default.
- **Dynamic evidence.** Coverage-report ingestion in all four tool packs
  (uncovered branches = incomplete-logic priority); `performance-analyzer` is
  measure-first (HIGH requires a number); `incomplete-logic-detector` gets Bash
  to *execute* reachability probes.
- **Adversarial verification of HIGH+** findings from every agent (was: only
  incomplete-logic), with downgrade-not-drop semantics.
- **Prevention between audits.** Warn-only `check_new_debt.sh` (+ PostToolUse
  hook wiring) flags newly introduced markers/suppressions in changed lines;
  `--strict` available as an opt-in CI gate. Patterns shared with the audit via
  `debt_patterns.sh` — detector and hook cannot drift.
- **Detection blind spots closed.** Marker grep now case-insensitive and covers
  the full taxonomy list (incl. "for now", WIP, TBD, PLACEHOLDER); vendored/build/
  audit dirs excluded (no more run-N poisoning run-N+1); new suppression scan
  (noqa/ts-ignore/allow/nosec/nolint → taxonomy **Category G**); per-language
  incomplete-logic idiom table (TS/Rust/Go); git-history signals (WIP commits,
  churn hotspots).
- **Mechanical fixes.** Monorepo-safe stack detection (manifests in TARGET);
  knip stderr no longer corrupts its JSON; gitleaks scans the target; renderer
  pills now render for the `### [SEVERITY]` finding format (with a
  false-positive guard) and pipe-in-prose can't be misparsed as a table; one
  severity rubric (`severity-rubric.md`) + confirmation gates for every agent;
  fingerprint-based dedup across agents; `$ARGUMENTS`/`argument-hint` wired in
  all commands.
- **Loop safety invariants** (`loop-safety.md`): detection never mutates; hooks
  warn, never block; broken state degrades to less action; silent truncation is
  a defect. A flawed loop can cost wrong reports, never damaged code.
- **Ground truth.** Planted-defect corpus (`test-fixtures/planted/` +
  `EXPECTED_FINDINGS.yaml`: every category, exclusion traps, a must-not-flag
  dynamic-dispatch decoy, a broken documented journey) and `scripts/self_test.sh`
  (25 assertions) for the deterministic layer. **Miss-to-fixture rule:** every
  real-world escape is planted red before its detection fix lands.
- Spec items now carry `Status` + fingerprint; new `docs/FIX_LOG.md` discipline
  mirrors `DELETION_LOG.md` for fixes.
- **Hardened by adversarial review before release.** Three independent
  author-blind agents audited the redesign; everything they found was fixed with
  a red-first regression fixture (self-test: 25 → 38 assertions). Highlights:
  the prevention hook now emits `hookSpecificOutput.additionalContext` JSON
  (plain stdout never reaches the model) and scans untracked files whole (a
  brand-new file has no diff); an unresolvable base ref is loud and fails
  `--strict` instead of silently passing; marker regexes are word-boundary
  anchored (on_swipe/HACKATHON/XXXL/stubborn no longer count as debt) with
  precision fixtures; the answer-key manifest moved out of the scanned corpus
  (assertions were passing off the manifest, not the plants); fingerprints are
  `path:symbol:slug` with category as metadata (five markers on one function are
  five findings, not one; cross-agent dedup actually works); the ratchet only
  compares same-target runs against the last audit baseline; FIXED-via-removal
  requires a FIX_LOG/DELETION_LOG entry naming the finding (a bare deletion
  commit is STALE, not FIXED); findings a re-audit fails to re-detect stay OPEN;
  renderer table cells keep `a | b` code spans intact and single-pipe prose
  stays prose; excluded-dir collisions (a real `audit/`/`build/` source dir) are
  recorded for Not-covered instead of vanishing. Full register:
  `docs/GAPS_SPEC.md` → Closure status.

## 1.2.0
- **One command, end to end: `/audit`.** Detects the stack, runs the deterministic pass, dispatches all five agents in parallel, and produces three artifacts:
  - `audit/HEALTH_REPORT.md` — every finding (`file:line` · severity · evidence · fix), with a consolidated HIGH-and-above table.
  - `audit/SPEC.md` — the findings turned into an implementation-ready, SAFE-first wave plan; every item carries a regression-test seam.
  - `audit/HEALTH_REPORT.html` — a self-contained visual render for human review.
- **New `scripts/render_report.py`** — pure-stdlib markdown→HTML renderer. No pip, no CDN; safe in offline/locked-down environments. Severity words auto-render as colored pills; sticky TOC sidebar; print styles. Optionally renders `SPEC.html` too.
- **New reference `spec-format.md`** — the findings→spec template: wave ordering by reversibility, one revertable change per item, and a mandatory test seam (a missing seam becomes an architecture finding rather than an untestable patch).
- `--no-html` and `--spec-only` flags on `/audit`.

## 1.1.0
- **Strictness layer added** (for codebases that pass lint/types but still feel off):
  - New `architecture-reviewer` agent — shallow modules, leaky seams, speculative abstractions, pure-functions-extracted-for-testability.
  - New `/architecture` and `/diagnose-bug` commands.
  - New references: `architecture-and-strictness.md` (deep-module vocabulary, deletion test, seam discipline) and `feedback-loop-diagnosis.md` (red-capable loop before hypothesizing).
  - `dead-code-cleanup` now applies the deletion test (catches shallow pass-throughs that have callers but earn nothing).
  - `incomplete-logic-detector` now requires confirmed reachability before grading HIGH.
  - `/health-audit` runs five agents and cross-links no-seam bugs to architecture findings.
- Architecture + diagnosis layers adapt Matt Pocock's engineering skills (mattpocock/skills, MIT).

## 1.0.0
- Initial release.
- Commands: `/health-audit`, `/dead-code`, `/incomplete-logic`.
- Agents: `dead-code-cleanup`, `incomplete-logic-detector`, `security-auditor`, `performance-analyzer`.
- Skill: `cleanup-audit` with incomplete-logic taxonomy, safe-deletion workflow, and cross-language tooling references.
- Language packs: Python, TypeScript/JS, Rust, Go (auto-detected).
