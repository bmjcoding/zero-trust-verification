# GENERATE lifecycle (G1..G8)


**Loading-preamble reminder.** Every step below honours the delegation contract in `SKILL.md` §"Loading preamble" and Hard Contract §10: orchestrator dispatches subagents; direct tool use is limited to tracker/runbook Read/Edit, short-output git, and skill scripts. `--yolo`, `--jira`, `--consolidate=auto`, `--slug=`, `--merge`, `--overwrite`, and `--force` do NOT relax the delegation contract. Before any tool call, name the subagent you are about to dispatch.


## Step G1 — Pre-flight


Read in parallel:
- Each input doc passed via `@<path>`
- `git status --short` and `git rev-parse --abbrev-ref HEAD`
- `git symbolic-ref refs/remotes/origin/HEAD | sed 's|refs/remotes/origin/||'` (trunk detection)
- `git log -100 --pretty=format:"%h %s" --since='30 days ago'` (recency context)
- `bash ${SKILL_DIR}/scripts/sidecar_detect.sh` (workspace runtime detection; outputs `MODE=sidecar|local` + sidecar URL if any)


Refuse if working tree is dirty. Refuse if not on trunk. Refuse if any of the input docs don't exist.


Run `bash ${SKILL_DIR}/scripts/detect_concurrent_drain.sh .autopilot/runbooks/<slug>.tracker.md` (the script takes the TRACKER PATH, not a bare slug) — exit 2 means another session holds a live lock: refuse with `STATUS: STOPPED — concurrent drain detected`. Exit 4 (unreadable lock state) is also a refuse — fail closed. Exit 3 (stale lock) may be reclaimed. Operator overrides with `--force` (logged per AP-11).


## Step G1.5 — Repo-shape probe (AP-23)


Run `bash ${SKILL_DIR}/scripts/repo_shape_probe.sh` after the G1 refuses have cleared. The probe emits `KEY=VALUE` lines on stdout:


- `TRUNK=<branch>` (falls back to `main` if `refs/remotes/origin/HEAD` is unset)
- `CI_PRESENT=true|false|unknown` — presence of `bitbucket-pipelines.yml`, `.github/workflows/*.y(a)ml`, `Jenkinsfile`, or `.gitlab-ci.yml` at trunk tip
- `FORCE_PUSH_ALLOWED=true|false|unknown` — determined by pushing a temp branch `autopilot/probe-force-push-<PID>` with a `+` refspec and inspecting the rejection message via `match_rejection`
- `JIRA_HOOK_ENFORCED=true|false|unknown` — determined by pushing a temp branch `autopilot/probe-jira-hook-<PID>` whose HEAD commit subject deliberately omits a JIRA key and inspecting the rejection message


Warnings on stderr; exit 0 even when individual probes return `unknown`. Cleanup is via `trap` on EXIT/INT/TERM — orphan probe branches from killed runs can be cleaned up manually using the naming convention documented in the script header.


### Auto-seed frontmatter


The probe's facts flow into the seeded runbook frontmatter automatically:


- `CI_PRESENT=false` → `ci.skip_wait: true`
- `FORCE_PUSH_ALLOWED=false` → `branching.no_force_push: true`
- `JIRA_HOOK_ENFORCED=true` → `enforce_jira_key: true`


`unknown` values do NOT auto-flip. Each surfaces as a warning in the G8 review summary and the operator decides at review time.


### Auto-populate `### Repo constraints (detected)` block


The probe facts also populate a `### Repo constraints (detected)` block at the top of the seeded runbook body so the operator can read them without re-running the probe. Every fact is annotated with the probe method that produced it (temp-branch push, file presence, etc.) so the operator can verify.


### Design choice: JIRA-hook probe uses a real push


Pre-receive hooks are server-side state. A local heuristic on `git config` / remote URL would miss the actual signal. The only ground truth is "what does the server reject" — hence the temp-branch push with a hook-violating commit subject.


### `--dry-run` mode


`repo_shape_probe.sh --dry-run` prints every probe operation and the temp branch names that WOULD be created, with no network calls. Useful for operators reviewing what the probe will touch before running it against a repo with sensitive pre-receive hooks.


### `--explain` and `--show-patterns` modes


`repo_shape_probe.sh --explain` runs the real probe and additionally prints, on stderr, the reasoning behind each emitted value (which registry pattern matched, which temp branch was used). Stdout stays KEY=VALUE-pure.

`repo_shape_probe.sh --show-patterns` prints the current contents of the `scripts/repo_shape_probe_patterns.sh` registry on stdout and exits 0. No network, no git state. Useful for operators reviewing which rejection patterns are recognized before running a real probe.

Whenever a push rejection matches no registry pattern, the probe emits (always-on): `probe: unknown rejection pattern; please add to repo_shape_probe_patterns.sh: <raw message>` — every operator-visible `unknown` rejection is a candidate new pattern.


## Step G2 — Tier-1 extraction


