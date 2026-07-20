# Runbook Template (autopilot v3.1.0)

> The runbook is the operator's contract with autopilot. Read it in full
> before every drain; never cache stale frontmatter across auto-compaction
> boundaries. Frontmatter flags override defaults only within their declared
> scope — see SKILL.md §"Override scoping".

A runbook is one YAML+Markdown file defining a unit of autonomous work. The operator writes it once (or GENERATE seeds it); the dispatcher reads it on every step. It also carries the G1.5 auto-detected repo-shape flags (the `Repo constraints (detected)` block below).

## File location (canonical artifact paths)

Runbooks live at `.autopilot/runbooks/<slug>.md`; the sibling tracker at `.autopilot/runbooks/<slug>.tracker.md`. These are the ONLY artifact paths. The slug is kebab-case, matches the `autopilot/<slug>/...` branch prefix, and is the only identifier correlating plans, trackers, and PRs.

## Frontmatter

```yaml
---
slug: <kebab-case-identifier>            # required, matches filename and branch prefix
title: <human-readable title>            # required, used in PR titles
audit_handoff: <path-or-null>            # path to TRIAGE.md from a codebase-health audit, or null
audited_sha: <git-sha>                   # AP-5: required if audit_handoff is set; the SHA the audit ran against
priority: <high|medium|low>              # affects budget allocation only, not ordering
budget:
  max_subtasks: 20                       # hard cap on planner output
  max_cycles_per_subtask: 8              # hard cap on TDD cycles per subtask (D4)
  max_impl_blocks: 3                     # AP-2: consecutive_impl_blocks cap before HUMAN_NEEDED
  max_ci_blocks: 2                       # AP-2: consecutive_ci_blocks cap before HUMAN_NEEDED
  max_claim_waits: 16                    # AV3-09: consecutive claim-blocked fires before claim-deadlock
  max_runtime_minutes: 240               # wall-clock cap; HUMAN_NEEDED at expiry
  max_mutants_per_subtask: 40            # ADR 0016 (MT-07): D6.5 mutant budget; exceeding → partial [note], never a false block
  max_mutation_seconds: 120              # ADR 0016 (MT-07): D6.5 wall-clock budget; same degrade rule
validators:                              # run on every D5; catalog = validator-prompts.md
  - integration                          # always
  - design                               # always
  - quality                              # always
  # - security                           # optional; planner-added on auth/secret/token/cookie paths
  # - sre                                # optional; planner-added on operational hot paths
cadence:                                 # AP-19: in-session only, no external_scheduler field
  mode: in-session                       # only legal value
  step_pause_seconds: 0                  # operator-facing pause between dispatch steps
gates:                                   # language-agnostic gate commands (D6.1, D5 quality,
                                         # conflict-resolution, implementer). Placeholders: {paths} =
                                         # changed module/dir scope, {files} = changed file list,
                                         # {test} = single test id. Defaults shown are the Python pack;
                                         # replace per-repo (e.g. "npx vitest run {paths}",
                                         # "go test {paths}", "cargo test -p {paths}").
  test_scoped: "pytest -x -q {paths}"
  test_single: "pytest {test} -x"
  test_random: "pytest -p randomly -q {paths}"   # AV3-12 (OPTIONAL): the order-randomized round of
                                                 # the D6.4 determinism gate. Omit when the repo has no
                                                 # randomization plugin — D6.4 skips that round with a
                                                 # loud [note] (e.g. JS: "vitest run --sequence.shuffle {paths}").
  # test_mutation: "mutmut run --paths-to-mutate {files} ; mutmut show"   # ADR 0016 (OPTIONAL): the
                                                 # resolved D6.5 anti-vacuous mutation command. Omit → D6.5
                                                 # SKIPS with a loud [note] (never a false block). Pair with
                                                 # test_mutation_tool below. Adapters: references/mutation-adapters.md.
  # test_mutation_tool: mutmut             # ADR 0016: which adapter parses D6.5 survivors
                                           # (stryker | cargo-mutants | mutmut | go-mutesting).
  test_contract: "pytest -m contract -x -q {paths}"
  typecheck: "mypy {paths}"
  lint: "ruff check {paths}"             # scoped to changed files — never repo-wide (brownfield debt
                                         # elsewhere must not block a Subtask)
  format: "ruff format {files}"          # OPTIONAL: the implementer's format-before-every-commit
                                         # gate (implementer-prompt commit rule 7). Omit when the
                                         # repo has no formatter — gates.lint / gates.precommit stay
                                         # the backstop. Defining it absorbs the formatting-only
                                         # validator fix cycle (~a whole fix pass of mechanical churn).
  precommit: "pre-commit run --files {files}"
contract_paths: []                       # optional globs marking wire-shape/contract modules; the
                                         # planner adds the `contract` test gate for Subtasks touching them
regen_rituals: []                        # optional: generated-artifact regen rituals. Entry shape:
                                         #   - paths: "<glob>"       # the generated artifact(s)
                                         #     ritual: "<doc-or-skill that performs/reviews the regen>"
                                         #     classification: additive-vs-breaking   # `breaking`
                                         #                     # requires operator sign-off
                                         # Producer: implementer commit rule 8 writes the `regen:`
                                         # line into the regenerating commit's body. Enforcement:
                                         # integration validator check 7 blocks a matching diff
                                         # without that evidence — an auto-regen must never fold
                                         # silently into a PR.
ci:
  platform: bitbucket-dc                 # informational only; host.sh detects the backend from origin (ADR 0013)
  skip_wait: false                       # when true, do not poll for build; push is terminal. Auto-flipped by G1.5.
  build_states:                          # RESERVED (documents the host adapter's build-status vocabulary;
    success: [SUCCESSFUL]                # validated but not yet consumed)
    failure: [FAILED]
    in_progress: [INPROGRESS]
branching:
  no_force_push: false                   # AP-23: when true, tracker deltas queue in-tracker and flush at D7.1a. Auto-flipped by G1.5.
  single_branch_single_pr: false         # when true, the whole drain collapses to one feature branch + one PR
enforce_jira_key: false                  # AP-22: every commit subject must carry [<JIRA-KEY>]. Auto-flipped by G1.5 or --jira.
pack_subtasks: false                     # AP-21: G3.6 consolidation; equivalent to --consolidate=auto
merge:
  strategy: merge-commit                 # AP-10: required for stacked PRs to preserve cycle history
  delete_source_on_merge: true
force_audit: []                          # AP-11: dispatcher-appended on --force; do not edit
---
```

