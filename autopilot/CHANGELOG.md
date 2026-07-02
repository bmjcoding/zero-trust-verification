# Changelog

All notable changes to the autopilot skill. Format follows Keep a Changelog; versioning is SemVer. CHANGELOG.md is the single source of truth for version history — the SKILL.md frontmatter does not carry a `version:` field.

## [2.3.0] - 2026-06-29

Closes all three v2.2.0 "Known follow-ups" in one release: the batched tracker-delta queue (AP-23 dispatcher contract), the probe rejection-message regex registry, and the sidecar-contract probe-budget documentation. The v2.2.0 frontmatter `branching.no_force_push: true` flag now has the dispatcher machinery behind it — under v2.2.0 the contract was documented but the dispatcher would still fall through to the same force-push code path; under v2.3.0 the flag is honoured.

Versioning rationale (chose v2.3.0 minor over v2.2.1 patch):

- The batched-delta queue is a NEW dispatcher concept with new tracker state (`## Pending Tracker Deltas (batched)` section), new D-step extensions (D1.0.4 migration + recovery, D2 / D7.1a / D7.4 queue interactions), new commit-shape rules (`Tracker deltas folded in:` body block), and new PR-body section (`## Tracker deltas folded in`). Calling that a patch would obscure a dispatcher behavior change. The v2.2.0 contract was incomplete — v2.3.0 is the implementation, not a fix.
- Items B (regex registry) and C (sidecar docs) are small in isolation but are bundled into the same minor bump to keep the audit trail clean per the operator's "less noise" bias.

### Added

- **AP-23 batched tracker-delta queue** (`SKILL.md` §"Tracker delta batching (AP-23)", `references/tracker-delta-batching.md`, `references/runbook-template.md` tracker body sections). When `branching.no_force_push: true`, tracker bookkeeping commits cannot land on a rolling tracker branch (no force-push, divergence is fatal). The queue holds tracker deltas inside the tracker file at `## Pending Tracker Deltas (batched)`; the next successful Subtask's PR (D7.1a) flushes the queue into one atomic commit alongside the impl edit. Queue entries carry `subtask_id`, `delta_kind` (one of `subtask_done | in_progress_claim | drift_notes | status_change | session_lock | crash_recovery | other`), `diff_summary`, and verbatim `body:`. Durable across BLOCKED fires until the next-Subtask-PR-merge.
- **D1.0.4 — Pending-deltas migration + crash recovery** (`references/drain-lifecycle.md`). New first step in DRAIN dispatch when `branching.no_force_push: true`. Injects the queue section header on first fire against a v2.1.0 / v2.2.0 tracker; on crash-recovery (non-empty queue at fire start), appends a `delta_kind: crash_recovery` audit entry without removing prior entries. Idempotent.
- **D7.1a tracker-delta fold step** (`references/drain-lifecycle.md`). Extends D7.1's "stage owned_files[]" step under `branching.no_force_push: true`: reads the queue, builds a `Tracker deltas folded in:` block in the commit body listing each pending entry's `delta_kind` + `diff_summary`, flushes the queue to `_(empty)_`, stages the tracker file alongside `owned_files[]`. Single atomic commit lands the impl edit + cumulative tracker mutations + queue flush. D7.3 surfaces the same folded entries as a `## Tracker deltas folded in` H2 in the PR description.
- **`scripts/repo_shape_probe_patterns.sh`** (NEW). Regex registry for rejection-message parsing. Each row is `<pattern>|<signal_name>` (e.g., `FORCE_PUSH_REJECTED`, `JIRA_HOOK_REJECTED`) with a comment citing the DC version where each pattern was observed. The probe sources this file at startup; matching is delegated to a `match_rejection` helper that emits the raw rejection to stderr with `probe: unknown rejection pattern; please add to repo_shape_probe_patterns.sh: <raw message>` whenever no entry matches. This is the corpus-growth seam — every operator-visible `unknown` rejection is a candidate new pattern.
- **`repo_shape_probe.sh --explain` flag.** Prints the current registry contents on stdout and exits 0. No network, no git state. Useful for operators reviewing which rejection patterns are recognized before running a real probe.
- **Sidecar-contract `## Probe budget under sidecar mode` section** (`references/sidecar-contract.md`). Enumerates which probe operations require sidecar mediation (none today; all four AP-23 probes use local git transport + file inspection) and which hypothetical future probes would (REST-based `audit-log` or `pre-receive-hook-list`). Documents the hybrid-sidecar failure mode where local git transport is blocked: the probe falls through to `unknown` for network-bound checks and the runbook's `## Repo constraints (detected)` block surfaces the `unknown` state; the `unknown` values explicitly do NOT auto-flip frontmatter flags, so the operator decides each.

