---
description: Diagnose a confirmed or suspected bug/regression with a disciplined feedback-loop method — build a red-capable repro before hypothesizing, then fix with a regression test.
argument-hint: "<bug description or finding tag>"
---

# /diagnose-bug

Turn a reported or audit-surfaced bug into a *verified* fix. Use after `/health-audit` flags a HIGH correctness finding, or whenever something is broken/throwing/slow. `$ARGUMENTS` is the bug description, or a finding tag/fingerprint from `audit/state.json` to look up.

Follow `cleanup-audit` skill → `references/feedback-loop-diagnosis.md` (adapted from Matt Pocock's diagnosing-bugs skill, MIT). The discipline, in short:

1. **Feedback loop first.** Build one command that goes red on *this* bug (failing test → curl → CLI diff → harness → replay → bisection → differential). Do NOT hypothesize until you have run it red once. No red-capable command, no next phase.
2. **Reproduce + minimise** to the smallest scenario that still goes red; every remaining element load-bearing.
3. **Hypothesise** — 3–5 ranked, falsifiable hypotheses ("if X, then changing Y fixes it"); show the list to the user.
4. **Instrument** one variable at a time; tag debug logs `[DEBUG-xxxx]`; for perf, measure first then bisect.
5. **Fix + regression test** at a correct seam. The regression test satisfies the Phase-5 anti-flakiness checklist (no sleeps, seeded randomness, injected clock, faked transport, order-independent — per `references/feedback-loop-diagnosis.md`): red without the fix, green **5/5** with it (`/verify`'s determinism gate reruns it the same way). If no correct seam exists, that absence IS the finding — route to the `architecture-reviewer` agent.
6. **Cleanup + post-mortem** — remove tagged logs, record the winning hypothesis, ask "what would have prevented this?"; hand architectural causes to `architecture-reviewer` after the fix.

Use for the audit's correctness findings (e.g. `asyncio.run()` from a running loop, unimplemented classification paths) to confirm each is real and reachable before grading HIGH (per the skill's `references/severity-rubric.md`), and to ship it with a test that goes red without the fix. Record the fix in `docs/FIX_LOG.md` (tag/fingerprint · commit · regression test · rerun evidence, e.g. `5/5`) so `/verify` can grade it FIXED.
