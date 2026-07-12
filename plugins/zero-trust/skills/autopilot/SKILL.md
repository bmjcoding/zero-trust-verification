---
name: autopilot
description: >
  Turn ADRs / design docs / specs into an autonomous task queue and
  drain it into PRs across self-scheduled fires — no re-prompting
  between Subtasks for as long as the session lives. Use when the user
  says "drain ADR", "run autopilot on a doc", "/autopilot", or wants an
  unattended-within-session PR drain.
argument-hint: "--generate @<doc>... | --drain @<runbook> | --resume @<runbook> [--yolo|--merge|--overwrite|--jira <PROJ>|--consolidate=auto|--slug=<name>|--reprobe|--no-probe|--no-auto-seed|--force]"
---


# Autopilot


CHANGELOG.md is the single source of truth for version history. This SKILL.md carries no `version:` or `lifecycle:` field (the canonical Anthropic skill schema defines neither); the current release is the top entry in CHANGELOG.md. Status: beta.


Take a spec document — ADR, design doc, RFC, PRD, TO-DO list, anything markdown that defines work — and turn it into a self-prompting drain loop that ships PRs end-to-end. The operator reviews once at GENERATE-time; after that the loop runs autonomously **within a live Claude Code session** — the adaptive cron re-arms in-session, and the drain does not survive session death (there is no headless mode; see AP-19 in `references/role-prompts-rationale.md`). Autopilot targets Bitbucket Data Center via `git` + REST, runs cleanly inside ephemeral workspace containers (no external scheduler, no host crontab assumptions), and reads secrets via a portable resolver chain (sidecar → keychain → env) so the token never enters Claude's context or tool-call arguments.

Loop-safety invariants (what the loop may NEVER do, and which mechanism enforces each) live in `references/loop-safety.md`; every lifecycle step below is bound by them. The deterministic substrate (all `scripts/`) is covered by `scripts/self_test.sh`; cross-file contract consistency is enforced by `scripts/lint_consistency.sh`.


## Loading preamble (read first, every invocation)


**Delegation is the positive default, not a fallback.** This skill is an orchestrator. Its job is to name and dispatch subagents (`Explore`, `Plan`, `general-purpose`) that do the actual reading, planning, editing, and testing. Direct orchestrator tool use is limited to reading the tracker/runbook, running short-output git and skill scripts, and writing tracker/runbook edits. Everything else — reading source, running test gates, running long Bashes — belongs to a subagent.


**First-action gate.** Before any tool call in a GENERATE or DRAIN fire, name the subagent you are about to dispatch. If the next action is not a dispatch and does not fall inside the orchestrator-direct allow-list above, stop and re-read this preamble. This gate survives every override in the modes table below; it is Hard Contract §10 stated positively.


**Context-poisoning trap.** Having the SPEC.md, the ADR, or the runbook body in your context window is more reason to delegate, not less. Rich context makes it easy to reach for direct edits because "you already know what to write" — that is the failure mode. The tracker is the source of truth across fires; the orchestrator's job is to keep its own context small enough to survive every step boundary and every auto-compaction. If in doubt, spawn.


**Override scoping.** `--yolo` skips the GENERATE→review gate and arms the drain cron immediately. `--force` bypasses a specific refusal (concurrent drain, existing artifacts) and logs the override to `## Force Audit`. `branching.single_branch_single_pr: true` collapses the drain into one branch + one PR. `branching.no_force_push: true` switches tracker bookkeeping on the Runbook PR (AV3-08) from direct commits to the AP-23 batched-delta queue (appends only, no force-push). **None of these overrides relaxes the delegation contract.** They are orthogonal — a `--yolo` drain still dispatches subagents at every step; a single-branch drain still dispatches subagents at every step; a no-force-push drain still dispatches subagents at every step. Do not read any override as licensing direct orchestrator edits to source files.