### Changed

- **`scripts/repo_shape_probe.sh` delegates rejection matching to the registry.** The inline `grep -qiE 'force|deny|reject|protected|pre-receive'` (force-push) and `grep -qiE 'jira|JIRA ID|missing.*key|pre-receive'` (JIRA) calls are replaced by `match_rejection <logfile> <outvar>`, which loops the registry and writes the matching signal name (or empty string) to the caller-supplied output variable. Unknown rejections surface raw text on stderr automatically.
- **D2 and D7.4 honour `branching.no_force_push: true`.** Under the flag, neither step commits the tracker delta directly — both append entries to `## Pending Tracker Deltas (batched)` instead. The committed-tracker behavior under `branching.no_force_push: false` (default) is unchanged.

### Known follow-ups (not in this release)

- _(none — all v2.2.0 follow-ups closed in this release.)_

### Fixed (on-demand patch, 2026-06-29)

- **Delegation rule reframed from permission-shape to positive default + first-action gate** (`SKILL.md` new "Loading preamble (read first, every invocation)" section; Hard contracts §10 rewrite). Failure mode observed: orchestrator read Rule 10 ("Orchestrator NEVER directly Reads source files...") and still defaulted to direct edits because (a) the rule was the 10th of 15 bullets, (b) wording was prohibition-shaped without a positive default, (c) no first-action precondition enforced naming the subagent before any tool call, and (d) `--yolo` plus a "one branch, one PR" branching override were misread as licensing skip of the dispatch contract. Fix adds: (1) Loading preamble at the top of the skill body framing delegation as the positive default and stating the first-action gate ("before any tool call, name the subagent you are about to dispatch"); (2) explicit override-scoping section establishing that `--yolo` and branching-model overrides are orthogonal to the delegation contract; (3) context-poisoning note that having SPEC.md / ADR text in context is more reason to delegate, not less; (4) Rule 10 itself rewritten with the explicit "survives every override" clause and cross-reference to the preamble; (5) D1 in-fire preamble cross-references the first-action gate so it survives auto-compaction that drops the top of the file.

### Fixed (full-cycle structural cleanup, 2026-06-29)

- **SKILL.md body split to satisfy 500-line cap (S07) and removed unsupported `version:` frontmatter field (S09)** — resolves the two P2 items deferred in the prior on-demand patch. Body went from 766 → 189 lines by extracting reference / lookup material into three new files; orchestrator-must-read content (loading preamble, override scoping, context-poisoning trap, all 15 hard contracts including the rewritten Rule 10, modes table) is unchanged and remains in SKILL.md.
  - **`references/generate-lifecycle.md`** (NEW). Holds the full G1..G8 step text: pre-flight, G1.5 repo-shape probe (AP-23), G2 extraction, G3 planning, G3.5 plan-review (AP-3), G3.6 consolidation (AP-21), G4 topo-sort + hot-file detection, G5 already-shipped, G6 Jira, G7 write, G8 review/arm. SKILL.md keeps a one-paragraph overview + a step index table pointing into the reference.
  - **`references/drain-lifecycle.md`** (NEW). Holds the full D1..D8 lifecycle including the D1 WIP-recovery dispatch table, D3 audited-SHA verification (AP-5), D4 TDD per-cycle commits (AP-1), D5 validator contradictory-finding escalation (AP-18), D6 commit-shape audit (AP-1), D7 pre-push rebase + commit + PR + D7.1a tracker-delta fold (AP-23), D7.5 CI-poll dispatch table (including `ci.skip_wait` short-circuit), D8 adaptive cron re-arm. Also holds the Resume mode contract, failure-escalation rules (AP-2), STATUS state machine, tracker-PR availability dispatch table, and end-of-drain output contract. The file opens with an explicit reminder that the SKILL.md loading-preamble delegation contract (Rule 10 + override scoping + context-poisoning trap + first-action gate) applies to every step inside.
  - **`references/tracker-delta-batching.md`** (NEW). Holds the AP-23 batched-tracker-delta queue contract: queue location, valid `delta_kind:` values, flush points, durability across BLOCKED fires, recovery semantics, schema migration. Also holds the `branching.no_force_push: true` short-circuit that disables the rolling tracker PR pattern. Lifecycle integration points (D1.0.4 / D1.0 / D2 / D7.1a / D7.4) stay in `drain-lifecycle.md`; this file is the data-and-rationale document. Opens with the same delegation-contract reminder.
