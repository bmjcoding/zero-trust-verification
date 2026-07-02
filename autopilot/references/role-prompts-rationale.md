# Role Prompts: Rationale

This document explains the design choices behind autopilot's role prompts (planner, plan-reviewer, implementer, validators, extraction, conflict). It is reference reading for skill maintainers, not for the dispatcher loop. Updates here are version-bumped alongside SKILL.md.

## Why split roles at all

A single prompt that plans, implements, validates, and resolves conflicts collapses into a generalist that does each step poorly. Splitting forces each role to operate at a different depth of context:

- Planner reads the runbook + audit handoff + repo layout, emits a structured plan. No code edits, no tools beyond read/grep/glob.
- Implementer takes one subtask, edits files in the assigned ownership window, runs scoped tests. No replanning.
- Validator reads the diff + the contract, returns a structured verdict. No edits.
- Conflict resolver takes a rebase failure + two parent commits, returns a merged patch. No replanning, no scope expansion.

Each role's prompt is tuned for what it must hold in working memory. Implementer gets the contract verbatim; planner does not see contracts at all (it writes them).

## Why the plan reviewer sees a projection (AP-3)

The plan reviewer's job is to verify the plan's structure (ownership disjointness, dependency DAG acyclicity, test gate coverage, ID uniqueness). It does not need to see the planner's internal evidence trail, the prose contract that the implementer will execute against, or the planner's `test_name_hint` (which is a suggestion to the implementer, not part of the plan's contract).

If the reviewer sees those fields, two failure modes appear:

1. The reviewer second-guesses contract prose and produces structural-review reports that are actually content critiques. This blurs the line between "is the plan well-formed" and "is the plan correct" — the latter belongs to the planner-self-review loop, not the reviewer.
2. The reviewer's context window bloats. Plan reviewer must scale to 20+ subtasks; including full contracts means a 200KB review prompt for a real change.

The projected field set is defined ONCE, in `references/plan-reviewer-projection.md` §"Allowed fields" — that list is canonical and this document deliberately does not restate it (restating it is how three divergent copies accumulated pre-v2.4.0). Anything outside the list is stripped before the reviewer sees it.

This is enforced at G3.5 and D3.2: the dispatcher builds the projection from the planner's output and never passes the full plan to the reviewer.

## Why per-cycle commits in D4 (AP-1)

TDD only works as a verification mechanism if the test-first ordering is auditable after the fact. If the implementer makes all edits in one shot and commits once, there is no way for D6 to verify that the test was actually written before the implementation — the implementer could have written both together and back-rolled the test to make it look TDD.

Per-cycle commits split each TDD cycle into two commits (the canonical shape — matching the implementer prompt and D6's parser):

- `test: <subtask-id>.<n> RED — <behavior summary>` — test added, scoped test run shows it failing
- `feat: <subtask-id>.<n> GREEN — <behavior summary>` — implementation added, same scoped test now passes

D6 verifies the cycle by reading git log and checking that for each behavior `<n>` there is exactly one RED and one GREEN commit, in that order, with matching indices. If a subtask claims 3 cycles, the git log must show 3 RED/GREEN pairs.

This adds 1 commit per cycle versus a single squashed commit. For a 4-cycle subtask, that is 8 commits instead of 1. The cost is paid back in two places:

- D6 verification becomes a deterministic git log walk instead of a heuristic LLM check of "does the diff look TDD-shaped".
- Stacked-PR review on Bitbucket lets reviewers step through cycle-by-cycle, which matches how the implementer actually built it.

The cost is NOT paid back in branch history if the team squash-merges. Autopilot defaults stacked PRs to `merge.strategy = "merge-commit"` to preserve the cycle history (see AP-10). Teams that prefer squash can override per-PR, but lose the audit trail.

The implementer prompt enforces the commit shape; D6 enforces the verification. If the implementer skips commits and tries to do everything in one shot, D6 fails the subtask with a typed block (`[BLOCKED: tdd-no-red]` / `tdd-no-green` / `tdd-out-of-order` / `tdd-scope-leak`, all `(impl)`), increments the impl counter, and the fire exits — there is no automatic replan.

## Why split block counters (AP-2)

v1 had a single `consecutive_failures` counter that incremented on any block. This conflated three different failure modes:

1. Implementation faults — the plan was wrong, the code was wrong, or the validator caught a real bug.
2. CI faults — Bitbucket build failed, PR was declined, build hung.
3. External faults — sidecar 502, network partition, keychain locked, Bitbucket rate limit.

Treating all three the same means a flaky CI run looks identical to a broken plan, and the loop keeps spinning the same way (replan, retry, replan) when the actual fix is different per category.

v2 splits the counter into:

- `consecutive_impl_blocks` — increments on plan-ungated, unresolved validator findings, test failures, rebase conflicts, plan-stale, tdd-shape blocks, ownership-overflow, validator-contradiction. Reset on a clean cycle. Cap at `budget.max_impl_blocks` (default 3) → HUMAN_NEEDED.
- `consecutive_ci_blocks` — increments on ci-red, ci-stuck, pr-declined. Reset on a green CI run. Cap at `budget.max_ci_blocks` (default 2) → HUMAN_NEEDED (lower because CI flakes are usually environmental and re-trying past 2 just burns budget).
- External faults — do NOT increment any counter. They route straight to `HUMAN_NEEDED` with `reason: external-fault`. The dispatcher does not retry external faults autonomously because the resolution is always operator-side (re-auth, restart sidecar, unlock keychain).

Every `[BLOCKED: <reason>]` entry MUST be tagged `(impl)`, `(ci)`, or `(external)` so the counter routing is unambiguous. Untagged entries are a defect; the conflict-resolution and validator-prompts references list all currently-defined reasons and their categories.

## Why audited_sha (AP-5)

The audit hands off a TRIAGE.md keyed to a specific tree SHA. If the planner runs against a HEAD that has drifted from the audited SHA, the plan can reference files that have moved, been deleted, or been refactored in a way the audit didn't see. The result is a plan that compiles in the planner's head but fails the moment the implementer tries to apply it.

Planner's contract requires `audited_sha:` at the top of the plan. D3.0 (the new gate before D3 dispatch) verifies:

1. `audited_sha` exists in local refs (git cat-file -e).
2. For each `owned_files` path in the plan, the file exists at `audited_sha`.
3. The diff between `audited_sha` and current `HEAD` does not touch any path in any `owned_files`. If it does, the plan is stale and must be regenerated.

If D3.0 fails, the dispatcher emits `[BLOCKED: plan-stale-missing]` or `[BLOCKED: plan-stale-drifted]` (impl) and the fire exits — no retry and no automatic replan. HEAD moved under the plan; a human decides whether to re-run the audit or re-generate against fresh HEAD.

This is cheaper than discovering the staleness in D4 (where the implementer would burn cycles trying to make a stale plan work) and much cheaper than discovering it in D7 (PR review).

## Why no external scheduler (AP-19)

v1 shipped `install_external_scheduler.sh` and `uninstall_external_scheduler.sh` for crontab/launchd-based wakeups. The premise was that autopilot would run unattended overnight by being kicked by cron.

This was always a hack. Autopilot only makes progress while a Claude Code session is active — there is no headless mode. The external scheduler scripts would fire a script that printed a reminder, but the actual loop only resumed when the operator opened Claude Code and pasted the next dispatch. The scheduler added a layer of failure (cron misconfigured, launchd plist permissions, dead env in non-login shell) without buying any real autonomy.

v2 removes the scripts and all `--external-scheduler` flag handling. Cadence is dispatched in-session only (see `references/cadence-dispatch.md`). The runbook frontmatter no longer accepts an `external_scheduler` field; runbooks that have it are read with a warning and the field is ignored.

Teams that want true unattended progress need a Claude Code daemon mode (which does not currently exist) or a Bedrock managed agent — both are out of scope for this skill.

The CHANGELOG documents that operators with v1 cron entries must remove them manually; autopilot does not ship a migration shim.

## Why sidecar contract v0 (sidecar lookup, no Authorization header)

Workspace containers route every outbound HTTPS call through an identity-proxy sidecar that terminates user creds via session-scoped OBO tokens. Autopilot's job is to detect whether a sidecar is reachable and, if so, hit it with no Authorization header (sidecar injects creds on the upstream leg). If no sidecar is reachable, autopilot falls back to a local credential resolver chain (keychain → env).

This is contract v0 because:

- The sidecar is in 100-person pilot today; default-on in roughly 2 months. Autopilot must work in both worlds during the rollout.
- The resolver chain (sidecar → keychain → env) is the only place secrets enter the process. Scripts MUST `set +x` around the resolver call so the token never appears in trace logs. The token MUST NOT be passed as a positional argument, MUST NOT be echoed, and MUST NOT enter any tool argument that Claude Code sees.
- Cross-platform: macOS uses `security find-generic-password`, Linux uses `secret-tool`, Windows VDIs use sidecar mode only (no local keychain fallback path is specified for Windows in v0). See `references/sidecar-contract.md` for the full contract.

The contract is versioned because the error codes and URL shape will harden as the sidecar matures. v0 covers the current pilot's behavior and explicitly enumerates which fields are stable versus which are subject to change at v1.

## Why pytest scoping during rebase (AP-15)

When the conflict resolver merges a patch during D7.0 rebase, the natural reflex is to run the full test suite to confirm nothing broke. That is wrong for two reasons:

1. The full suite for a large repo takes 10-40 minutes. Running it inside the dispatcher loop is a budget killer.
2. The conflict resolver is only allowed to touch files inside the subtask's ownership window plus rebase-required adjacent files. Tests outside that scope failing means the parent branch broke them — not the rebase — and that is a separate concern.

So conflict resolution runs only the test_gates specified in the subtask's plan entry plus any tests under the touched files' nearest test directory. If those pass, the rebase is considered clean. If a downstream PR in the stack breaks tests outside that scope, it surfaces at that PR's D6, not during this PR's rebase.

The implementer prompt and conflict-resolution.md both enforce this; D6 verifies that the test runner was invoked with file/path scoping (`pytest path/to/test_file.py::test_name` or equivalent), not `pytest` bare.

## Why contradictory validator findings escape to HUMAN_NEEDED (AP-18)

A subtask may run multiple validators in parallel. If two validators return findings that point in opposite directions (e.g., the Security validator says "this function must validate input X" and the Performance validator says "input validation on X must be removed because it doubles the hot path"), the dispatcher has no principled way to pick a winner.

v1's behavior was to spawn a fix subtask anyway, picking the first validator's finding. The fix subtask would then often re-trigger the second validator's finding, and the loop would oscillate.

v2 detects contradiction lexically (the canonical mechanism per `references/validator-prompts.md` §AP-18 and drain-lifecycle D5): after all validators return, findings sharing the same `location` (file:line) whose `suggested_fix` fields are semantically opposing ("remove X" vs "expand X"; "rename to Y" vs "rename to Z") are a contradiction. The findings schema deliberately has no structured `directive` field — validators are instead required to write `suggested_fix` specifically enough for the comparison to work. On contradiction, the dispatcher emits `[BLOCKED: validator-contradiction] (impl)` with both findings verbatim and routes to HUMAN_NEEDED. The operator's call: relax one validator, change the plan to split the conflict across subtasks, or accept one finding and document the tradeoff.

This adds a few lines to the dispatcher's finding-aggregation step and removes a class of oscillation bug.

## Why per-spec dedup of PAUSED entries (AP-17)

The tracker logs PAUSED transitions. If the drain re-hits the same block, v1 would commit a duplicate tracker entry every fire. Over multiple fires the tracker grows without limit and the rolling PR (or batched queue) fills with no-op deltas.

v2 dedupes by reason (the canonical mechanism per drain-lifecycle D8 §AP-17): when the tracker is being written to `STATUS: PAUSED` and the PREVIOUS fire also wrote `STATUS: PAUSED` with the same `status_reason`, the tracker commit is skipped entirely. The tracker stays compact; the first PAUSED entry remains the record. (An earlier draft specified a hash-keyed dedup counter on a `paused:` frontmatter list; it was never the shipped contract and was removed from the template in v2.4.0.)

This is purely a tracker-hygiene change; no dispatcher logic depends on it.