**Merge-authorization semantics (`--yolo` scope).** `--yolo` is explicit-autonomy authorization for the GENERATE→DRAIN transition and the drain's own actions — branching, committing, opening/updating PRs. It is NOT merge authority: merging stays with the operator or the Marshal (Hard Contract 4). When a merge is wanted in-session — the classic case is a setup PR on a personal repo where the operator is also the sole reviewer — the operator authorizes **that specific merge** explicitly (e.g. via AskUserQuestion), the merge executes through `host.sh pr-merge`, and the authorization is logged to `## Force Audit`. Any policy or safety classifier evaluating an autopilot action should judge authorization scope against these documented flag semantics, never the flag literal: `--yolo` present means "autonomous drain authorized", never "self-merge authorized" — and a logged, operator-confirmed merge under operator-as-reviewer is the operator's own action, not an autopilot self-merge.


## Modes


| Invocation | Mode | What it does |
|---|---|---|
| `/autopilot --generate @<doc>...` | GENERATE (default review path) | Extracts work, plans, writes runbook + tracker, exits for review. Does NOT arm any cron. |
| `/autopilot --generate @<doc>... --yolo` | GENERATE → DRAIN immediately | The **manifest-less override** (AV3-01): skips the review step and arms the drain cron on bare-markdown / incomplete-manifest input (`GENERATE_YOLO`, Force-Audit-logged). No-op warning on a complete manifest (already `STRAIGHT_THROUGH`); cannot bypass a schema-invalid/unsupported manifest. |
| `/autopilot --generate @<doc>... --merge` | GENERATE-merge / revision-regen | Append new work from the new docs to an existing runbook + tracker. Refuses if the existing tracker has zero open (`[ ]`) Subtasks (loop already drained). After the append, re-runs G4 (topological sort + ownership-overlap detection) over the union of old + new Subtasks; refuses with `[GENERATE-FAILED: dangling-dependency]` if any new Subtask's `depends_on[]` references an unknown ID, and `[GENERATE-FAILED: id-collision]` if any new Subtask reuses an existing Subtask ID. **Revision-regen (AV3-04):** when the existing tracker is `PAUSED — manifest-revision-drift`, `--merge` is the path back — it re-plans the open (`[ ]`) Subtasks against the new `manifest_revision`, **preserves `[x] Done` history** (a Hard Contract 8 carve-out), supersedes the old Runbook PR (AV3-08), and closes the orphaned draft Story PRs it lists. |
| `/autopilot --generate @<doc>... --overwrite` | GENERATE-overwrite | Replace existing runbook + tracker. Refuses if any `[x] Done` entries exist (history loss). Logged to `## Force Audit` (AP-11). |
| `/autopilot --generate @<doc>... --jira <PROJ>` | GENERATE + Jira | Same as GENERATE; additionally creates real Jira Story + Subtask tickets via `mcp__dev-tools__activate_jira` and stores keys in the runbook. Shallow integration only — no two-way sync. Implies `enforce_jira_key: true`. |
| `/autopilot --generate @<doc>... --consolidate=auto` | GENERATE + AP-21 consolidation | Enables G3.6 Subtask consolidation for eligible same-kind config / docs Subtasks. Equivalent to `pack_subtasks: true` in the runbook. |
| `/autopilot --drain @<runbook>` | DRAIN | Arms the adaptive cron and starts the work loop on a previously generated runbook. |
| `/autopilot --generate @<doc>... --slug=<name>` | GENERATE + slug override | Overrides the auto-derived slug. Combine with any other GENERATE flag. Slug must match `[a-z0-9][a-z0-9-]*` and be unique across in-flight drains. |
| `/autopilot --resume @<runbook>` | RESUME | Resume a paused drain — or reclaim a stale-ACTIVE one. `STATUS: PAUSED` → validates runbook + tracker, flips `STATUS: ACTIVE`, re-arms the cron at appropriate cadence, and continues. `STATUS: ACTIVE` → refused while the session lock is live; reclaimed (`ACTIVE → PAUSED`, then the normal PAUSED path) only when the lock is null/expired AND a dead-session signal holds — `last_heartbeat_at` > 90 min stale (the D1.3 crash standard) or `awaiting_ci: true` with no in-flight Subtask work (lifecycle.md §Resume step 2). Never hand-flip `STATUS`. |
| `/autopilot --force ...` | Any mode + force override | Bypass the matching refusal (concurrent drain, existing artifacts, etc.). Every use is logged to the tracker's `## Force Audit` section with timestamp + flag + reason. AP-11. |
| `/autopilot ... --reprobe` | Any mode + probe refresh | Re-run the G1.5 repo-shape probe against an existing runbook and refresh the `Repo constraints (detected)` block (operator edits newer than the probe are preserved). |
| `/autopilot ... --no-probe` | GENERATE without probe | Skip G1.5 entirely; the runbook keeps hand-authored `Repo constraints (detected)` values (or defaults when none). |
| `/autopilot ... --no-auto-seed` | GENERATE + probe, no flag flips | G1.5 still runs and populates the detected block, but no frontmatter flags are auto-flipped; the operator decides each at review. |