## Removed fields (migration from v1)

Runbooks containing these are read with a warning and the fields ignored:

- `external_scheduler` / any `cron_*` keys (AP-19)
- `gh_cli_path` (host binding is never a runbook field — `host.sh` detects the backend from origin, ADR 0013)
- `consecutive_failures_cap` (AP-2: replaced by the split impl/ci caps)
- `secrets_inline` / any inline credential field (sidecar/keychain only — no inline secrets ever)
- `validator_contradiction_resolution` (AP-18: contradictions always escape to HUMAN_NEEDED)
- `tracker_pr.force_push` (superseded by `branching.no_force_push`)
- `wait_for_ci` (superseded by `ci.skip_wait`)
- `test_runner` (superseded by `gates:`; legacy alias `test_runner.cmd: X` is read as `gates.test_scoped: "X -x -q {paths}"` with a warning)

## Body sections

The dispatcher reads these sections by name (Goal / Constraints / Non-Goals / Stories / Subtasks (tier-2 plan) / Role prompts, plus the G1.5-owned `Repo constraints (detected)` block); everything else is operator notes.

### Goal

One paragraph of user-visible outcome — the planner's highest-level intent. Longer than a paragraph usually means two goals and two runbooks.

### Constraints

Bullet list of invariants the work must preserve; the planner echoes them into every Subtask's contract and validators check for violations. E.g. "Public API of `frobnicator.py` must not change"; "All new endpoints require `@requires_auth(\"admin\")`"; "No new direct imports of `legacy_db`; route through the repository layer."

