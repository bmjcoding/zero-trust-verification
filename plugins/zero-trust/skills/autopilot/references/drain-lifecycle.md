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


Land the tracker delta on the **Runbook PR** (`autopilot/<slug>/runbook`, AV3-08) before doing any other work: under `branching.no_force_push: false` commit it directly to the runbook branch; under `branching.no_force_push: true` append it as `delta_kind: session_lock` to `## Pending Tracker Deltas (batched)` for the next D7.1a flush to the runbook branch.


> **Known limitation (batched-delta mode).** Under `branching.no_force_push: true` the lock write stays in the local tracker file until the next D7.1a fold lands — a second session draining from a DIFFERENT clone cannot see it. AP-4's session lock is therefore checkout-local in that mode; the cross-clone guard is the branch-namespace check (`git ls-remote origin 'refs/heads/autopilot/<slug>/*'` showing branches you didn't create) plus operator discipline. Documented, not solved, in v2.4.0.


### D1.0.4 — Pending-deltas migration + crash recovery (AP-23)


Runs only when `branching.no_force_push: true`. Otherwise skipped.


1. **Migration.** If the tracker was created by an autopilot version prior to v2.3.0 and does not yet contain a `## Pending Tracker Deltas (batched)` section, inject the section header with body `_(empty)_` between `## Drift Notes` and the first Subtask. Idempotent.
2. **Crash recovery.** A non-empty queue at fire start is NORMAL in batched mode (D2 claims, D4 heartbeats, and D7.4 status deltas all wait for the next D7.1a fold) — it is a crash signal only when accompanied by evidence the prior fire did not exit cleanly: this fire reclaimed an expired foreign lock at D1.0, or D1.3's 90-minute heartbeat crash detector fired. Only then append ONE `delta_kind: crash_recovery` entry with `body:` documenting the recovered queue's SHA-fingerprint. Do NOT remove prior entries — the D7.1a fold on the next successful Subtask PR is the only legitimate flush point. (Appending on every non-empty queue would spam a `crash_recovery` entry into every healthy fire and grow the queue without bound.)


Full contract, `delta_kind:` catalog, and recovery semantics: `references/tracker-delta-batching.md`.


### D1.0.5 — Drift-notes hydration (AP-20)


Read every `## Drift Notes` entry in the tracker before any git or Bitbucket action. Drift notes are hard preconditions, not commentary. Examples: "trunk renamed mid-drain to `develop`" — subsequent D1.4 must use `develop`, not the frontmatter's original `trunk_branch`. "operator flipped `branching.single_branch_single_pr` after 2 Subtasks landed" — subsequent D7 must merge into the existing single branch, not open a new PR.


This step stops fires re-deriving the same workarounds from scratch every 5 minutes.


### D1.0.6 — Manifest-revision drift gate (MS §6 / AV3-04)


Runs only on a manifest-backed drain (the tracker recorded a `manifest_revision` at GENERATE). Compare it against the Spec's current manifest:


```bash
bash ${SKILL_DIR}/scripts/manifest_revision_gate.sh drift \
  .autopilot/runbooks/<slug>.tracker.md <spec>.manifest.yaml
# exit 0 OK / NO-MANIFEST · exit 3 DRIFT recorded=<a> current=<b>
```


On **exit 3 (DRIFT)** the Spec was amended by a new revision under a live drain. This is an EXTERNAL fault (no counter increment). Handle it gracefully, not abruptly:
- If a Subtask is mid-cycle, let it **complete its current RED→GREEN commit pair** (never leave a half-written cycle), then stop.
- Write `STATUS: PAUSED` with `status_reason: manifest-revision-drift` in the tracker frontmatter.
- It is **NOT `--force`-bypassable** — `--force` overrides refusals, not a spec that moved under you.
- **Draft Story PRs stay draft** (never auto-readied or merged; they are listed in the end-of-drain dangling-draft disposition).
- `CronDelete`, release the session lock (D8), exit.


Recovery is NOT plain `--resume` (it would re-plan nothing against the new revision) — it is the `--generate --merge` **revision-regen** path (see Resume mode below and AV3-08's Runbook-PR supersession). On **exit 0** continue to D1.1.


### D1.1 — Branch shape check (AP-7)


`git branch --show-current` MUST match either:
- `autopilot/<slug>/setup`
- `autopilot/<slug>/<story-id>` — the **Story branch** (PR-per-Story, AV3-06 / ADR 0007): one Story = one branch = one PR, and each Subtask of that Story is a commit series on it. (Pre-v3 per-Subtask branches `autopilot/<slug>/<subtask-id>` are retired.)
- `autopilot/<slug>/runbook` — the **Runbook PR branch** (AV3-08): carries the runbook + tracker and is the single bookkeeping home (the pre-v3 rolling tracker branch `autopilot/<slug>/tracker` is retired).
- The runbook's single feature branch (only under `branching.single_branch_single_pr: true`)


Anything else → `STATUS: HUMAN_NEEDED — unexpected-branch-shape` citing the current branch. `CronDelete`, exit.


### D1.2 — Hydrate


Read in parallel:
- `.autopilot/runbooks/<slug>.tracker.md`
- `git status --short`
- `git fetch origin && git rev-list --count <drain-start-sha>..origin/<trunk>` (external churn count)
- `git branch --show-current`


Update `last_heartbeat_at: <now>` (AP-6 first heartbeat of the fire).


**Foreign dirty-tree handling.** `git status --short` may show unstaged/untracked changes to files OUTSIDE the drain's surface — session-level orphan edits (e.g. a memory/notes file another workflow keeps dirty) that G1's clean-tree refusal could not see because they appeared after invocation. Handle them once per fire, by rule, instead of re-deriving an ad-hoc workaround every 5 minutes:

- Dirty paths touching the tracker, the runbook, or any in-flight Subtask's `owned_files[]` → `STATUS: HUMAN_NEEDED — dirty-drain-state` citing the paths, `CronDelete`, exit. (External fault: no counter increment — someone edited drain state out-of-band.)
- Any other dirty TRACKED path: before the fire's first branch checkout/rebase, stash exactly those paths with a labeled stash — `git stash push -m "autopilot/<slug> foreign-dirty <iso8601>" -- <paths>` — and record a one-line `## Drift Notes` entry naming the stash label and paths. At D8, before exiting the fire, `git stash pop` the labeled stash; if the pop conflicts, LEAVE it stashed and extend the Drift Note with the stash ref (`stash@{n}`) — foreign work is preserved or restored, never dropped (invariant 7's delta-preservation discipline applied to operator files).
- Untracked files never block branch operations; leave them alone.


**Runtime budget check.** If `now - drain_started_at > budget.max_runtime_minutes`, write `STATUS: HUMAN_NEEDED — runtime-budget-expired`, `CronDelete`, exit. (`drain_started_at` is seeded by the first fire.)


### D1.3 — Heartbeat-driven crash detection


If `in_progress.last_heartbeat_at > 90 min old` → treat as crashed; apply RESUME or ABANDON dispatch below.


### D1.4 — WIP recovery dispatch


**Rows are evaluated top-to-bottom; the FIRST matching row wins** (several conditions overlap by construction — e.g. a pushed Subtask has `subtask_id` set AND `awaiting_ci: true` AND a local branch ahead of base; external PR state must be checked before generic CI polling so a merged PR is never mistaken for a hung build).


| `in_progress` block in tracker | Action |
|---|---|
| `git symbolic-ref refs/remotes/origin/HEAD` differs from the trunk baked into the runbook | Trunk renamed mid-drain — write `STATUS: HUMAN_NEEDED — trunk-renamed` citing old vs new trunk, `CronDelete`, exit. (External fault: no counter increment.) |
| Local Story branch `autopilot/<slug>/<story-id>` has commits (beyond `prev_pushed_sha`) whose author email is not `git config user.email` | Foreign push detected — write `STATUS: HUMAN_NEEDED — foreign-commits-on-branch` listing the offending SHAs, `CronDelete`, exit. (External fault: no counter increment.) |
| Empty / null | Normal — proceed to D2. |
| `awaiting_ci: true`, `pr_number` set, and PR state (`pr-state --num <pr_number>`) = `MERGED` | PR was merged externally — mark Subtask `[x] Done` with PR URL + merge commit SHA, reset both counters to 0, clear `in_progress`, re-arm at `*/5`, exit fire. |
| `awaiting_ci: true`, `pr_number` set, and PR state = `DECLINED` | PR was declined externally — write `[BLOCKED: pr-declined]` (ci) on Subtask citing the PR URL, increment `consecutive_ci_blocks`, clear `in_progress`, re-arm at `*/30`, exit fire. |
| `awaiting_ci: true`, `pr_number` set, PR state = `OPEN`, and `ci.skip_wait: false` | CI-poll mode — run `bash ${SKILL_DIR}/scripts/ci_check.sh --sha <in_progress.pushed_sha> --pr <pr_number> --once`; act on result (D7.5). **Hard contract: after D7.5 completes, exit the fire regardless of outcome. Do NOT continue to D2 in the same fire.** |
| `awaiting_ci: true`, `pr_number` set, PR state = `OPEN`, and `ci.skip_wait: true` | The PR is awaiting operator merge (no CI polling); re-arm at `*/30`, exit. |
| `subtask_id` set (not awaiting CI), the Subtask's Story branch exists locally with commits ahead of `prev_pushed_sha` | RESUME — rebase the Story branch on base, re-run Step D6 test gate over `prev_pushed_sha..HEAD`; if green → push + open-or-update the Story PR (D7: draft `pr-open` if this is the Story's first Subtask, else the draft Story PR already exists); if red → spawn ONE `general-purpose` quality fix attempt; then push or `[BLOCKED: resume-failed]` (impl). |
| `subtask_id` set, Story branch missing or empty | ABANDON — clear `in_progress`, write `[BLOCKED: orphan-resume]` (impl) on that Subtask, continue to D2 with the next Subtask. |


Refuse the fire if `STATUS != ACTIVE`. On terminal statuses the cron has already been deleted (Hard Contract §9); if a fire runs anyway (manual invocation, stray cron), no-op WITHOUT re-arming. Recovery from `PAUSED` is exclusively via `/autopilot --resume` — do not hand-flip `STATUS` back to `ACTIVE` (Resume refuses a live-locked ACTIVE tracker and reclaims only a stale one — see Resume step 2's stale-ACTIVE reclaim; a hand-flip to ACTIVE strands the drain with no cron and no resume path).


External churn > 100 commits since drain start → write `## Drift Notes` warning to tracker; don't auto-restart.