- **Dropped `version:` frontmatter field** (`SKILL.md` frontmatter). The canonical Anthropic skill schema (per `definition-review/scripts/lint-definition.py` SUPPORTED_SKILL_FIELDS set) does not define `version`; CHANGELOG.md is now the single source of truth for version history. Linter S09 warning resolved. A note in the SKILL.md intro states "CHANGELOG.md is the single source of truth for version history" so the field's absence is documented rather than implicit.
- **Reference index expanded** (`SKILL.md`). The reference table now lists the three new files alongside the existing references; the index also adds `scripts/repo_shape_probe.sh` and `scripts/repo_shape_probe_patterns.sh` which were already on disk but not surfaced in the index.
- **Behavioral preservation verified.** All five rules from the prior on-demand patch are intact post-split: (1) loading preamble at top of SKILL.md, (2) override scoping section (`--yolo` / branching orthogonality clause), (3) context-poisoning trap section, (4) Rule 10 rewrite with "survives every override" clause and cross-reference to the preamble, (5) first-action gate restated at the start of `references/drain-lifecycle.md` §D1 so it survives auto-compaction. Linter PASS (0 errors, 0 warnings).

## [2.2.0] - 2026-06-29

Adds the AP-23 repo-shape probe at GENERATE time, closing the gap that forced the `audit-pre-gates` drain to ship an operator-authored "Repo constraints (READ FIRST)" block by hand. Also rolls in the three surgical fixes from the [2.1.1] follow-up pass (see Changed / Added below) so there is one current release tag rather than two minor-version bumps in the same hour.

### Added

- **AP-23: G1.5 repo-shape probe** (`scripts/repo_shape_probe.sh`, `SKILL.md`, `references/runbook-template.md`). New GENERATE step run after dirty-tree / not-on-trunk / concurrent-drain refusals. Probes the remote for: trunk branch, CI manifest presence (`bitbucket-pipelines.yml` / `.github/workflows/*.y(a)ml` / `Jenkinsfile` / `.gitlab-ci.yml`), force-push acceptance (via temp-branch `+` refspec push), and JIRA-key pre-receive hook enforcement (via temp-branch push with a hook-violating commit subject). Emits `KEY=VALUE` lines on stdout, warnings on stderr, exit 0 even when individual probes return `unknown`. Cleanup is via `trap` on EXIT/INT/TERM — orphan probe branches from killed runs can be cleaned up manually using the temp-branch naming convention documented in the script header (`autopilot/probe-force-push-<PID>`, `autopilot/probe-jira-hook-<PID>`).
  - Probe facts seed runbook frontmatter automatically: `CI_PRESENT=false` → `ci.skip_wait: true`; `FORCE_PUSH_ALLOWED=false` → `branching.no_force_push: true`; `JIRA_HOOK_ENFORCED=true` → `enforce_jira_key: true`. `unknown` values do NOT auto-flip — they surface as warnings in the G8 review summary and the operator decides.
  - Probe facts ALSO populate a `### Repo constraints (detected)` block at the top of the seeded runbook body so the operator can read them without re-running the probe. This is the auto-populated complement to the operator-authored `### Repo constraints (READ FIRST)` block that the audit-pre-gates drain produced manually.
  - JIRA-hook probe design choice: temp-branch push (same approach as the force-push probe) rather than a heuristic on `git config` / remote URL. Pre-receive hooks are server-side state; the only ground truth is "what does the server reject". A local heuristic would miss the actual signal.
  - `--dry-run` flag prints every probe operation and the temp branch names that WOULD be created, with no network calls. Useful for operators reviewing what the probe will touch.
