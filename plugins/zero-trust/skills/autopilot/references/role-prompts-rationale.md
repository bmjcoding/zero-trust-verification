# Role Prompts: Rationale

Why autopilot's role prompts are shaped the way they are. Maintainer reading only — never loaded by the dispatcher.

## Why split roles at all

A single prompt that plans, implements, validates, and resolves conflicts collapses into a generalist doing each step poorly. Splitting tunes each role to what it must hold in working memory: the planner reads the runbook + repo layout and emits a structured plan (no code edits); the implementer takes one Subtask inside its ownership window (no replanning); the validator reads the diff + contract and returns a verdict (no edits); the conflict resolver takes a rebase failure (no scope expansion). The implementer gets the contract verbatim; the planner never sees contracts at all — it writes them.

## Why the plan reviewer sees a projection (AP-3)

The reviewer verifies plan STRUCTURE (ownership disjointness, DAG acyclicity, gate coverage, ID uniqueness). Shown the planner's evidence trail and contract prose, two failure modes appear: (1) the reviewer second-guesses prose and produces content critiques instead of structural review; (2) its context bloats — 20+ Subtasks with full contracts is a 200KB review prompt. Concur rates ran ~95% even when the reviewer was prompted to disagree: agents read confident prose and absorb its conclusions. The projected field set is defined ONCE in `references/plan-reviewer-projection.md` §"Allowed fields" — deliberately not restated here (restating it is how three divergent copies accumulated pre-v2.4.0).

## Why per-cycle commits in D4 (AP-1)

TDD only works as a verification mechanism if the test-first ordering is auditable after the fact — a single squashed commit lets the implementer write test and impl together and back-roll the test to look TDD. Per-cycle commits (`test: <id>.<n> RED` then `feat: <id>.<n> GREEN`) make D6 verification a deterministic git-log walk instead of a heuristic "does the diff look TDD-shaped" judgment, and let PR reviewers step through cycle-by-cycle. The cost — ~2 commits per cycle — is lost if the team squash-merges, so stacked PRs default to `merge.strategy: merge-commit` (AP-10). An implementer skipping commits gets a typed block from D6 (`tdd-no-red` / `tdd-no-green` / `tdd-out-of-order` / `tdd-scope-leak`, all `(impl)`); there is no automatic replan.

## Why split block counters (AP-2)

v1's single `consecutive_failures` counter conflated implementation faults, CI faults, and external faults — a flaky CI run looked identical to a broken plan, and the loop kept retrying the wrong fix. v2 splits: `consecutive_impl_blocks` (plan/validator/test/rebase/ownership blocks; cap default 3), `consecutive_ci_blocks` (ci-red/ci-stuck/pr-declined; cap default 2 — CI flakes are environmental, retrying past 2 burns budget), and external faults touch no counter, routing straight to HUMAN_NEEDED because the fix is always operator-side (re-auth, restart sidecar, unlock keychain). Every `[BLOCKED]` is tagged `(impl)`/`(ci)`/`(external)` so routing is unambiguous.

## Why audited_sha (AP-5)

A plan built against one tree can silently fail against a moved HEAD — files relocated, deleted, or refactored under it. The planner emits `audited_sha:`; D3.0 verifies the SHA exists, every `owned_files` path exists at it, and no owned path changed between it and HEAD. A stale plan blocks at D3.0 (`plan-stale-missing`/`plan-stale-drifted`, no retry — a human decides whether to re-audit or re-generate), which is far cheaper than the implementer discovering staleness mid-D4, and cheaper still than PR review discovering it at D7.

## Why no external scheduler (AP-19)

v1 shipped crontab/launchd wakeup scripts on the premise of unattended overnight runs. Autopilot only makes progress while a Claude Code session is live — there is no headless mode — so the external scheduler added failure surface (misconfigured cron, plist permissions, dead env in non-login shells) without buying autonomy: the "wakeup" just printed a reminder no one was there to read. v2 removed the scripts and all `--external-scheduler` handling; cadence is in-session only (`references/cadence-dispatch.md`), and the `external_scheduler` runbook field is read-with-warning and ignored. True unattended progress needs a daemon mode or managed agent — out of scope. Operators with v1 cron entries remove them manually.

## Why sidecar contract v0 (sidecar lookup, no Authorization header)

Workspace containers route outbound HTTPS through an identity-proxy sidecar that terminates user creds via session-scoped OBO tokens. Autopilot detects the sidecar and, when present, calls it with no Authorization header (the sidecar injects creds upstream); otherwise it falls back to keychain → env. It is v0 because the sidecar is mid-rollout and autopilot must work in both worlds; the error codes and URL shape will harden at v1. The resolver chain is the only place secrets enter the process — `set +x` around the resolver, never positional args, never echoed, never in any tool argument Claude Code sees. Full contract: `references/sidecar-contract.md`.

## Why test-gate scoping during rebase (AP-15)

A full suite for a large repo is 10–40 minutes — a budget killer inside the dispatcher loop — and tests outside the Subtask's ownership window failing means the parent branch broke them, a separate concern that surfaces at that PR's own D6. So conflict resolution runs only the Subtask's scoped gates plus tests under the touched files; D6 verifies the runner was invoked with file/path scoping via `gates.test_single`/`gates.test_scoped`, never bare.

## Why contradictory validator findings escape to HUMAN_NEEDED (AP-18)

When two parallel validators point in opposite directions at the same location, the dispatcher has no principled way to pick a winner — v1 spawned a fix for the first finding, which re-triggered the second, and the loop oscillated. v2 detects contradiction lexically (same `location`, semantically opposing `suggested_fix`) and escapes with both findings verbatim; the findings schema deliberately has no structured `directive` field — validators must instead write `suggested_fix` specifically enough for the comparison to work. The operator relaxes a validator, splits the conflict across Subtasks, or accepts one finding and documents the tradeoff.

## Why per-spec dedup of PAUSED entries (AP-17)

Re-hitting the same block every fire would commit a duplicate PAUSED tracker entry each time, growing the tracker and filling the Runbook PR (or batched queue) with no-op deltas. D8 skips the tracker commit when the previous fire already wrote PAUSED with the same `status_reason` — the first entry remains the record. Pure tracker hygiene; no dispatcher logic depends on it.