### Non-Goals

Bullet list of work explicitly out of scope; the planner uses it to reject candidate Subtasks drifting into adjacent territory. E.g. "Refactoring the test infrastructure"; "Removing deprecated endpoints (separate runbook)."

### Stories (sizing + coverage ledger)

> Written by G7 from the planner output and the G4 sizing gate — one row per
> Story (PR-per-Story, AV3-06). The dispatcher reads `predicted_hours` for the
> 48-hour invariant audit trail; the audit tier reads `Behavior IDs` to
> distinguish intentionally-not-yet-wired work from Memory Rot.

| Story | Subtasks | predicted_hours (Σ, ≤48) | Behavior IDs | As-built docs |
|---|---|---|---|---|
| `S-pricing` | A1, A2, A3 | 28 | `B-pricing-001`, `B-pricing-002` | `docs/journeys/pricing.md` |

- **predicted_hours (Σ)** — Story sum; G4 refuses >48 (`story-oversized`) and any Subtask over its size ceiling (`story-size-inconsistent`). ADR 0012 / AV3-07.
- **Behavior IDs** — the active manifest Behaviors the Story's Subtasks own (planner `behavior_ids[]`, verified at D6.3). Empty only for manifest-less drains.
- **As-built docs** — the journey-doc / README deltas the Story must ship inside its own Story PR when its behaviors are journey-bearing (integration validator check 8).

### Subtasks (tier-2 plan)

> Written by G7 from the reviewed planner union (post-G3.5 review, post-G3.6
> consolidation) — one full tier-2 schema block per Subtask, VERBATIM. D3.1
> and D4 dispatch a Subtask's block from here word-for-word (it is
> implementer-prompt input 1); the dispatcher never paraphrases or summarizes
> a block.

### Role prompts

> Written by G7; the dispatcher reads a role's block verbatim at dispatch
> time. One block per in-drain role WITHOUT a standalone reference prompt
> (the G3 planner, the D4 implementer, and the D5 validators have their own
> reference files and are never duplicated here). Currently exactly one:

**Plan agent (dispatched at D3.1; re-invoked in REVIEW mode at D3.2).** The block G7 writes:

- *Plan mode (D3.1):* "You are the Plan agent for ONE Subtask. Refine the Subtask's schema block into an implementation plan: file-by-file intent for every `owned_files[]` entry (what changes in each file and why), the integration contract each `interface_change.public_api` symbol promises its callers, and a mapping of every `behaviors_to_test[]` entry to its `test_gates[]` gate. Plan only — never edit files."
- *Review mode (D3.2):* the same role re-invoked on the schema-only projection; it re-checks feasibility, file-path existence, dependency gaps, ownership overlap, and behaviors-to-test completeness — mirroring what `references/plan-reviewer-projection.md` expects.

### Authoring guidance — byte-stability refactors (scope-expansion clauses)

A `kind: refactor` imposing byte-stability constraints (frozen output file, frozen binder/signature) frequently discovers mid-flight that the constraint forces touches outside its strict `owned_files[]` — and burns zero-commit `[BLOCKED: ownership-overflow]` cycles before anyone authorizes the expansion. Two authoring patterns prevent that (planner Rule 4 carries the same guidance; this section is for operators hand-authoring runbooks):

1. **Pre-declare the conditional surface** in `owned_files[]` with an acceptance-criteria note (`owned_files may expand to include <X, Y> if <constraint> requires`) — D3 can then expand within the declared envelope without a blocked fire.
2. **Plan it as `kind: code`** when the true surface is genuinely unknowable — TDD-style scope discovery is more honest than a guessed file list.

### Repo constraints (detected)

> Written by G1.5 (`scripts/repo_shape_probe.sh`) on the first drain against a
> fresh runbook, or on `--reprobe`. Operator edits are authoritative — the
> dispatcher never overwrites values newer than the probe (`probed_at:` is the
> freshness marker).

