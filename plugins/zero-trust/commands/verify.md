---
description: Verify that previously-audited findings were actually fixed — grade each OPEN/PARTIAL/FIXED/REGRESSED/STALE with evidence, and run the debt ratchet.
argument-hint: "[--finding <tag|fingerprint>] [--strict] [--wontfix <tag> --reason <why>]"
---

# /verify

The back half of the audit loop. `/audit` claims *what's wrong*; `/verify` checks
*what actually got fixed* — with evidence, not self-report. Read-only with respect
to product code: the only writes are `audit/VERIFY_REPORT.md` and status updates
in `audit/state.json`.

Read `cleanup-audit` skill → `references/audit-state-and-verify.md` first — it
defines fingerprints, the state schema, the status lifecycle, and the ratchet.

`$ARGUMENTS` may narrow to one finding (`--finding IL-H1`), enable `--strict`
(any PARTIAL/REGRESSED/ratchet-increase makes the summary verdict FAIL — for CI),
or record a human decision (`--wontfix IL-H1 --reason "extension point by design"`
— the only path that sets WONTFIX, and the reason is mandatory).

## Steps

1. **Load state.** Parse `audit/state.json`. Missing/corrupt/unknown schema →
   report "no verifiable state; run /audit first" and STOP. Never guess.
2. **Refresh deterministic counts — at the audited scope.** Run the skill's
   `scripts/run_audit.sh <target>` with the `target` recorded in the run being
   verified (counts computed over a different scope are not comparable; see the
   ratchet rules in `references/audit-state-and-verify.md`). Note: on Rust
   projects this builds the crate (`cargo build`/`clippy`); everything else is
   read-only.
3. **Grade every finding** not already WONTFIX. Per finding:
   - **Locate the symbol** at `path:symbol`.
     - Symbol gone → **first rule out a move/rename**: `git log --follow -- <path>`,
       grep for the symbol name repo-wide; if found, update path/symbol (keep
       the old fingerprint as an alias) and re-judge the defect at the new
       location like any present symbol. Genuinely gone → FIXED **only** if a
       `docs/FIX_LOG.md` or `docs/DELETION_LOG.md` entry names this finding's
       tag or fingerprint (`verified_by` = that entry + commit). A bare
       git-log deletion commit is NOT an explanation — grade STALE, needs
       human. Every deletion has some commit; that proves nothing about
       whether the behavior was replaced or lost.
   - **Symbol present → re-judge the original defect** (re-read against the
     original category's criteria — e.g. does the validator still accept any
     non-empty string?).
     - Defect still present → OPEN (or REGRESSED if it was previously FIXED).
     - Defect gone → **run the closing-test determinism gate** (defined in
       `references/audit-state-and-verify.md` § "Closing-test determinism" —
       the escape-probability rationale lives there, not here). Find the test
       that exercises this seam and confirm it asserts the fixed behavior,
       then run it **5 times, each in a fresh process**, order-randomized on
       one of the five where the runner supports it (`pytest -p randomly`,
       `jest`, `go test -shuffle=on`). **N=5 is fixed per Decision 3 — no
       override flag exists.** Screen the test's file with `FLAKY_RE` sourced
       from the skill's `scripts/debt_patterns.sh` (the same definition the
       detector and the prevention hook use). Screen hits are judged, not
       auto-fatal: a demonstrably mitigated source — seeded randomness,
       injected/frozen clock, faked transport, `tmp_path` — passes with a note.
       - 5/5 green + clean-or-mitigated screen → FIXED with `verified_by` =
         test path **plus the rerun count**, e.g.
         `tests/test_auth.py::test_rejects_unknown_key (5/5)`.
       - Any red among the five, an unrunnable test, an unmitigated screen
         hit, or no test at all → **PARTIAL** — locked by a flaky test is
         not locked; never round up to FIXED.
     - Defect *partially* addressed (some paths fixed, others not; TODO left in
       the fix; error path still fake) → PARTIAL with the remaining defect
       quoted. This is the highest-value verdict — half-done fixes are new
       half-baked code.
   - **`test-health/*` findings** close per `references/test-health.md`
     (§ Closure), strongest evidence first: (nondeterminism) deterministic
     replacement plus a bounded stability probe; (vacuity) a fresh owner-run
     mutation report with the previously-survived mutants killed, or the
     re-read assertion now substantive plus a passing run. A
     still-unconstraining rewrite → PARTIAL. Deletion requires a
     FIX_LOG/DELETION_LOG entry naming the fingerprint, else STALE.
   - **`journey/uninstrumented` findings**: an emission added without a test
     asserting it fires → PARTIAL — an unasserted emission is not locked down.
4. **Cross-check `audit/SPEC.md`** if present: every spec item's `Status` field
   is reconciled with the verdicts above; mismatches (spec says Done, verify says
   PARTIAL) are called out explicitly.
5. **Run the ratchet.** Compare all eight fresh counts (`marker_count`,
   `suppression_count`, `flaky_count`, `test_vacuity_count`, `test_skip_count`,
   `stdout_logging_count`, `giant_file_count`, `commented_code_count`) against
   the most recent **same-target** run in `state.json`, preferring the last
   `kind: "audit"` run as baseline (repeated verifies must not creep the
   baseline). No same-target baseline → report "no comparable baseline", never
   compare across scopes; a pre-1.4 baseline lacks the six new counts → report
   "no comparable baseline for `<count>`" for those counts alone — never read
   an absent field as 0, never report a fake regression. Increase → list the
   newly-introduced lines. `stdout_logging_count` is report-only: it never
   flips the summary verdict to FAIL, even under `--strict`.
6. **Write outputs.**
   - `audit/VERIFY_REPORT.md`: verdict table (fingerprint · tag · status ·
     evidence), the PARTIAL/REGRESSED/STALE details, ratchet result, and a
     one-line summary verdict (PASS / ATTENTION / FAIL under `--strict`).
   - Update `audit/state.json` statuses + append the run entry with
     `kind: "verify"` and the target used.
   - Severity of each verdict presentation follows `references/severity-rubric.md`.
7. **Tell the user** the summary verdict and the single most important item
   (usually the worst PARTIAL).

## Rules

- Evidence or it didn't happen: FIXED requires `verified_by`. "The code looks
  right now" without a test is PARTIAL by definition.
- A nondeterministic pass never rounds up to FIXED: any red among the 5 reruns,
  an unrunnable closing test, or an unmitigated `FLAKY_RE` hit grades PARTIAL
  (loop-safety invariant 9 — a flaky gate is no gate).
- Never modify product code, tests, or docs — report only. If a missing
  regression test should be written, that's a spec item, not a `/verify` action.
- Verdicts must be reproducible: quote the exact code/test lines that justify
  each status so a human can re-check in seconds.
