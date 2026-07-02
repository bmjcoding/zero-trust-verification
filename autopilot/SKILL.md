---
name: autopilot
description: >
  Turn ADRs / design docs / specs into an autonomous task queue and
  drain it into PRs while you sleep. Use when the user says "drain
  ADR", "run autopilot on a doc", "/autopilot", or wants overnight
  autonomous PR drain.
lifecycle: beta
---


# Autopilot


CHANGELOG.md is the single source of truth for version history. This SKILL.md carries no `version:` field (the canonical Anthropic skill schema does not define one); the current release is the top entry in CHANGELOG.md.


Take a spec document — ADR, design doc, RFC, PRD, TO-DO list, anything markdown that defines work — and turn it into a self-prompting drain loop that ships PRs end-to-end. The operator reviews once at GENERATE-time; the loop runs autonomously after that. Autopilot targets Bitbucket Data Center via `git` + REST, runs cleanly inside ephemeral workspace containers (no external scheduler, no host crontab assumptions), and reads secrets via a portable resolver chain (sidecar → keychain → env) so the token never enters Claude's context or tool-call arguments.


## Loading preamble (read first, every invocation)


**Delegation is the positive default, not a fallback.** This skill is an orchestrator. Its job is to name and dispatch subagents (`Explore`, `Plan`, `general-purpose`) that do the actual reading, planning, editing, and testing. Direct orchestrator tool use is limited to reading the tracker/runbook, running short-output git and skill scripts, and writing tracker/runbook edits. Everything else — reading source, running pytest, running long Bashes — belongs to a subagent.


**First-action gate.** Before any tool call in a GENERATE or DRAIN fire, name the subagent you are about to dispatch. If the next action is not a dispatch and does not fall inside the orchestrator-direct allow-list above, stop and re-read this preamble. This gate survives every override in the modes table below; it is Hard Contract §10 stated positively.


**Context-poisoning trap.** Having the SPEC.md, the ADR, or the runbook body in your context window is more reason to delegate, not less. Rich context makes it easy to reach for direct edits because "you already know what to write" — that is the failure mode. The tracker is the source of truth across fires; the orchestrator's job is to keep its own context small enough to survive every step boundary and every auto-compaction. If in doubt, spawn.


**Override scoping.** `--yolo` skips the GENERATE→review gate and arms the drain cron immediately. `--force` bypasses a specific refusal (concurrent drain, existing artifacts) and logs the override to `## Force Audit`. `branching.single_branch_single_pr: true` collapses the drain into one branch + one PR. `branching.no_force_push: true` disables the rolling tracker PR and enables the AP-23 batched-delta queue. **None of these overrides relaxes the delegation contract.** They are orthogonal — a `--yolo` drain still dispatches subagents at every step; a single-branch drain still dispatches subagents at every step; a no-force-push drain still dispatches subagents at every step. Do not read any override as licensing direct orchestrator edits to source files.


## Modes


| Invocation | Mode | What it does |
|---|---|---|
| `/autopilot --generate @<doc>...` | GENERATE (default review path) | Extracts work, plans, writes runbook + tracker, exits for review. Does NOT arm any cron. |
| `/autopilot --generate @<doc>... --yolo` | GENERATE → DRAIN immediately | Same as above, but skips the review step and arms the drain cron. Use when the input is already vetted. |
| `/autopilot --generate @<doc>... --merge` | GENERATE-merge | Append new work from the new docs to an existing runbook + tracker. Refuses if the existing tracker has zero `## Open` items (loop already drained). After the append, re-runs G4 (topological sort + ownership-overlap detection) over the union of old + new Subtasks; refuses with `[GENERATE-FAILED: dangling-dependency]` if any new Subtask's `depends_on[]` references an unknown ID, and `[GENERATE-FAILED: id-collision]` if any new Subtask reuses an existing Subtask ID. |
| `/autopilot --generate @<doc>... --overwrite` | GENERATE-overwrite | Replace existing runbook + tracker. Refuses if any `[x] Done` entries exist (history loss). Logged to `## Force Audit` (AP-11). |
| `/autopilot --generate @<doc>... --jira <PROJ>` | GENERATE + Jira | Same as GENERATE; additionally creates real Jira Story + Subtask tickets via `mcp__dev-tools__activate_jira` and stores keys in the runbook. Shallow integration only — no two-way sync. Implies `enforce_jira_key: true`. |
| `/autopilot --generate @<doc>... --consolidate=auto` | GENERATE + AP-21 consolidation | Enables G3.6 Subtask consolidation for eligible same-kind config / docs Subtasks. Equivalent to `pack_subtasks: true` in the runbook. |
| `/autopilot --drain @<runbook>` | DRAIN | Arms the adaptive cron and starts the work loop on a previously generated runbook. |
| `/autopilot --generate @<doc>... --slug=<name>` | GENERATE + slug override | Overrides the auto-derived slug. Combine with any other GENERATE flag. Slug must match `[a-z0-9][a-z0-9-]*` and be unique across in-flight drains. |
| `/autopilot --resume @<runbook>` | RESUME | Resume a paused drain. Auto-detects `STATUS: PAUSED`, validates runbook + tracker, flips `STATUS: ACTIVE`, re-arms the cron at appropriate cadence, and continues. |
| `/autopilot --force ...` | Any mode + force override | Bypass the matching refusal (concurrent drain, existing artifacts, etc.). Every use is logged to the tracker's `## Force Audit` section with timestamp + flag + reason. AP-11. |


