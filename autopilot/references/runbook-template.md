# Runbook Template (autopilot v2.3.0)

> Loading preamble reminder: the runbook is the operator's contract with
> autopilot. Read it in full before every drain; do not cache stale
> frontmatter across auto-compaction boundaries. Frontmatter flags override
> defaults only within the scope declared by that flag (repo-wide vs
> drain-scoped) — see SKILL.md for the override-scoping table.

A runbook is a single YAML+Markdown file that defines a unit of autonomous work for autopilot to execute. The operator writes this once; the dispatcher reads it on every step. As of v2.3.0 the runbook also carries the auto-detected repo-shape flags produced by G1.5 (see the `Repo constraints (detected)` block below).

## File location

Runbooks live under `.autopilot/runbooks/<slug>.md` in the repository root. The slug is kebab-case, matches the branch prefix used in `autopilot/<slug>/...`, and is the only identifier the dispatcher uses to correlate plans, trackers, and PRs.

## Frontmatter

```yaml
---
slug: <kebab-case-identifier>            # required, matches filename and branch prefix
title: <human-readable title>            # required, used in PR titles
audit_handoff: <path-or-null>            # path to TRIAGE.md from codebase-health audit, or null for non-audit runbooks
audited_sha: <git-sha>                   # AP-5: required if audit_handoff is set; the SHA the audit was run against
priority: <high|medium|low>              # affects budget allocation only, not ordering
budget:
  max_subtasks: 20                       # hard cap on planner output
  max_cycles_per_subtask: 8              # hard cap on TDD cycles per subtask (D4)
  max_impl_blocks: 3                     # AP-2: consecutive_impl_blocks cap before HUMAN_NEEDED
  max_ci_blocks: 2                       # AP-2: consecutive_ci_blocks cap before HUMAN_NEEDED
  max_runtime_minutes: 240               # wall-clock cap; dispatcher emits HUMAN_NEEDED at expiry
validators:                              # list of validator names to run on every D5
  - correctness
  - security
  - performance
  - style
cadence:                                 # AP-19: in-session only, no external_scheduler field
  mode: in-session                       # only legal value
  step_pause_seconds: 0                  # operator-facing pause between dispatch steps; 0 = no pause
test_runner:
  cmd: pytest                            # base command; subtask plans add path+nodeid scoping
  scoped_flag: ""                        # any flag prepended to scoped invocations; usually empty
ci:
  platform: bitbucket-dc                 # AP-13: only legal value
  skip_wait: false                       # AP-23: when true, do not poll for build; treat push as terminal. Auto-flipped true by G1.5 when CI_PRESENT=false.
  build_states:
    success: [SUCCESSFUL]
    failure: [FAILED]
    in_progress: [INPROGRESS]
branching:
  no_force_push: false                   # AP-23: when true, tracker deltas queue in-tracker and flush at D7.1a; disables rolling tracker-PR pattern. Auto-flipped true by G1.5 when FORCE_PUSH_ALLOWED=false.
  single_branch_single_pr: false         # AP-23: when true, tracker branch == Subtask branch; flush commit is part of the Subtask PR itself.
enforce_jira_key: false                  # AP-22: when true, every commit message must satisfy the JIRA-key regex. Auto-flipped true by G1.5 when JIRA_HOOK_ENFORCED=true.
pack_subtasks: false                     # AP-21: when true, planner consolidates Subtasks per G3.6 heuristic; equivalent to `--consolidate=auto` at invocation.
merge:
  strategy: merge-commit                 # AP-10: required for stacked PRs to preserve cycle history
  delete_source_on_merge: true
force_audit: []                          # AP-11: appended to by dispatcher when --force is used; do not edit
---
```

## Removed fields (migration from v1)

The following frontmatter fields are NOT accepted. Runbooks containing them are read with a warning and the fields ignored:

- `external_scheduler` and any `cron_*` keys (AP-19: external scheduler removed)
- `gh_cli_path` (AP-13: gh CLI replaced by git + Bitbucket REST)
- `consecutive_failures_cap` (AP-2: replaced by split impl/ci caps above)
- `secrets_inline` and any inline credential field (sidecar/keychain only — no inline secrets ever)
- `validator_contradiction_resolution: <strategy>` (AP-18: contradictions always escape to HUMAN_NEEDED)
- `tracker_pr.force_push` (AP-23: superseded by `branching.no_force_push`)
- `wait_for_ci` (AP-23: superseded by `ci.skip_wait`)

