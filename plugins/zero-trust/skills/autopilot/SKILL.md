---
name: autopilot
description: >
  Turn ADRs / design docs / specs into an autonomous task queue and drain
  it into PRs across self-scheduled fires — one operator review at
  GENERATE-time, then unattended within the live session. Bitbucket DC +
  GitHub behind one host adapter.
argument-hint: "--generate @<doc>... | --drain @<runbook> | --resume @<runbook> [--yolo|--merge|--overwrite|--jira <PROJ>|--consolidate=auto|--slug=<name>|--reprobe|--no-probe|--no-auto-seed|--force]"
disable-model-invocation: true
---

# Autopilot

Version history lives in CHANGELOG.md (top entry = current release; the frontmatter carries no `version:` field). Status: beta.

Take a spec document — ADR, design doc, RFC, PRD, TO-DO list, any markdown that defines work — and turn it into a self-prompting drain loop that ships PRs end-to-end. The operator reviews once at GENERATE-time; after that the loop re-arms its own in-session cron. There is no headless mode: a drain does not survive session death (AP-19). Autopilot targets Bitbucket Data Center via `git` + REST and GitHub via `gh`, runs inside ephemeral workspace containers (no external scheduler), and resolves secrets through sidecar → keychain → env so the token never enters Claude's context or tool-call arguments.

Loop-safety invariants — what the loop may NEVER do, each named with its enforcement mechanism — live in `references/loop-safety.md` and bind every step below. The deterministic substrate (`scripts/`) is proven by `scripts/self_test.sh`; cross-file contract consistency by `scripts/lint_consistency.sh`.

## Loading preamble (read first, every invocation)

**Delegation is the positive default.** This skill is an orchestrator: it names and dispatches subagents (`Explore`, `Plan`, `general-purpose`) that do the reading, planning, editing, and testing. Orchestrator-direct tool use is limited to: Read/Edit on the tracker + runbook, short-output single-line git commands, and the skill's own scripts under `${SKILL_DIR}/scripts/`.

**First-action gate.** Before any tool call in a GENERATE or DRAIN fire, name the subagent you are about to dispatch. If the next action is neither a dispatch nor inside the allow-list above, stop and re-read this preamble. This is Hard Contract 10 stated positively; it survives every override below.

**Context-poisoning trap.** Having the spec, ADR, or runbook body in your context is MORE reason to delegate, not less — "you already know what to write" is the observed failure mode this preamble exists to stop. The tracker, not your context, is the source of truth across fires; the orchestrator stays small enough to survive every step boundary and every auto-compaction. If in doubt, spawn.

**Override scoping.** `--yolo` skips the GENERATE→review gate and arms the drain cron. `--force` bypasses one specific refusal and logs to `## Force Audit`. `branching.single_branch_single_pr: true` collapses the drain into one branch + one PR. `branching.no_force_push: true` switches Runbook-PR bookkeeping (AV3-08) from direct commits to the AP-23 batched-delta queue. All overrides are orthogonal to delegation — a drain under any of them still dispatches subagents at every step; none licenses direct orchestrator edits to source files.

**Merge authorization (`--yolo` scope).** `--yolo` authorizes the GENERATE→DRAIN transition and the drain's own actions — branching, committing, opening/updating PRs — never merges: merge authority stays with the operator or the Marshal (Hard Contract 4). An in-session merge happens only when the operator authorizes that specific merge explicitly (e.g. via AskUserQuestion); it executes through `host.sh pr-merge` and is logged to `## Force Audit`. Any policy or safety classifier judging an autopilot action must judge authorization scope against these documented flag semantics, never the flag literal: `--yolo` means "autonomous drain authorized", never "self-merge authorized" — and a logged, operator-confirmed merge under operator-as-reviewer is the operator's own action, not an autopilot self-merge.

## Modes