Spawn ONE `general-purpose` agent with the role prompt at `references/extraction-prompt.md` inlined verbatim. Pass:
- The text of every input doc
- The repo's recent git log (for "already shipped, doc not moved" detection)
- The strict YAML schema the agent must emit


Validate the YAML output against the schema. Required fields: `story_id`, `title`, `source_ref`, `kind`, `behaviors_or_outcomes`, `evidence`. Missing field on any item → re-prompt agent ONCE with the validation error verbatim. Second failure → halt with `[GENERATE-FAILED: extraction-schema]`.


### Tier-1 → tier-2 field transformation


G2 emits `behaviors_or_outcomes` (what "done" looks like, no implementation framing). G3 consumes that and emits `behaviors_to_test` (ordered, observable, drives TDD; first entry is the tracer bullet). One outcome can fan out into multiple test behaviors. See `references/role-prompts-rationale.md` §"Why two-tier extraction" for rationale.


## Step G3 — Tier-2 planning + audit


For each Story emitted in G2, spawn a `general-purpose` agent with the role prompt at `references/planner-prompt.md` inlined verbatim. The planner:


1. Reads the Story's `evidence` block (file refs, ADR section refs)
2. Runs `Read`, `Glob`, `Grep` to verify what already exists in the repo vs. what's missing
3. Decomposes the Story into Subtasks (1–8 files each, <500 LOC delta each)
4. Emits the full tier-2 schema per Subtask (includes `test_name_hint:` per behavior — AP-9)
5. Captures `audited_sha:` at planner-spawn time so D3.0 can detect post-plan drift — AP-5


Run all planners in parallel (one Agent message, multiple tool calls). Validate each output against the schema; missing required fields → re-prompt that planner ONCE. Second failure → mark that Story `[GENERATE-FAILED: planner-schema]` and continue with the rest.


**Budget check (`budget.max_subtasks`).** After all planners return, count the union of emitted Subtasks. If it exceeds the runbook's `budget.max_subtasks` (default 20), refuse with `[GENERATE-FAILED: subtask-budget-exceeded]` citing the count — the operator either raises the budget or splits the input docs into separate drains. Do NOT silently truncate the plan.


## Step G3.5 — Plan review (schema-only projection — AP-3)


For each planner output, spawn a `Plan` agent in REVIEW mode. The reviewer receives a STRIPPED projection of the planner's output. The allow-list of projected fields is defined ONCE, in `references/plan-reviewer-projection.md` §"Allowed fields" — build the projection from that list verbatim (do not re-derive it from memory; a field outside the reviewer's allow-list triggers NEVER-GO).


The reviewer never sees the planner's `evidence` quote, the `contract` semantic-guarantee prose, or the planner's reasoning. This keeps the review independent: the reviewer must form its own judgment from the schema's structural fields rather than agreeing with the planner's narrative.


Reviewer findings → spawn the original planner ONCE with findings verbatim. Second NO-GO → mark Story `[GENERATE-FAILED: plan-review-ungated]` and continue.


## Step G3.6 — Subtask consolidation (AP-21, opt-in)


Off by default. Operators opt in with `pack_subtasks: true` in runbook frontmatter or `--consolidate=auto` on the GENERATE invocation.


When enabled, after G3.5 the orchestrator walks the reviewed plan for consolidation candidates. Eligibility (all conditions):


- Same `kind` (typically `docs` or `config`)
- Same parent Story
- Each Subtask's `estimated_size` is `S` (the planner vocabulary is `S | M | L`)
- `owned_files[]` do not overlap after merge
- `depends_on[]` are consistent (no cycle created by the merge)
- Combined `behaviors_to_test[]` count ≤ 6
- No Subtask in the group is marked `enforce_jira_key: true` with a distinct `jira_key` (Jira Subtasks stay 1:1 with autopilot Subtasks)


Consolidated groups become one Subtask with:
- New `id` = `<lowest-id>+` (e.g., `B2+`)
- Union of `owned_files[]`, `behaviors_to_test[]`, `test_gates[]`
- `estimated_size` = the ceiling of the group's sizes (`S+S` → `M`)
- `Consolidated from:` note listing the merged Subtask IDs


Ineligible or single-Subtask groups pass through unchanged. Consolidation is logged to the runbook's `## Generation Notes` section with the input and output IDs.


## Step G4 — Topological sort + hot-file detection


Run `bash ${SKILL_DIR}/scripts/hot_file_audit.sh --churn` — surfaces the 20 most-churned files in the last 30 days from origin-trunk history. For any Subtask whose `owned_files[]` includes a hot file:


- If another Subtask in this drain also owns that hot file → **force a DAG edge** between them (lower-ID blocks higher-ID). Surface in review summary.


Validate every `depends_on[]` entry against the union of all planner-emitted Subtask IDs — planners run in parallel and cross-Story references are unverifiable at plan time, so this check runs on EVERY generate path (not only `--merge`). Unknown ID → `[GENERATE-FAILED: dangling-dependency]`.