## Body sections

The runbook body is plain Markdown. The dispatcher reads three optional H2 sections by name; everything else is operator notes.

### Goal

One paragraph describing the user-visible outcome. The planner reads this as the highest-level intent. Keep it crisp; if it's longer than a paragraph, the goal is probably two goals and the runbook should be split.

### Constraints

Bullet list of invariants the work must preserve. The planner echoes these into every subtask's contract; validators check for violations. Examples:

- Public API of `frobnicator.py` must not change.
- All new endpoints require `@requires_auth("admin")`.
- No new direct imports of `legacy_db`; route through the repository layer.

### Non-Goals

Bullet list of work explicitly out of scope. The planner uses this to reject candidate subtasks that drift into adjacent territory. Examples:

- Refactoring the test infrastructure.
- Removing deprecated endpoints (separate runbook).
- Adding telemetry to existing code paths.

### Repo constraints (detected)

> This block is written by G1.5 (`scripts/repo_shape_probe.sh`) on the first
> drain against a fresh runbook, or on any drain where the operator passes
> `--reprobe`. Operators may edit the block manually to override auto-detected
> values; the dispatcher treats operator edits as authoritative and will not
> overwrite them on subsequent probes (a `probed_at:` timestamp older than the
> current probe run acts as the freshness marker).

```yaml
probed_at: <iso8601>
probed_from: G1.5
TRUNK: main                              # detected trunk branch name; used to shape autopilot/<slug>/... branches
CI_PRESENT: true|false|unknown           # `unknown` does NOT auto-flip ci.skip_wait
FORCE_PUSH_ALLOWED: true|false|unknown   # `unknown` does NOT auto-flip branching.no_force_push
JIRA_HOOK_ENFORCED: true|false|unknown   # `unknown` does NOT auto-flip enforce_jira_key
notes: |
  Free-form probe observations (rejection strings matched, temp branches
  used, cleanup status). Preserved verbatim across drains.
```

Auto-seed rules (applied only on `unknown` → `true|false` transitions, never
on `unknown` values themselves):

- `CI_PRESENT=false` → `ci.skip_wait: true`
- `FORCE_PUSH_ALLOWED=false` → `branching.no_force_push: true`
- `JIRA_HOOK_ENFORCED=true` → `enforce_jira_key: true`

Operators disable auto-seed globally by passing `--no-auto-seed` to the
dispatcher; the probe still runs and populates this block, but flags are
not flipped.

### Pending Tracker Deltas (batched)

> Present only in the tracker file (`<slug>.tracker.md`), not in the runbook
> itself. See `references/tracker-delta-batching.md` for the full contract.
> This section header is injected by D1.0.4 on the first drain against a
> pre-v2.3 tracker. Do not hand-edit entries under this header; the
> dispatcher owns append and flush semantics.

## Tracker file

The dispatcher writes a sibling tracker at `.autopilot/runbooks/<slug>.tracker.md`. Operators do not edit this; it is the dispatcher's append-only state log. The frontmatter holds the lockfile (AP-4):

```yaml
---
slug: <kebab-case-identifier>
session_id: <CLAUDE_SESSION_ID>          # AP-4: lock owner
lock_acquired_at: <iso8601>              # AP-4: expires 30 minutes after this
last_heartbeat_at: <iso8601>             # AP-6: updated every step boundary
current_step: <D0..D7.5>
consecutive_impl_blocks: 0               # AP-2
consecutive_ci_blocks: 0                 # AP-2
force_audit:                             # AP-11
  - {at: <iso8601>, step: <Dx>, reason: <string>}
paused:                                  # AP-17: deduped by spec_hash
  - {spec_hash: <sha>, subtask_id: <id>, reason: <string>, first_seen: <iso8601>, paused_count: <int>}
---
```

Body is a Markdown log of dispatch events in append-only order. Each entry: `<iso8601> <step> <subtask-id-or-->: <one-line-summary>`. Multi-line details (validator findings, conflict patches) go in collapsible sections.

## How autopilot reads the runbook