## Step D2 — Select next Subtask


Topo-walk the DAG. Pick the lowest-ID Subtask where:
- Status is `[ ]` (not `[x]`, not `[BLOCKED]`)
- All `depends_on[]` Subtasks are `[x] Done`
- **Not claim-blocked (ADR 0009 / AV3-09):** if the Subtask has a `blocked_by_pr: <host>/<pr#>` edge (set at G4 by claim consultation), it is eligible ONLY when that PR has resolved. Poll `bash ${SKILL_DIR}/scripts/host.sh pr-state --num <pr#>` (same cadence as D7.5) and gate on `bash ${SKILL_DIR}/scripts/claim_overlap.sh eligibility --pr-state <STATE>`:

  | `claim_overlap.sh eligibility` exit | `<STATE>` | Action |
  |---|---|---|
  | 0 | `MERGED \| DECLINED \| NONE` | The claim resolved — the Subtask is eligible; select it. |
  | 2 | `OPEN \| DRAFT` | The claim is still open — treat as claim-blocked (the WAIT path below). |
  | 64 | a `<STATE>` outside `OPEN\|DRAFT\|MERGED\|DECLINED\|NONE` — either `UNKNOWN` (`host.sh pr-state` read the PR but its state was null / unmappable to the vocabulary) or an empty string (`host.sh pr-state` itself died `exit 1` on an unreadable read, leaving `<STATE>` empty) | **FAIL CLOSED (loop-safety invariant 3).** `claim_overlap.sh` refused to guess eligibility from an unresolvable state, so the orchestrator must NOT proceed — proceeding would fail OPEN on an unresolved claim. Write `STATUS: HUMAN_NEEDED — claim-eligibility-usage-error` citing the offending `<STATE>` (empty when the read died), `CronDelete`, exit. **External fault: no `impl`/`ci` counter increment** — identical handling to D7.5's `exit 64 → ci-check-usage-error` and D1.0's `exit 64 → lock-check-usage-error`. |