- **`ci.skip_wait` frontmatter flag** (`SKILL.md` D7.5.0, `references/runbook-template.md`). When true, D7.5 skips the entire CI poll branch and treats every operator-approved PR as GREEN. The dispatcher does NOT call `ci_check.sh` under this flag; calling it would consume polling fires that never resolve. Default `false`; auto-set by G1.5 when `CI_PRESENT=false`.
- **`branching.no_force_push` frontmatter flag** (`SKILL.md` tracker-PR availability, `references/runbook-template.md`). When true, the rolling tracker PR pattern is disabled — tracker bookkeeping rides on each in-flight Subtask PR's branch instead, as a final `chore(tracker): <id> — …` commit. Default `false`; auto-set by G1.5 when `FORCE_PUSH_ALLOWED=false`.
- **`branching.single_branch_single_pr` frontmatter flag** (`references/runbook-template.md`). Operator-toggle only (NOT auto-set by the probe). When true, the entire drain collapses into ONE feature branch and ONE PR; Subtasks merge into the same branch as incremental commits. Use when the work is tightly coupled and the operator-mandated review unit is the drain, not the Subtask (the audit-pre-gates pattern). Default `false`; G1.5 emits a `## Drift Notes` reminder when the operator has manually flipped this flag so subsequent dispatchers know to honour the single-PR model.

### Changed (was [2.1.1] surgical follow-up; folded into 2.2.0)

- **`scripts/bitbucket.sh pr-merge`: 409 retry-with-fresh-GET.** New `bb_curl_status` helper captures HTTP status codes separately from response bodies. On `409 Conflict` from the merge POST (PR version changed between our GET and POST — typical causes: comment added, approval recorded, external rebase landed), the script re-GETs the PR, refreshes `version`, and retries the POST exactly once. A second 409 is surfaced as `pr-merge: 409 Conflict after refresh-and-retry; PR is contested`. No further retry — looping would mask the underlying problem. Other status codes are unaffected (non-2xx still hard-fail with the response body excerpt).
- **`scripts/ci_check.sh`: emit `LAST_STATE=<value>` on stderr before exit 2/3.** The D7.5 dispatch table row for exit 2 cites "the script's last seen build state"; the script captured `LAST_STATE` at line 70 but never emitted it. Now `LAST_STATE=<value>` (or `LAST_STATE=UNKNOWN` if never set) is written to stderr immediately before `exit 2` (STUCK timeout) and `exit 3` (UNDETERMINED grace-window expiry). Stdout stays machine-parseable (`VERDICT=…`); LAST_STATE is on stderr only.
- **`scripts/secret_set.sh`: write/read divergence guard rails.** Adds `--as-host` (writes to the host-derived joined name, e.g. `bitbucket-token:cluster03`, instead of the default `autopilot-<service>` namespace — for operators who want one shared entry across their tooling) and `--force` (bypasses the operator-credential abort and writes the autopilot-namespaced copy anyway). In default mode, the script now probes every OTHER resolver-chain candidate from `secret_get.sh` (override env var, host-named, bare `<service>-token`, bare `<service>`) and aborts with `operator-owned credential detected at <name>` when any of them has a non-empty entry — preventing the silent two-copy state where an operator had `bitbucket-token:cluster03` and then ran `secret_set.sh bitbucket` and ended up with both. Both flags can be combined; rejected alternative (a single flag without the abort) would have left the silent-duplicate failure mode in place.

### Known follow-ups (not in this release)

- **Dispatcher implementation of batched tracker-delta queue under `branching.no_force_push: true`.** Delivered in [2.3.0] (AP-23 dispatcher contract).
- **Probe rejection-message regex registry.** Delivered in [2.3.0] (`scripts/repo_shape_probe_patterns.sh`).
- **Probe budget under sidecar mode.** Delivered in [2.3.0] (`references/sidecar-contract.md` §"Probe budget under sidecar mode").

## [2.1.0] - 2026-06-29

