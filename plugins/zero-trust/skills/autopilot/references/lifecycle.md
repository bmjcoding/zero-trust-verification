# Autopilot lifecycles — GENERATE (G0..G8), DRAIN (D1..D8), Resume, failure escalation, STATUS, Runbook-PR availability, end-of-drain output

**Loading-preamble reminder (survives auto-compaction).** Every step below honours the delegation contract in `SKILL.md` §"Loading preamble" and Hard Contract 10. Delegation is the positive default: before any tool call, name the subagent you are about to dispatch. Every override — `--yolo`, `--force`, `--jira`, `--consolidate=auto`, `--slug=`, `--merge`, `--overwrite`, `branching.single_branch_single_pr`, `branching.no_force_push`, and any future flag — is ORTHOGONAL to this contract; none licenses direct orchestrator edits to source files. Rich context (spec, ADR, runbook body) is *more* reason to delegate, not less. First-action gate: if the next action is not a dispatch and not inside the orchestrator-direct allow-list (tracker/runbook Read/Edit, short-output git, skill scripts), stop and re-read the preamble.

# GENERATE lifecycle (G0..G8)

## Step G0 — Mode inference (ADR 0008 / AV3-01)

Decide the GENERATE *shape* from the input's companion Verification Manifest. Locate `<spec-basename>.manifest.yaml` next to each input doc; if present, validate it with the manifest validator — the plugin's canonical single-file `scripts/validate_manifest.sh`, NOT autopilot's `--union`-only checker (exit codes 0 complete · 3 incomplete · 4 schema-invalid · 5 unsupported). For multi-doc invocations also run `scripts/validate_manifest.sh --union` (AV3-03) first. Then:

```bash
bash ${SKILL_DIR}/scripts/detect_input_mode.sh \
  --intent generate [--manifest <path>] [--validator-exit <n>] [--yolo]
# -> MODE=STRAIGHT_THROUGH | GENERATE_PAUSE | GENERATE_YOLO
#    | REFUSE-MANIFEST-INVALID | REFUSE-MANIFEST-UNSUPPORTED
```

| MODE | Meaning | G8 behavior |
|---|---|---|
| `STRAIGHT_THROUGH` | valid + complete manifest (exit 0) | drain immediately, no review pause, no flag — the manifest is the vetting (ADR 0008) |
| `GENERATE_PAUSE` | bare markdown, or incomplete manifest (exit 3 — consumable only by a resumed spec session, MS §11) | default review path — write artifacts, print summary, exit |
| `GENERATE_YOLO` | the manifest-less `--yolo` override | skip review, arm the drain, append a `## Force Audit` entry (AP-11) |
| `REFUSE-MANIFEST-INVALID` | exit 4 (schema-invalid) | refuse; report the schema error; NEVER degrade to manifest-less (MS §11); `--yolo` cannot bypass |
| `REFUSE-MANIFEST-UNSUPPORTED` | exit 5 (`schema_version` > supported) | refuse `[MANIFEST-UNSUPPORTED]` |

`--drain`/`--resume` intents map straight to `DRAIN`/`RESUME`. Multi-doc `STRAIGHT_THROUGH` requires the union validation (G4) to pass.

## Step G1 — Pre-flight

Read in parallel: each input doc; `git status --short`; `git rev-parse --abbrev-ref HEAD`; trunk via `git symbolic-ref refs/remotes/origin/HEAD`; `git log -100 --pretty=format:"%h %s" --since='30 days ago'` (recency context); `bash ${SKILL_DIR}/scripts/sidecar_detect.sh` (`MODE=sidecar|local`).

Refuse if the working tree is dirty, if not on trunk, or if any input doc is missing.

Derive `<slug>` now — THE derivation rule, stated once here (G7 cites it): kebab-case of the input doc's H1 title (the first doc on multi-doc invocations); no H1 → kebab-case of the doc's basename; `--slug=` always wins. The tracker path and every branch name need it. Then run `bash ${SKILL_DIR}/scripts/detect_concurrent_drain.sh .autopilot/runbooks/<slug>.tracker.md` (takes the TRACKER PATH, not a bare slug): exit 1 (environment error — e.g. `CLAUDE_SESSION_ID` unset) → refuse LOUDLY citing the script's stderr message (an env error is never a claim conflict); exit 2 (live foreign lock) → refuse `STATUS: STOPPED — concurrent drain detected`; exit 4 (unreadable lock state) → refuse, fail closed; exit 64 (malformed invocation) → refuse, fix the call; exit 3 (stale lock) may be reclaimed. `--force` overrides, logged per AP-11.

## Step G1.5 — Repo-shape probe (AP-23)

Run `bash ${SKILL_DIR}/scripts/repo_shape_probe.sh` after the G1 refuses clear. It emits `KEY=VALUE` on stdout, warnings on stderr, exit 0 even when individual probes return `unknown`; cleanup is via an EXIT/INT/TERM trap on `autopilot/probe-*-<PID>` temp branches:

- `TRUNK=<branch>` (falls back to `main`)
- `CI_PRESENT=true|false|unknown` — a build-status sample on recent trunk commits, or CI config presence at trunk tip
- `CI_STATUS_REPORTING=true|false|unknown` — does the CI that runs post to the host build-status API? Sampled over recent trunk commits AND PR head shas (never just the tip: PR-only-reporting CI posts to PR heads that squash/rebase merges never bring onto trunk). `false` = CI config exists but the endpoint never populates — polling it would never resolve
- `FORCE_PUSH_ALLOWED=true|false|unknown` — a `+`-refspec push of a temp branch, rejection message parsed via `match_rejection`
- `JIRA_HOOK_ENFORCED=true|false|unknown` — a temp-branch push whose commit subject deliberately omits a JIRA key. Server-side pre-receive hooks are invisible to local heuristics; the only ground truth is what the server rejects — hence a real push

The probe's facts auto-seed the runbook frontmatter and populate the `### Repo constraints (detected)` block (each fact annotated with the probe method that produced it). The auto-seed table — which fact flips which flag — is canonical in `references/runbook-template.md` §"Repo constraints (detected)". `unknown` never auto-flips (loop-safety invariant 2); each `unknown` surfaces in the G8 summary and the operator decides.