**Story affinity (AV3-06).** PR-per-Story caps the drain at **one open (draft) Story PR at a time**. If a Story already has an open draft PR — i.e. some of its Subtasks are `[x] Done` and at least one is still `[ ]`, and it is not blocked — restrict selection to that Story's remaining eligible Subtasks: finish (or block out) the open Story before opening another. Only when the open Story has no eligible Subtask left (all its `[ ]` Subtasks are dependency- or claim-blocked) may D2 start a Subtask in a different Story. This keeps the branch/PR count bounded and the Story PR reviewable as a coherent unit. When two Stories are both fully open (none started), the lowest-ID Subtask's Story wins and becomes the open Story.


If no eligible Subtask:
- All `[x]` → write `STATUS: DRAINED`, render `MERGE-ORDER.md`, `CronDelete`, exit fire successfully.
- **All remaining open Subtasks are claim-blocked (ADR 0009 / AV3-09) → WAIT state, NOT terminal.** A drain re-queues at no one's cost: increment `claim_waits` on the tracker, re-arm the cron at `*/30`, and re-check next fire (the blocking PRs may merge/decline in the interim — the D2 eligibility poll picks that up). Escalate to `STATUS: HUMAN_NEEDED — claim-deadlock` (external fault, no impl/ci counter) ONLY after `claim_waits >= budget.max_claim_waits` (default 16) consecutive claim-blocked fires. NEVER terminal-pause on the first blockage.
- All blocked (non-claim) or pending-deps → write `STATUS: HUMAN_NEEDED`, `CronDelete`, exit.
- `consecutive_impl_blocks >= budget.max_impl_blocks` OR `consecutive_ci_blocks >= budget.max_ci_blocks` (runbook-configured; defaults 3 / 2) → write `STATUS: HUMAN_NEEDED` + `## Escalation` block citing which counter tripped and the contributing Subtasks, `CronDelete`, exit. AP-2.

A successful (non-claim-blocked) Subtask selection resets `claim_waits` to 0.


Otherwise: write the chosen Subtask's full block to `in_progress` in the tracker, with `started_at`, `last_heartbeat_at`, and a placeholder `pr_number: null`.


**Tracker commit routing (AP-23).**


- Under `branching.no_force_push: false`: commit the tracker delta directly to the Runbook PR branch (`autopilot/<slug>/runbook`, AV3-08).
- Under `branching.no_force_push: true`: append the delta as `delta_kind: in_progress_claim` to `## Pending Tracker Deltas (batched)` with a `diff_summary` describing the claim. Do NOT commit directly — the D7.1a fold flushes the queue to the Runbook PR branch.


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


Work happens on the Subtask's **Story branch** `autopilot/<slug>/<story-id>` (PR-per-Story, AV3-06). Whether to create it or continue on it depends on where the Subtask sits in its Story:
- **First Subtask of the Story** (the Story branch does not yet exist) → create it from the appropriate base per the DAG-aware branching rule:
  - the Story has no cross-Story dependency on an in-flight Story → branch from `origin/<trunk>`
  - the Story depends on another Story that is `[x] Done` (already merged to trunk) → branch from `origin/<trunk>`
  - the Story depends on another Story that is in-flight (its Story PR still open) → branch from that Story's branch tip `autopilot/<slug>/<dep-story-id>` → produces a **stacked Story PR** (merge-commit strategy, D7.3a)