Surgical fixes from the `audit-pre-gates` drain on `HLASTRO/astro-agents` (5 fires, 3 PRs landed). Each item below traces to a documented `## Drift Notes` finding in the consumer-repo tracker. No breaking changes; all v2.0.x runbooks continue to work.

### Added

- **AP-20: D1.0.5 drift-notes hydration** (`references/drain-lifecycle.md`). New first step in every DRAIN fire: read every `## Drift Notes` entry in the tracker before any git or Bitbucket action and treat the documented findings as hard preconditions, not commentary. Stops fires re-deriving the same workarounds from scratch.
- **AP-21: G3.6 Subtask consolidation pass** (`references/generate-lifecycle.md`, `references/runbook-template.md`). After plan-review, eligible groups of small same-kind config / docs Subtasks within a Story can be merged into one before draining. Off by default; operators opt in with `pack_subtasks: true` in runbook frontmatter or `--consolidate=auto` on the GENERATE invocation.
- **AP-22: JIRA-key per-commit enforcement** (`references/drain-lifecycle.md`, `references/runbook-template.md`). New `enforce_jira_key:` frontmatter flag. When true (or under `--jira` mode), every TDD-cycle commit, every PR-tip commit, and every tracker-bookkeeping commit prefixes the JIRA key in brackets. Required for pre-receive hooks that reject pushes containing any commit without a key.
- **`bitbucket.sh pr-approve` and `pr-decline` subcommands.** State-changing endpoints with the XSRF-safe `X-Atlassian-Token: no-check` header applied centrally in `bb_curl`. Previously the skill had no way to drive approval / decline through the script.
- **`bitbucket.sh pr-merge-strategies` subcommand.** Queries the PR merge endpoint to discover which strategy IDs the repo has enabled (`merge-commit`, `no-ff`, `squash`, etc.) so `pr-merge` can fall back from `merge-commit` to `no-ff` on repos where only one is enabled.
- **D7.5 dispatch table rows for `ci_check.sh` exits 2 (STUCK timeout) and 4 (PR_DECLINED) and 64 (usage error).** Previously only exits 0, 1, and 3 were enumerated; exit 2 was silently masked as "no-op fire that bumps the counter".

### Changed

- **`scripts/bitbucket.sh` response sanitisation.** Every response body now passes through `python3 ... decode('utf-8', errors='replace')` before reaching `jq`. Em-dashes and other non-UTF-8 bytes in PR titles / descriptions no longer make `pr-open` silently misreport "no PR number in response" when the PR was actually created. Stable across DC versions; stdlib-only.
- **`scripts/bitbucket.sh` XSRF header.** Every state-changing POST now includes `X-Atlassian-Token: no-check`. Bitbucket DC's XSRF guard rejects approve / merge POSTs from non-browser clients without it on some cluster configurations.
- **`scripts/bitbucket.sh` `pr-merge` strategy discovery.** Translates the caller's intent (`merge-commit` | `squash`) into an ordered candidate list and probes which strategies the repo has enabled via `pr-merge-strategies` before posting. Falls back to the first candidate on parse miss (older DC). Avoids the "Enabled strategies … are: no-ff" 400 hit on repos that only enable `no-ff`.
- **`scripts/secret_get.sh` keychain service-name resolver.** Now probes a priority list of candidate service names — `$AUTOPILOT_<SERVICE>_KEYCHAIN_NAME` override, `autopilot-<service>` canonical, host-derived joined-name (`<service>-token:cluster03` sniffed from `$BITBUCKET_HOST` or the origin remote URL), `<service>-token`, bare `<service>` — instead of the single canonical name. Stops the convention `bitbucket-token:cluster03` keychain entry from being invisible to the script.

### Known follow-ups (not in this release)

- **Repo-shape probe at GENERATE time.** Delivered in [2.2.0] (AP-23).

## [2.0.0] - 2026-06-27

This is a breaking release. Read the migration section before upgrading.

### Added