Mode detection: ADR / design-doc / spec markdown → GENERATE. `AUTOPILOT-PROMPT-*.md` with `--drain` → DRAIN. Same file with `--resume` → RESUME.


## When to invoke


- "drain ADR <X>" / "drain ADRs <X> and <Y>"
- "generate the autopilot tracker for <doc>"
- "set up the overnight loop for <feature>"
- Explicit `/autopilot` (any flag combination)


For one-off tasks use `/loop` instead. Autopilot is for multi-task autonomous drain.


## Companion skills


| Skill | Use |
|---|---|
| `/grill-me` | Stress-test under-baked spec before `--generate`. |
| `/loop` | Ad-hoc recurring prompts; autopilot uses adaptive cron internally. |
| `/jira` | Full Jira lifecycle (autopilot's `--jira` is shallow only). |
| `/retro` | Debrief after `STATUS: DRAINED`. |


## Hard contracts (non-negotiable)


1. **One Subtask per drain fire.** Hard contract. Each fire = one tracker delta = one PR or one `[BLOCKED]` reason. No batching (the AP-23 tracker-delta queue is orthogonal — it batches bookkeeping, not Subtasks).
2. **Vanilla Claude Code agents only.** `Explore`, `Plan`, `general-purpose`. No dependency on user-defined `~/.claude/agents/`.
3. **Role-via-prompt, not role-via-subagent_type.** All role differentiation lives in inline prompts in the generated runbook.
4. **Direct-to-main never.** Every commit lands via PR, including tracker bookkeeping (rolling tracker PR OR batched deltas folded into the next Subtask PR — see `references/tracker-delta-batching.md`).
5. **TDD vertical slice with per-cycle local commits.** Code subtasks do RED → GREEN per behavior; each RED is `test: <id>.<n> RED`, each GREEN is `feat: <id>.<n> GREEN`. D6 verifies via `git log`. AP-1.
6. **Non-overlapping file ownership** within a drain — guaranteed by the planner.
7. **No `--no-verify`, no rebases of trunk. `--force` is logged.** AP-11.
8. **Refuse-by-default on existing artifacts.** Re-running `--generate` requires explicit `--merge` or `--overwrite`.
9. **Stop conditions are terminal.** `STATUS: DRAINED | PAUSED | HUMAN_NEEDED | STOPPED` ends the drain; the cron is deleted.
10. **Orchestrator-as-coordinator only. This rule survives every override — `--yolo`, `--force`, single-branch, no-force-push, and any future flag.** Orchestrator NEVER directly Reads source files, Greps the repo, runs pytest, or runs long-output Bashes. Delegate to subagents (Plan, general-purpose, Explore). Orchestrator-direct is limited to (a) Read/Edit on the tracker + runbook, (b) short-output single-line git commands, (c) the skill's own scripts under `${SKILL_DIR}/scripts/`. See the loading preamble at the top of this file for the first-action gate and the context-poisoning trap; both must be honoured at every step boundary. The tracker is the source of truth across fires.
11. **Bitbucket Data Center is the source-of-truth host.** All PR / build-status operations go through `scripts/bitbucket.sh`. The `gh` CLI is NOT a dependency.
12. **Secrets never enter Claude's context.** Tokens are resolved through `scripts/secret_get.sh` (sidecar → keychain → env), echoed only into curl `-H` headers via subshell, and never logged. AP-13/14.
13. **Heartbeats at every step boundary.** D3, D4, D5, D6, D7.x each update `last_heartbeat_at` so D1's 90-min-old crash detector is meaningful. AP-6.
14. **Tracker frontmatter session lock.** Each fire claims a `session_lock` keyed on `${CLAUDE_SESSION_ID}` with `lock_expires_at = now + 30 min`. Two concurrent sessions hitting the same tracker is a refuse. AP-4.
15. **Block counters split by domain.** `consecutive_impl_blocks` and `consecutive_ci_blocks` escalate independently at N≥3 so a CI flake streak doesn't mask real impl failures. External faults (foreign commits, trunk rename, tracker-pr-blocked) route straight to `HUMAN_NEEDED` and don't increment counters. AP-2.


---


## Lifecycle overview


Autopilot has two primary lifecycles plus a small recovery mode. Full step text lives in the references below so that this SKILL.md stays under the 500-line orchestrator-must-read budget. Every step in every reference honours the loading preamble at the top of this file.


### GENERATE mode (G1..G8)


Extract work from spec documents, plan Subtasks, review the plan, write the runbook + tracker, and either exit for operator review (default) or arm the drain cron (`--yolo`). Full step text: `references/generate-lifecycle.md`.


| Step | Purpose | Key contract |
|---|---|---|
| G1 | Pre-flight | Dirty tree / trunk / concurrent drain refuse; sidecar detect |
| G1.5 | Repo-shape probe | AP-23; probes trunk / CI presence / force-push / JIRA hook; seeds frontmatter and `### Repo constraints (detected)` block |
| G2 | Tier-1 extraction | Spawn `general-purpose` with `references/extraction-prompt.md` |
| G3 | Tier-2 planning + audit | Spawn `general-purpose` per Story with `references/planner-prompt.md`; captures `audited_sha` (AP-5) and `test_name_hint` (AP-9) |
| G3.5 | Plan review | Schema-only projection (AP-3); spawn `Plan` in REVIEW mode |
| G3.6 | Subtask consolidation | AP-21; opt-in via `pack_subtasks: true` or `--consolidate=auto` |
| G4 | Topo-sort + hot-file detection | Cycle detect, ownership overlap detect, hot-file DAG edges |
| G5 | Already-shipped detection | Mark Subtasks `[x] Done` pre-emptively with commit SHA |
| G6 | Optional Jira creation | `--jira <PROJ>` only; shallow integration |
| G7 | Write runbook + tracker | Seed tracker frontmatter; write `AUTOPILOT-PROMPT-<slug>.md` + `AUTOPILOT-TRACKER-<slug>.md` |
| G8 | Review or arm | Default: print summary and exit. `--yolo`: invoke DRAIN mode. |


### DRAIN mode (D1..D8)


Each fire is one Subtask end-to-end. Per-fire scope is HARD: one Subtask, one PR (or one `[BLOCKED]`), then exit after writing the next cron and updating the tracker. Full step text: `references/drain-lifecycle.md`.


| Step | Purpose | Key contract |
|---|---|---|
| D1 | Hydrate + WIP recovery | Session lock (AP-4), branch shape (AP-7), heartbeat crash detect, WIP dispatch table, AP-20 drift-notes hydration, AP-23 D1.0.4 pending-deltas migration + crash recovery |
| D2 | Select next Subtask | Topo-walk DAG; escalate at counter cap (AP-2); write `in_progress` (batched under `branching.no_force_push`) |
| D3 | Plan + Plan review | D3.0 audited-SHA verification (AP-5); D3.1 Plan agent; D3.2 review on schema projection (AP-3) |
| D4 | Implement (TDD vertical slice) | Spawn `general-purpose` with `references/implementer-prompt.md`; per-cycle commits (AP-1); JIRA-key prefix under AP-22 |
| D5 | Validate (parallel) | Three validators from `references/validator-prompts.md`; contradictory-finding escape (AP-18) |
| D6 | Test gate + commit-shape audit | Scoped pytest (AP-15); TDD shape from `git log` (AP-1) |
| D7 | Pre-push rebase + commit + PR | D7.0 rebase; D7.1 stage; D7.1a AP-23 tracker-delta fold; D7.2 push; D7.3 PR (`bitbucket.sh pr-open`); D7.4 tracker update (batched under `branching.no_force_push`); D7.5 stacked-merge strategy |
| D7.5 | CI poll (cross-fire) | `ci_check.sh`; short-circuits when `ci.skip_wait: true` |
| D8 | Adaptive cron re-arm | Cadence dispatch per `references/cadence-dispatch.md`; session-lock release on terminal STATUS; PAUSED spec dedup (AP-17) |


### RESUME mode


Triggered by `/autopilot --resume @<runbook>`. Recovers a paused drain without requiring the operator to re-paste a resume prompt. Full step text: `references/drain-lifecycle.md` §"Resume mode".


### Failure escalation, STATUS state machine, tracker-PR availability, end-of-drain output


All defined in `references/drain-lifecycle.md`. The short version: `consecutive_impl_blocks` and `consecutive_ci_blocks` escalate independently at N≥3; external faults route straight to `HUMAN_NEEDED` without incrementing counters; the tracker PR (or the batched-delta queue under `branching.no_force_push`) is the only place bookkeeping ever lands; `STATUS: DRAINED` produces `MERGE-ORDER.md`.


---


## Tracker delta batching (AP-23)


Under `branching.no_force_push: true` (auto-set by G1.5 when the repo rejects force pushes), the rolling tracker PR pattern is disabled — divergence on a rolling tracker branch would be fatal because we cannot force-push to reconcile. Instead, tracker deltas queue inside the tracker file at the `## Pending Tracker Deltas (batched)` section, and the NEXT successful Subtask's PR (D7.1a) flushes the queue into a single atomic commit alongside the impl edit. Full contract: `references/tracker-delta-batching.md`.


Queue entry schema, valid `delta_kind:` values, durability across BLOCKED fires, recovery semantics, and schema migration all live in the reference. Lifecycle integration points (D1.0.4 injection + crash-recovery, D1.0 hydrate, D2 in_progress claim, D7.1a fold + commit body block, D7.3 PR-body section, D7.4 status-change queue) are documented in `references/drain-lifecycle.md`.


---


## Reference index


| File | Purpose | When loaded |
|---|---|---|
| `references/generate-lifecycle.md` | Full G1..G8 step text (AP-21, AP-23 G1.5 probe) | GENERATE (all steps) |
| `references/drain-lifecycle.md` | Full D1..D8 step text; Resume mode; failure escalation; STATUS state machine; tracker-PR availability; end-of-drain output | DRAIN (all steps), RESUME |
| `references/tracker-delta-batching.md` | AP-23 queue contract; `delta_kind:` catalog; recovery semantics; schema migration | DRAIN under `branching.no_force_push: true` |
| `references/extraction-prompt.md` | Tier-1 LLM extractor role prompt | GENERATE Step G2 |
| `references/planner-prompt.md` | Tier-2 planner role prompt with TDD schema requirements | GENERATE Step G3 |
| `references/plan-reviewer-projection.md` | Schema-only projection contract for plan review (AP-3) | GENERATE Step G3.5, DRAIN Step D3.2 |
| `references/implementer-prompt.md` | Step D4 TDD-vertical-slice role prompt with per-cycle commits (AP-1) | DRAIN Step D4 (inlined into runbook) |
| `references/validator-prompts.md` | 3 parallel validator role prompts | DRAIN Step D5 (inlined into runbook) |
| `references/conflict-resolution.md` | Pocock-style rebase protocol | DRAIN Step D7.0 (inlined into runbook) |
| `references/cadence-dispatch.md` | Step D8 cadence dispatch | DRAIN Step D8 (inlined into runbook) |
| `references/sidecar-contract.md` | v0 workspace-sidecar contract (env vars, URL shape, error codes, `## Probe budget under sidecar mode`) | `scripts/secret_get.sh`, `scripts/bitbucket.sh`, `scripts/repo_shape_probe.sh` |
| `references/role-prompts-rationale.md` | ADR-style explanation of why each prompt is shaped the way it is | Maintainer reading; not loaded at runtime |
| `references/runbook-template.md` | The `AUTOPILOT-PROMPT-<slug>.md` skeleton GENERATE fills in | GENERATE Step G7 |
| `scripts/repo_shape_probe.sh` | AP-23 G1.5 repo-shape probe (trunk / CI / force-push / JIRA-hook) | GENERATE Step G1.5 |
| `scripts/repo_shape_probe_patterns.sh` | Regex registry for rejection-message parsing (`match_rejection`) | Sourced by `repo_shape_probe.sh` |
| `scripts/detect_concurrent_drain.sh` | Branch-namespace concurrency check | GENERATE Step G1, DRAIN Step D1 |
| `scripts/hot_file_audit.sh` | 30-day churn analysis | GENERATE Step G4 |
| `scripts/ci_check.sh` | Bitbucket build-status poll (git CLI + REST; no `gh` dependency); emits `LAST_STATE=<value>` on stderr before exit 2/3 | DRAIN Step D7.5 |
| `scripts/bitbucket.sh` | PR lifecycle via Bitbucket DC REST: `pr-open`, `pr-state`, `pr-comment`, `pr-merge` (409 retry + strategy discovery), `pr-approve`, `pr-decline`, `pr-merge-strategies`, `build-status`. XSRF header + UTF-8 response sanitisation applied centrally. | DRAIN Steps D1, D7.3, D7.5 |
| `scripts/secret_get.sh` | Resolver chain: sidecar → keychain → env. Probes a priority list of candidate service names. Token never echoed to stdout/stderr. | All REST-calling scripts |
| `scripts/secret_set.sh` | Operator setup: store token in OS-native keychain. `--as-host` writes to the host-derived joined name; `--force` bypasses the operator-credential abort. | One-time setup |
| `scripts/sidecar_detect.sh` | Detect identity-proxy sidecar; emit MODE=sidecar\|local | GENERATE Step G1, sourced by `bitbucket.sh` |