```yaml
probed_at: <iso8601>
probed_from: G1.5
TRUNK: main                              # detected trunk; shapes autopilot/<slug>/... branches
CI_PRESENT: true|false|unknown           # `unknown` does NOT auto-flip ci.skip_wait
CI_STATUS_REPORTING: true|false|unknown  # does CI post to the host build-status API? `false` =
                                         # CI config exists but the endpoint never populates;
                                         # `unknown` does NOT auto-flip anything
FORCE_PUSH_ALLOWED: true|false|unknown   # `unknown` does NOT auto-flip branching.no_force_push
JIRA_HOOK_ENFORCED: true|false|unknown   # `unknown` does NOT auto-flip enforce_jira_key
notes: |
  Free-form probe observations (rejection strings matched, temp branches
  used, cleanup status). Preserved verbatim across drains.
```

Auto-seed rules (applied only on `unknown` → `true|false` transitions, never on `unknown` itself — loop-safety invariant 2):

- `CI_PRESENT=false` → `ci.skip_wait: true`
- `CI_PRESENT=true` **and** `CI_STATUS_REPORTING=false` → `ci.skip_wait: true` (CI runs but never posts to the host build-status API — polling would spin to `ci-stuck-pending` on every Subtask; the local test gates remain the merge gate and the degradation is declared here instead of discovered mid-drain)
- `FORCE_PUSH_ALLOWED=false` → `branching.no_force_push: true`
- `JIRA_HOOK_ENFORCED=true` → `enforce_jira_key: true`

`--no-auto-seed` disables the flips globally; the probe still runs and populates this block.

### Pending Tracker Deltas (batched)

> Present only in the tracker file, not the runbook. Full contract:
> `references/tracker-delta-batching.md`. The header is injected by D1.0.4 on
> the first drain against a pre-v2.3 tracker. Never hand-edit entries — the
> dispatcher owns append and flush.

## Runbook PR (bookkeeping home — AV3-08)

G7 opens ONE long-lived Runbook PR at Pickup on `autopilot/<slug>/runbook`, carrying the runbook + tracker — the single home for all tracker bookkeeping under both `no_force_push` settings (the pre-v3 rolling tracker PR is retired), and the FINAL entry in `MERGE-ORDER.md` (the operator or Marshal merges it; autopilot never merges its own PRs).

Its body carries the drain's predicted file surface, delimited by literal marker comments so foreign planners and AV3-09 claim consultation parse it without prose heuristics:

```markdown
## Predicted file surface
<!-- autopilot:file-surface:begin -->
- `path/one.py`
- `path/two.py`
<!-- autopilot:file-surface:end -->
```

`scripts/runbook_pr.sh file-surface <body-file>` extracts the entries (a missing/unbalanced marker pair is a hard error, never a silent empty surface).

## Tracker file

The dispatcher writes the sibling tracker at `.autopilot/runbooks/<slug>.tracker.md` — its append-only state log; operators do not edit it. The frontmatter below is the CANONICAL schema (defined once, here):

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
                                  #   Absent on manifest-less drains.
status_reason: <string-or-absent> # set alongside STATUS: PAUSED|HUMAN_NEEDED (e.g.
                                  #   manifest-revision-drift, runtime-budget-expired). Cleared on Resume.
trunk_branch: <name>              # from G1.5 TRUNK=
host: bitbucket-dc                # informational only; host.sh detects the backend from origin (ADR 0013)
ci:
  skip_wait: <bool>               # G1.5 CI_PRESENT auto-set
branching:
  no_force_push: <bool>           # G1.5 FORCE_PUSH_ALLOWED auto-set
  single_branch_single_pr: false  # operator-toggle only
enforce_jira_key: <bool>          # G1.5 JIRA_HOOK_ENFORCED or --jira auto-set
pack_subtasks: <bool>             # AP-21 operator-toggle
in_progress: null                 # or the claimed Subtask block (subtask_id, started_at,
                                  #   last_heartbeat_at, pr_number [the Story PR], pushed_at, pushed_sha,
                                  #   prev_pushed_sha [AV3-06: the D6.2 audit base — the Story branch tip
                                  #   the previous Subtask left; null for the Story's first Subtask],
                                  #   awaiting_ci, ci_check_count, replans [AV3-10 claim-loss re-plan count])