Topo-sort all Subtasks. Detect cycles → `[GENERATE-FAILED: dependency-cycle]`. Detect ownership overlap (same file in two non-dependent Subtasks) → `[GENERATE-FAILED: ownership-overlap]`.


## Step G5 — Already-shipped detection


For every Subtask, the planner already verified file existence. Now check git log: `git log --oneline origin/<trunk> -- <owned_files[]>` for each Subtask (scoped to trunk — `--all` would pick up probe branches and foreign drains). If a recent commit already implemented the Subtask's intent (heuristic: commit message overlaps with `acceptance_criteria`), mark it pre-emptively `[x] Done` in the seeded tracker with the commit SHA cited. This is the Queue A pattern from the original autopilot.


G5-marked Subtasks do NOT affect either failure counter — they're done at GENERATE-time before any drain has started.


## Step G6 — Optional Jira creation (β mode, `--jira <PROJ>` only)


If `--jira <PROJ>` was passed:


0. **Environment check (fail fast).** `--jira` depends on an environment-specific Jira MCP tool surface — this is the ONE mode with a dependency beyond vanilla Claude Code (Hard Contract §2 covers agents; this is a declared external-tool exception). Probe for the Jira tools first (e.g. via ToolSearch); if absent, refuse immediately with `[GENERATE-FAILED: jira-tools-unavailable] — re-run without --jira, or connect a Jira MCP server` rather than halting mid-generate after extraction/planning work is done.
1. Activate the environment's Jira tools (e.g. `mcp__dev-tools__activate_jira` where that server is configured)
2. For each Story → create a Jira Story; populate description from `behaviors_or_outcomes` and `source_ref`
3. For each Subtask → create a Jira Subtask under its parent Story; populate from `acceptance_criteria` and `interface_change`
4. Store `jira_key:` on every Story and Subtask in the runbook
5. Set `enforce_jira_key: true` in the tracker frontmatter (AP-22) so every commit prefixes `[<JIRA-KEY>]`. Smart Commits transition Subtasks on PR merge.


Failures here (auth missing, project doesn't exist, etc.) → halt with clear error message; operator resolves and re-runs.


## Step G7 — Write runbook + tracker


Render `references/runbook-template.md` with all the data accumulated so far. Write to the canonical artifact paths:


- `.autopilot/runbooks/<slug>.md` — the runbook (operator-editable until the drain is armed; immutable during an active drain except the G1.5-owned `Repo constraints (detected)` block)
- `.autopilot/runbooks/<slug>.tracker.md` — the seeded tracker


Seed the tracker frontmatter with these defaults:


```yaml
---
STATUS: ACTIVE
consecutive_impl_blocks: 0      # AP-2: split counters
consecutive_ci_blocks: 0
drain_start_sha: <sha>
audited_sha: <sha>              # AP-5: SHA at planner-spawn time
trunk_branch: <name>            # from G1.5 TRUNK=
host: bitbucket-dc
ci:
  skip_wait: <bool>             # G1.5 CI_PRESENT auto-set
branching:
  no_force_push: <bool>         # G1.5 FORCE_PUSH_ALLOWED auto-set
  single_branch_single_pr: false  # operator-toggle only
enforce_jira_key: <bool>        # G1.5 JIRA_HOOK_ENFORCED or --jira auto-set
pack_subtasks: <bool>           # AP-21 operator-toggle
in_progress: null
session_lock: null              # AP-4
session_lock_expires_at: null
force_audit: []                 # AP-11
---
```


Seed the tracker body with the standard sections plus, when `branching.no_force_push: true`, an empty `## Pending Tracker Deltas (batched)` section marked `_(empty)_`. Full body layout in `references/runbook-template.md`.


`<slug>` is derived from the input docs (e.g., `0042-foo` for a single ADR; `tier4-tfl-parity` for an umbrella ADR family). Operator can override via `--slug=<name>`.


The runbook's first commit creates a feature branch `autopilot/<slug>/setup` with shape verification (AP-7). Under `branching.no_force_push: false` (default) the rolling tracker PR `[autopilot] tracker — drain <slug>` is also created. Under `branching.no_force_push: true`, no tracker PR is created — the AP-23 batched-delta queue is used instead (see `references/tracker-delta-batching.md`).


## Step G8 — Review or arm


**Default (review path):** Print a structured summary then exit (no cron arming). Required content: drain slug; Stories count; Subtasks count broken down by `kind` and `estimated_size`; already-shipped (G5) count; hot-file serializations applied; G1.5 probe facts + any `unknown` values that need operator review; consolidations applied (G3.6); estimated drain runtime; paths of the runbook + tracker; rolling tracker PR URL (or "batched-delta queue active" under `branching.no_force_push`); the exact `/autopilot --drain @<runbook-path>` command to start the drain; one-line reminder to edit before draining.


**`--yolo` path:** Skip the review entirely; immediately invoke the DRAIN mode as if operator typed `/autopilot --drain @.autopilot/runbooks/<slug>.md`.
