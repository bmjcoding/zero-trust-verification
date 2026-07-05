# DRAIN lifecycle (D1..D8), Resume, failure escalation, STATUS, tracker-PR availability, end-of-drain output


**Loading-preamble reminder (survives auto-compaction).** Every step below honours the delegation contract in `SKILL.md` §"Loading preamble" and Hard Contract §10. Delegation is the positive default. Before any tool call, name the subagent you are about to dispatch. `--yolo`, `--force`, `branching.single_branch_single_pr`, `branching.no_force_push`, and any future override are ORTHOGONAL to this contract — none of them licenses direct orchestrator edits to source files. Rich context (SPEC.md, ADR text, runbook body) is *more* reason to delegate, not less. First-action gate: if the next action is not a dispatch and does not fall inside the orchestrator-direct allow-list (tracker/runbook Read/Edit, short-output git, skill scripts under `${SKILL_DIR}/scripts/`), stop and re-read this preamble.


Each fire follows the 8-step lifecycle below. Per-fire scope is HARD: one Subtask end-to-end, then exit (writing the next cron and updating tracker before exiting).


## Step D1 — Hydrate + WIP recovery


Orchestrator-direct work in this step is limited to: reading the tracker, reading the runbook, running short single-line git commands, and running the skill's own scripts. Orchestrator MUST NOT Read any source file under the repo's code directories — that work belongs to subagents in D3/D4/D5. This caps per-fire parent context accumulation; the tracker is the source of truth across fires.


### D1.0 — Session lock claim (AP-4)