stories: {}                       # AV3-06: per-Story entry keyed by <story-id>, each carrying
                                  #   last_pushed_sha (feeds the next Subtask's prev_pushed_sha) +
                                  #   pr_number + behavior coverage (D7.4 mirror, AV3-05)
subtask_blocks: {}                # AV3-09: per-Subtask blocked_by_pr: <host>/<pr#> claim edges (G4-written, D2-evaluable)
last_heartbeat_at: <iso8601>      # AP-6: updated every step boundary
session_lock: null                # AP-4: CLAUDE_SESSION_ID of the lock owner
session_lock_expires_at: null     # AP-4: now+30min, refreshed every fire
force_audit: []                   # AP-11
---
```

Body: a Markdown log of dispatch events in append-only order (`## Drift Notes`, the Subtask sections, `## Force Audit`, and — under `branching.no_force_push: true` — `## Pending Tracker Deltas (batched)`). Each entry: `<iso8601> <step> <subtask-id-or-->: <one-line-summary>`; multi-line detail (validator findings, conflict patches) goes in collapsible sections.

## How autopilot reads the runbook

The operative step graphs are GENERATE G0..G8 and DRAIN D1..D8 in `references/lifecycle.md` — canonical for step semantics. In brief, each DRAIN fire: D1 claims the session lock, verifies branch shape and heartbeat freshness, recovers WIP; D2 claims the next eligible Subtask; D3 plans and reviews on the projection after the D3.0 `audited_sha` gate; D4 implements TDD-vertically with per-cycle commits; D5 validates in parallel; D6 runs the `gates:` commands and the git-log commit-shape audit; D7 rebases, folds batched deltas, pushes, opens the PR; D7.5 takes one CI observation; D8 re-arms the adaptive cron.

## Validators

Frontmatter `validators:` names map to `references/validator-prompts.md` sections; all run in parallel on every D5. Contradictions (AP-18) escape to HUMAN_NEEDED; non-contradictory findings spawn a fix pass.

## Failure routing

Every `[BLOCKED: <reason>]` is tagged `(impl)`, `(ci)`, or `(external)`:

- `(impl)` → `consecutive_impl_blocks`; cap `max_impl_blocks` → HUMAN_NEEDED.
- `(ci)` → `consecutive_ci_blocks`; cap `max_ci_blocks` → HUMAN_NEEDED.
- `(external)` → no counter; straight to HUMAN_NEEDED with `reason: external-fault`.

The reason taxonomy lives in `references/conflict-resolution.md` and `references/validator-prompts.md`; a new reason updates both.

## Resuming a runbook

After HUMAN_NEEDED — the operator recovery procedure. `HUMAN_NEEDED` exits the automated loop by design: `--resume` refuses it, and this procedure is the sanctioned re-entry (lifecycle.md Resume step 2 and D1.4 point here).

1. Read the tracker's last entry and identify the blocking Subtask; resolve the block.
2. Append a manual tracker-body entry documenting the resolution and NAMING the resolved block (e.g. `<iso8601> operator-recovery <subtask-id>: resolved [BLOCKED: orphan-resume] — <how>`).
3. Reset the relevant counter (`consecutive_impl_blocks` / `consecutive_ci_blocks`) to 0 in the tracker frontmatter.
4. Flip `STATUS: HUMAN_NEEDED → ACTIVE` in the same edit. This operator flip — with the manual entry (2) and counter reset (3) alongside it — is the ONE sanctioned hand-edit of `STATUS`; the lifecycle's "never hand-flip `STATUS`" rule governs the automated loop and `PAUSED` recovery, not this procedure.
5. Re-dispatch in-session: `/autopilot --drain @<runbook-path>` — that fire's D8 re-arms the cron, so the hand-flip strands nothing.

`--force` resumes append to `force_audit:` (AP-11) — read-only audit, never control flow.