- **A later Subtask of the same Story** (the Story branch already exists, carrying the prior Subtasks' commits) → `git checkout autopilot/<slug>/<story-id>` and continue the commit series on it; do NOT branch anew. D6.2 audits only `prev_pushed_sha..HEAD` so the accumulated prior commits are not re-audited.
- Under `branching.single_branch_single_pr: true` → always branch from (or reset onto) the drain's single feature branch.


`git checkout -b autopilot/<slug>/<story-id>` on the Story's first Subtask, `git checkout autopilot/<slug>/<story-id>` for a later one (or `git checkout <single-feature-branch>` under the single-branch mode).


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


Validators are NEVER skipped — not for single-edit Subtasks, not for "trivial" refactors. The touched-files view is exactly what misses a repo-wide regression (a shared test-helper edit that breaks unowned test files reaches trunk on local gates alone); the quality validator's shared-helper blast-radius check exists for precisely the smallest diffs.


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


**Scoped-test blast radius — shared helpers + invalidated seams.** `{paths}` for `gates.test_scoped` is normally the changed-module scope. Two declared expansions apply:

- **Shared mock/test helpers:** when the Subtask touched a module imported by tests beyond the changed dirs — test-tree helpers (fakes, fixture factories, conftest-registered helpers) AND src-shipped test fakes (the `<pkg>/testing.py` pattern) alike; being imported by tests is the trigger, residence in the test tree is not — `{paths}` = ALL test files importing the touched module(s) — repo-wide import scan, not just the touched files. This holds even for a single-edit Subtask; a repo-wide helper regression escapes the touched-file net otherwise.
- **Invalidated seams:** when the Subtask schema declares `invalidated_seams[]` (planner Rule 13), `{paths}` additionally includes every listed seam-test module — the tests whose monkeypatches bind to the import paths this Subtask changed.


### D6.2 — TDD audit via git log (AP-1)


The implementer's report is no longer the source of truth for TDD compliance — git log is.


**Audit range = `prev_pushed_sha..HEAD`, NOT `origin/<base>..HEAD` (AV3-06).** Under PR-per-Story the Story branch accumulates every prior Subtask's commit series, so `origin/<base>..HEAD` would sweep in commits belonging to already-audited Subtasks and false-flag `tdd-scope-leak`. The audit range is bounded to *this* Subtask's commits: `in_progress.prev_pushed_sha..HEAD` (the SHA the Story branch pointed at when the previous Subtask finished pushing; `origin/<trunk>..HEAD` for the Story's very first Subtask, where `prev_pushed_sha` is null). The range arithmetic **and** the shape checks below are extracted to `scripts/audit_commit_shape.sh` so they are deterministically self-tested (AV3-06.1–.6):


```bash
bash ${SKILL_DIR}/scripts/audit_commit_shape.sh \
  --id <subtask-id> --base <prev_pushed_sha-or-origin/<trunk>> \
  --kind <code|test-only|refactor|docs|config> [--jira-key <KEY>]
# -> "OK" exit 0, or "[BLOCKED: <reason>] <detail>" exit 1 (D6.2 catalog below)
```


Expected shape for `kind: code | test-only` (the script enforces exactly this):
- For each behavior `<n>` in `behaviors_to_test[]`, exactly one `test: <id>.<n> RED — ...` commit AND exactly one `feat: <id>.<n> GREEN — ...` commit, in that order.
- Under `enforce_jira_key: true`, every commit subject must include `[<JIRA-KEY>]` in the required position.
- Optional `refactor: <id> — ...` commits at the end.
- No `chore:` / `fix:` / `docs:` mixed in (those signal scope leak).

**Compressed-cycle exception (new-file relocation).** When the implementer's report declares `Compressed cycle: new-file-relocation` (implementer-prompt.md §Compressed-cycle exception — legitimate only when every impl file is `# NEW` and the behaviors are relocated, already-tested behavior), the expected shape is ONE `test: <id>.1 RED` + ONE `feat: <id>.1 GREEN` pair covering all behaviors. The design validator's behavior-coverage check (every behavior in `behaviors_to_test[]` backed by a test) remains fully in force — the exception compresses the COMMIT shape, never the coverage.


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


### D6.3 — Behavior-ID → test binding audit (MS §13.9 / AV3-05)


Manifest-backed drains only (a Subtask with `behavior_ids[]`). Build the `## Behavior coverage` mapping (Behavior ID → the pytest-style test node IDs that cover it) and verify it against the git log — the implementer's self-report is not the source of truth:


```bash
bash ${SKILL_DIR}/scripts/audit_behavior_binding.sh --coverage <coverage-file> --base <prev_pushed_sha-or-origin/<trunk>>
# OK exit 0 · [BLOCKED: unbound-behavior] <B-id> · [BLOCKED: unproven-binding] <B-id> <test>
```


Every mapped Behavior must have ≥1 bound test node (`unbound-behavior` otherwise), and each bound test's function name must be NAMED in a `test: ... RED` commit in the Subtask's range (`unproven-binding` otherwise — a coverage claim with no RED evidence). Failure dispatch matches D5 (typed `[BLOCKED]` (impl)). The verified mapping feeds D7.3's PR-body section and D7.4's tracker mirror (consumed by the PR Gate per MS §13.11).


### D6.4 — Closing-test determinism gate, N=5 (AV3-12)


Run the Subtask's OWN changed tests 5× (never the full suite — bounded to `gates.test_scoped` with `{paths}` = the Subtask's test files); one round is order-randomized via the new optional `gates.test_random`. The 5×-loop is runner-agnostic — it takes the resolved commands and compares exit codes + failure fingerprints:


```bash
bash ${SKILL_DIR}/scripts/determinism_gate.sh \
  --cmd "<resolved gates.test_scoped for {paths}>" \
  [--random-cmd "<resolved gates.test_random>"]   # omit -> that round is skipped with a loud [note]
# DETERMINISTIC (5 rounds) exit 0 · [BLOCKED: flaky-test] <detail> exit 1
```


When the repo has no randomization mechanism (`gates.test_random` unset), the order-randomized round is SKIPPED with a loud `[note]` on stderr — NEVER silently (a silent skip would claim order-independence it never checked; honor the `[det]`/`[drain]` split honestly). Any inconsistency across the 5 rounds → `[BLOCKED: flaky-test]` (impl-block counter); dispatch matches D5. This is the runtime backstop for the AV3-11 anti-flakiness contract.


### D6.5 — Anti-vacuous (mutation) gate (ADR 0016)


D6.4 catches a test that passes for the wrong reason (nondeterminism); D6.5 catches a test that passes for NO reason (vacuity). After D6.1–D6.4, D6.5 runs the repo's mutation tool over THIS Subtask's changed product FILES, then filters the survivors to the changed LINES of `prev_pushed_sha..HEAD` (the D6.2 range). A survived mutant on a changed line is deterministic proof a test executes that line and constrains nothing. OPTIONAL: runs only when `gates.test_mutation` is set and the language has an adapter (`references/mutation-adapters.md` — the MT-01 map, vendored byte-identical from codebase-health, pinned by root lint V7).


```bash
bash ${SKILL_DIR}/scripts/mutation_gate.sh \
  --tool <stryker|cargo-mutants|mutmut|go-mutesting> \
  --run-cmd "<resolved gates.test_mutation for {files}>" \
  --base <prev_pushed_sha-or-origin/<trunk>> --files "<changed product files>" \
  [--max-mutants <budget.max_mutants_per_subtask=40>] [--max-seconds <budget.max_mutation_seconds=120>]
# NON-VACUOUS (…) exit 0 · [BLOCKED: vacuous-test] <file:line…> exit 1 ·
# skip/partial [note] exit 0 · clean-index refuse / usage exit 64
```


**Isolation is a NEW named mechanism, not free reuse (loop-safety invariant 1).** A mutation tool rewrites source on disk, so D6.5 NEVER runs on the live Story checkout. `mutation_gate.sh` runs the resolved command inside an EXPLICIT `git worktree add <throwaway> HEAD`, torn down by an EXIT/INT/TERM trap (`git worktree remove --force`), gated behind a clean-index precheck (refuses a tree with uncommitted TRACKED changes). The live checkout is never mutated — even on injected mid-run failure (the trap fires on error and on TERM alike).


**Dispatch identical to D6.4's flaky-test.** `[BLOCKED: vacuous-test]` → impl-block counter, `consecutive_impl_blocks`, re-arm `*/30`, escalate at `max_impl_blocks=3`. **Self-remediation closure:** the fix MUST be a strengthened assertion re-verified by D6.5 on the SAME changed lines — NOT deleting the product code at the mutation point (that trips D6.2 `tdd-scope-leak`) and NOT editing `gates.test_mutation` to dodge the gate (outside the implementer's `owned_files[]`).