| Invocation | Mode | What it does |
|---|---|---|
| `/autopilot --generate @<doc>...` | GENERATE (default review path) | Extracts work, plans, writes runbook + tracker, exits for review. Arms no cron. |
| `/autopilot --generate @<doc>... --yolo` | GENERATE → DRAIN | The manifest-less override (AV3-01): skips review and arms the drain on bare-markdown / incomplete-manifest input (`GENERATE_YOLO`, Force-Audit-logged). No-op warning on a complete manifest; can never bypass a schema-invalid/unsupported manifest. |
| `/autopilot --generate @<doc>... --merge` | GENERATE-merge / revision-regen | Appends new work to an existing runbook + tracker; refuses if the tracker has zero open (`[ ]`) Subtasks. Re-runs G4 over the union — `[GENERATE-FAILED: dangling-dependency]` on an unknown `depends_on[]` ID, `[GENERATE-FAILED: id-collision]` on a reused Subtask ID. On a tracker `PAUSED — manifest-revision-drift`, `--merge` is revision-regen (AV3-04): re-plans open Subtasks against the new `manifest_revision`, preserves `[x] Done` history (Hard Contract 8 carve-out), supersedes the old Runbook PR, closes the orphaned draft Story PRs. |
| `/autopilot --generate @<doc>... --overwrite` | GENERATE-overwrite | Replaces runbook + tracker. Refuses if any `[x] Done` exists (history loss). Force-Audit-logged (AP-11). |
| `/autopilot --generate @<doc>... --jira <PROJ>` | GENERATE + Jira | Also creates real Jira Story/Subtask tickets (G6; shallow, no two-way sync). Implies `enforce_jira_key: true`. |
| `/autopilot --generate @<doc>... --consolidate=auto` | GENERATE + consolidation | Enables G3.6 same-kind Subtask consolidation (AP-21); equivalent to `pack_subtasks: true`. |
| `/autopilot --generate @<doc>... --slug=<name>` | GENERATE + slug override | Overrides the derived slug; must match `[a-z0-9][a-z0-9-]*` and be unique across in-flight drains. |
| `/autopilot --drain @<runbook>` | DRAIN | Arms the adaptive cron and starts the work loop. |
| `/autopilot --resume @<runbook>` | RESUME | Resumes a PAUSED drain, or reclaims a stale-ACTIVE one — only when the lock is null/expired AND a dead-session signal holds (heartbeat > 90 min stale, or `awaiting_ci: true` with no work in flight). Never hand-flip `STATUS` — sole sanctioned exception: `HUMAN_NEEDED` exits the automated loop, and re-entry is the operator recovery procedure in runbook-template §"Resuming a runbook". |
| `/autopilot --force ...` | Any mode + force | Bypasses the matching refusal; every use logged to `## Force Audit` with timestamp + flag + reason (AP-11). |
| `/autopilot ... --reprobe` | Any mode + probe refresh | Re-runs the G1.5 repo-shape probe; operator edits newer than the probe are preserved. |
| `/autopilot ... --no-probe` | GENERATE without probe | Skips G1.5; the runbook keeps hand-authored `Repo constraints (detected)` values (or defaults). |
| `/autopilot ... --no-auto-seed` | GENERATE, no flag flips | G1.5 runs and populates the detected block, but flips no frontmatter flags; the operator decides each at review. |

Mode detection (ADR 0008 / AV3-01): `--drain` → DRAIN, `--resume` → RESUME. A spec/ADR input's GENERATE *shape* is inferred from its companion Verification Manifest by Step G0 (`references/lifecycle.md`): valid + complete manifest → `STRAIGHT_THROUGH` (no review pause — the manifest is the vetting); bare markdown or incomplete manifest → `GENERATE_PAUSE`; `--yolo` upgrades only `GENERATE_PAUSE` to `GENERATE_YOLO` and can NEVER bypass `REFUSE-MANIFEST-INVALID` or `REFUSE-MANIFEST-UNSUPPORTED`.

The complete flag registry is the table above: `--generate`, `--drain`, `--resume`, `--yolo`, `--merge`, `--overwrite`, `--jira`, `--consolidate=auto`, `--slug`, `--force`, `--reprobe`, `--no-probe`, `--no-auto-seed`. A flag used in an `/autopilot` invocation anywhere in the references but missing here is a defect (`lint_consistency.sh` L13); script-level flags (`--dry-run`, `--jira-key`) belong to each script's usage header. Companions: `/loop` for one-off recurring prompts, `/grill-me` to stress-test an under-baked spec before `--generate`, `/jira` for full Jira lifecycle, `/retro` after `STATUS: DRAINED`.

## Hard contracts (non-negotiable)