Run `bash ${SKILL_DIR}/scripts/detect_concurrent_drain.sh .autopilot/runbooks/<slug>.tracker.md` as the fast pre-check: exit 2 → another session holds a live lock, refuse the fire (`CronDelete`, exit silently — the other session's cron keeps firing); exit 4 → corrupt lock state, refuse with `STATUS: HUMAN_NEEDED — tracker-lock-unreadable` (fail closed); exit 64 → the invocation itself is wrong (suspect path), refuse with `STATUS: HUMAN_NEEDED — lock-check-usage-error` (external fault); exit 0 or 3 → proceed to the dispatch table below.


Read the tracker's frontmatter. Compute `now_iso = $(date -u +%Y-%m-%dT%H:%M:%SZ)`.


| Frontmatter state | Action |
|---|---|
| `session_lock: null` | Set `session_lock: ${CLAUDE_SESSION_ID}` and `session_lock_expires_at: <now + 30 min>`. Continue. |
| `session_lock: ${CLAUDE_SESSION_ID}` (our own) | Refresh `session_lock_expires_at: <now + 30 min>`. Continue. |
| `session_lock: <other>` + `session_lock_expires_at > now` | Refuse: another session is draining. `CronDelete`, exit fire silently. The other session's adaptive cron will keep firing. |
| `session_lock: <other>` + `session_lock_expires_at <= now` | Treat as crashed: claim the lock ourselves. Add a `## Drift Notes` entry: "session lock expired from <other>; reclaimed by <this>". |


Commit the tracker delta via the rolling tracker PR (under `branching.no_force_push: false`) OR append the delta as `delta_kind: session_lock` to `## Pending Tracker Deltas (batched)` (under `branching.no_force_push: true`) before doing any other work.


> **Known limitation (batched-delta mode).** Under `branching.no_force_push: true` the lock write stays in the local tracker file until the next D7.1a fold lands — a second session draining from a DIFFERENT clone cannot see it. AP-4's session lock is therefore checkout-local in that mode; the cross-clone guard is the branch-namespace check (`git ls-remote origin 'refs/heads/autopilot/<slug>/*'` showing branches you didn't create) plus operator discipline. Documented, not solved, in v2.4.0.


### D1.0.4 — Pending-deltas migration + crash recovery (AP-23)


Runs only when `branching.no_force_push: true`. Otherwise skipped.


1. **Migration.** If the tracker was created by an autopilot version prior to v2.3.0 and does not yet contain a `## Pending Tracker Deltas (batched)` section, inject the section header with body `_(empty)_` between `## Drift Notes` and the first Subtask. Idempotent.
2. **Crash recovery.** A non-empty queue at fire start is NORMAL in batched mode (D2 claims, D4 heartbeats, and D7.4 status deltas all wait for the next D7.1a fold) — it is a crash signal only when accompanied by evidence the prior fire did not exit cleanly: this fire reclaimed an expired foreign lock at D1.0, or D1.3's 90-minute heartbeat crash detector fired. Only then append ONE `delta_kind: crash_recovery` entry with `body:` documenting the recovered queue's SHA-fingerprint. Do NOT remove prior entries — the D7.1a fold on the next successful Subtask PR is the only legitimate flush point. (Appending on every non-empty queue would spam a `crash_recovery` entry into every healthy fire and grow the queue without bound.)


Full contract, `delta_kind:` catalog, and recovery semantics: `references/tracker-delta-batching.md`.


### D1.0.5 — Drift-notes hydration (AP-20)


Read every `## Drift Notes` entry in the tracker before any git or Bitbucket action. Drift notes are hard preconditions, not commentary. Examples: "trunk renamed mid-drain to `develop`" — subsequent D1.4 must use `develop`, not the frontmatter's original `trunk_branch`. "operator flipped `branching.single_branch_single_pr` after 2 Subtasks landed" — subsequent D7 must merge into the existing single branch, not open a new PR.


This step stops fires re-deriving the same workarounds from scratch every 5 minutes.


### D1.1 — Branch shape check (AP-7)


`git branch --show-current` MUST match either:
- `autopilot/<slug>/setup`
- `autopilot/<slug>/<subtask-id>`
- `autopilot/<slug>/tracker` (only under `branching.no_force_push: false`)
- The runbook's single feature branch (only under `branching.single_branch_single_pr: true`)


Anything else → `STATUS: HUMAN_NEEDED — unexpected-branch-shape` citing the current branch. `CronDelete`, exit.


### D1.2 — Hydrate


Read in parallel:
- `.autopilot/runbooks/<slug>.tracker.md`
- `git status --short`
- `git fetch origin && git rev-list --count <drain-start-sha>..origin/<trunk>` (external churn count)
- `git branch --show-current`


Update `last_heartbeat_at: <now>` (AP-6 first heartbeat of the fire).


**Runtime budget check.** If `now - drain_started_at > budget.max_runtime_minutes`, write `STATUS: HUMAN_NEEDED — runtime-budget-expired`, `CronDelete`, exit. (`drain_started_at` is seeded by the first fire.)


### D1.3 — Heartbeat-driven crash detection


If `in_progress.last_heartbeat_at > 90 min old` → treat as crashed; apply RESUME or ABANDON dispatch below.


### D1.4 — WIP recovery dispatch


**Rows are evaluated top-to-bottom; the FIRST matching row wins** (several conditions overlap by construction — e.g. a pushed Subtask has `subtask_id` set AND `awaiting_ci: true` AND a local branch ahead of base; external PR state must be checked before generic CI polling so a merged PR is never mistaken for a hung build).


| `in_progress` block in tracker | Action |
|---|---|
| `git symbolic-ref refs/remotes/origin/HEAD` differs from the trunk baked into the runbook | Trunk renamed mid-drain — write `STATUS: HUMAN_NEEDED — trunk-renamed` citing old vs new trunk, `CronDelete`, exit. (External fault: no counter increment.) |
| Local branch `autopilot/<slug>/<subtask-id>` has commits whose author email is not `git config user.email` | Foreign push detected — write `STATUS: HUMAN_NEEDED — foreign-commits-on-branch` listing the offending SHAs, `CronDelete`, exit. (External fault: no counter increment.) |
| Empty / null | Normal — proceed to D2. |
| `awaiting_ci: true`, `pr_number` set, and PR state (`pr-state --num <pr_number>`) = `MERGED` | PR was merged externally — mark Subtask `[x] Done` with PR URL + merge commit SHA, reset both counters to 0, clear `in_progress`, re-arm at `*/5`, exit fire. |
| `awaiting_ci: true`, `pr_number` set, and PR state = `DECLINED` | PR was declined externally — write `[BLOCKED: pr-declined]` (ci) on Subtask citing the PR URL, increment `consecutive_ci_blocks`, clear `in_progress`, re-arm at `*/30`, exit fire. |
| `awaiting_ci: true`, `pr_number` set, PR state = `OPEN`, and `ci.skip_wait: false` | CI-poll mode — run `bash ${SKILL_DIR}/scripts/ci_check.sh --sha <in_progress.pushed_sha> --pr <pr_number> --once`; act on result (D7.5). **Hard contract: after D7.5 completes, exit the fire regardless of outcome. Do NOT continue to D2 in the same fire.** |
| `awaiting_ci: true`, `pr_number` set, PR state = `OPEN`, and `ci.skip_wait: true` | The PR is awaiting operator merge (no CI polling); re-arm at `*/30`, exit. |
| `subtask_id` set (not awaiting CI), branch exists locally with commits ahead of base | RESUME — rebase on base, re-run Step D6 test gate; if green → push + open PR (D7); if red → spawn ONE `general-purpose` quality fix attempt; then push or `[BLOCKED: resume-failed]` (impl). |
| `subtask_id` set, branch missing or empty | ABANDON — clear `in_progress`, write `[BLOCKED: orphan-resume]` (impl) on that Subtask, continue to D2 with the next Subtask. |


Refuse the fire if `STATUS != ACTIVE`. On terminal statuses the cron has already been deleted (Hard Contract §9); if a fire runs anyway (manual invocation, stray cron), no-op WITHOUT re-arming. Recovery from `PAUSED` is exclusively via `/autopilot --resume` — do not hand-flip `STATUS` back to `ACTIVE` (Resume refuses an already-ACTIVE tracker, so a hand-flip strands the drain with no cron and no resume path).


External churn > 100 commits since drain start → write `## Drift Notes` warning to tracker; don't auto-restart.


## Step D2 — Select next Subtask


Topo-walk the DAG. Pick the lowest-ID Subtask where:
- Status is `[ ]` (not `[x]`, not `[BLOCKED]`)
- All `depends_on[]` Subtasks are `[x] Done`


If no eligible Subtask:
- All `[x]` → write `STATUS: DRAINED`, render `MERGE-ORDER.md`, `CronDelete`, exit fire successfully.
- All blocked or pending-deps → write `STATUS: HUMAN_NEEDED`, `CronDelete`, exit.
- `consecutive_impl_blocks >= budget.max_impl_blocks` OR `consecutive_ci_blocks >= budget.max_ci_blocks` (runbook-configured; defaults 3 / 2) → write `STATUS: HUMAN_NEEDED` + `## Escalation` block citing which counter tripped and the contributing Subtasks, `CronDelete`, exit. AP-2.


Otherwise: write the chosen Subtask's full block to `in_progress` in the tracker, with `started_at`, `last_heartbeat_at`, and a placeholder `pr_number: null`.


**Tracker commit routing (AP-23).**


- Under `branching.no_force_push: false`: commit the tracker delta via the rolling tracker PR.
- Under `branching.no_force_push: true`: append the delta as `delta_kind: in_progress_claim` to `## Pending Tracker Deltas (batched)` with a `diff_summary` describing the claim. Do NOT commit directly — the D7.1a fold will land the queue's contents atomically with the next Subtask PR.


Refresh heartbeat (AP-6).


## Step D3 — Plan + Plan review (AP-5 + AP-3)


### D3.0 — Audited-SHA verification (AP-5)


For each file in the Subtask's `owned_files[]` that is NOT marked `# NEW`:


```bash
git cat-file -e ${audited_sha}:<file> 2>/dev/null || echo "MISSING"
git diff --quiet ${audited_sha}..HEAD -- <file> || echo "DRIFTED"
```


If any file is MISSING at `audited_sha` → `[BLOCKED: plan-stale-missing]` (impl). If any file DRIFTED between `audited_sha` and HEAD → `[BLOCKED: plan-stale-drifted]` (impl) with the drifted paths listed. No retry; this means HEAD moved under the plan and the Subtask needs human re-plan.


### D3.1 — Plan


Spawn `Plan` agent (Claude Code native). Prompt: the Subtask's full schema block + the runbook's "Plan agent role" section.


### D3.2 — Plan review (schema-only projection)


Spawn `Plan` agent again in REVIEW mode. Prompt: the schema-only projection of the first plan's output (no `evidence`, no `contract` prose, no `test_name_hint`) + "review the plan above for: feasibility, file-path verification, dependency gaps, ownership overlap with concurrent in-flight branches (`git branch --remote --list 'autopilot/<slug>/*'`), behaviors-to-test completeness." AP-3.


If reviewer NO-GO: re-spawn original `Plan` agent ONCE with reviewer findings. Still NO-GO → write `[BLOCKED: plan-ungated]` (impl) on the Subtask, increment `consecutive_impl_blocks`, re-arm cron at `*/30`, exit fire.


Refresh heartbeat (AP-6).


## Step D4 — Implement (TDD vertical slice with per-cycle commits — AP-1)


Branch from the appropriate base per the DAG-aware branching rule:
- `depends_on: []` → branch from `origin/<trunk>`
- `depends_on: [X]` and X is `[x] Done` → branch from `origin/<trunk>` (X is in trunk)
- `depends_on: [X]` and X is in-flight (rolling PR or batched queue) → branch from `autopilot/<slug>/<X-id>` tip → produces a stacked PR
- Under `branching.single_branch_single_pr: true` → always branch from (or reset onto) the drain's single feature branch


`git checkout -b autopilot/<slug>/<subtask-id>` (or `git checkout <single-feature-branch>` under the single-branch mode).


Spawn ONE `general-purpose` agent with the role prompt at `references/implementer-prompt.md` inlined verbatim, plus the runbook's `gates:` command table (the implementer runs tests through `gates.test_scoped`, never a hardcoded runner). The number of TDD cycles may not exceed `budget.max_cycles_per_subtask`; hitting the cap mid-Subtask → `[BLOCKED: cycle-budget-exhausted]` (impl). The prompt enforces:
- TDD vertical slice: for each behavior in `behaviors_to_test[]`, RED → GREEN, in order
- **Per-cycle local commits** (AP-1):
  - After each RED: `git add <test files>` + `git commit -m "test: <id>.<n> RED — <behavior>"`
  - After each GREEN: `git add <impl files>` + `git commit -m "feat: <id>.<n> GREEN — <behavior>"`
  - Test files and impl files committed separately even if edited in the same cycle
- **JIRA-key prefix (AP-22)** when `enforce_jira_key: true`: every commit subject is prefixed with `[<JIRA-KEY>]`, i.e. `test: <id>.<n> [<JIRA-KEY>] RED — <behavior>`. Applies to TDD-cycle commits, the D7.1 final commit, and every tracker bookkeeping commit.
- Refactor only after all behaviors GREEN — committed as `refactor: <id> — <change>` (with JIRA-key prefix if enforced)
- Public-interface tests only; never mock internal collaborators
- Report per-behavior RED → GREEN sequence in the final summary (capped at 800 tokens — AP-16)


The agent's `kind`-aware behavior:


| `kind` | What the agent does |
|---|---|
| `code`, `test-only` | Full TDD vertical slice with per-cycle commits |
| `refactor` | Run existing tests first to confirm GREEN baseline; refactor (single `refactor:` commit); re-run to confirm GREEN preserved |
| `docs`, `config` | Skip TDD inner loop; single `docs:` or `chore:` commit; run any kind-specific gate |


Refresh `last_heartbeat_at` in the tracker (AP-6). Under `branching.no_force_push: true`, append a `delta_kind: other` heartbeat delta to the queue rather than committing directly.


## Step D5 — Validate (parallel)


Spawn THREE `general-purpose` agents in ONE message (parallel) with role prompts from `references/validator-prompts.md`:


1. **Integration validator** — types compile, contracts honored, no import cycles, file-path verification.
2. **Design validator** — structural coherence, no premature abstractions, layer rule respected. Tests verify behavior through public interface.
3. **Quality validator** — runs the scoped test gates (`gates.test_single` / `gates.test_scoped`) and any contract tests added.


Read all three outputs in parallel.


### Contradictory validator escalation (AP-18)


If two validators return findings on the SAME `location` (file:line) but their `suggested_fix` fields are semantically opposing (one says "remove X", another says "expand X"; one says "rename to Y", another says "rename to Z"), do NOT spawn a fix agent — the agents will thrash. Instead: write `[BLOCKED: validator-contradiction]` (impl), include both findings verbatim in the tracker entry, increment `consecutive_impl_blocks`, re-arm at `*/30`, exit.


### Normal findings handling


If any validator returns findings (non-contradictory):
- Spawn ONE `general-purpose` agent in fix mode (prompt = findings list verbatim + affected files + "fix only what's listed").
- Re-run validators (parallel).
- Cap: validator findings = 2 fix-passes; lint-only = 4 fix-passes; test-fail = 2 fix-passes.


Past cap → write typed `[BLOCKED: <kind>-unresolved]` (impl), increment `consecutive_impl_blocks`, re-arm at `*/30`, exit fire.


Refresh heartbeat after validation pass (AP-6).


## Step D6 — Test gate + AP-1 commit-shape audit


### D6.1 — Test gates


Run the runbook's `gates:` commands (see `references/runbook-template.md` §gates — Python defaults shown in parentheses), must all pass:
- `gates.test_scoped` against the **changed module scope only** (default `pytest -x -q {paths}`; AP-15: not full suite during rebase loops)
- `gates.test_contract` on the scoped paths (default `pytest -m contract -x -q {paths}`; only if `test_gates` includes `contract`)
- `gates.typecheck` on the changed modules (default `mypy {paths}`; delta only)
- `gates.lint` on the changed files (default `ruff check {paths}`; scoped, not repo-wide — pre-existing lint debt elsewhere in a brownfield repo must not block this Subtask)
- `gates.precommit` (default `pre-commit run --files {files}`; NEVER `--no-verify`)


### D6.2 — TDD audit via git log (AP-1)


The implementer's report is no longer the source of truth for TDD compliance — git log is.


```bash
git log --oneline origin/<base>..HEAD --pretty=format:"%s"
```


Expected shape for `kind: code | test-only`:
- For each behavior `<n>` in `behaviors_to_test[]`, exactly one `test: <id>.<n> RED — ...` commit AND exactly one `feat: <id>.<n> GREEN — ...` commit, in that order.
- Under `enforce_jira_key: true`, every commit subject must include `[<JIRA-KEY>]` in the required position.
- Optional `refactor: <id> — ...` commits at the end.
- No `chore:` / `fix:` / `docs:` mixed in (those signal scope leak).


Failure modes:
- Cycle count (RED/GREEN pairs) exceeds `budget.max_cycles_per_subtask` → `[BLOCKED: cycle-budget-exhausted]` (impl) — the git log is the enforcement point, not the implementer's self-report.
- Missing RED for behavior N → `[BLOCKED: tdd-no-red]` (impl) citing N.
- Missing GREEN for behavior N → `[BLOCKED: tdd-no-green]` (impl) citing N.
- GREEN precedes RED for any N → `[BLOCKED: tdd-out-of-order]` (impl).
- Extra commits with foreign types → `[BLOCKED: tdd-scope-leak]` (impl).
- JIRA-key missing on any commit under `enforce_jira_key: true` → `[BLOCKED: jira-key-missing]` (impl) citing the offending commits.


For `kind: refactor`: expect exactly one `refactor: <id> — ...` commit and zero `test:` / `feat:` commits. Violations → `[BLOCKED: refactor-shape-wrong]` (impl).


For `kind: docs | config`: expect exactly one commit of the appropriate type (`docs:` or `chore:`).


Failure dispatch matches Step D5 (typed BLOCKED, increment `consecutive_impl_blocks`).


## Step D7 — Pre-push rebase + commit + PR


**Step D7.0 — Pre-push rebase.** `git fetch origin && git rebase origin/<base>`. If clean, continue. If conflicts, follow the protocol at `references/conflict-resolution.md` (inlined Pocock-style). Budget: 3 hunks across 2 files max — past that, `[BLOCKED: rebase-too-large]` (impl), no retry (planning failure; needs human).


During conflict resolution, run `gates.test_scoped` against changed paths only — never the full suite (AP-15).


**Step D7.1 — Stage owned_files[].** The per-cycle commits from D4 ARE the PR's commits. Stage only `owned_files[]` if any unstaged changes remain from refactor pass; otherwise skip. Never `git add -A`.


When a final commit IS needed (e.g., for `kind: docs | config | refactor`), follow these rules:


- Stage only `owned_files[]`.
- Conventional Commits: `<type>: <id> — <title>` (e.g., `refactor: B1 — decouple validator from registry`).
- Under `enforce_jira_key: true` (AP-22), prefix with `[<JIRA-KEY>]`: `feat: B1 [PROJ-1235] — F.1a discriminator audit`.
- Body: `acceptance_criteria` checklist + `Rationale:` paragraph (AP-8) explaining the chosen approach in 2-3 sentences + `Refs:` footer with JIRA-KEY (if any) and source_ref.
- Trailer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
- HEREDOC for formatting.


**Step D7.1a — Tracker-delta fold (AP-23).** Runs only under `branching.no_force_push: true`. Read the tracker's `## Pending Tracker Deltas (batched)` section. If it is `_(empty)_`, skip. Otherwise:


1. Build a `Tracker deltas folded in:` block for the commit body listing each pending entry's `delta_kind` + `diff_summary` (one line per entry).
2. Apply every entry's `body:` field to the tracker file (mutations accumulated in-order).
3. Flush the queue: replace the section body with `_(empty)_`.
4. Stage the tracker file alongside `owned_files[]`. This is the ONLY commit in the fire that stages the tracker file directly.
5. The final commit lands: impl edit + cumulative tracker mutations + queue flush, atomically.


Under `branching.no_force_push: false` this step is a no-op — tracker bookkeeping stays on the rolling tracker PR.


**Step D7.2 — Push.** `git push -u origin <branch>`. Transient failure → 1 retry. Auth failure → `[BLOCKED: bitbucket-token-missing]` (impl), no retry.


**Step D7.3 — PR.** `bash ${SKILL_DIR}/scripts/host.sh pr-open --title "<commit-subject>" --src <head-branch> --dest <base-branch> --body-file <body-file>` returns the PR number on stdout (host.sh dispatches to the detected backend — never call a backend directly, Hard Contract 11). Dest = the rebase base from D7.0. Body file = Summary + Test plan + TDD sequence + Checklist sections.


Under `branching.no_force_push: true` with a non-empty D7.1a fold, the PR body ALSO includes a `## Tracker deltas folded in` H2 listing each entry's `delta_kind` + `diff_summary` for reviewer visibility.


Under `branching.single_branch_single_pr: true`, D7.3 opens the PR only on the FIRST successful Subtask; subsequent Subtasks push additional commits to the same branch and update the existing PR via `host.sh pr-comment` (append a "Subtask <id> landed" note).


**Step D7.4 — Tracker update.** Set `in_progress.pr_number = <num>`, `in_progress.awaiting_ci = true`, `in_progress.pushed_at = <iso8601>`, `in_progress.pushed_sha = <HEAD sha just pushed>` (consumed by D7.5's `ci_check.sh --sha`), `in_progress.ci_check_count = 0`, `last_heartbeat_at = <now>`.


- Under `branching.no_force_push: false`: commit via rolling tracker PR.
- Under `branching.no_force_push: true`: append `delta_kind: status_change` to the queue. The next Subtask's D7.1a fold will land it. Between now and then, D2 will surface the pending entry on hydrate.


### D7.3a — Stacked PR merge strategy (AP-10)


(Renamed from a second "D7.5" in v2.4.0 — the step id collided with the CI poll below.) When the PR being created stacks on another in-flight Subtask's branch, the PR description MUST request a **merge commit (not squash)**. Bitbucket's PR merge UI defaults to squash; squash on a stacked PR collapses the dependency chain and breaks subsequent rebases. `host.sh pr-merge` defaults to the merge-commit intent and uses `pr-merge-strategies` discovery to fall back to the closest enabled strategy on repos that don't offer it (the Bitbucket DC backend maps to `no-ff`/`squash`/…; the GitHub backend to `--merge`/`--squash`/`--rebase`).


## Step D7.5 — CI poll (cross-fire)


This step runs only on a fire that started with `awaiting_ci: true` (D1 dispatch). Under `ci.skip_wait: true` this step is short-circuited — D1's WIP dispatch already handled the merged/open/declined cases without running `ci_check.sh`.


Run `bash ${SKILL_DIR}/scripts/ci_check.sh --sha <in_progress.pushed_sha> --pr <pr_number> --once`. `--once` takes ONE observation and exits immediately (the drain design is cross-fire; the blocking poll mode is for interactive operator use only). The script emits `LAST_STATE=<actual last observed build state>` on stderr before every exit; cite it in tracker entries.


| `ci_check.sh --once` result | Action |
|---|---|
| exit 0 (VERDICT=GREEN) | Mark Subtask `[x] Done` with PR URL + commit SHA + `[<JIRA-KEY>]` if any. Reset both counters to 0 (AP-2: a Done resets impl AND ci). Clear `in_progress`. Re-arm cron at `*/5`. Exit fire. |
| exit 1 (VERDICT=RED) | Write `[BLOCKED: ci-red]` (ci) on Subtask with the failing check name + log URL. Increment `consecutive_ci_blocks`. Clear `in_progress`. Re-arm cron at `*/30`. Exit fire. **No retry.** |
| exit 5 (VERDICT=PENDING) + `ci_check_count < 6` | Build in progress or not yet reported. Increment `ci_check_count`. Update `last_heartbeat_at`. Re-arm cron at `*/10`. Exit fire. |
| exit 5 (VERDICT=PENDING) + `ci_check_count >= 6` | Write `[BLOCKED: ci-stuck-pending]` (ci) citing `LAST_STATE=` (INPROGRESS = a build is hung; UNKNOWN = CI never reported for this SHA). Increment `consecutive_ci_blocks`. Clear `in_progress`. Re-arm cron at `*/30`. Exit fire. |
| exit 4 (VERDICT=PR_DECLINED) | Write `[BLOCKED: pr-declined]` (ci) on Subtask citing PR URL. Increment `consecutive_ci_blocks`. Clear `in_progress`. Re-arm at `*/30`. Exit fire. |
| exit 64 (usage error) | Write `STATUS: HUMAN_NEEDED — ci-check-usage-error` citing stderr, `CronDelete`, exit. (External fault: no counter increment.) |


(Exit codes 2 STUCK and 3 UNDETERMINED belong to the blocking mode and cannot occur under `--once`.)


## Step D8 — Adaptive cron re-arm


Always the last action before exiting a fire. Cadence dispatch is defined once in `references/cadence-dispatch.md` and inlined into the runbook at GENERATE-time.


### Session-lock release


On terminal STATUS (`DRAINED | PAUSED | HUMAN_NEEDED | STOPPED`), clear `session_lock` and `session_lock_expires_at` so a `--resume` can claim cleanly.


### PAUSED spec deduplication (AP-17)


If the tracker is being written to `STATUS: PAUSED` and the previous fire ALSO wrote `STATUS: PAUSED` with the same `status_reason`, skip the tracker commit entirely (the rolling PR or the batched queue doesn't need yet another no-op delta).


---


# Resume mode


Triggered by `/autopilot --resume @<runbook>`. Recovers a paused drain without requiring the operator to re-paste a long resume prompt.


Steps in order:


1. **Validate inputs.** Confirm runbook exists at the given path; derive `<slug>` from the filename; confirm `.autopilot/runbooks/<slug>.tracker.md` exists. Refuse if either is missing.
2. **Validate STATUS.** Read `STATUS:` from the tracker frontmatter.
   - `PAUSED` → continue.
   - `ACTIVE` → refuse with `Resume refused: drain already ACTIVE. Either a fire is in flight or the previous session is still draining.`
   - `DRAINED | HUMAN_NEEDED | STOPPED` → refuse with `Resume refused: drain is in terminal state <STATUS>. Use --generate to start a new drain.`
3. **Validate session lock.** If `session_lock` is set and not expired, refuse with `Resume refused: session lock held by <session>; expires <iso8601>.`
4. **Flip STATUS.** Change `STATUS: PAUSED` → `STATUS: ACTIVE` and clear `status_reason` (delete the field if present).
5. **Determine cadence from tracker state.** Inspect `in_progress`:
   - `awaiting_ci: true` + `ci.skip_wait: false` → use `*/10`
   - `awaiting_ci: true` + `ci.skip_wait: true` → use `*/30` (no CI polling; wait for operator merge)
   - `consecutive_ci_blocks > 0` or `consecutive_impl_blocks > 0` and last entry is `[BLOCKED]` → use `*/30`
   - else → use `*/5`
6. **Re-arm cron.** `CronCreate(cron=<expr>, recurring=True, durable=False, prompt='/autopilot --drain @<runbook-path>')` — the prompt must carry the `/autopilot --drain` invocation, not a bare `@file` reference (a bare file mention gives the next fire no instruction to run the DRAIN lifecycle).
7. **Print one-line summary.** `Resumed drain '<slug>' at cadence <expr>; <N> Subtasks remaining.` (Count `[ ]` Subtasks in the tracker.)


---


# Failure escalation (AP-2)


Tracker tracks `consecutive_impl_blocks: N` and `consecutive_ci_blocks: N` at the top frontmatter. Increment the corresponding counter on every `[BLOCKED]` outcome based on the block's domain tag (every BLOCKED in this skill is tagged `(impl)`, `(ci)`, or `(external)`). Reset both to 0 whenever a Subtask transitions to `[x] Done` during a drain fire (the D7.5 all-green path).


G5 already-shipped Subtasks do NOT affect either counter — they're marked Done at GENERATE-time before any drain has started.


External faults (`foreign-commits-on-branch`, `trunk-renamed`, `tracker-pr-blocked`, `unexpected-branch-shape`, `ci-check-usage-error`) route straight to `HUMAN_NEEDED` and never touch counters.


The caps are runbook-configured: `budget.max_impl_blocks` (default 3) and `budget.max_ci_blocks` (default 2 — CI flakes are usually environmental; retrying past 2 burns budget). At `consecutive_impl_blocks >= budget.max_impl_blocks` OR `consecutive_ci_blocks >= budget.max_ci_blocks`:


1. Write `STATUS: HUMAN_NEEDED` at the top.
2. List which counter tripped and the contributing blocked Subtask IDs + reasons in a `## Escalation` section.
3. `CronDelete`.
4. Exit fire.


# STATUS state machine


| Status | Meaning | Cron |
|---|---|---|
| `ACTIVE` | Loop running normally | Armed, adaptive |
| `DRAINED` | All Subtasks `[x] Done` | Deleted; success exit |
| `PAUSED` | Operator-paused manually | Cron deleted (Resume re-arms) |
| `HUMAN_NEEDED` | Auto-escalated (3 consecutive impl OR ci blocks) OR external fault | Deleted; failure exit |
| `STOPPED` | Hard fault (dirty trunk, missing runbook, concurrent drain detected) | Deleted |


# Tracker-PR availability


Every fire under `branching.no_force_push: false` writes its tracker delta through the rolling tracker PR (`autopilot/<slug>/tracker`). If that PR becomes unmergeable mid-drain, the loop has no place to land bookkeeping commits and must surface for human triage rather than silently diverging.


Under `branching.no_force_push: true` this section does not apply — bookkeeping lands via the AP-23 batched-delta queue, and there is no rolling tracker PR to poll.


At the top of D1 (after D1.0/D1.1, before D2), when `branching.no_force_push: false`, check the tracker PR state via `bash ${SKILL_DIR}/scripts/host.sh pr-state --branch autopilot/<slug>/tracker`. The observable states are exactly what the adapter emits — `OPEN | MERGED | DECLINED | NONE` (a draft tracker PR would read `DRAFT`; mergeability is NOT observable through `pr-state` — a conflicted tracker PR surfaces later as a failed push/merge, not here):


| Tracker PR state | Action |
|---|---|
| `OPEN` | Normal — continue. |
| `NONE` | No PR exists for the tracker branch (e.g. a prior fire pushed the branch but crashed before PR creation, or the PR was deleted). If the remote branch exists, open the rolling tracker PR (`pr-open`); if not, branch `autopilot/<slug>/tracker` from `origin/<trunk>`, push, and open it. Add a `## Drift Notes` entry; continue. |
| `DECLINED` | Write `STATUS: HUMAN_NEEDED — tracker-pr-blocked` citing the tracker PR URL, `CronDelete`, exit. (External fault: no counter increment.) |
| `MERGED` | Re-open the rolling tracker PR pattern by branching `autopilot/<slug>/tracker` from `origin/<trunk>` and pushing; continue. |


# End-of-drain output


When `STATUS: DRAINED` is written, the final fire produces `MERGE-ORDER.md` next to the tracker. Required content:


- DAG-topological list of PRs with dependency annotations (DAG root / depends on / stacked, with the merge-commit-not-squash flag highlighted for stacked PRs)
- Drain start SHA, current `origin/<trunk>` SHA + commit delta
- Mid-drain rebase count
- Hot-file serialization count
- G3.6 consolidations applied (AP-21)
- G1.5 probe facts + any `unknown` values that persisted through drain (AP-23)
- Total D7.1a tracker-delta fold count (AP-23)
- A one-line rebase recovery hint (`git fetch origin && git rebase origin/<trunk>`)