Probe flags (usage detail in the script header): `--dry-run` previews every operation with zero network/git-state effect; `--explain` prints the reasoning per emitted value on stderr; `--show-patterns` prints the rejection-pattern registry. `--jira-key <KEY>` prefixes probe commit subjects so the force-push probe works on JIRA-hook-enforcing repos (without it the hook rejects the probe's own commits and `FORCE_PUSH_ALLOWED` degrades to `unknown`); G1.5 passes the runbook's `jira_key` automatically when present. A rejection matching no registry pattern always emits `probe: unknown rejection pattern; please add to repo_shape_probe_patterns.sh: <raw message>`.

## Step G2 — Tier-1 extraction

Spawn ONE `general-purpose` agent with `references/extraction-prompt.md` inlined verbatim. Pass: the text of every input doc, the recent git log (already-shipped awareness), and the strict YAML schema.

Validate the output against the schema (required per item: `story_id`, `title`, `source_ref`, `kind`, `behaviors_or_outcomes`, `evidence`). Missing field → re-prompt ONCE with the validation error verbatim; second failure → halt `[GENERATE-FAILED: extraction-schema]`.

G2 emits `behaviors_or_outcomes` (what done looks like, no implementation framing); G3 consumes that and emits `behaviors_to_test` (ordered, observable, drives TDD; first entry is the tracer bullet). One outcome can fan out into several test behaviors.

## Step G3 — Tier-2 planning + audit

For each Story, spawn a `general-purpose` agent with `references/planner-prompt.md` inlined verbatim. The planner verifies paths against the live repo, decomposes into Subtasks, emits the full tier-2 schema — including `test_name_hint:` (AP-9), `predicted_hours:` (AV3-07), `behavior_ids:` (AV3-02, mapping every active manifest Behavior; skipped for manifest-less drains) — and captures `audited_sha:` at spawn time so D3.0 can detect post-plan drift (AP-5).

Run all planners in parallel (one message, multiple tool calls). Validate each output; missing fields → re-prompt that planner ONCE; second failure → mark that Story `[GENERATE-FAILED: planner-schema]` and continue with the rest.

**Budget check.** If the union of emitted Subtasks exceeds `budget.max_subtasks` (default 20) → refuse `[GENERATE-FAILED: subtask-budget-exceeded]` citing the count; the operator raises the budget or splits the input. Never silently truncate.

## Step G3.5 — Plan review (schema-only projection — AP-3)

For each planner output, spawn a `Plan` agent in REVIEW mode on a STRIPPED projection. The allow-list of projected fields is defined ONCE in `references/plan-reviewer-projection.md` §"Allowed fields" — build the projection from that list verbatim (a field outside it triggers NEVER-GO). The reviewer never sees the planner's `evidence`, `contract` prose, or reasoning, so it must judge the structure instead of absorbing the narrative.

Reviewer findings → re-spawn the original planner ONCE with findings verbatim. Second NO-GO → `[GENERATE-FAILED: plan-review-ungated]` for that Story; continue.

## Step G3.6 — Subtask consolidation (AP-21, opt-in)

Off by default; enabled by `pack_subtasks: true` or `--consolidate=auto`. After G3.5, walk the reviewed plan for consolidation candidates. Eligibility (ALL conditions): same `kind` (typically `docs`/`config`); same parent Story; every `estimated_size` is `S`; `owned_files[]` disjoint after merge; `depends_on[]` consistent (no cycle created); combined `behaviors_to_test[]` ≤ 6; no member has a distinct `jira_key` under `enforce_jira_key: true` (Jira Subtasks stay 1:1).

A consolidated group becomes one Subtask: `id` = `<lowest-id>+` (e.g. `B2+`); union of `owned_files[]` / `behaviors_to_test[]` / `test_gates[]`; `estimated_size` = the group ceiling (`S+S` → `M`); a `Consolidated from:` note listing the merged IDs. Ineligible groups pass through unchanged; consolidations are logged to `## Generation Notes`.

## Step G4 — Topological sort + gates

**Hot files.** `bash ${SKILL_DIR}/scripts/hot_file_audit.sh --churn` surfaces the 20 most-churned files (30 days, origin-trunk). Two Subtasks owning the same hot file → force a DAG edge (lower-ID blocks higher-ID); surface in the review summary.

**Dependency validation.** Validate every `depends_on[]` entry against the union of planner-emitted IDs — planners run in parallel, so cross-Story references are unverifiable at plan time; this check runs on EVERY generate path. Unknown ID → `[GENERATE-FAILED: dangling-dependency]`. Topo-sort; cycles → `[GENERATE-FAILED: dependency-cycle]`; same file in two non-dependent Subtasks → `[GENERATE-FAILED: ownership-overlap]`.

**Manifest union (MS §2 / AV3-03), multi-doc only.** `bash ${SKILL_DIR}/scripts/validate_manifest.sh --union <a.manifest.yaml> <b.manifest.yaml> ...`: a Journey/Behavior ID shared across manifests → `[GENERATE-FAILED: manifest-id-collision: <id>]` (interrogation-log `DL-###` IDs are per-manifest and not unioned); differing `observability.profile` or `environments` → `[GENERATE-FAILED: manifest-union-mismatch: <profile|environments>]`.

**Sizing + mapping gate (ADR 0012 / AV3-07 + MS §13.6 / AV3-02).** Render the planner union to `.autopilot/plan.json` — repo-relative, alongside the `.autopilot/runbooks/` artifacts (a GENERATE-time intermediate, not part of the runbook/tracker canonical artifact set); run `bash ${SKILL_DIR}/scripts/validate_plan_mapping.sh .autopilot/plan.json [<manifest.yaml>]` (manifest arg only on manifest-backed drains):

- Sizing (always): `predicted_hours` within its `estimated_size` ceiling (S≤4, M≤16, L≤48) → `[GENERATE-FAILED: story-size-inconsistent: <subtask-id>]`; Story roll-up ≤48h → `[GENERATE-FAILED: story-oversized: <story-id>]`. Deterministic over a declared prediction — the Marshal owns actuals (ADR 0012). On `story-oversized`, re-spawn that Story's planner to split into sequential, independently mergeable Stories (each its own Story branch/PR).
- Behavior mapping (manifest only): every `kind: code | test-only` Subtask maps ≥1 Behavior → `[GENERATE-FAILED: unmapped-subtask]`; every mapped ID active in the manifest → `[GENERATE-FAILED: unknown-behavior]`; every active Behavior owned by ≥1 Subtask → `[GENERATE-FAILED: unowned-behavior]` (refactor/config/docs exempt). On a mapping refusal, re-spawn the planner with the offending IDs. G7 records the behavior-IDs-per-Story ledger so the audit tier can distinguish not-yet-wired work from Memory Rot.

**Claim consultation (ADR 0009 / AV3-09).** Build the open-PR inventory via the host adapter — for every open PR capture branch, state, business-day age, and declared file surface (`runbook_pr.sh file-surface` on its body). Per Subtask: `bash ${SKILL_DIR}/scripts/claim_overlap.sh --self-namespace autopilot/<slug>/ --inventory <inv.tsv> <owned-files...>`. `BINDING` (foreign draft) or `TERMINAL` (foreign ready) overlap → write a `blocked_by_pr: <host>/<pr#>` edge on the Subtask (D2-evaluable); `ADVISORY` (stale >2 business days) is a note; the drain's own `autopilot/<slug>/*` branches are `EXCLUDED` (closes the re-GENERATE self-deadlock). D2 gates on the edge; the drain NEVER terminal-pauses on first blockage — it waits and re-checks.

## Step G5 — Already-shipped detection

Per Subtask, check `git log --oneline origin/<trunk> -- <owned_files[]>` (trunk-scoped — `--all` would sweep probe branches and foreign drains). A recent commit that already implements the Subtask's intent (commit message overlaps `acceptance_criteria`) → mark it `[x] Done` in the seeded tracker with the SHA cited. G5-marked Subtasks never touch the AP-2 counters (see §Failure escalation).

## Step G6 — Optional Jira creation (`--jira <PROJ>` only)

0. **Environment check, fail fast.** `--jira` is the ONE mode with a dependency beyond vanilla Claude Code (a Jira MCP tool surface). Probe for the tools first (e.g. ToolSearch); absent → refuse immediately `[GENERATE-FAILED: jira-tools-unavailable] — re-run without --jira, or connect a Jira MCP server`, before extraction/planning work is spent.
1. Activate the environment's Jira tools (e.g. `mcp__dev-tools__activate_jira` where configured).
2. Story → Jira Story (description from `behaviors_or_outcomes` + `source_ref`); Subtask → Jira Subtask under its parent (from `acceptance_criteria` + `interface_change`).
3. Store `jira_key:` on every Story and Subtask in the runbook; set `enforce_jira_key: true` (AP-22) so every commit carries `[<JIRA-KEY>]`. Smart Commits transition Subtasks on PR merge.

Failures here (auth, missing project) → halt with a clear message; the operator resolves and re-runs.

## Step G7 — Write runbook + tracker

Render `references/runbook-template.md` with the accumulated data. `<slug>` comes from the G1 derivation rule (kebab-case of the input doc's H1, else its basename; `--slug=` wins) — defined once at G1, never re-derived differently here. Canonical artifact paths — the ONLY ones:

- `.autopilot/runbooks/<slug>.md` — the runbook (operator-editable until the drain is armed; immutable during an active drain except the G1.5-owned `Repo constraints (detected)` block)
- `.autopilot/runbooks/<slug>.tracker.md` — the seeded tracker

Seed the tracker frontmatter per the CANONICAL schema — defined once in `references/runbook-template.md` §"Tracker file", never restated here — with its seed values (`STATUS: ACTIVE`, counters + `claim_waits` at 0, null `in_progress`/locks, `force_audit: []`). This GENERATE captures `drain_start_sha` and `audited_sha` (AP-5); `manifest_revision` is frozen from the Spec's manifest (AV3-04; omitted when manifest-less); `trunk_branch` from G1.5 `TRUNK=`; `ci.skip_wait` / `branching.no_force_push` / `enforce_jira_key` per the auto-seed table (`--jira` also sets `enforce_jira_key`); `branching.single_branch_single_pr` and `pack_subtasks` are operator-toggles only. Under `branching.no_force_push: true`, seed an empty `## Pending Tracker Deltas (batched)` section (`_(empty)_`).

The rendered runbook body carries — alongside Goal / Constraints / Non-Goals / Stories — the two dispatch-consumed sections: `## Subtasks (tier-2 plan)` (the reviewed planner union's schema blocks, verbatim — D3.1 and D4 dispatch from here) and `## Role prompts` (the D3.1/D3.2 Plan-agent role; content spec: `references/runbook-template.md` §"Role prompts").

The runbook's first commit creates `autopilot/<slug>/setup` with shape verification (AP-7).

**Open the Runbook PR at Pickup (AV3-08).** G7 immediately opens ONE long-lived Runbook PR on `autopilot/<slug>/runbook` carrying the runbook + tracker — the single bookkeeping home under both `no_force_push` settings (the pre-v3 rolling tracker PR is retired). Its body carries the drain's predicted file surface as a grep-able block, so foreign planners and AV3-09 claim consultation consult one place:

```markdown
## Predicted file surface
<!-- autopilot:file-surface:begin -->
- `path/one.py`
- `path/two.py`
<!-- autopilot:file-surface:end -->
```

`bash ${SKILL_DIR}/scripts/runbook_pr.sh file-surface <body-file>` extracts the block deterministically. The Runbook PR opens non-draft and is the FINAL entry in `MERGE-ORDER.md`; the operator (or the Marshal) merges it — autopilot NEVER merges its own PRs.

## Step G8 — Review or arm

**Default (review path):** print a structured summary, then exit without arming any cron. Required content: slug; Story count; Subtask count by `kind` and `estimated_size`; already-shipped (G5) count; hot-file serializations; G1.5 probe facts + any `unknown` values needing operator review; consolidations (G3.6); estimated drain runtime; runbook + tracker paths; Runbook PR URL; the exact `/autopilot --drain @<runbook-path>` command; a one-line reminder to edit before draining.

**`--yolo` / `STRAIGHT_THROUGH`:** skip the review; immediately invoke DRAIN as if the operator typed `/autopilot --drain @.autopilot/runbooks/<slug>.md`.

# DRAIN lifecycle (D1..D8)

Per-fire scope is HARD: one Subtask end-to-end — or one `[BLOCKED]` reason — then exit, after writing the next cron and updating the tracker.

## Step D1 — Hydrate + WIP recovery

Orchestrator-direct work in this step: reading the tracker/runbook, short single-line git commands, the skill's own scripts. Reading source files belongs to subagents in D3/D4/D5 — this caps per-fire parent-context growth; the tracker is the source of truth across fires.

### D1.0 — Session lock claim (AP-4)

Run `bash ${SKILL_DIR}/scripts/detect_concurrent_drain.sh .autopilot/runbooks/<slug>.tracker.md` as the fast pre-check: exit 1 → environment error (e.g. `CLAUDE_SESSION_ID` unset), fail the fire LOUDLY — `STATUS: HUMAN_NEEDED — lock-check-env-error` citing the script's stderr message (external fault; an env error is never a claim conflict, so never the silent exit-2 path); exit 2 → foreign live lock, refuse the fire (`CronDelete`, exit silently — the other session's cron keeps firing); exit 4 → corrupt lock state, `STATUS: HUMAN_NEEDED — tracker-lock-unreadable` (fail closed); exit 64 → `STATUS: HUMAN_NEEDED — lock-check-usage-error` (external fault); exit 0 or 3 → the dispatch table below.

Read the tracker frontmatter; compute `now_iso = $(date -u +%Y-%m-%dT%H:%M:%SZ)`.

| Frontmatter state | Action |
|---|---|
| `session_lock: null` | Set `session_lock: ${CLAUDE_SESSION_ID}`, `session_lock_expires_at: <now + 30 min>`. Continue. |
| `session_lock: ${CLAUDE_SESSION_ID}` (our own) | Refresh `session_lock_expires_at: <now + 30 min>`. Continue. |
| `session_lock: <other>` + unexpired | Refuse: another session is draining. `CronDelete`, exit silently. |
| `session_lock: <other>` + expired | Treat as crashed: claim the lock; add a `## Drift Notes` entry recording the reclaim. |

Land the lock delta on the Runbook PR (`autopilot/<slug>/runbook`, AV3-08) before any other work: direct commit under `no_force_push: false`; `delta_kind: session_lock` queue append under `no_force_push: true`.

> **Known limitation (batched-delta mode).** Under `no_force_push: true` the lock write stays in the local tracker until the next D7.1a fold, so a session draining from a DIFFERENT clone cannot see it: AP-4 is checkout-local in that mode. The cross-clone guard is the branch-namespace check (`git ls-remote origin 'refs/heads/autopilot/<slug>/*'` showing branches you didn't create) plus operator discipline. Documented, not solved.

### D1.0.4 — Pending-deltas migration + crash recovery (AP-23)

Runs only under `branching.no_force_push: true`.

1. **Migration.** A pre-v2.3.0 tracker without a `## Pending Tracker Deltas (batched)` section gets the header injected (body `_(empty)_`) between `## Drift Notes` and the first Subtask. Idempotent.
2. **Crash recovery.** A non-empty queue at fire start is NORMAL in batched mode (claims, heartbeats, and status deltas all wait for the next D7.1a fold). It is a crash signal ONLY with evidence the prior fire exited dirty: this fire reclaimed an expired foreign lock at D1.0, or D1.3's 90-minute detector fired. Only then append ONE `delta_kind: crash_recovery` entry with the recovered queue's SHA-fingerprint. Never remove prior entries — the D7.1a fold is the only legitimate flush point. (Appending on every non-empty queue would spam every healthy fire and grow the queue without bound.)

Full contract + `delta_kind:` catalog: `references/tracker-delta-batching.md`.

### D1.0.5 — Drift-notes hydration (AP-20)

Read every `## Drift Notes` entry before any git or host action. Drift notes are hard preconditions, not commentary — e.g. "trunk renamed mid-drain to `develop`" means D1.4 uses `develop`, not the frontmatter's original `trunk_branch`. This stops fires re-deriving the same workaround every 5 minutes.

### D1.0.6 — Manifest-revision drift gate (MS §6 / AV3-04)

Manifest-backed drains only (the tracker recorded a `manifest_revision`):

```bash
bash ${SKILL_DIR}/scripts/manifest_revision_gate.sh drift \
  .autopilot/runbooks/<slug>.tracker.md <spec>.manifest.yaml
# exit 0 OK / NO-MANIFEST · exit 3 DRIFT recorded=<a> current=<b>
```

**Exit 3 (DRIFT)** — the Spec was amended under a live drain. External fault (no counter increment); handle gracefully: a mid-cycle Subtask completes its current RED→GREEN pair first (never leave a half-written cycle); write `STATUS: PAUSED`, `status_reason: manifest-revision-drift`; NOT `--force`-bypassable (`--force` overrides refusals, not a spec that moved under you); draft Story PRs stay draft (listed in the end-of-drain dangling-draft disposition); `CronDelete`, release the lock (D8), exit. Recovery is the `--generate --merge` revision-regen path (see Resume step 2a), never plain `--resume`. Exit 0 → D1.1.

### D1.1 — Branch shape check (AP-7)

`git branch --show-current` MUST be one of: `autopilot/<slug>/setup`; the Story branch `autopilot/<slug>/<story-id>` (PR-per-Story, AV3-06 — one Story = one branch = one PR; Subtasks are its commit series); the Runbook PR branch `autopilot/<slug>/runbook` (AV3-08); or the drain's single feature branch (only under `branching.single_branch_single_pr: true`). Anything else → `STATUS: HUMAN_NEEDED — unexpected-branch-shape` citing the branch; `CronDelete`, exit.

### D1.2 — Hydrate

Read in parallel: the tracker; `git status --short`; `git fetch origin && git rev-list --count <drain-start-sha>..origin/<trunk>` (external churn); `git branch --show-current`. Update `last_heartbeat_at` (AP-6, first heartbeat of the fire).

**Foreign dirty-tree handling.** `git status` may show changes OUTSIDE the drain's surface that appeared after G1's clean-tree refusal (e.g. a session-level notes file another workflow keeps dirty). Handle once per fire, by rule:

- Dirty paths touching the tracker, the runbook, or any in-flight Subtask's `owned_files[]` → `STATUS: HUMAN_NEEDED — dirty-drain-state` citing the paths, `CronDelete`, exit. (External fault — someone edited drain state out-of-band.)
- Any other dirty TRACKED path: before the fire's first checkout/rebase, stash exactly those paths with a label — `git stash push -m "autopilot/<slug> foreign-dirty <iso8601>" -- <paths>` — and drift-note the label + paths. At D8, pop the labeled stash; on pop conflict LEAVE it stashed and extend the Drift Note with the stash ref — foreign work is preserved or restored, never dropped (invariant 7's delta-preservation discipline applied to operator files).
- Untracked files never block branch operations; leave them alone.

**Runtime budget.** `now - drain_started_at > budget.max_runtime_minutes` → `STATUS: HUMAN_NEEDED — runtime-budget-expired`, `CronDelete`, exit. (`drain_started_at` is seeded by the first fire.)

### D1.3 — Heartbeat-driven crash detection

`in_progress.last_heartbeat_at` > 90 min old → treat as crashed; apply the RESUME/ABANDON rows below.

### D1.4 — WIP recovery dispatch

**Rows evaluate top-to-bottom; the FIRST match wins** (conditions overlap by construction — external PR state must be checked before generic CI polling so a merged PR is never mistaken for a hung build).

| `in_progress` block in tracker | Action |
|---|---|
| `git symbolic-ref refs/remotes/origin/HEAD` differs from the runbook's trunk | Trunk renamed mid-drain — `STATUS: HUMAN_NEEDED — trunk-renamed` citing old vs new, `CronDelete`, exit. (External fault.) |
| Story branch has commits beyond `prev_pushed_sha` whose author email ≠ `git config user.email` | Foreign push — `STATUS: HUMAN_NEEDED — foreign-commits-on-branch` listing the SHAs, `CronDelete`, exit. (External fault.) |
| Empty / null | Normal — proceed to D2. |
| `awaiting_ci: true`, `pr_number` set, PR state (`pr-state --num`) = `MERGED` | Merged externally — mark Subtask `[x] Done` with PR URL + merge SHA, reset both counters, clear `in_progress`, re-arm `*/5`, exit. |
| `awaiting_ci: true`, `pr_number` set, PR state = `DECLINED` | `[BLOCKED: pr-declined]` (ci) citing the PR URL, increment `consecutive_ci_blocks`, clear `in_progress`, re-arm `*/30`, exit. |
| `awaiting_ci: true`, PR `OPEN`, `ci.skip_wait: false` | CI-poll mode — run D7.5. **Hard contract: after D7.5 completes, exit the fire regardless of outcome; never continue to D2 in the same fire.** |
| `awaiting_ci: true`, PR `OPEN`, `ci.skip_wait: true` | Awaiting operator merge (no CI polling); re-arm `*/30`, exit. |
| `subtask_id` set (not awaiting CI), Story branch exists with commits ahead of `prev_pushed_sha` | RESUME — rebase the Story branch, re-run the D6 gate over `prev_pushed_sha..HEAD`; green → push + open-or-update the Story PR (D7); red → ONE `general-purpose` fix attempt, then push or `[BLOCKED: resume-failed]` (impl). |
| `subtask_id` set, Story branch missing or empty | ABANDON — clear `in_progress`, `[BLOCKED: orphan-resume]` (impl) on that Subtask, continue to D2. |

Refuse the fire if `STATUS != ACTIVE`. On terminal statuses the cron is already deleted (Hard Contract 9); a stray fire no-ops WITHOUT re-arming. Recovery from `PAUSED` is exclusively `/autopilot --resume` — never hand-flip `STATUS` (a hand-flip to ACTIVE strands the drain with no cron and no resume path). ONE sanctioned exception: `HUMAN_NEEDED` exits the automated loop, and re-entry is the operator recovery procedure in `references/runbook-template.md` §"Resuming a runbook" — an operator STATUS flip back to ACTIVE with a manual resolution entry + counter reset, followed by an in-session re-dispatch (whose D8 re-arms the cron, so nothing strands).

External churn > 100 commits since drain start → `## Drift Notes` warning; don't auto-restart.

## Step D2 — Select next Subtask

Topo-walk the DAG. Pick the lowest-ID Subtask where: status is `[ ]`; all `depends_on[]` are `[x] Done`; and it is not claim-blocked (AV3-09) — a `blocked_by_pr: <host>/<pr#>` edge (G4-written) is eligible only once that PR resolves. Poll `bash ${SKILL_DIR}/scripts/host.sh pr-state --num <pr#>` and gate on `bash ${SKILL_DIR}/scripts/claim_overlap.sh eligibility --pr-state <STATE>`:

| `eligibility` exit | `<STATE>` | Action |
|---|---|---|
| 0 | `MERGED \| DECLINED \| NONE` | Claim resolved — select the Subtask. |
| 2 | `OPEN \| DRAFT` | Still claimed — the WAIT path below. |
| 64 | anything else — `UNKNOWN` (read succeeded, state unmappable) or empty (`pr-state` itself died) | **FAIL CLOSED (loop-safety invariant 3):** proceeding would fail OPEN on an unresolved claim. `STATUS: HUMAN_NEEDED — claim-eligibility-usage-error` citing the `<STATE>`, `CronDelete`, exit. External fault, no counter — identical handling to D7.5's `ci-check-usage-error` and D1.0's `lock-check-usage-error`. |

**Story affinity (AV3-06).** PR-per-Story caps the drain at one open draft Story PR at a time. While a Story has an open draft PR and eligible `[ ]` Subtasks, selection is restricted to that Story — finish (or block out) the open Story before opening another. Only when the open Story has no eligible Subtask left may D2 start a different Story. When two Stories are both unstarted, the lowest-ID Subtask's Story wins. This bounds the branch/PR count and keeps each Story PR reviewable as a unit.

If no eligible Subtask:

- All `[x]` → `STATUS: DRAINED`, render `MERGE-ORDER.md`, `CronDelete`, exit successfully.
- **All remaining open Subtasks claim-blocked → WAIT, not terminal.** Increment `claim_waits`, re-arm `*/30`, re-check next fire. Escalate `STATUS: HUMAN_NEEDED — claim-deadlock` (external fault) only at `claim_waits >= budget.max_claim_waits` (default 16). NEVER terminal-pause on the first blockage — a drain re-queues at no one's cost.
- All blocked (non-claim) or pending-deps → `STATUS: HUMAN_NEEDED`, `CronDelete`, exit.
- `consecutive_impl_blocks >= budget.max_impl_blocks` OR `consecutive_ci_blocks >= budget.max_ci_blocks` → `STATUS: HUMAN_NEEDED` + `## Escalation` block citing the tripped counter and contributing Subtasks, `CronDelete`, exit. AP-2.

A successful selection resets `claim_waits` to 0. Write the chosen Subtask's block to `in_progress` (`started_at`, `last_heartbeat_at`, `pr_number: null`).

**Tracker commit routing (AP-23):** `no_force_push: false` → commit the delta directly to the Runbook PR branch; `true` → append `delta_kind: in_progress_claim` to the queue (the D7.1a fold flushes it). Refresh heartbeat (AP-6).

## Step D3 — Plan + Plan review (AP-5 + AP-3)

### D3.0 — Audited-SHA verification (AP-5)

For each `owned_files[]` entry not marked `# NEW`:

```bash
git cat-file -e ${audited_sha}:<file> 2>/dev/null || echo "MISSING"
git diff --quiet ${audited_sha}..HEAD -- <file> || echo "DRIFTED"
```

MISSING → `[BLOCKED: plan-stale-missing]` (impl); DRIFTED → `[BLOCKED: plan-stale-drifted]` (impl) with paths. No retry — HEAD moved under the plan; a human re-plans. Catching this here is cheaper than letting the implementer burn cycles on a stale plan.

### D3.1 — Plan

Spawn a `Plan` agent. Prompt: the Subtask's full schema block (verbatim from the runbook's `## Subtasks (tier-2 plan)` section) + the runbook's `## Role prompts` Plan-agent block (G7 writes both into the runbook body; the Plan-agent content spec is `references/runbook-template.md` §"Role prompts").

### D3.2 — Plan review (schema-only projection)

Spawn `Plan` again in REVIEW mode on the schema-only projection (per the `references/plan-reviewer-projection.md` allow-list) + "review for: feasibility, file-path verification, dependency gaps, ownership overlap with concurrent in-flight branches (`git branch --remote --list 'autopilot/<slug>/*'`), behaviors-to-test completeness." AP-3.

NO-GO → re-spawn the original `Plan` agent ONCE with findings. Still NO-GO → `[BLOCKED: plan-ungated]` (impl), increment `consecutive_impl_blocks`, re-arm `*/30`, exit. Refresh heartbeat (AP-6).

## Step D4 — Implement (TDD vertical slice — AP-1)

Work lands on the Story branch `autopilot/<slug>/<story-id>` (PR-per-Story, AV3-06):

- **First Subtask of the Story** → create the branch from the DAG-aware base: no in-flight cross-Story dependency → `origin/<trunk>`; dependency on a Done (merged) Story → `origin/<trunk>`; dependency on an in-flight Story → that Story's branch tip (a **stacked Story PR**; merge-commit strategy, D7.3a).
- **Later Subtask of the same Story** → `git checkout autopilot/<slug>/<story-id>` and continue the commit series; never branch anew. (D6.2 audits only `prev_pushed_sha..HEAD`, so prior Subtasks' commits are not re-audited.)
- Under `branching.single_branch_single_pr: true` → always the drain's single feature branch.

Spawn ONE `general-purpose` agent with `references/implementer-prompt.md` inlined verbatim, plus the runbook's `gates:` command table, `budget.max_cycles_per_subtask`, `regen_rituals:` when declared, and `enforce_jira_key` + the Subtask's `jira_key` when enforced (the prompt's inputs 5–7; its commit rules carry the full TDD cycle contract: per-behavior RED→GREEN commits, JIRA-key prefix under AP-22 rule 9, refactor-after-green, public-interface tests, 800-token report cap AP-16). Cycle count past the budget → `[BLOCKED: cycle-budget-exhausted]` (impl).

The agent's `kind`-aware shape (D6.2 audits it from git log):

| `kind` | Shape |
|---|---|
| `code`, `test-only` | Full TDD vertical slice, per-cycle commits |
| `refactor` | Confirm GREEN baseline; refactor; single `refactor:` commit; confirm GREEN preserved |
| `docs`, `config` | No TDD inner loop; single `docs:`/`chore:` commit; kind-specific gate if any |

Refresh heartbeat (AP-6); under `no_force_push: true` queue it as a `delta_kind: other` entry.

**Dead implementer (in-fire).** A dispatched implementer that dies or vanishes mid-Subtask is NOT recovered in-fire — exit the fire; the NEXT fire's D1.4 WIP table owns recovery (the ABANDON row for a missing/empty Story branch, RESUME for a branch with commits). Design note (deliberate fail-safe): a single implementer death on a critical-path Subtask can leave D2 with no eligible Subtask and terminate the drain to `HUMAN_NEEDED` — an autonomy tier never auto-retries what it cannot diagnose; the sanctioned re-entry is the operator recovery procedure in `references/runbook-template.md` §"Resuming a runbook".

## Step D5 — Validate (parallel)

Validators are NEVER skipped — not for single-edit Subtasks, not for "trivial" refactors: the touched-files view is exactly what misses a repo-wide regression (a shared test-helper edit breaking unowned test files reaches trunk on local gates alone); the quality validator's blast-radius check exists for precisely the smallest diffs.

Spawn THREE `general-purpose` agents in ONE message with role prompts from `references/validator-prompts.md`: **integration** (types compile, contracts honored, no import cycles, path verification), **design** (structural coherence, test quality through the public interface), **quality** (scoped test gates + contract tests). Read all three outputs in parallel.

**Contradictory findings (AP-18).** Two validators returning findings at the SAME `location` with semantically opposing `suggested_fix` ("remove X" vs "expand X") → do NOT spawn a fix agent (they will thrash): `[BLOCKED: validator-contradiction]` (impl), both findings verbatim in the tracker, increment `consecutive_impl_blocks`, re-arm `*/30`, exit.

**Normal findings.** Spawn ONE `general-purpose` fix agent (findings verbatim + affected files + "fix only what's listed"); re-run validators in parallel. Caps: validator findings = 2 fix-passes; lint-only = 4; test-fail = 2. Past cap → typed `[BLOCKED: <kind>-unresolved]` (impl), increment, re-arm `*/30`, exit. Refresh heartbeat (AP-6).

## Step D6 — Test gate + commit-shape audit

### D6.1 — Test gates

Run the runbook's `gates:` commands (schema + Python defaults: `references/runbook-template.md` §gates); all must pass: `gates.test_scoped` on the changed-module scope only (AP-15 — never the full suite); `gates.test_contract` on the scoped paths (only if `test_gates` includes `contract`); `gates.typecheck` and `gates.lint` on the delta only (pre-existing brownfield debt elsewhere must not block this Subtask); `gates.precommit` (NEVER `--no-verify`).

**Blast-radius expansions of `{paths}`.** Two declared cases widen the scope:

- **Shared test helpers:** the Subtask touched a module imported by tests beyond the changed dirs — being imported by tests is the trigger, regardless of whether the module lives in the test tree (fixture factories, conftest helpers) or in src (the `<pkg>/testing.py` fake pattern). `{paths}` = ALL test files importing the touched module(s), found by repo-wide import scan. Holds even for a single-edit Subtask — a repo-wide helper regression escapes the touched-file net otherwise.
- **Invalidated seams:** the Subtask declares `invalidated_seams[]` (planner Rule 13) → `{paths}` additionally includes every listed seam-test module (the tests whose monkeypatches bind to import paths this Subtask changed).

### D6.2 — TDD audit via git log (AP-1)

Git log — not the implementer's report — is the source of truth for TDD compliance. **Audit range = `prev_pushed_sha..HEAD`, never `origin/<base>..HEAD`** (AV3-06): the Story branch accumulates prior Subtasks' commits, and the wider range would false-flag `tdd-scope-leak` on already-audited work. `prev_pushed_sha` = the Story branch tip when the previous Subtask finished pushing; `origin/<trunk>` for the Story's first Subtask. Range arithmetic and shape checks are extracted to a self-tested script:

```bash
bash ${SKILL_DIR}/scripts/audit_commit_shape.sh \
  --id <subtask-id> --base <prev_pushed_sha-or-origin/<trunk>> \
  --kind <code|test-only|refactor|docs|config> [--jira-key <KEY>]
# -> "OK" exit 0, or "[BLOCKED: <reason>] <detail>" exit 1
```

Expected shape for `kind: code | test-only`: per behavior `<n>`, exactly one `test: <id>.<n> RED — ...` then one `feat: <id>.<n> GREEN — ...`; `[<JIRA-KEY>]` in every subject under `enforce_jira_key: true`; optional trailing `refactor: <id> — ...` commits; no `chore:`/`fix:`/`docs:` mixed in (scope leak). For `kind: refactor`: exactly one `refactor:` commit, zero `test:`/`feat:` → else `[BLOCKED: refactor-shape-wrong]`. For `kind: docs | config`: exactly one `docs:`/`chore:` commit.

**Compressed-cycle exception (new-file relocation).** When the implementer's report declares `Compressed cycle: new-file-relocation` (legitimate only when every impl file is `# NEW` and the behaviors are relocated, already-tested behavior), the expected shape is ONE RED + ONE GREEN pair covering all behaviors. The design validator's behavior-coverage check remains fully in force — the exception compresses the COMMIT shape, never the coverage.

Failure catalog (all `(impl)`, dispatch as D5): cycle pairs > `budget.max_cycles_per_subtask` → `[BLOCKED: cycle-budget-exhausted]`; missing RED/GREEN for behavior N → `[BLOCKED: tdd-no-red]` / `[BLOCKED: tdd-no-green]` citing N; GREEN before RED → `[BLOCKED: tdd-out-of-order]`; foreign commit types → `[BLOCKED: tdd-scope-leak]`; missing JIRA key → `[BLOCKED: jira-key-missing]` citing the commits.

### D6.3 — Behavior-ID → test binding audit (MS §13.9 / AV3-05)

Manifest-backed drains only. Build the `## Behavior coverage` mapping (Behavior ID → covering test node IDs) and verify it against git log:

```bash
bash ${SKILL_DIR}/scripts/audit_behavior_binding.sh --coverage <coverage-file> --base <prev_pushed_sha-or-origin/<trunk>>
# OK exit 0 · [BLOCKED: unbound-behavior] <B-id> · [BLOCKED: unproven-binding] <B-id> <test>
```

Every mapped Behavior needs ≥1 bound test node (`unbound-behavior` otherwise), and each bound test's name must be NAMED in a `test: ... RED` commit in the range (`unproven-binding` — a coverage claim with no RED evidence). Dispatch as D5. The verified mapping feeds D7.3's PR-body section and D7.4's tracker mirror (consumed by the PR Gate, MS §13.11).

### D6.4 — Closing-test determinism gate, N=5 (AV3-12)

Run the Subtask's OWN changed tests 5× — bounded to `gates.test_scoped` with `{paths}` = the Subtask's test files, never the full suite — one round order-randomized via `gates.test_random`. Runner-agnostic: compares exit codes + failure fingerprints.

```bash
bash ${SKILL_DIR}/scripts/determinism_gate.sh \
  --cmd "<resolved gates.test_scoped for {paths}>" \
  [--random-cmd "<resolved gates.test_random>"]   # omit -> that round is skipped with a loud [note]
# DETERMINISTIC (5 rounds) exit 0 · [BLOCKED: flaky-test] <detail> exit 1
```

No `gates.test_random` → the randomized round is SKIPPED with a loud stderr `[note]`, never silently (a silent skip would claim order-independence it never checked). Any inconsistency across the 5 rounds → `[BLOCKED: flaky-test]` (impl); dispatch as D5. This is the runtime backstop for the AV3-11 anti-flakiness contract.

### D6.5 — Anti-vacuous (mutation) gate (ADR 0016)

D6.4 catches a test that passes for the wrong reason (nondeterminism); D6.5 catches a test that passes for NO reason (vacuity). After D6.1–D6.4, run the repo's mutation tool over THIS Subtask's changed product files, filter survivors to the changed LINES of `prev_pushed_sha..HEAD`: a survived mutant on a changed line is deterministic proof a test executes that line and constrains nothing. OPTIONAL: runs only when `gates.test_mutation` is set and the language has an adapter (`references/mutation-adapters.md` — the pointer to the MT-01 map, whose ONE copy lives in `skills/cleanup-audit/references/cross-language-tooling.md` since ADR 0025).

```bash
bash ${SKILL_DIR}/scripts/mutation_gate.sh \
  --tool <stryker|cargo-mutants|mutmut|go-mutesting> \
  --run-cmd "<resolved gates.test_mutation for {files}>" \
  --base <prev_pushed_sha-or-origin/<trunk>> --files "<changed product files>" \
  [--max-mutants <budget.max_mutants_per_subtask=40>] [--max-seconds <budget.max_mutation_seconds=120>]
# NON-VACUOUS (…) exit 0 · [BLOCKED: vacuous-test] <file:line…> exit 1 ·
# skip/partial [note] exit 0 · clean-index refuse / usage exit 64
```

**Isolation is a NEW named mechanism, not free reuse (loop-safety invariant 1).** A mutation tool rewrites source on disk, so D6.5 NEVER runs on the live Story checkout: `mutation_gate.sh` runs inside an EXPLICIT `git worktree add <throwaway> HEAD`, torn down by an EXIT/INT/TERM trap, gated behind a clean-index precheck. The live checkout is never mutated — even on injected mid-run failure.

**Dispatch identical to D6.4's flaky-test:** `[BLOCKED: vacuous-test]` → impl counter, re-arm `*/30`, escalate at the cap. **Self-remediation closure:** the fix MUST be a strengthened assertion re-verified by D6.5 on the SAME changed lines — never deleting the product code at the mutation point (trips D6.2 `tdd-scope-leak`), never editing `gates.test_mutation` to dodge the gate (outside `owned_files[]`).

**Budget + degrade, honestly (MT-07/MT-08).** Exceeding `--max-mutants`/`--max-seconds` → `[note] mutation-budget-exhausted — partial (N of M)`, exit 0, NEVER a false `[BLOCKED]` (inconclusive ≠ survivor — the D6.4 skipped-round honesty). No tool for the language / `gates.test_mutation` omitted / unsupported tool → SKIP with a loud stderr `[note]`, exit 0. A file-granular survivor (a tool with no line resolver) cannot be pinned to a changed line → comment-only, never a block. D6.5 adds no new autonomous mutating path beyond the trap-isolated throwaway worktree.

## Step D7 — Pre-push rebase + commit + PR

**D7.0 — Pre-push rebase.** `git fetch origin && git rebase origin/<base>`, `<base>` = the Story's D4 branching base. The unit rebased is the Story branch (AV3-06) — the replay carries every prior Subtask's commits on it. Conflicts → the protocol in `references/conflict-resolution.md`. Budget: 3 hunks across 2 files max.

**On budget trip — attribute before escalating (ADR 0009 / AV3-10).** Do not reflexively `[BLOCKED: rebase-too-large]`; first run the attribution predicate over the conflicting-hunk files and this Subtask's recorded claim-overlap files:

```bash
bash ${SKILL_DIR}/scripts/claim_loss_attribution.sh \
  --overlap-files <claim-overlap-files-csv> --conflict-files <conflicting-hunk-files-csv> \
  --replans-so-far <n>   # from the Subtask's tracker entry
# REPLAN (exit 0) · NOT-ATTRIBUTED (exit 1) · REPLAN-BUDGET-EXHAUSTED (exit 2)
```

- **REPLAN** — a foreign claim we were told about merged first and rewrote these files: route to D3 re-plan against the new trunk (not the impl-block path); increment the Subtask's re-plan count, record `replanned-after-claim-loss`. Bounded: 2 re-plans per Subtask.
- **NOT-ATTRIBUTED / REPLAN-BUDGET-EXHAUSTED** — genuine planning conflict (or bound spent): `[BLOCKED: rebase-too-large]` (impl), no retry.

During conflict resolution run `gates.test_scoped` on changed paths only — never the full suite (AP-15).

**D7.1 — Stage owned_files[].** The per-cycle commits from D4 ARE the PR's commits; stage only `owned_files[]` if the refactor pass left unstaged changes, else skip. Never `git add -A`. When a final commit IS needed (`kind: docs | config | refactor`): stage only `owned_files[]`; Conventional Commits `<type>: <id> — <title>`; `[<JIRA-KEY>]` prefix under `enforce_jira_key: true` (AP-22); body = `acceptance_criteria` checklist + a 2–3-sentence `Rationale:` paragraph (AP-8) + `Refs:` footer (JIRA key, source_ref); trailer `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`; HEREDOC for formatting.

**D7.1a — Tracker-delta fold to the Runbook PR (AP-23 / AV3-08).** Only under `branching.no_force_push: true`. If `## Pending Tracker Deltas (batched)` is `_(empty)_`, skip. Otherwise flush to the Runbook PR branch (`autopilot/<slug>/runbook`) — kept OFF the Story branch so the tracker never self-intersects a Story's claim surface (AV3-09):

1. Build a `Tracker deltas folded in:` commit-body block listing each entry's `delta_kind` + `diff_summary`.
2. Apply every entry's `body:` to the tracker file on the runbook branch, in order.
3. Reset the queue section body to `_(empty)_` (header remains).
4. Commit the tracker on `autopilot/<slug>/runbook` as its OWN append commit — the fold never rides a Story branch and never stages `owned_files[]`, so Story code and bookkeeping never share a branch and the Story PR carries only code.

Under `no_force_push: false` the deltas were committed directly at claim time (D2/D7.4); this fold is skipped.

**D7.2 — Push.** `git push -u origin <branch>`. Transient failure → 1 retry. Auth failure → `[BLOCKED: bitbucket-token-missing]` (impl), no retry.

**D7.3 — Story PR (draft-open / update / ready-flip).** One Story = one branch = one PR, opened draft, kept draft until the whole Story is Done (AV3-06):

1. **The Story's FIRST pushed Subtask** (no Story PR yet) → open the draft Story PR:
   ```bash
   bash ${SKILL_DIR}/scripts/host.sh pr-open --draft \
     --title "<story-title>" --src autopilot/<slug>/<story-id> --dest <base-branch> --body-file <body-file>
   ```
   `host.sh` dispatches to the detected backend (Hard Contract 11 — never call a backend directly). Dest = the D7.0 rebase base. Body = Summary + Test plan + per-Subtask TDD sequence + Checklist + (manifest-backed) the `## Behavior coverage` section. On a DC server predating draft PRs the backend applies the `[DRAFT]`-title-prefix fallback transparently (`AUTOPILOT_BITBUCKET_DRAFT_MODE`).

   **`## Behavior coverage` (MS §13.9 / AV3-05)** — the D6.3-verified Behavior-ID → test-node mapping, grep-able and marker-delimited so the PR Gate (MS §13.11) can parse it:

   ```markdown
   ## Behavior coverage
   <!-- autopilot:behavior-coverage -->
   - B-pricing-001: tests/test_pricing.py::test_rejects_expired_lock
   - B-pricing-002: tests/test_pricing.py::test_a, tests/test_pricing.py::test_b
   ```
2. **A later Subtask of a Story with an open draft PR** → the D7.2 push already updated it; append a `host.sh pr-comment` "Subtask `<id>` landed" note. Never open a second PR.
3. **The Subtask that completes the Story** (ALL of its Subtasks `[x] Done` — checked by set membership, never position) → flip draft to ready: `bash ${SKILL_DIR}/scripts/host.sh pr-ready --num <story-pr-number>`. A Story PR with any `[ ]` or `[BLOCKED]` Subtask stays draft. (The ready-flip is also reached from the D7.5 green path and the D1.4 external-merge path — wherever the closing Subtask goes Done.)

Under `no_force_push: true` with a non-empty D7.1a fold, the PR body also carries a `## Tracker deltas folded in` H2 (each entry's `delta_kind` + `diff_summary`) for reviewer visibility. Under `branching.single_branch_single_pr: true`, D7.3 opens ONE PR on the drain's first successful Subtask; later Subtasks push to the same branch and update it via `host.sh pr-comment`.

**D7.4 — Tracker update.** Set `in_progress.pr_number` (the Story PR — same number for every Subtask of the Story), `awaiting_ci: true`, `pushed_at`, `pushed_sha` (consumed by D7.5's `--sha`), `ci_check_count: 0`, `last_heartbeat_at`. Record the Story's `last_pushed_sha = pushed_sha` on its tracker entry — the NEXT Subtask of this Story reads it as `prev_pushed_sha` (the D6.2 audit base; the Story's first Subtask audits from `origin/<trunk>`). On a manifest-backed drain, mirror the `## Behavior coverage` mapping to the tracker (AV3-05) so the binding survives across fires and is auditable without the PR. Routing: direct commit to the Runbook PR branch under `no_force_push: false` — subject carries the `[<JIRA-KEY>]` prefix under `enforce_jira_key: true` (AP-22; the server hook rejects bare subjects); `delta_kind: status_change` queue append under `true` (the fold commit's JIRA handling: `tracker-delta-batching.md` §Interaction with `enforce_jira_key`).

### D7.3a — Stacked PR merge strategy (AP-10)

When the Story PR stacks on another in-flight Story's branch (cross-Story dependency, D4), the PR description MUST request a **merge commit, not squash** — squash on a stacked PR collapses the dependency chain and breaks subsequent rebases (Bitbucket's merge UI defaults to squash). `host.sh pr-merge` defaults to the merge-commit intent and uses `pr-merge-strategies` discovery to fall back to the closest enabled strategy.

## Step D7.5 — CI poll (cross-fire)

Runs only on a fire that started with `awaiting_ci: true` (D1 dispatch); short-circuited under `ci.skip_wait: true` (D1's WIP dispatch already handled merged/open/declined without `ci_check.sh`).

Run `bash ${SKILL_DIR}/scripts/ci_check.sh --sha <in_progress.pushed_sha> --pr <pr_number> --once` — ONE observation, exit immediately (the drain is cross-fire; the blocking poll mode is operator-only). The script emits `LAST_STATE=<last observed build state>` on stderr before every exit; cite it in tracker entries.

| `ci_check.sh --once` result | Action |
|---|---|
| exit 0 (GREEN) | Mark Subtask `[x] Done` with Story PR URL + SHA + `[<JIRA-KEY>]` if any. Reset both counters (AP-2). If this makes ALL of the Story's Subtasks Done, flip the Story PR ready (D7.3 case 3). Clear `in_progress`. Re-arm `*/5`. Exit. |
| exit 1 (RED) | `[BLOCKED: ci-red]` (ci) with failing check name + log URL. Increment `consecutive_ci_blocks`. Clear `in_progress`. Re-arm `*/30`. Exit. No retry. |
| exit 5 (PENDING), `ci_check_count < 6` | Increment `ci_check_count`, update heartbeat, re-arm `*/10`, exit. |
| exit 5 (PENDING), `ci_check_count >= 6` | `[BLOCKED: ci-stuck-pending]` (ci) citing `LAST_STATE=` (INPROGRESS = hung build; UNKNOWN = CI never reported for this SHA). Increment `consecutive_ci_blocks`. Clear `in_progress`. Re-arm `*/30`. Exit. |
| exit 4 (PR_DECLINED) | `[BLOCKED: pr-declined]` (ci) citing the PR URL. Increment `consecutive_ci_blocks`. Clear `in_progress`. Re-arm `*/30`. Exit. |
| exit 64 (usage error) | `STATUS: HUMAN_NEEDED — ci-check-usage-error` citing stderr, `CronDelete`, exit. (External fault.) |

(Exits 2 STUCK and 3 UNDETERMINED belong to the blocking mode and cannot occur under `--once`.)

## Step D8 — Adaptive cron re-arm

Always the last action of a fire. Cadence dispatch is defined once in `references/cadence-dispatch.md` and inlined into the runbook at GENERATE-time.

**Session-lock release.** On terminal STATUS (`DRAINED | PAUSED | HUMAN_NEEDED | STOPPED`), clear `session_lock` and `session_lock_expires_at` so `--resume` can claim cleanly. Before exiting, pop the fire's labeled foreign-dirty stash if D1.2 created one (pop-conflict → leave stashed + extend the Drift Note).

**Terminal-fire contract — session death while awaiting CI.** A fire exiting with `awaiting_ci: true` leaves `STATUS: ACTIVE` by design — the in-session cron continues the D7.5 poll next fire. If the SESSION dies between such fires, no code path in the dead session can flip the status: the tracker is stranded `ACTIVE` with a lock that self-expires within 30 minutes. That stranding is expected, not a defect — recovery is Resume step 2's stale-ACTIVE reclaim (`ACTIVE → PAUSED`, `status_reason: "session_ended_between_ci_polls"`, then the normal PAUSED path). Operators never hand-edit `STATUS` for this.

**PAUSED spec deduplication (AP-17).** Writing `STATUS: PAUSED` when the previous fire also wrote PAUSED with the same `status_reason` → skip the tracker commit entirely (no no-op deltas).

---

# Resume mode

Triggered by `/autopilot --resume @<runbook>`. Steps in order:

1. **Validate inputs.** Runbook exists at the path; derive `<slug>`; `.autopilot/runbooks/<slug>.tracker.md` exists. Refuse if either is missing.
2. **Validate STATUS.**
   - `PAUSED` → continue to step 2a.
   - `ACTIVE` → inspect the lock AND a dead-session signal (**stale-ACTIVE reclaim**):
     - Lock held and unexpired → refuse: `Resume refused: drain already ACTIVE. Either a fire is in flight or the previous session is still draining.`
     - Lock null or expired → expiry alone is NOT proof of death: the lock is refreshed only at fire start (now + 30 min, D1.0) while mid-fire liveness is `last_heartbeat_at`, and a normal implementation fire routinely outlives its 30-minute lock. Reclaim ONLY when a dead-session signal ALSO holds — `last_heartbeat_at` > 90 min old (the D1.3 crash standard), or `in_progress.awaiting_ci: true` (pushed, between CI polls, no implementation work in flight — the classic stranding, D8 §Terminal-fire contract). Then flip `ACTIVE → PAUSED` (`status_reason: "session_ended_between_ci_polls"` when awaiting CI, else `"session_ended_mid_fire"`), drift-note the reclaim, and continue as the normal PAUSED path.
     - Lock null/expired but NEITHER signal holds (fresh heartbeat, not awaiting CI) → a live fire is likely mid-implementation past its lock; reclaiming would race its tracker writes and working tree. Refuse: `Resume refused: drain ACTIVE with a recent heartbeat (<last_heartbeat_at>) — a fire may still be live. Retry after the heartbeat is 90+ min stale.`
   - `DRAINED | STOPPED` → refuse: `Resume refused: drain is in terminal state <STATUS>. Use --generate to start a new drain.`
   - `HUMAN_NEEDED` → refuse: `Resume refused: HUMAN_NEEDED exits the automated loop; re-entry is the operator recovery procedure in runbook-template.md §"Resuming a runbook".` (That procedure's operator STATUS flip is the ONE sanctioned hand-edit of `STATUS` — see D1.4.)
2a. **Refuse manifest-revision drift (MS §6 / AV3-04).** `bash ${SKILL_DIR}/scripts/manifest_revision_gate.sh resume-check .autopilot/runbooks/<slug>.tracker.md` — exit 2 (`status_reason: manifest-revision-drift`) → plain resume REFUSED (it would re-plan nothing against the new revision); print the revision-regen pointer and stop. Recovery is `--generate --merge` **revision-regen**: re-plans the open (`[ ]`) Subtasks against the new `manifest_revision`, preserves `[x] Done` history (a Hard Contract 8 carve-out — regen is neither overwrite nor plain merge; §6's ID-stability lets surviving Behavior IDs re-plan without rework), supersedes the old Runbook PR (AV3-08), and closes the orphaned draft Story PRs it lists. Exit 0 → continue.
3. **Validate session lock.** Set and unexpired → refuse: `Resume refused: session lock held by <session>; expires <iso8601>.`
4. **Flip STATUS.** `PAUSED → ACTIVE`; delete `status_reason`.
5. **Cadence from tracker state:** `awaiting_ci: true` + `ci.skip_wait: false` → `*/10`; `awaiting_ci: true` + `skip_wait: true` → `*/30`; either counter > 0 with a `[BLOCKED]` last entry → `*/30`; else `*/5`.
6. **Re-arm cron.** `CronCreate(cron=<expr>, recurring=True, durable=False, prompt='/autopilot --drain @<runbook-path>')` — the prompt must carry the `/autopilot --drain` invocation; a bare `@file` reference gives the next fire no instruction to run the DRAIN lifecycle.
7. **Print one line.** `Resumed drain '<slug>' at cadence <expr>; <N> Subtasks remaining.`

---

# Failure escalation (AP-2)

The tracker carries `consecutive_impl_blocks` and `consecutive_ci_blocks`. Every `[BLOCKED]` is tagged `(impl)`, `(ci)`, or `(external)` and increments its counter (external never does). Both reset to 0 whenever a Subtask goes `[x] Done` during a fire. G5 already-shipped Subtasks never touch counters (marked Done before any drain started).

External faults (`foreign-commits-on-branch`, `trunk-renamed`, `runbook-pr-blocked`, `unexpected-branch-shape`, `dirty-drain-state`, `ci-check-usage-error`, `claim-eligibility-usage-error`, `lock-check-env-error`) route straight to `HUMAN_NEEDED`, no counters.

Caps are runbook-configured: `budget.max_impl_blocks` (default 3), `budget.max_ci_blocks` (default 2 — CI flakes are usually environmental; retrying past 2 burns budget). At either cap: write `STATUS: HUMAN_NEEDED`; list the tripped counter + contributing Subtask IDs and reasons in `## Escalation`; `CronDelete`; exit.

# STATUS state machine

| Status | Meaning | Cron |
|---|---|---|
| `ACTIVE` | Loop running normally | Armed, adaptive |
| `DRAINED` | All Subtasks `[x] Done` | Deleted; success exit |
| `PAUSED` | Operator-paused (or gate-paused, e.g. manifest drift) | Deleted (Resume re-arms) |
| `HUMAN_NEEDED` | Counter cap OR external fault | Deleted; failure exit |
| `STOPPED` | Hard fault (dirty trunk, missing runbook, concurrent drain) | Deleted |

# Runbook-PR availability (AV3-08)

Every fire lands bookkeeping on the Runbook PR (`autopilot/<slug>/runbook`) — if that PR becomes unmergeable mid-drain the loop has nowhere to land state and must surface for triage rather than silently diverge. At the top of D1 (after D1.0/D1.1, before D2), check `bash ${SKILL_DIR}/scripts/host.sh pr-state --branch autopilot/<slug>/runbook`. Observable states are exactly what the adapter emits (mergeability is NOT observable via `pr-state`; a conflicted Runbook PR surfaces later as a failed push):

| Runbook PR state | Action |
|---|---|
| `OPEN` | Normal — continue. |
| `NONE` | No PR for the branch (crashed before creation, or deleted). Remote branch exists → open the Runbook PR; else branch from `origin/<trunk>`, push runbook + tracker, open it with the file-surface block (G7). Drift-note; continue. |
| `DECLINED` | `STATUS: HUMAN_NEEDED — runbook-pr-blocked` citing the URL, `CronDelete`, exit. (External fault.) |
| `MERGED` | Merged early by the operator/Marshal — re-open the bookkeeping home by re-branching `autopilot/<slug>/runbook` from `origin/<trunk>` and pushing; continue. |

# End-of-drain output

On `STATUS: DRAINED`, the final fire renders `MERGE-ORDER.md` next to the tracker — a list of **Story PRs** (one per Story, AV3-06). Required content: DAG-topological Story-PR list with dependency annotations (root / depends-on / stacked, merge-commit-not-squash flagged for stacked); the Runbook PR as the FINAL entry (the operator or Marshal merges it — autopilot NEVER merges its own PRs); drain start SHA + current `origin/<trunk>` SHA + commit delta; mid-drain rebase count; hot-file serialization count; G3.6 consolidations; G1.5 probe facts + surviving `unknown`s; total D7.1a fold count; a one-line rebase recovery hint (`git fetch origin && git rebase origin/<trunk>`).

## Dangling draft Story PRs (every terminal STATUS — AV3-06)

On ANY terminal STATUS, the end-of-drain output MUST enumerate every dangling draft Story PR — still `DRAFT` because its Story did not fully drain — with a required operator disposition each (autopilot never merges and never silently abandons a draft). On a non-`DRAINED` terminal (`HUMAN_NEEDED`/`PAUSED`), the Runbook PR is listed alongside them with its own disposition (stays open as the bookkeeping home until the drain resumes or the operator closes it):

```
DRAFT Story PR <host>/<pr#>  story=<story-id>  branch=autopilot/<slug>/<story-id>
  done:    <n>/<m> Subtasks
  open:    <subtask-ids still [ ]>
  blocked: <subtask-ids [BLOCKED], with reasons>
  disposition: <one of — resume (fixable block), decline+replan (stale), or hand-merge-partial (operator accepts the partial Story)>
```

A `DRAINED` state normally has zero dangling drafts; a non-empty list under `DRAINED` is itself a defect to surface. Under `PAUSED — manifest-revision-drift` the drafts stay draft by contract, listed here for revision-regen to supersede.
