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

The projection passed to the reviewer is therefore restricted to: `id`, `kind`, `owned_files`, `depends_on`, `test_gates` (names only), `validators` (names only), `public_api` (signature only — no contract prose), `behaviors` (one-line summaries only — no acceptance criteria), and `estimated_size`. Anything else is stripped before the reviewer sees it.

This is enforced in D2.1: the dispatcher builds the projection from the planner's output and never passes the full plan to the reviewer.

## Why per-cycle commits in D4 (AP-1)

TDD only works as a verification mechanism if the test-first ordering is auditable after the fact. If the implementer makes all edits in one shot and commits once, there is no way for D6 to verify that the test was actually written before the implementation — the implementer could have written both together and back-rolled the test to make it look TDD.

Per-cycle commits split each TDD cycle into two commits:

- `test: <subtask-id> <test-name> [RED]` — test added, scoped test run shows it failing
- `feat: <subtask-id> <impl-summary> [GREEN]` — implementation added, same scoped test now passes

D6 verifies the cycle by reading git log and checking that each `feat:` commit's parent is a `test:` commit with a matching `<subtask-id>` and that the RED→GREEN ordering holds for every cycle in the subtask. If a subtask claims 3 cycles, the git log must show 3 alternating commits ending on `feat: [GREEN]`.

This adds 1 commit per cycle versus a single squashed commit. For a 4-cycle subtask, that is 8 commits instead of 1. The cost is paid back in two places:

- D6 verification becomes a deterministic git log walk instead of a heuristic LLM check of "does the diff look TDD-shaped".
- Stacked-PR review on Bitbucket lets reviewers step through cycle-by-cycle, which matches how the implementer actually built it.

The cost is NOT paid back in branch history if the team squash-merges. Autopilot defaults stacked PRs to `merge.strategy = "merge-commit"` to preserve the cycle history (see AP-10). Teams that prefer squash can override per-PR, but lose the audit trail.

The implementer prompt enforces the commit shape; D6 enforces the verification. If implementer skips commits and tries to do everything in one shot, D6 fails the subtask with `[BLOCKED: tdd-shape] (impl)` and returns to D3 for replan.

## Why split block counters (AP-2)

v1 had a single `consecutive_failures` counter that incremented on any block. This conflated three different failure modes:

1. Implementation faults — the plan was wrong, the code was wrong, or the validator caught a real bug.
2. CI faults — Bitbucket build failed, PR was declined, build hung.
3. External faults — sidecar 502, network partition, keychain locked, Bitbucket rate limit.

Treating all three the same means a flaky CI run looks identical to a broken plan, and the loop keeps spinning the same way (replan, retry, replan) when the actual fix is different per category.

v2 splits the counter into:

- `consecutive_impl_blocks` — increments on plan-ungated, unresolved validator findings, test failures, rebase conflicts, plan-stale, tdd-shape, ownership-overflow, validator-contradiction. Reset on a clean cycle. Cap at 3 → HUMAN_NEEDED.
- `consecutive_ci_blocks` — increments on ci-red, ci-stuck, ci-undetermined, pr-declined. Reset on a green CI run. Cap at 2 → HUMAN_NEEDED (lower because CI flakes are usually environmental and re-trying past 2 just burns budget).
- External faults — do NOT increment any counter. They route straight to `HUMAN_NEEDED` with `reason: external-fault`. The dispatcher does not retry external faults autonomously because the resolution is always operator-side (re-auth, restart sidecar, unlock keychain).

Every `[BLOCKED: <reason>]` entry MUST be tagged `(impl)`, `(ci)`, or `(external)` so the counter routing is unambiguous. Untagged entries are a defect; the conflict-resolution and validator-prompts references list all currently-defined reasons and their categories.

## Why audited_sha (AP-5)

The audit hands off a TRIAGE.md keyed to a specific tree SHA. If the planner runs against a HEAD that has drifted from the audited SHA, the plan can reference files that have moved, been deleted, or been refactored in a way the audit didn't see. The result is a plan that compiles in the planner's head but fails the moment the implementer tries to apply it.

Planner's contract requires `audited_sha:` at the top of the plan. D3.0 (the new gate before D3 dispatch) verifies:

1. `audited_sha` exists in local refs (git cat-file -e).
2. For each `owned_files` path in the plan, the file exists at `audited_sha`.
3. The diff between `audited_sha` and current `HEAD` does not touch any path in any `owned_files`. If it does, the plan is stale and must be regenerated.

If D3.0 fails, the dispatcher emits `[BLOCKED: plan-stale] (impl)` and returns to D2 for replan. The new plan can either retarget HEAD (re-running audit) or rebase the existing changes onto a fresh audit; planner picks per the staleness pattern.

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

v2 detects contradiction by checking whether any pair of findings shares a `target_path` but has opposing `directive` (where directive is one of `add`, `remove`, `change-signature`, `change-semantics`). If a contradiction is found, the dispatcher emits `[BLOCKED: validator-contradiction] (impl)` and routes to HUMAN_NEEDED with the contradiction pair included in the report. The operator's call: relax one validator, change the plan to split the conflict across subtasks, or accept one finding and document the tradeoff.

This adds 4 lines to the dispatcher's finding-aggregation step and removes a class of oscillation bug.

## Why per-spec dedup of PAUSED entries (AP-17)

The tracker file logs every D7.0 PAUSED event (subtask paused for human review). If the operator unblocks and the subtask runs again to the same PAUSED state, v1 would log a duplicate entry. Over multiple unblock attempts the tracker grows without limit and the dispatcher's "show pending PAUSED" view becomes noise.

v2 dedupes by spec hash: each PAUSED entry includes `spec_hash: <sha256-of-{subtask_id, blocking_reason, validator_finding_id}>`. Before logging, the dispatcher checks if the most recent PAUSED entry has the same spec_hash; if so, increment a `paused_count` field on that entry instead of appending a new one. The tracker stays compact and the count tells the operator how many times the same block has been encountered.

This is purely a tracker-hygiene change; no dispatcher logic depends on it.