**Budget + degrade, honestly (MT-07/MT-08).** Exceeding `--max-mutants` or `--max-seconds` → `[note] mutation-budget-exhausted — partial (N of M)`, exit 0, NEVER a false `[BLOCKED]` (inconclusive ≠ survivor — the D6.4 skipped-randomization honesty). No tool for the language, `gates.test_mutation` omitted, or an unsupported tool → SKIP with a loud stderr `[note] no mutation tool for <lang> — D6.5 anti-vacuous gate skipped (optional)`, exit 0. A file-granular survivor (a tool with no line resolver, e.g. go-mutesting/mutmut without `mutmut show`) cannot be pinned to a changed line, so it is comment-only, never a block (the line filter is post-hoc for file-granular tools). D6.5 adds no new autonomous mutating path beyond the trap-isolated throwaway worktree.


## Step D7 — Pre-push rebase + commit + PR


**Step D7.0 — Pre-push rebase.** `git fetch origin && git rebase origin/<base>`, where `<base>` is the Story's branching base from D4 (`origin/<trunk>`, or the dependency Story's branch tip for a stacked Story). The unit being rebased is the **Story branch** (AV3-06) — the replay carries every prior Subtask's commit series that already lives on it, not just the current Subtask's. If clean, continue. If conflicts, follow the protocol at `references/conflict-resolution.md` (inlined Pocock-style). Budget: 3 hunks across 2 files max.


**On budget trip — attribute before escalating (ADR 0009 / AV3-10).** When the budget trips, do NOT reflexively `[BLOCKED: rebase-too-large]`. First run the attribution predicate over the rebase's conflicting-hunk files and this Subtask's recorded claim-overlap files (AV3-09):


```bash
bash ${SKILL_DIR}/scripts/claim_loss_attribution.sh \
  --overlap-files <claim-overlap-files-csv> --conflict-files <conflicting-hunk-files-csv> \
  --replans-so-far <n>   # from the Subtask's tracker entry
# REPLAN (exit 0) · NOT-ATTRIBUTED (exit 1) · REPLAN-BUDGET-EXHAUSTED (exit 2)
```


- **REPLAN (exit 0)** — a foreign claim (a PR we were told overlapped) merged first and rewrote these files. Route to **D3 re-plan against the new trunk** instead of the impl-block path; increment the Subtask's re-plan count and record `replanned-after-claim-loss` on the tracker. Bounded: 2 re-plans per Subtask.
- **NOT-ATTRIBUTED (exit 1)** or **REPLAN-BUDGET-EXHAUSTED (exit 2)** — genuine planning conflict (or the 2-re-plan bound is spent): `[BLOCKED: rebase-too-large]` (impl), no retry (needs human).


During conflict resolution, run `gates.test_scoped` against changed paths only — never the full suite (AP-15).


**Step D7.1 — Stage owned_files[].** The per-cycle commits from D4 ARE the PR's commits. Stage only `owned_files[]` if any unstaged changes remain from refactor pass; otherwise skip. Never `git add -A`.