D0 (init):
1. Acquire lock on tracker frontmatter (AP-4) keyed on `CLAUDE_SESSION_ID`; if locked by another session and `lock_acquired_at` is less than 30 minutes old, exit with `[BLOCKED: lock-held] (external)`.
2. If `audit_handoff` is set, verify `audited_sha` exists (`git cat-file -e`); if not, `[BLOCKED: audit-sha-missing] (impl)`.
3. Verify branch shape (AP-7): current branch must match `autopilot/<slug>/(setup|tracker|<subtask-id>)`. If not, `[BLOCKED: branch-shape] (impl)`.
4. Write heartbeat (AP-6).

D1.x (audit/setup): only runs if `audit_handoff` set and tracker has no prior plan.

D2 (plan): planner reads goal, constraints, non-goals, audit handoff, audited_sha; emits structured plan; D2.1 runs reviewer on projection (AP-3); on review pass, plan is committed to tracker.

D3 (dispatch): per subtask, D3.0 checks plan freshness vs HEAD (AP-5); if stale, `[BLOCKED: plan-stale] (impl)`.

D4..D7.5: see SKILL.md for the full step graph. Each step boundary updates `last_heartbeat_at` (AP-6).

## Validators

Validator names listed in frontmatter `validators:` map to prompts in `references/validator-prompts.md`. The dispatcher runs all listed validators in parallel on every D5. Contradictions (AP-18) escape to HUMAN_NEEDED; non-contradictory findings spawn a fix subtask.

## Failure routing

Every `[BLOCKED: <reason>]` entry must be tagged `(impl)`, `(ci)`, or `(external)`:

- `(impl)` increments `consecutive_impl_blocks`; cap `max_impl_blocks` → HUMAN_NEEDED.
- `(ci)` increments `consecutive_ci_blocks`; cap `max_ci_blocks` → HUMAN_NEEDED.
- `(external)` does NOT increment counters; routes immediately to HUMAN_NEEDED with `reason: external-fault`.

The taxonomy of reasons and their categories is in `references/conflict-resolution.md` and `references/validator-prompts.md`. Adding a new reason requires updating both.

## Resuming a runbook

To resume after HUMAN_NEEDED:
1. Read the tracker, find the last entry, identify the blocking subtask.
2. Resolve the block (re-auth, fix the contradictory validator, rebase the branch manually, etc.).
3. Append a manual entry to the tracker body documenting the resolution.
4. Reset the relevant counter (`consecutive_impl_blocks: 0` or `consecutive_ci_blocks: 0`) in tracker frontmatter.
5. Re-dispatch autopilot in-session.

`--force` resumes (AP-11): if the operator passes `--force` to override a HUMAN_NEEDED, the dispatcher appends to `force_audit:` with the step, reason, and timestamp. This is read-only audit; the dispatcher never inspects it for control flow.

## Minimal runbook example

```markdown
---
slug: extract-token-bucket
title: Extract token-bucket rate limiter from monolith
audit_handoff: .codebase-health/runs/2026-06-25/TRIAGE.md
audited_sha: a3f8c91e0b
priority: medium
budget:
  max_subtasks: 8
  max_cycles_per_subtask: 6
  max_impl_blocks: 3
  max_ci_blocks: 2
  max_runtime_minutes: 180
validators:
  - correctness
  - security
  - style
cadence:
  mode: in-session
  step_pause_seconds: 0
test_runner:
  cmd: pytest
  scoped_flag: ""
ci:
  platform: bitbucket-dc
  skip_wait: false
  build_states:
    success: [SUCCESSFUL]
    failure: [FAILED]
    in_progress: [INPROGRESS]
branching:
  no_force_push: false
  single_branch_single_pr: false
enforce_jira_key: false
pack_subtasks: false
merge:
  strategy: merge-commit
  delete_source_on_merge: true
force_audit: []
---

## Goal

Extract the in-memory token bucket from `api/limiter.py` into a standalone module
under `lib/rate_limit/` with a clean interface, so the bucket can be unit-tested
in isolation and reused by the new ingestion service.

## Constraints

- Public callers of `api.limiter.acquire()` must not change signature or semantics.
- No new direct Redis access; the bucket stays in-memory.
- Logging format on rate-limit denial must remain byte-identical (downstream parser depends on it).

## Non-Goals

- Replacing the bucket with a distributed limiter (separate runbook).
- Migrating other limiters in the codebase.
- Adding metrics to the bucket (covered by observability runbook).
```