Mode detection (ADR 0008 / AV3-01): a runbook under `.autopilot/runbooks/` with `--drain` → DRAIN, with `--resume` → RESUME. A spec/ADR/design-doc → GENERATE, but the *shape* of the GENERATE is inferred from the input's companion Verification Manifest (`<spec-basename>.manifest.yaml`): the orchestrator validates it via the manifest validator (the spec-tier's single-file `validate_manifest.sh`, vendored per ADR 0001; autopilot's own `scripts/validate_manifest.sh --union` adds the multi-doc refusals) and feeds the path + exit code to `scripts/detect_input_mode.sh`, which returns the MODE token. A **valid + complete manifest → `STRAIGHT_THROUGH`** (GENERATE→DRAIN with no review pause, no flag — the manifest is the vetting). **Bare markdown or an incomplete manifest → `GENERATE_PAUSE`** (GENERATE, then pause for review). **`--yolo` is the manifest-less override only** — it turns `GENERATE_PAUSE` into `GENERATE_YOLO` (skip review, arm the drain, Force-Audit-logged); on a complete manifest it is a no-op warning, and it can NEVER bypass a schema-invalid (`REFUSE-MANIFEST-INVALID`) or unsupported-version (`REFUSE-MANIFEST-UNSUPPORTED`) manifest.

The complete flag registry is the table above plus this list — any flag used in an `/autopilot` invocation anywhere in the references but missing here is a defect (`lint_consistency.sh` L13 scans for exactly that): `--generate`, `--drain`, `--resume`, `--yolo`, `--merge`, `--overwrite`, `--jira`, `--consolidate=auto`, `--slug`, `--force`, `--reprobe`, `--no-probe`, `--no-auto-seed`. (Script-level flags such as the probe's `--dry-run`/`--jira-key` belong to each script's usage header, not this registry.)


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