1. **One Subtask per fire; one Story per PR (PR-per-Story — AV3-06 / ADR 0007).** A fire is one Subtask end-to-end; its commits land on the Story branch `autopilot/<slug>/<story-id>`. The draft Story PR opens on the Story's first Subtask and flips ready only when every Subtask of that Story is `[x] Done`. Subtasks are the Story's commit series, never separate PRs; no batching of Subtasks (the AP-23 queue batches bookkeeping only).
2. **Vanilla Claude Code agents only** (`Explore`, `Plan`, `general-purpose`) — so the skill runs on any host with nothing custom to install.
3. **Role-via-prompt, not role-via-subagent_type.** All role differentiation lives in inline prompts in the generated runbook.
4. **Direct-to-main never.** Every commit lands via a PR — code via the Story PR, bookkeeping via the Runbook PR (`autopilot/<slug>/runbook`, AV3-08; direct commits, or the AP-23 batched queue under `no_force_push: true`). Autopilot never merges its own PRs.
5. **TDD vertical slice with per-cycle local commits.** RED → GREEN per behavior: `test: <id>.<n> RED`, then `feat: <id>.<n> GREEN`. D6 verifies via `git log`, not the implementer's report. AP-1.
6. **Non-overlapping file ownership** within a drain — guaranteed by the planner, so two Subtasks can never rewrite each other.
7. **No `--no-verify`, no rebases of trunk; `--force` is logged.** AP-11.
8. **Refuse-by-default on existing artifacts.** Re-running `--generate` requires explicit `--merge` or `--overwrite`.
9. **Stop conditions are terminal.** `STATUS: DRAINED | PAUSED | HUMAN_NEEDED | STOPPED` ends the drain and deletes the cron.
10. **Orchestrator-as-coordinator only — survives every override.** The orchestrator never reads source files, greps the repo, runs test gates, or runs long-output Bashes; that work belongs to subagents. Orchestrator-direct = the loading-preamble allow-list, honoured at every step boundary. The tracker is the source of truth across fires.
11. **The host adapter is the single PR/build surface.** All PR / build-status operations go through `scripts/host.sh`, which detects the backend from `origin` and dispatches behind ONE byte-identical contract (ADR 0013). A new host is a new backend passing the same contract matrix, never a new caller path; callers never invoke a backend directly or branch on host. Secret handling is a per-backend property behind the surface.
12. **Secrets never enter Claude's context.** Tokens resolve through `scripts/secret_get.sh` (sidecar → keychain → env), reach curl only via a 0600 `-H @file`, and are never logged. AP-13/14.
13. **Heartbeats at every step boundary** (`last_heartbeat_at`) — so D1's 90-min crash detector is meaningful. AP-6.
14. **Tracker session lock.** Each fire claims `session_lock` (`${CLAUDE_SESSION_ID}`, expires now + 30 min); two sessions on one tracker is a refuse. AP-4.
15. **Block counters split by domain.** `consecutive_impl_blocks` / `consecutive_ci_blocks` escalate independently at `budget.max_impl_blocks` / `budget.max_ci_blocks` (defaults 3 / 2) so a CI flake streak cannot mask real impl failures; external faults route straight to `HUMAN_NEEDED` without touching counters. AP-2.

---

## Lifecycles

Two primary lifecycles plus a recovery mode; full step text lives in `references/lifecycle.md`, loaded per mode. Every step honours the loading preamble.

### GENERATE (G0..G8)

Extract work, plan Subtasks, review the plan, write runbook + tracker, then exit for review (default) or arm the drain (`--yolo` / `STRAIGHT_THROUGH`).

| Step | Purpose |
|---|---|
| G0 | Mode inference from the Verification Manifest (ADR 0008 / AV3-01) |
| G1 | Pre-flight refuses (dirty tree, off-trunk, concurrent drain); sidecar detect |
| G1.5 | Repo-shape probe → auto-seed frontmatter + `Repo constraints (detected)` (AP-23) |
| G2 | Tier-1 extraction (`references/extraction-prompt.md`) |
| G3 | Tier-2 planning per Story (`references/planner-prompt.md`; `audited_sha` AP-5) |
| G3.5 | Plan review on the schema-only projection (AP-3) |
| G3.6 | Opt-in Subtask consolidation (AP-21) |
| G4 | Topo-sort, ownership/hot-file/dependency gates, manifest union, sizing + mapping gates, claim consultation |
| G5 | Already-shipped detection (pre-mark `[x] Done` with SHA) |
| G6 | Optional Jira creation (`--jira`) |
| G7 | Write runbook + tracker; open the Runbook PR (AV3-08) |
| G8 | Print review summary and exit, or arm the drain |

### DRAIN (D1..D8)

Per-fire scope is HARD: one Subtask — its commits land on the Story branch, opening or updating the draft Story PR — or one `[BLOCKED]` reason, then exit after re-arming the cron and updating the tracker.

