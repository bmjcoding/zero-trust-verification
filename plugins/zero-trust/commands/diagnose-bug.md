---
description: Diagnose a confirmed or suspected bug/regression with a disciplined feedback-loop method — build a red-capable repro before hypothesizing, then fix with a regression test.
argument-hint: "<bug description or finding tag>"
---

# /diagnose-bug

Turn a reported or audit-surfaced bug into a *verified* fix. `$ARGUMENTS` is
the bug description, or a finding tag/fingerprint from `audit/state.json` to
look up.

Read `cleanup-audit` skill → `references/feedback-loop-diagnosis.md` FIRST
and follow its six phases as written (adapted from Matt Pocock's
diagnosing-bugs skill, MIT). The spine: **build one command that goes red on
THIS bug before forming any hypothesis** — no red-capable command, no next
phase. Then reproduce + minimise, hypothesise (ranked + falsifiable, shown to
the user), instrument one variable at a time, fix with a regression test at a
correct seam (red without the fix, green 5/5 with it — `/verify`'s
determinism gate reruns it the same way; no correct seam → that absence IS
the finding, route to `architecture-reviewer`), and clean up.

Record the fix in `docs/FIX_LOG.md` (tag/fingerprint · commit · regression
test · rerun evidence, e.g. `5/5`) so `/verify` can grade it FIXED.
