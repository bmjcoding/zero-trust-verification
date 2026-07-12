---
description: Verify that previously-audited findings were actually fixed — grade each OPEN/PARTIAL/FIXED/REGRESSED/STALE with evidence, and run the debt ratchet.
argument-hint: "[--finding <tag|fingerprint>] [--strict] [--wontfix <tag> --reason <why>]"
---

# /verify

The back half of the audit loop. `/audit` claims *what's wrong*; `/verify`
checks *what actually got fixed* — with evidence, not self-report. Read-only
with respect to product code: the only writes are `audit/VERIFY_REPORT.md` and
status updates in `audit/state.json`.

Read the `cleanup-audit` skill → `references/audit-state-and-verify.md` FIRST
— it defines fingerprints, the state schema, the status lifecycle, the
closing-test determinism gate, and the ratchet. Apply those definitions as
written; the steps below are the grading procedure that drives them.

`$ARGUMENTS` may narrow to one finding (`--finding IL-H1`), enable `--strict`
(any PARTIAL/REGRESSED/ratchet-increase makes the summary verdict FAIL — for
CI), or record a human decision (`--wontfix IL-H1 --reason "..."` — the only
path that sets WONTFIX, and the reason is mandatory).

## Steps

1. **Load state.** Parse `audit/state.json`. Missing/corrupt/unknown schema →
   report "no verifiable state; run /audit first" and STOP. Never guess.
2. **Refresh deterministic counts — at the audited scope.** Run the skill's
   `scripts/run_audit.sh <target>` with the `target` recorded in the run being
   verified (counts computed over a different scope are not comparable). Note:
   on Rust projects this builds the crate; everything else is read-only.
3. **Grade every finding** not already WONTFIX. Per finding:
   - **Locate the symbol** at `path:symbol`. Symbol gone → apply the
     rename/move rule, then the removed-symbol rule, from
     `references/audit-state-and-verify.md`: found elsewhere → update
     path/symbol (old fingerprint aliased) and re-judge there; genuinely gone
     → FIXED **only** with a FIX_LOG/DELETION_LOG entry naming this finding,
     else STALE (a bare git-log deletion commit explains nothing).
   - **Symbol present → re-judge the original defect** against the original
     category's criteria.
     - Defect still present → OPEN (REGRESSED if previously FIXED).
     - Defect gone → **run the closing-test determinism gate** as defined in
       `references/audit-state-and-verify.md` ("Closing-test determinism"):
       find the test that asserts the fixed behavior, run it 5 times in fresh
       processes (one order-randomized; **N=5 is fixed, no override flag
       exists** — Decision 3), screen its file with `FLAKY_RE` from
       `scripts/debt_patterns.sh` (hits judged, not auto-fatal). 5/5 green +
       clean-or-mitigated screen → FIXED with `verified_by` = test path plus
       rerun count. Any red, an unrunnable test, an unmitigated screen hit,
       or no test at all → **PARTIAL** — never round up to FIXED.
     - Defect *partially* addressed (some paths fixed, others not; TODO left
       in the fix; error path still fake) → PARTIAL with the remaining defect
       quoted. This is the highest-value verdict — half-done fixes are new
       half-baked code.
   - **`test-health/*` findings** close per `references/test-health.md`
     (§ Closure). **`journey/uninstrumented` findings**: an emission added
     without a test asserting it fires → PARTIAL — an unasserted emission is
     not locked down.
4. **Cross-check `audit/SPEC.md`** if present: reconcile every spec item's
   `Status` field with the verdicts; call out mismatches (spec says Done,
   verify says PARTIAL) explicitly.
5. **Run the ratchet** per `references/audit-state-and-verify.md`: all eight
   fresh counts against the most recent **same-target** run (preferring the
   last `kind: "audit"` baseline). No same-target baseline, or a pre-1.4
   baseline lacking a count → "no comparable baseline (for `<count>`)" —
   never read an absent field as 0, never compare across scopes. Increase →
   list the newly-introduced lines. `stdout_logging_count` is report-only: it
   never flips the summary verdict, even under `--strict`.
6. **Write outputs.** `audit/VERIFY_REPORT.md`: verdict table (fingerprint ·
   tag · status · evidence), the PARTIAL/REGRESSED/STALE details, ratchet
   result, and a one-line summary verdict (PASS / ATTENTION / FAIL under
   `--strict`). Update `audit/state.json` statuses + append the run entry
   with `kind: "verify"` and the target used.
7. **Tell the user** the summary verdict and the single most important item
   (usually the worst PARTIAL).

## Rules

- Evidence or it didn't happen: FIXED requires `verified_by`. "The code looks
  right now" without a test is PARTIAL by definition.
- A nondeterministic pass never rounds up to FIXED (loop-safety invariant 9 —
  a flaky gate is no gate).
- Never modify product code, tests, or docs — report only. A missing
  regression test that should be written is a spec item, not a `/verify`
  action.
- Verdicts must be reproducible: quote the exact code/test lines that justify
  each status so a human can re-check in seconds.