1. **One Subtask per drain fire; one Story per PR (PR-per-Story — AV3-06 / ADR 0007).** Each fire is still exactly one Subtask end-to-end, but its commit series lands on the **Story branch** `autopilot/<slug>/<story-id>`, and the PR granularity is the **Story**, never the Subtask: a draft Story PR is opened on the Story's first Subtask, kept draft until every one of that Story's Subtasks is `[x] Done`, then flipped ready-for-review. Subtasks are the Story's commit series, not separate PRs. No batching of Subtasks (the AP-23 tracker-delta queue is orthogonal — it batches bookkeeping, not Subtasks).
2. **Vanilla Claude Code agents only.** `Explore`, `Plan`, `general-purpose`. No dependency on user-defined `~/.claude/agents/`.
3. **Role-via-prompt, not role-via-subagent_type.** All role differentiation lives in inline prompts in the generated runbook.
4. **Direct-to-main never.** Every commit lands via a PR — code via the Story PR, tracker bookkeeping via the **Runbook PR** (`autopilot/<slug>/runbook`, AV3-08): direct commits under `no_force_push: false`, or the AP-23 batched-delta queue flushed onto the runbook branch under `no_force_push: true` (see `references/tracker-delta-batching.md`). Autopilot never merges its own PRs.
5. **TDD vertical slice with per-cycle local commits.** Code subtasks do RED → GREEN per behavior; each RED is `test: <id>.<n> RED`, each GREEN is `feat: <id>.<n> GREEN`. D6 verifies via `git log`. AP-1.
6. **Non-overlapping file ownership** within a drain — guaranteed by the planner.
7. **No `--no-verify`, no rebases of trunk. `--force` is logged.** AP-11.
8. **Refuse-by-default on existing artifacts.** Re-running `--generate` requires explicit `--merge` or `--overwrite`.
9. **Stop conditions are terminal.** `STATUS: DRAINED | PAUSED | HUMAN_NEEDED | STOPPED` ends the drain; the cron is deleted.
10. **Orchestrator-as-coordinator only. This rule survives every override — `--yolo`, `--force`, single-branch, no-force-push, and any future flag.** Orchestrator NEVER directly Reads source files, Greps the repo, runs test gates, or runs long-output Bashes. Delegate to subagents (Plan, general-purpose, Explore). Orchestrator-direct is limited to (a) Read/Edit on the tracker + runbook, (b) short-output single-line git commands, (c) the skill's own scripts under `${SKILL_DIR}/scripts/`. See the loading preamble at the top of this file for the first-action gate and the context-poisoning trap; both must be honoured at every step boundary. The tracker is the source of truth across fires.
11. **The host adapter is the single PR/build surface.** All PR / build-status operations go through `scripts/host.sh`, which detects the backend from `origin` and dispatches to `scripts/bitbucket.sh` (Bitbucket Data Center) or `scripts/github.sh` (GitHub via `gh`) behind ONE byte-identical contract. Autopilot is host-agnostic BY CONTRACT (ADR 0013): a new host is a new backend passing the same contract matrix, never a new caller path. Secret handling and loop-safety are per-backend properties behind the surface (DC routes the sidecar→keychain→env resolver; GitHub delegates to `gh`'s auth). Callers NEVER invoke a backend directly or branch on host.
12. **Secrets never enter Claude's context.** Tokens are resolved through `scripts/secret_get.sh` (sidecar → keychain → env), echoed only into curl `-H` headers via subshell, and never logged. AP-13/14.
13. **Heartbeats at every step boundary.** D3, D4, D5, D6, D7.x each update `last_heartbeat_at` so D1's 90-min-old crash detector is meaningful. AP-6.
14. **Tracker frontmatter session lock.** Each fire claims a `session_lock` keyed on `${CLAUDE_SESSION_ID}` with `lock_expires_at = now + 30 min`. Two concurrent sessions hitting the same tracker is a refuse. AP-4.
15. **Block counters split by domain.** `consecutive_impl_blocks` and `consecutive_ci_blocks` escalate independently at the runbook's `budget.max_impl_blocks` / `budget.max_ci_blocks` caps (defaults 3 / 2) so a CI flake streak doesn't mask real impl failures. External faults (foreign commits, trunk rename, runbook-pr-blocked) route straight to `HUMAN_NEEDED` and don't increment counters. AP-2.


---


## Lifecycle overview


Autopilot has two primary lifecycles plus a small recovery mode. Full step text lives in the references below so that this SKILL.md stays under the 500-line orchestrator-must-read budget. Every step in every reference honours the loading preamble at the top of this file.


### GENERATE mode (G1..G8)


Extract work from spec documents, plan Subtasks, review the plan, write the runbook + tracker, and either exit for operator review (default) or arm the drain cron (`--yolo`). Full step text: `references/lifecycle.md`.


| Step | Purpose | Key contract |
|---|---|---|
| G1 | Pre-flight | Dirty tree / trunk / concurrent drain refuse; sidecar detect |
| G1.5 | Repo-shape probe | AP-23; probes trunk / CI presence / CI status-reporting / force-push / JIRA hook; seeds frontmatter and `### Repo constraints (detected)` block |
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


Each fire is one Subtask end-to-end. Per-fire scope is HARD: one Subtask — its commit series lands on the Story branch, opening or updating the draft Story PR (PR-per-Story) — or one `[BLOCKED]` reason, then exit after writing the next cron and updating the tracker. Full step text: `references/lifecycle.md`.


| Step | Purpose | Key contract |
|---|---|---|
| D1 | Hydrate + WIP recovery | Session lock (AP-4), branch shape (AP-7), heartbeat crash detect, WIP dispatch table, AP-20 drift-notes hydration, AP-23 D1.0.4 pending-deltas migration + crash recovery, D1.2 foreign-dirty stash |
| D2 | Select next Subtask | Topo-walk DAG; escalate at counter cap (AP-2); write `in_progress` (batched under `branching.no_force_push`) |
| D3 | Plan + Plan review | D3.0 audited-SHA verification (AP-5); D3.1 Plan agent; D3.2 review on schema projection (AP-3) |
| D4 | Implement (TDD vertical slice) | Spawn `general-purpose` with `references/implementer-prompt.md`; per-cycle commits (AP-1); JIRA-key prefix under AP-22 |
| D5 | Validate (parallel) | Three validators from `references/validator-prompts.md`; contradictory-finding escape (AP-18) |
| D6 | Test gate + commit-shape audit | Scoped `gates:` commands (AP-15); TDD shape + cycle budget from `git log` (AP-1) |
| D7 | Pre-push rebase + commit + PR | D7.0 rebase; D7.1 stage; D7.1a AP-23 tracker-delta fold; D7.2 push; D7.3 PR (`host.sh pr-open`); D7.3a stacked-merge strategy (AP-10); D7.4 tracker update (batched under `branching.no_force_push`) |
| D7.5 | CI poll (cross-fire) | `ci_check.sh --once`; short-circuits when `ci.skip_wait: true` |
| D8 | Adaptive cron re-arm | Cadence dispatch per `references/cadence-dispatch.md`; session-lock release on terminal STATUS; terminal-fire contract (stale-ACTIVE reclaim is Resume's); PAUSED spec dedup (AP-17) |


### RESUME mode


Triggered by `/autopilot --resume @<runbook>`. Recovers a paused drain — and reclaims a stale-ACTIVE tracker whose owning session died (step 2's stale-ACTIVE reclaim; gated on an expired lock PLUS a dead-session signal, never lock expiry alone) — without requiring the operator to re-paste a resume prompt. Full step text: `references/lifecycle.md` §"Resume mode".


### Failure escalation, STATUS state machine, tracker-PR availability, end-of-drain output


All defined in `references/lifecycle.md`. The short version: `consecutive_impl_blocks` and `consecutive_ci_blocks` escalate independently at the runbook's `budget.max_impl_blocks` / `budget.max_ci_blocks` caps (defaults 3 / 2); external faults route straight to `HUMAN_NEEDED` without incrementing counters; the Runbook PR (AV3-08) is the only place bookkeeping ever lands; `STATUS: DRAINED` produces `MERGE-ORDER.md`.


---


## Tracker delta batching (AP-23)


All tracker bookkeeping lands on the Runbook PR (`autopilot/<slug>/runbook`, AV3-08). Under `branching.no_force_push: true` (auto-set by G1.5 when the repo rejects force pushes), deltas cannot be reconciled by force-push, so instead of committing each one directly they queue inside the tracker file at the `## Pending Tracker Deltas (batched)` section, and D7.1a flushes the queue as an append commit onto the runbook branch (never mixed into a Story PR — one bookkeeping home, no self-intersecting claim surfaces). Full contract: `references/tracker-delta-batching.md`.


Queue entry schema, valid `delta_kind:` values, durability across BLOCKED fires, recovery semantics, and schema migration all live in the reference. Lifecycle integration points (D1.0.4 injection + crash-recovery, D1.0 hydrate, D2 in_progress claim, D7.1a fold + commit body block, D7.3 PR-body section, D7.4 status-change queue) are documented in `references/lifecycle.md`.


---


## Reference index


| File | Purpose | When loaded |
|---|---|---|
| `references/lifecycle.md` §GENERATE | Full G1..G8 step text (AP-21, AP-23 G1.5 probe) | GENERATE (all steps) |
| `references/lifecycle.md` §DRAIN | Full D1..D8 step text; Resume mode; failure escalation; STATUS state machine; tracker-PR availability; end-of-drain output | DRAIN (all steps), RESUME |
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
| `references/loop-safety.md` | Loop-safety invariants: what the loop may never do, and which mechanism enforces each | Maintainer + every lifecycle step (binding) |
| `scripts/repo_shape_probe.sh` | AP-23 G1.5 repo-shape probe (trunk / CI presence / CI status-reporting / force-push / JIRA-hook); `--dry-run`, `--explain` (reasoning trace on stderr), `--show-patterns` | GENERATE Step G1.5 |
| `scripts/repo_shape_probe_patterns.sh` | Regex registry for rejection-message parsing (`match_rejection`; signal = text after the LAST `\|` so regexes may contain alternations) | Sourced by `repo_shape_probe.sh` |
| `scripts/detect_concurrent_drain.sh` | Tracker session-lock concurrency check (canonical `session_lock` / `session_lock_expires_at` fields; fail-closed exit 4 on unreadable state). Takes the TRACKER PATH. | GENERATE Step G1, DRAIN Step D1 |
| `scripts/hot_file_audit.sh` | `--churn`: 30-day churn analysis (G4). `--subtasks <slug>`: cross-branch overlap hotspots (D7.0). | GENERATE Step G4, DRAIN Step D7.0 |
| `scripts/host.sh` | **The single PR/build surface (ADR 0013).** Detects the backend from `origin` (`BITBUCKET_DC` via the `/scm/` path shape, `GITHUB` via `github.com`, override via `$AUTOPILOT_HOST_BACKEND`) and dispatches `pr-open [--draft]`, `pr-ready`, `pr-state`, `pr-comment`, `pr-merge`, `pr-approve`, `pr-decline`, `pr-merge-strategies`, `build-status` by exec (byte-identical pass-through). `host.sh backend` prints the detected backend. | DRAIN Steps D1, D7.3, D7.5 |
| `scripts/ci_check.sh` | Build-status check via the host adapter (`host.sh` — host-agnostic). Dispatcher uses `--once` (single observation: GREEN/RED/PENDING/PR_DECLINED, exits 0/1/5/4); blocking poll mode is operator-only. `LAST_STATE=<actual last build state>` on stderr before every exit. | DRAIN Step D7.5 |
| `scripts/bitbucket.sh` | Bitbucket DC backend behind `host.sh`: `pr-open [--draft]`, `pr-ready`, `pr-state` (`--num`/`--branch`, emits `DRAFT`), `pr-comment`, `pr-merge` (409 retry + strategy discovery), `pr-approve`, `pr-decline`, `pr-merge-strategies`, `build-status`. XSRF header + UTF-8 request AND response sanitisation applied centrally. Draft mechanism via `AUTOPILOT_BITBUCKET_DRAFT_MODE` (native `draft` flag, or `title-prefix` fallback for older servers). REST host derivation: `AUTOPILOT_BITBUCKET_HOST` override > https-origin host > ssh-origin host with the `-ssh` endpoint suffix stripped (split-SSH-endpoint DC convention); internal `repo-coords` debug subcommand prints the derivation. | DC backend (via `host.sh`) |
| `scripts/github.sh` | GitHub backend behind `host.sh`, implementing the byte-identical contract via the `gh` CLI (which owns credential resolution — token never in argv/context). Maps GitHub's vocabulary onto the shared one (`isDraft`→`DRAFT`, `CLOSED`→`DECLINED`); `build-status` aggregates the commit-status AND check-runs APIs. | GitHub backend (via `host.sh`) |
| `scripts/secret_get.sh` | Resolver chain: sidecar → keychain → env. Probes a priority list of candidate service names (`--list-candidates` prints them). Token never echoed to stdout/stderr, never in argv. | All REST-calling scripts |
| `scripts/secret_set.sh` | Operator setup: store token in OS-native keychain. `--as-host` writes the host-scoped `autopilot-<service>-<host>` name; default mode probes ALL resolver candidates and aborts on collision; `--force` bypasses. | One-time setup |
| `scripts/sidecar_detect.sh` | Detect identity-proxy sidecar (HTTP 200 + "ok" body); emit MODE=sidecar\|local | GENERATE Step G1, sourced by `bitbucket.sh` |
| `scripts/detect_input_mode.sh` | **Mode inference (ADR 0008 / AV3-01).** Maps (intent, manifest presence, validator exit, `--yolo`) → MODE token (`STRAIGHT_THROUGH` \| `GENERATE_PAUSE` \| `GENERATE_YOLO` \| `DRAIN` \| `RESUME` \| `REFUSE-MANIFEST-*`). Pure decision function. | GENERATE Step G0 |
| `scripts/validate_manifest.sh` | **Multi-doc union check (MS §2 / AV3-03).** `--union <a> <b> …`: cross-manifest Journey/Behavior ID collision + `observability.profile`/`environments` mismatch. (Single-file schema validation is the spec-tier's vendored validator.) | GENERATE Step G4 |
| `scripts/validate_plan_mapping.sh` | **Plan gate (AV3-07 + AV3-02).** `<plan.json> [<manifest>]`: 48h Story sizing (`predicted_hours` vs S/M/L ceiling; Story roll-up ≤48) + Subtask↔Behavior-ID mapping (unmapped/unowned/unknown). | GENERATE Step G4 |
| `scripts/manifest_revision_gate.sh` | **Revision drift (MS §6 / AV3-04).** `drift <tracker> <manifest>` (D1.0.6 hydrate check) + `resume-check <tracker>` (Resume refusal → `--generate --merge` revision-regen). | DRAIN Step D1.0.6, RESUME |
| `scripts/runbook_pr.sh` | **Runbook PR helper (AV3-08).** `file-surface <body>`: extract the grep-able predicted-file-surface block (marker-delimited) from a Runbook PR body. | GENERATE Step G7, DRAIN D1 |
| `scripts/claim_overlap.sh` | **Claim consultation (ADR 0009 / AV3-09) — VENDORED byte-identical.** Classifies open-PR file-surface overlaps (BINDING/TERMINAL/ADVISORY/EXCLUDED) → `blocked_by_pr` edges; `eligibility --pr-state` is the D2 gate. | GENERATE Step G4, DRAIN Step D2 |
| `scripts/claim_loss_attribution.sh` | **Divergence routing (AV3-10).** Intersects rebase-conflict files with claim-overlap files → `REPLAN` (route to D3, bounded 2/Subtask) vs `NOT-ATTRIBUTED` (impl-block). | DRAIN Step D7.0 |
| `scripts/audit_commit_shape.sh` | **D6.2 TDD commit-shape audit (AV3-06).** Audits `prev_pushed_sha..HEAD` (Story-range, not whole-branch — no false `tdd-scope-leak`) for RED/GREEN pairing, order, jira-key, refactor/docs shapes. | DRAIN Step D6.2 |
| `scripts/audit_behavior_binding.sh` | **D6.3 Behavior→test binding (MS §13.9 / AV3-05).** Verifies each mapped Behavior is bound to a test NAMED in a `test: … RED` commit (`unbound-behavior`/`unproven-binding`). | DRAIN Step D6.3 |
| `scripts/determinism_gate.sh` | **D6.4 determinism gate, N=5 (AV3-12).** Runs the resolved scoped-test command 5× (one order-randomized, or a loud skip-note), compares exit codes + failure fingerprints → `[BLOCKED: flaky-test]`. Runner-agnostic. | DRAIN Step D6.4 |
| `scripts/self_test.sh` | Hermetic self-test of every script against fixtures (mock Bitbucket server via `uv run`, local bare repos, deny-hooks, gh-argv shim). Run after ANY change under `scripts/`. | Maintainer / CI |
| `scripts/lint_consistency.sh` | Cross-file contract lint (L1–L23): canonical paths, tracker schema, step ids, validator catalog, flag registry, version refs, no consumer-repo leakage, host-adapter surface (L16), PR-per-Story (L17), AP-3 allow-list (L18), Runbook PR (L19), Behavior-coverage format (L20), anti-flakiness (L21), vendored escalation (L22), as-built docs (L23) | Maintainer / CI (also invoked by `self_test.sh`) |