- **Sidecar contract v0** (`references/sidecar-contract.md`). Autopilot detects an identity-proxy sidecar and routes Bitbucket DC traffic through it with NO Authorization header when available. Sidecar mode is required in workspace-container deployments; local-laptop deployments fall back to the resolver chain.
- **Credential resolver chain** (sidecar → OS keychain → env). Scripts: `scripts/secret_get.sh`, `scripts/secret_set.sh`, `scripts/sidecar_detect.sh`. Tokens never enter argv, trace logs, or Claude Code tool arguments.
- **Bitbucket DC adapter** (`scripts/bitbucket.sh`) replacing all gh CLI calls. Subcommands: `pr-open`, `pr-state`, `pr-comment`, `pr-merge`, `build-status`.
- **Per-cycle TDD commits** (AP-1). D4 implementer emits a `test:` commit (RED) and a `feat:` commit (GREEN) per TDD cycle. D6 verifies the cycle by walking git log, replacing the old heuristic LLM check.
- **Split block counters** (AP-2). `consecutive_impl_blocks` and `consecutive_ci_blocks` track impl vs CI failure modes independently. External faults (foreign commits, trunk rename, tracker-pr-blocked) bypass counters and escape directly to HUMAN_NEEDED.
- **Plan reviewer projection** (AP-3). Plan reviewer at D3.2 sees only `id`, `kind`, `owned_files`, `depends_on`, `test_gates`, `validators`, `public_api` signature, `behaviors_to_test`, `estimated_size`. Internal contract prose and `test_name_hint` are stripped.
- **Tracker lockfile keyed on CLAUDE_SESSION_ID** (AP-4) with 30-min expiry and heartbeat refresh.
- **audited_sha pre-check** (AP-5). Planner emits the SHA the audit was run against. D3.0 verifies every `owned_files` path exists at that SHA and HEAD has not drifted into any owned path. Stale plans return `[BLOCKED: plan-stale-*]` (impl).
- **Heartbeat enforcement at every step boundary** (AP-6). `last_heartbeat_at` is written at D1.2, D3, D4, D5, D6, D7.x.
- **Branch shape check at D1.1** (AP-7). Current branch must match `autopilot/<slug>/(setup|tracker|<subtask-id>)`.
- **Rationale paragraph in D7.1 commit body** (AP-8).
- **test_name_hint in planner schema** (AP-9).
- **Stacked PR merge-commit strategy** (AP-10). `bitbucket.sh pr-merge` defaults to `merge-commit` to preserve TDD cycle history. Squash is opt-in per PR.
- **Force-audit trail** (AP-11). `--force` operator overrides are logged to `force_audit:` in tracker frontmatter.
- **PAUSED dedup** (AP-17). Same block re-hit does not emit a duplicate tracker commit.
- **Contradictory validator handling** (AP-18). Findings with opposing directives on the same path emit `[BLOCKED: validator-contradiction]` (impl) and route to HUMAN_NEEDED.
- **Scoped pytest during rebase** (AP-15). Conflict resolution runs only the subtask's test_gates plus tests under touched paths, never the full suite.
- **800-token cap on implementer report** (AP-16).

### Changed

- **D6 (TDD verification)** is now a deterministic git log walk over per-cycle commits (AP-1) instead of an LLM heuristic.
- **CI platform** is exclusively `bitbucket-dc` in v2.0.0. GitHub support has been removed.

### Removed

- **`install_external_scheduler.sh` and `uninstall_external_scheduler.sh`** (AP-19). Cadence is now strictly in-session.
- **`--external-scheduler` flag and all related dispatcher branches**.
- **gh CLI dependency** (AP-13). All Bitbucket interaction routes through `scripts/bitbucket.sh` (git + Bitbucket REST).

### Migration from v1

Required operator actions before first v2 dispatch:

1. **Remove v1 cron entries.** v1 may have installed crontab/launchd entries via `install_external_scheduler.sh`. v2 does not ship `uninstall_external_scheduler.sh`. Remove entries manually.
2. **Store Bitbucket DC token** via `scripts/secret_set.sh bitbucket` (token read from STDIN, never argv), or rely on sidecar mode.
3. **Update each runbook's frontmatter**: add `audited_sha:`, replace `consecutive_failures_cap:` with `max_impl_blocks:` and `max_ci_blocks:`, remove `external_scheduler:`, `cron_*`, `gh_cli_path:`, `secrets_inline:`.
4. **Uninstall gh CLI** if it was installed solely for autopilot v1.
