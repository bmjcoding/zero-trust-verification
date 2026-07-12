# Feedback-Loop Diagnosis

Discipline for turning a *reported* bug into a *verified* fix. Adapted from Matt Pocock's `diagnosing-bugs` skill (https://github.com/mattpocock/skills, MIT). The audit's job is detection; this is how a HIGH correctness finding becomes a confirmed, regression-tested fix rather than a one-line guess.

**Core rule: build a red-capable feedback loop BEFORE forming any hypothesis.** If you catch yourself reading code to build a theory before you have one command that goes red on *this* bug, stop — that is the exact failure this prevents.

## Phase 1 — Build a feedback loop (this is the skill)
Construct one command that fails on this specific bug. Try in order: failing test at the seam → curl/HTTP script → CLI invocation diffed against known-good → headless browser → replay a captured trace → throwaway harness → property/fuzz loop → bisection harness → differential (old vs new) → HITL script (last resort).

Completion criterion — you can name **one command you have already run** that is:
- **Red-capable** — drives the real bug path and asserts the user's exact symptom (not "runs without erroring").
- **Deterministic** — same verdict every run (flaky: raise reproduction rate until debuggable).
- **Fast** — seconds, not minutes.
- **Agent-runnable** — unattended.

## Phase 2 — Reproduce + minimise
Run it red. Confirm it's the *user's* failure mode, not a nearby one. Then shrink to the smallest scenario that still goes red — cut inputs/callers/config one at a time, re-running after each. Done when every remaining element is load-bearing.

## Phase 3 — Hypothesise
Generate **3–5 ranked, falsifiable hypotheses** before testing any. Format: "If X is the cause, changing Y makes the bug disappear / Z makes it worse." No prediction = it's a vibe; sharpen or discard. Show the ranked list to the user — they often re-rank instantly.

## Phase 4 — Instrument
One probe per prediction, one variable at a time. Prefer debugger/REPL > targeted boundary logs > never "log everything and grep". Tag every debug log with a unique prefix (`[DEBUG-a4f2]`) so cleanup is one grep. **Perf branch:** measure first (timing harness/profiler/query plan), then bisect — logs are usually wrong for perf.

## Phase 5 — Fix + regression test
Write the regression test **before** the fix — but only if a **correct seam** exists (one that exercises the real bug pattern at the call site). **If no correct seam exists, that is itself the finding** — the architecture is preventing the bug from being locked down; route it to architecture review.

**Anti-flakiness checklist** — the regression test must satisfy ALL of these, or it cannot serve as closure evidence:
- **No sleeps, no wall-clock** — no `time.sleep`/`setTimeout` synchronization, no `datetime.now()`/`Date.now()` reads; inject the clock (frozen time, fake timers).
- **Seeded randomness** — any randomness on the path takes an explicit seed or a seeded instance.
- **No real network** — fake the transport; a unit test that dials out is itself a `test-health/T5` finding.
- **Order-independent and fresh-process rerunnable** — no shared mutable state with other tests; passes from a cold process, any order.

Closing sequence: failing test → watch fail → fix → watch pass **five consecutive runs** (randomize test order on one of them) → re-run the original loop. The deterministic screen for the checklist is `FLAKY_RE` in `scripts/debt_patterns.sh` (judged, not auto-fatal — seeded/injected/faked hits are mitigated), and `/verify` enforces the same gate: closing tests rerun N=5 in fresh processes, and a test that cannot pass 5/5 grades the finding PARTIAL, never FIXED.

## Phase 6 — Cleanup + post-mortem
Original repro gone; regression test passes (or seam-absence documented); all `[DEBUG-]` logs removed; throwaways deleted; the correct hypothesis recorded in the commit message. Then ask: **what would have prevented this?** If the answer is architectural, hand off to architecture review *after* the fix — you know more now.

## Why this matters for an audit
An audit finding listed as a one-liner is a *hypothesis*, not a confirmed bug. Run it through Phase 1–2 to prove it's real and reachable before grading it HIGH, and through Phase 5 to ship it with a test that goes red without the fix.
