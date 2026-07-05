# Runbook Template (autopilot v2.4.0)

> Loading preamble reminder: the runbook is the operator's contract with
> autopilot. Read it in full before every drain; do not cache stale
> frontmatter across auto-compaction boundaries. Frontmatter flags override
> defaults only within the scope declared by that flag (repo-wide vs
> drain-scoped) — see SKILL.md for the override-scoping table.

A runbook is a single YAML+Markdown file that defines a unit of autonomous work for autopilot to execute. The operator writes this once (or GENERATE seeds it); the dispatcher reads it on every step. Since v2.3.0 the runbook also carries the auto-detected repo-shape flags produced by G1.5 (see the `Repo constraints (detected)` block below).

## File location (canonical artifact paths)

Runbooks live under `.autopilot/runbooks/<slug>.md` in the repository root; the sibling tracker is `.autopilot/runbooks/<slug>.tracker.md`. These are the ONLY artifact paths (v2.4.0 removed a competing scheme under the repo's design-docs tree that GENERATE and DRAIN disagreed on). The slug is kebab-case, matches the branch prefix used in `autopilot/<slug>/...`, and is the only identifier the dispatcher uses to correlate plans, trackers, and PRs.

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
  max_claim_waits: 16                    # AV3-09: consecutive claim-blocked fires before HUMAN_NEEDED — claim-deadlock
  max_runtime_minutes: 240               # wall-clock cap; dispatcher emits HUMAN_NEEDED at expiry
validators:                              # validator names run on every D5; catalog = validator-prompts.md
  - integration                          # always
  - design                               # always
  - quality                              # always
  # - security                           # optional; auto-added by planner on auth/secret/token/cookie paths
  # - sre                                # optional; auto-added by planner on operational hot paths
cadence:                                 # AP-19: in-session only, no external_scheduler field
  mode: in-session                       # only legal value
  step_pause_seconds: 0                  # operator-facing pause between dispatch steps; 0 = no pause
gates:                                   # v2.4.0: language-agnostic gate commands (D6.1, D5 quality,
                                         # conflict-resolution, implementer). Placeholders: {paths} =
                                         # changed module/dir scope, {files} = changed file list,
                                         # {test} = single test id. Defaults shown are the Python pack;
                                         # replace per-repo (e.g. "npx vitest run {paths}",
                                         # "go test {paths}", "cargo test -p {paths}").
  test_scoped: "pytest -x -q {paths}"
  test_single: "pytest {test} -x"
  test_contract: "pytest -m contract -x -q {paths}"
  typecheck: "mypy {paths}"
  lint: "ruff check {paths}"             # scoped to changed files — never repo-wide (brownfield debt
                                         # elsewhere must not block a Subtask)
  precommit: "pre-commit run --files {files}"
contract_paths: []                       # optional globs marking wire-shape/contract modules; the
                                         # planner adds the `contract` test gate for Subtasks touching them
ci:
  platform: bitbucket-dc                 # informational only; host.sh detects the backend (bitbucket-dc | github) from origin at runtime (ADR 0013)
  skip_wait: false                       # AP-23: when true, do not poll for build; treat push as terminal. Auto-flipped true by G1.5 when CI_PRESENT=false.
  build_states:                          # RESERVED (documentation of the host adapter's build-status vocabulary).
    success: [SUCCESSFUL]                # every backend's build-status emits exactly these tokens
    failure: [FAILED]                    # exact names; the field is validated but not yet consumed.
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
- `gh_cli_path` (host binding is never a runbook field; `host.sh` detects the backend from origin — ADR 0013. The GitHub backend uses `gh`, but the caller surface stays host-agnostic.)
- `consecutive_failures_cap` (AP-2: replaced by split impl/ci caps above)
- `secrets_inline` and any inline credential field (sidecar/keychain only — no inline secrets ever)
- `validator_contradiction_resolution: <strategy>` (AP-18: contradictions always escape to HUMAN_NEEDED)
- `tracker_pr.force_push` (AP-23: superseded by `branching.no_force_push`)
- `wait_for_ci` (AP-23: superseded by `ci.skip_wait`)
- `test_runner` (v2.4.0: superseded by `gates:`; accepted as a legacy alias — `test_runner.cmd: X` is read as `gates.test_scoped: "X -x -q {paths}"` — with a warning)

## Body sections

The runbook body is plain Markdown. The dispatcher reads the sections below by name (Goal / Constraints / Non-Goals, plus the G1.5-owned `Repo constraints (detected)` block); everything else is operator notes.

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

### Stories (sizing + coverage ledger)

> Written by G7 from the planner output and the G4 sizing gate — one row per
> Story (PR-per-Story, AV3-06). The dispatcher reads `predicted_hours` for the
> 48-hour invariant audit trail; the audit tier reads `Behavior IDs` to
> distinguish intentionally-not-yet-wired work from Memory Rot.

| Story | Subtasks | predicted_hours (Σ, ≤48) | Behavior IDs | As-built docs |
|---|---|---|---|---|
| `S-pricing` | A1, A2, A3 | 28 | `B-pricing-001`, `B-pricing-002` | `docs/journeys/pricing.md` |

- **predicted_hours (Σ)** — sum of the Story's Subtasks' `predicted_hours`; G4
  refuses any Story summing to more than 48 hours (`story-oversized`) and any
  Subtask whose hours exceed its `estimated_size` ceiling (`story-size-inconsistent`).
  ADR 0012 / AV3-07.
- **Behavior IDs** — the active manifest Behavior IDs the Story's Subtasks own
  (planner `behavior_ids[]`, mapped at G3, verified at D6). Empty column only for
  manifest-less drains (v2.4.0 semantics).
- **As-built docs** — the journey-doc / README deltas the Story must ship inside
  its own Story PR when the Story's behaviors are journey-bearing per the manifest.

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

## Runbook PR (bookkeeping home — AV3-08)

G7 opens ONE long-lived **Runbook PR** at Pickup on branch `autopilot/<slug>/runbook`, carrying the runbook + tracker. It is the single home for all tracker bookkeeping under both `no_force_push` settings (the pre-v3 rolling tracker PR is retired), and it is the FINAL entry in `MERGE-ORDER.md` — the operator (or the Marshal, once built) merges it; autopilot never merges its own PRs.

Its body carries the drain's **predicted file surface** as a grep-able block, delimited by literal marker comments so foreign planners and the AV3-09 claim consultation can parse it without prose heuristics:

```markdown
## Predicted file surface
<!-- autopilot:file-surface:begin -->
- `path/one.py`
- `path/two.py`
<!-- autopilot:file-surface:end -->
```

`scripts/runbook_pr.sh file-surface <body-file>` extracts the entries (marker contract; a missing/unbalanced pair is a hard error, never a silent empty surface).

## Tracker file

The dispatcher writes a sibling tracker at `.autopilot/runbooks/<slug>.tracker.md`. Operators do not edit this; it is the dispatcher's append-only state log. The frontmatter is the CANONICAL schema (v2.4.0 — this section previously documented a divergent legacy field set that neither G7 nor `detect_concurrent_drain.sh` could interoperate with; see docs/GAPS_SPEC.md C2):

```yaml
---
STATUS: ACTIVE                    # ACTIVE | DRAINED | PAUSED | HUMAN_NEEDED | STOPPED
consecutive_impl_blocks: 0        # AP-2: split counters
consecutive_ci_blocks: 0
claim_waits: 0                    # AV3-09: consecutive claim-blocked fires; cap budget.max_claim_waits
drain_start_sha: <sha>
drain_started_at: <iso8601>       # seeded by the first fire; budget.max_runtime_minutes anchor
audited_sha: <sha>                # AP-5: SHA at planner-spawn time
manifest_revision: <int-or-absent> # AV3-04: frozen at GENERATE from the Spec's manifest;
                                  #   D1.0.6 compares it against the live manifest each fire.
                                  #   Absent on manifest-less drains (v2.4.0 semantics).
status_reason: <string-or-absent> # set alongside STATUS: PAUSED|HUMAN_NEEDED (e.g.
                                  #   manifest-revision-drift, runtime-budget-expired). Cleared on Resume.
trunk_branch: <name>              # from G1.5 TRUNK=
host: bitbucket-dc
ci:
  skip_wait: <bool>               # G1.5 CI_PRESENT auto-set
branching:
  no_force_push: <bool>           # G1.5 FORCE_PUSH_ALLOWED auto-set
  single_branch_single_pr: false  # operator-toggle only
enforce_jira_key: <bool>          # G1.5 JIRA_HOOK_ENFORCED or --jira auto-set
pack_subtasks: <bool>             # AP-21 operator-toggle
in_progress: null                 # or the claimed Subtask block (subtask_id, started_at,
                                  #   last_heartbeat_at, pr_number, pushed_at, pushed_sha,
                                  #   awaiting_ci, ci_check_count)
last_heartbeat_at: <iso8601>      # AP-6: updated every step boundary
session_lock: null                # AP-4: CLAUDE_SESSION_ID of the lock owner
session_lock_expires_at: null     # AP-4: now+30min, refreshed every fire
force_audit: []                   # AP-11
---
```

Body is a Markdown log of dispatch events in append-only order (`## Drift Notes`, the Subtask sections, `## Force Audit`, and — under `branching.no_force_push: true` — `## Pending Tracker Deltas (batched)`). Each entry: `<iso8601> <step> <subtask-id-or-->: <one-line-summary>`. Multi-line details (validator findings, conflict patches) go in collapsible sections.

## How autopilot reads the runbook

The operative step graphs are GENERATE G1..G8 (`references/generate-lifecycle.md`) and DRAIN D1..D8 (`references/drain-lifecycle.md`); those files are canonical for step semantics. In brief, each DRAIN fire: D1 claims the session lock (AP-4, via `session_lock`/`session_lock_expires_at`), verifies branch shape (AP-7) and heartbeat freshness (AP-6), and recovers WIP; D2 claims the next eligible Subtask; D3 plans and reviews on the projection (AP-3) after the D3.0 `audited_sha` staleness gate (AP-5); D4 implements TDD-vertically with per-cycle commits (AP-1); D5 validates in parallel; D6 runs the `gates:` commands and the git-log commit-shape audit; D7 rebases, folds batched deltas (D7.1a), pushes, opens the PR; D7.5 takes one CI observation; D8 re-arms the adaptive cron.

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
  - integration
  - design
  - quality
  - security
cadence:
  mode: in-session
  step_pause_seconds: 0
gates:
  test_scoped: "pytest -x -q {paths}"
  test_single: "pytest {test} -x"
  typecheck: "mypy {paths}"
  lint: "ruff check {paths}"
  precommit: "pre-commit run --files {files}"
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