When a final commit IS needed (e.g., for `kind: docs | config | refactor`), follow these rules:


- Stage only `owned_files[]`.
- Conventional Commits: `<type>: <id> — <title>` (e.g., `refactor: B1 — decouple validator from registry`).
- Under `enforce_jira_key: true` (AP-22), prefix with `[<JIRA-KEY>]`: `feat: B1 [PROJ-1235] — F.1a discriminator audit`.
- Body: `acceptance_criteria` checklist + `Rationale:` paragraph (AP-8) explaining the chosen approach in 2-3 sentences + `Refs:` footer with JIRA-KEY (if any) and source_ref.
- Trailer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
- HEREDOC for formatting.


**Step D7.1a — Tracker-delta fold to the Runbook PR (AP-23 / AV3-08).** Runs only under `branching.no_force_push: true`. Read the tracker's `## Pending Tracker Deltas (batched)` section. If it is `_(empty)_`, skip. Otherwise flush the queue to the **Runbook PR branch** (`autopilot/<slug>/runbook`) — the single bookkeeping home, kept OFF the Story branch so the tracker never self-intersects a Story's claim surface (AV3-09):


1. Build a `Tracker deltas folded in:` block for the commit body listing each pending entry's `delta_kind` + `diff_summary` (one line per entry).
2. Apply every entry's `body:` field to the tracker file on the runbook branch (mutations accumulated in-order).
3. Flush the queue: replace the section body with `_(empty)_`.
4. Commit the tracker file on `autopilot/<slug>/runbook` with the folded-in block as the commit body. This is an APPEND (no force-push), so it holds under both `no_force_push` settings; the Story PR carries only code. The impl commit on the Story branch and this bookkeeping commit on the runbook branch are now separate PRs.


Under `branching.no_force_push: false` the delta was already committed directly to the runbook branch at claim time (D2), so this batched fold is skipped.


**Step D7.2 — Push.** `git push -u origin <branch>`. Transient failure → 1 retry. Auth failure → `[BLOCKED: bitbucket-token-missing]` (impl), no retry.


**Step D7.3 — Story PR (draft-open / update / ready-flip).** PR-per-Story: one Story = one branch = one PR, opened as a **draft** and kept draft until the whole Story is Done (AV3-06). The three cases:

1. **This Subtask is the Story's FIRST pushed Subtask** (no Story PR yet) → open the draft Story PR:
   ```bash
   bash ${SKILL_DIR}/scripts/host.sh pr-open --draft \
     --title "<story-title>" --src autopilot/<slug>/<story-id> --dest <base-branch> --body-file <body-file>
   ```
   `host.sh` dispatches to the detected backend (Hard Contract 11 — never call a backend directly). Dest = the rebase base from D7.0. Body file = Summary + Test plan + per-Subtask TDD sequence + Checklist + (manifest-backed drains) the **`## Behavior coverage`** section. On a DC server that predates draft PRs the backend applies the `[DRAFT]`-title-prefix fallback transparently (`AUTOPILOT_BITBUCKET_DRAFT_MODE`, HD03/HD05/HD07).

   **`## Behavior coverage` (MS §13.9 / AV3-05).** The Story PR body carries the D6.3-verified Behavior-ID → test-node-ID mapping in a grep-able, marker-delimited block so the PR Gate (MS §13.11) can parse it:

   ```markdown
   ## Behavior coverage
   <!-- autopilot:behavior-coverage -->
   - B-pricing-001: tests/test_pricing.py::test_rejects_expired_lock
   - B-pricing-002: tests/test_pricing.py::test_a, tests/test_pricing.py::test_b
   ```