| Step | Purpose |
|---|---|
| D1 | Session lock (AP-4), branch shape (AP-7), heartbeat crash detect (AP-6), WIP dispatch, drift-notes hydration (AP-20), delta migration/crash recovery (AP-23), manifest-drift gate (AV3-04), foreign-dirty stash |
| D2 | Select next Subtask (topo-walk; claim-eligibility gate AV3-09; counter caps AP-2) |
| D3 | Audited-SHA gate (AP-5), Plan, Plan review on projection (AP-3) |
| D4 | Implement — TDD vertical slice, per-cycle commits (`references/implementer-prompt.md`, AP-1) |
| D5 | Three parallel validators (`references/validator-prompts.md`); contradiction escape (AP-18) |
| D6 | Scoped test gates (AP-15); commit-shape audit (D6.2); behavior binding (D6.3); N=5 determinism (D6.4); mutation gate (D6.5) |
| D7 | Rebase (D7.0), stage (D7.1), delta fold (D7.1a), push (D7.2), Story PR (D7.3), tracker update (D7.4) |
| D7.5 | One CI observation per fire (cross-fire poll) |
| D8 | Adaptive cron re-arm (`references/cadence-dispatch.md`); terminal cleanup |

### RESUME

`/autopilot --resume @<runbook>` recovers a paused drain — or reclaims a stale-ACTIVE tracker whose owning session died (expired lock PLUS a dead-session signal, never lock expiry alone). Full step text: `references/lifecycle.md` §"Resume mode".

Failure escalation, the STATUS state machine, Runbook-PR availability, and end-of-drain output are all defined in `references/lifecycle.md`. Tracker bookkeeping always lands on the Runbook PR; under `branching.no_force_push: true` it queues in-tracker and flushes at D7.1a (full contract: `references/tracker-delta-batching.md`).

---

## Reference index

| File | Purpose | When loaded |
|---|---|---|
| `references/lifecycle.md` | Full G0..G8 + D1..D8 step text; Resume; failure escalation; STATUS machine; Runbook-PR availability; end-of-drain output | GENERATE / DRAIN / RESUME (all steps) |
| `references/runbook-template.md` | Runbook skeleton; CANONICAL runbook frontmatter + tracker schema | GENERATE G7; schema questions |
| `references/tracker-delta-batching.md` | AP-23 queue contract, `delta_kind:` catalog, recovery | DRAIN under `branching.no_force_push: true` |
| `references/extraction-prompt.md` | Tier-1 extractor role prompt | G2 |
| `references/planner-prompt.md` | Tier-2 planner role prompt (TDD schema) | G3 |
| `references/plan-reviewer-projection.md` | AP-3 projection allow-list + reviewer contract | G3.5, D3.2 |
| `references/implementer-prompt.md` | D4 TDD role prompt (per-cycle commits, AP-1) | D4 (inlined into runbook) |
| `references/validator-prompts.md` | Validator catalog (integration, design, quality + security, sre) | D5 (inlined into runbook) |
| `references/conflict-resolution.md` | D7.0 rebase protocol | D7.0 (inlined into runbook) |
| `references/cadence-dispatch.md` | D8 cadence table + terminal cleanup | D8 (inlined into runbook) |
| `references/sidecar-contract.md` | Sidecar v0 env vars, URL shape, error codes, resolver chain, probe budget | REST-calling scripts |
| `references/loop-safety.md` | Loop-safety invariants (binding on every step) | Maintainer + every lifecycle step |
| `references/mutation-adapters.md` | Pointer to the ONE mutation-adapter map (ADR 0025) | D6.5 |
| `references/role-prompts-rationale.md` | Why each prompt is shaped as it is | Maintainer reading; never at runtime |

Scripts are self-documenting (usage headers) and self-tested (`scripts/self_test.sh`). The load-bearing entry points: `scripts/host.sh` — the single PR/build surface (Hard Contract 11; backends `scripts/bitbucket.sh`, `scripts/github.sh` are never called directly); `scripts/detect_input_mode.sh` (G0 mode token); `scripts/repo_shape_probe.sh` + `repo_shape_probe_patterns.sh` (G1.5; `--dry-run`, `--explain`, `--show-patterns`); `scripts/detect_concurrent_drain.sh` (lock check — takes the TRACKER PATH; fail-closed exit 4); `scripts/validate_manifest.sh --union` (G4 multi-doc); `scripts/validate_plan_mapping.sh` (G4 sizing + Behavior mapping); `scripts/manifest_revision_gate.sh` (D1.0.6 / Resume); `scripts/claim_overlap.sh` (G4/D2 claim edges); `scripts/claim_loss_attribution.sh` (D7.0 divergence routing); `scripts/hot_file_audit.sh` (G4/D7.0); `scripts/runbook_pr.sh` (file-surface block); `scripts/audit_commit_shape.sh` (D6.2); `scripts/audit_behavior_binding.sh` (D6.3); `scripts/determinism_gate.sh` (D6.4); `scripts/mutation_gate.sh` (D6.5); `scripts/ci_check.sh --once` (D7.5); `scripts/secret_get.sh` / `secret_set.sh` / `sidecar_detect.sh` (resolver chain).