2. **A later Subtask of a Story whose draft PR already exists** → the push in D7.2 already updated the PR; append a `host.sh pr-comment` "Subtask `<id>` landed" note. Do NOT open a second PR.
3. **This Subtask completes the Story** (after it goes `[x] Done`, ALL of the Story's Subtasks are `[x] Done` — checked by set membership, never by position) → flip the draft to ready-for-review: `bash ${SKILL_DIR}/scripts/host.sh pr-ready --num <story-pr-number>`. A Story PR that still has any `[ ]` or `[BLOCKED]` Subtask stays draft. (The ready-flip is also reached from the D7.5 green path and the D1.4 external-merge path — wherever the Subtask that closes the Story transitions to Done.)


Under `branching.no_force_push: true` with a non-empty D7.1a fold, the PR body ALSO includes a `## Tracker deltas folded in` H2 listing each entry's `delta_kind` + `diff_summary` for reviewer visibility.


Under `branching.single_branch_single_pr: true`, the coarser collapse still applies: D7.3 opens ONE PR on the first successful Subtask of the whole drain; subsequent Subtasks push to the same branch and update the existing PR via `host.sh pr-comment`.


**Step D7.4 — Tracker update.** Set `in_progress.pr_number = <num>` (the Story PR — the same number for every Subtask of the Story), `in_progress.awaiting_ci = true`, `in_progress.pushed_at = <iso8601>`, `in_progress.pushed_sha = <HEAD sha just pushed>` (consumed by D7.5's `ci_check.sh --sha`), `in_progress.ci_check_count = 0`, `last_heartbeat_at = <now>`. Also record the Story's `last_pushed_sha = pushed_sha` on the Story's tracker entry: the NEXT Subtask of this Story reads it as its `prev_pushed_sha` (the D6.2 audit base — AV3-06). The Story's first Subtask has no predecessor, so its audit base is `origin/<trunk>`. On a manifest-backed drain, **mirror the `## Behavior coverage` mapping to the tracker** (AV3-05) alongside the Subtask entry, so the binding survives across fires and is auditable without the PR.


- Under `branching.no_force_push: false`: commit the status delta directly to the Runbook PR branch (`autopilot/<slug>/runbook`, AV3-08).
- Under `branching.no_force_push: true`: append `delta_kind: status_change` to the queue. The next Subtask's D7.1a fold lands it on the runbook branch. Between now and then, D2 will surface the pending entry on hydrate.


### D7.3a — Stacked PR merge strategy (AP-10)


(Renamed from a second "D7.5" in v2.4.0 — the step id collided with the CI poll below.) AP-10 is re-scoped to **Story PRs** (AV3-06): when the Story PR being created stacks on another in-flight Story's branch (a cross-Story dependency, D4), the PR description MUST request a **merge commit (not squash)**. Bitbucket's PR merge UI defaults to squash; squash on a stacked PR collapses the dependency chain and breaks subsequent rebases. `host.sh pr-merge` defaults to the merge-commit intent and uses `pr-merge-strategies` discovery to fall back to the closest enabled strategy on repos that don't offer it (the Bitbucket DC backend maps to `no-ff`/`squash`/…; the GitHub backend to `--merge`/`--squash`/`--rebase`).


## Step D7.5 — CI poll (cross-fire)


This step runs only on a fire that started with `awaiting_ci: true` (D1 dispatch). Under `ci.skip_wait: true` this step is short-circuited — D1's WIP dispatch already handled the merged/open/declined cases without running `ci_check.sh`.


Run `bash ${SKILL_DIR}/scripts/ci_check.sh --sha <in_progress.pushed_sha> --pr <pr_number> --once`. `--once` takes ONE observation and exits immediately (the drain design is cross-fire; the blocking poll mode is for interactive operator use only). The script emits `LAST_STATE=<actual last observed build state>` on stderr before every exit; cite it in tracker entries.


| `ci_check.sh --once` result | Action |
|---|---|
| exit 0 (VERDICT=GREEN) | Mark Subtask `[x] Done` with the Story PR URL + commit SHA + `[<JIRA-KEY>]` if any. Reset both counters to 0 (AP-2: a Done resets impl AND ci). **If this makes ALL of the Story's Subtasks `[x] Done`, flip the Story PR ready** (`host.sh pr-ready --num <story-pr>`; D7.3 case 3). Clear `in_progress`. Re-arm cron at `*/5`. Exit fire. |
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

Before exiting the fire, `git stash pop` the fire's labeled foreign-dirty stash if D1.2 created one (pop-conflict → leave stashed + extend the Drift Note; see D1.2 §Foreign dirty-tree handling).


### Terminal-fire contract — session death while awaiting CI


A fire that exits with `in_progress.awaiting_ci: true` leaves `STATUS: ACTIVE` by design — the in-session cron continues the D7.5 poll on the next fire. If the SESSION dies between such fires (or mid-fire, between D7.5 and D8), no code path in the dead session can flip the status: the tracker is stranded `ACTIVE` with a session lock that self-expires within 30 minutes. That stranding is expected, not a defect — recovery is owned by Resume step 2's **stale-ACTIVE reclaim** (below), which flips `ACTIVE → PAUSED` with `status_reason: "session_ended_between_ci_polls"` and proceeds through the normal PAUSED path. Operators never hand-edit `STATUS` for this case.


### PAUSED spec deduplication (AP-17)


If the tracker is being written to `STATUS: PAUSED` and the previous fire ALSO wrote `STATUS: PAUSED` with the same `status_reason`, skip the tracker commit entirely (the Runbook PR or the batched queue doesn't need yet another no-op delta).


---


# Resume mode


Triggered by `/autopilot --resume @<runbook>`. Recovers a paused drain without requiring the operator to re-paste a long resume prompt.


Steps in order:


1. **Validate inputs.** Confirm runbook exists at the given path; derive `<slug>` from the filename; confirm `.autopilot/runbooks/<slug>.tracker.md` exists. Refuse if either is missing.
2. **Validate STATUS.** Read `STATUS:` from the tracker frontmatter.
   - `PAUSED` → continue to the drift check below.
   - `ACTIVE` → inspect the session lock AND a dead-session signal before deciding (**stale-ACTIVE reclaim**):
     - `session_lock` held and unexpired → refuse with `Resume refused: drain already ACTIVE. Either a fire is in flight or the previous session is still draining.`
     - `session_lock` null or expired → lock expiry alone is NOT proof of death. The lock is set/refreshed only at fire start (`now + 30 min`, D1.0), while mid-fire liveness is `last_heartbeat_at`; a normal D2→D8 implementation fire routinely outlives its 30-minute lock (`detect_concurrent_drain.sh`'s expiry-only staleness is designed for between-fire gaps, not for judging a fire in flight). Reclaim ONLY when a dead-session signal ALSO holds — either:
       - `last_heartbeat_at` > 90 min old (the D1.3 crash standard), or
       - `in_progress.awaiting_ci: true` — the Subtask is pushed and the drain is between CI polls, so no implementation work is in flight (the classic stranding: session died between D7.5 and D8 — see D8 §Terminal-fire contract).

       Then flip `STATUS: ACTIVE → PAUSED` with `status_reason: "session_ended_between_ci_polls"` when `in_progress.awaiting_ci: true` (otherwise `status_reason: "session_ended_mid_fire"`), append a `## Drift Notes` entry recording the reclaim, and continue to the drift check below as the normal PAUSED path.
     - `session_lock` null or expired but NEITHER dead-session signal holds (heartbeat fresh, not awaiting CI) → a live fire is likely mid-implementation past its 30-minute lock; reclaiming would race its tracker writes and working tree. Refuse with `Resume refused: drain ACTIVE with a recent heartbeat (<last_heartbeat_at>) — a fire may still be live. Retry after the heartbeat is 90+ min stale.`
   - `DRAINED | HUMAN_NEEDED | STOPPED` → refuse with `Resume refused: drain is in terminal state <STATUS>. Use --generate to start a new drain.`
2a. **Refuse manifest-revision drift (MS §6 / AV3-04).** `bash ${SKILL_DIR}/scripts/manifest_revision_gate.sh resume-check .autopilot/runbooks/<slug>.tracker.md` — on exit 2 (`status_reason: manifest-revision-drift`) plain resume is REFUSED: it would re-plan nothing against the new revision. Print the revision-regen pointer and stop. Recovery is `--generate --merge` **revision-regen mode**: it re-plans the open (`[ ]`) Subtasks against the new `manifest_revision`, **preserves `[x] Done` history** (a Hard Contract 8 carve-out — regen is neither overwrite nor plain merge; §6's ID-stability guarantees the surviving Behavior IDs re-plan without rework), supersedes the old Runbook PR (AV3-08), and closes the orphaned draft Story PRs it lists. On exit 0 continue.
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


External faults (`foreign-commits-on-branch`, `trunk-renamed`, `runbook-pr-blocked`, `unexpected-branch-shape`, `dirty-drain-state`, `ci-check-usage-error`, `claim-eligibility-usage-error`) route straight to `HUMAN_NEEDED` and never touch counters.


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


# Runbook-PR availability (AV3-08)


Every fire lands its tracker bookkeeping on the **Runbook PR** (`autopilot/<slug>/runbook`) — the single bookkeeping home under BOTH `no_force_push` settings (the pre-v3 rolling tracker PR is retired). If that PR becomes unmergeable mid-drain, the loop has no place to land bookkeeping and must surface for human triage rather than silently diverging.


At the top of D1 (after D1.0/D1.1, before D2), check the Runbook PR state via `bash ${SKILL_DIR}/scripts/host.sh pr-state --branch autopilot/<slug>/runbook`. The observable states are exactly what the adapter emits — `OPEN | MERGED | DECLINED | NONE` (mergeability is NOT observable through `pr-state` — a conflicted Runbook PR surfaces later as a failed push, not here):


| Runbook PR state | Action |
|---|---|
| `OPEN` | Normal — continue. |
| `NONE` | No PR exists for the runbook branch (e.g. a prior fire pushed the branch but crashed before PR creation, or the PR was deleted). If the remote branch exists, open the Runbook PR (`host.sh pr-open`); if not, branch `autopilot/<slug>/runbook` from `origin/<trunk>`, push the runbook + tracker, and open it with the predicted file-surface block (G7). Add a `## Drift Notes` entry; continue. |
| `DECLINED` | Write `STATUS: HUMAN_NEEDED — runbook-pr-blocked` citing the Runbook PR URL, `CronDelete`, exit. (External fault: no counter increment.) |
| `MERGED` | The operator/Marshal merged the Runbook PR early — re-open the bookkeeping home by branching `autopilot/<slug>/runbook` from `origin/<trunk>` and pushing; continue. |


# End-of-drain output


When `STATUS: DRAINED` is written, the final fire produces `MERGE-ORDER.md` next to the tracker. It is a list of **Story PRs** (one per Story, AV3-06 — never per-Subtask). Required content:


- DAG-topological list of Story PRs with dependency annotations (DAG root / depends on / stacked, with the merge-commit-not-squash flag highlighted for stacked Story PRs)
- The **Runbook PR** (`autopilot/<slug>/runbook`) as the FINAL entry — the operator (or the Marshal, once built) merges it; autopilot NEVER merges its own PRs (Hard Contract 4 spirit). On `HUMAN_NEEDED`/`PAUSED` it is listed with a disposition alongside the dangling draft Story PRs.
- Drain start SHA, current `origin/<trunk>` SHA + commit delta
- Mid-drain rebase count
- Hot-file serialization count
- G3.6 consolidations applied (AP-21)
- G1.5 probe facts + any `unknown` values that persisted through drain (AP-23)
- Total D7.1a tracker-delta fold count (AP-23)
- A one-line rebase recovery hint (`git fetch origin && git rebase origin/<trunk>`)


## Dangling draft Story PRs (every terminal STATUS — AV3-06)


On ANY terminal STATUS (`DRAINED | PAUSED | HUMAN_NEEDED | STOPPED`), the end-of-drain output MUST enumerate every **dangling draft Story PR** — a Story PR still in `DRAFT` state because its Story did not fully drain — with a required operator disposition for each. Autopilot NEVER merges its own PRs (Hard Contract 4 spirit) and NEVER silently abandons a draft, so each dangling draft is listed as:


```
DRAFT Story PR <host>/<pr#>  story=<story-id>  branch=autopilot/<slug>/<story-id>
  done:    <n>/<m> Subtasks
  open:    <subtask-ids still [ ]>
  blocked: <subtask-ids [BLOCKED], with reasons>
  disposition: <one of — resume (fixable block), decline+replan (stale), or hand-merge-partial (operator accepts the partial Story)>
```


A `DRAINED` terminal state normally has zero dangling drafts (every Story flipped ready); a non-empty list under `DRAINED` is itself a defect to surface. Under `PAUSED — manifest-revision-drift` (AV3-04) the draft Story PRs stay draft by contract and are listed here for the revision-regen path to supersede.
