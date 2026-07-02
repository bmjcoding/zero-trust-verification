# autopilot

Autonomous TDD-driven implementation loop for Claude Code. Plans, implements, validates, and ships stacked PRs against Bitbucket Data Center with per-cycle commits, multi-validator review, and human-in-the-loop escape hatches.

## Status

v2.3.0 (2026-07-02). Adds repo-shape probe (AP-23), batched tracker deltas, JIRA-key enforcement (AP-22), Subtask consolidation (AP-21), drift-notes hydration (AP-20), and hardening across auth, XSRF, and CI classification. See CHANGELOG.md for the full history.

## What it does

Given a runbook (a YAML+Markdown file describing a unit of work, its goal, its constraints, and the audit handoff that motivates it), autopilot:

1. Plans the work into a DAG of subtasks with disjoint file ownership and explicit test gates.
2. Reviews the plan structure (not its content) for ownership disjointness, dependency acyclicity, and test coverage.
3. Implements each subtask via TDD cycles: `test:` commit (RED), then `feat:` commit (GREEN), per cycle.
4. Runs all configured validators in parallel on each subtask's diff. Spawns fix subtasks for findings; escapes contradictions to a human.
5. Opens a stacked PR per subtask against Bitbucket DC, polls CI, merges with `merge-commit` strategy to preserve cycle history.
6. Logs every step to an append-only tracker with session lock and heartbeat.

## When to use

- The work is well-scoped enough to write a runbook for (goal, constraints, non-goals, ideally an audit handoff).
- The repo lives in Bitbucket Data Center.
- You want machine-verifiable TDD evidence in git history, not just "the tests pass at the end".
- You want a single skill that handles plan → implement → validate → ship without re-prompting for each step.

## When NOT to use

- One-off scripts or single-file edits.
- Exploratory refactoring where the plan emerges as you work.
- Work that cannot tolerate stacked PRs (e.g., teams that strictly squash-merge and forbid merge commits; autopilot's TDD history is destroyed by squash).
- Repos hosted on GitHub. v2.0.0 ships Bitbucket DC only.

## Installation

1. Copy the `autopilot/` directory into your Claude Code skills root (e.g. `~/.claude/skills/autopilot/`), or symlink it from your skills source tree.
2. Ensure dependencies are on PATH: `git >= 2.30`, `jq >= 1.6`, `bash >= 4.0`, `curl`.
3. **macOS / Linux local mode**: store your Bitbucket DC personal access token in the OS keychain:
   ```
   echo -n "<token>" | scripts/secret_set.sh bitbucket
   ```
   The token is read from STDIN. It never enters argv, shell history, or trace output.
4. **Workspace container / sidecar mode**: nothing to do. The identity-proxy sidecar handles Bitbucket credentials via session-scoped OBO. Verify with:
   ```
   scripts/sidecar_detect.sh
   # should print: MODE=sidecar PLATFORMS="...bitbucket..." URL="..."
   ```

## Writing a runbook

See `references/runbook-template.md` for the full schema. A minimal example:

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
validators: [correctness, security, style]
cadence: { mode: in-session, step_pause_seconds: 0 }
test_runner: { cmd: pytest, scoped_flag: "" }
ci: { platform: bitbucket-dc }
merge: { strategy: merge-commit, delete_source_on_merge: true }
force_audit: []
---

## Goal
Extract the in-memory token bucket from api/limiter.py into lib/rate_limit/.

## Constraints
- Public callers of api.limiter.acquire() must not change signature or semantics.
- No new direct Redis access; the bucket stays in-memory.

## Non-Goals
- Replacing the bucket with a distributed limiter (separate runbook).
```

Place at `.autopilot/runbooks/extract-token-bucket.md`, then dispatch in a Claude Code session.

## Key design choices

Each of the items below maps to a finding in the adversarial review series (AP-1 .. AP-23). Full rationale in `references/role-prompts-rationale.md`.

- **Per-cycle TDD commits** (AP-1) — D6 verifies TDD by walking git log, not by inspecting diffs.
- **Split block counters** (AP-2) — impl, CI, and external faults route differently.
- **Plan reviewer projection** (AP-3) — reviewer sees structure, not contracts.
- **audited_sha gate** (AP-5) — plans are pinned to the SHA they were planned against.
- **Sidecar-first credential routing** — tokens never enter Claude's tool surface.
- **Bitbucket DC native** (AP-13) — gh CLI removed.
- **External scheduler removed** (AP-19) — autopilot is in-session only.
- **Drift-notes hydration** (AP-20) — D1.0.5 rehydrates prior drift observations into the current drain's Plan Reviewer projection.
- **Subtask consolidation** (AP-21) — G3.6 packs sub-threshold subtasks under `pack_subtasks: true` or `--consolidate=auto`.
- **JIRA-key enforcement** (AP-22) — `enforce_jira_key: true` requires every commit message to carry a JIRA key; auto-flipped by G1.5 when the server hook enforces it.
- **Repo-shape probe + batched tracker deltas** (AP-23) — G1.5 detects trunk, CI, force-push, and JIRA hook; tracker deltas queue in-tracker and flush at D7.1a under `branching.no_force_push: true`.
- **Loading preamble as a hard contract** — SKILL.md carries a delegation-positive-default preamble that survives every override and every auto-compaction boundary; see SKILL.md §1.

## Reference index

- `SKILL.md` — the dispatcher. Step graph D0..D7.5, role activations, exit conditions.
- `references/runbook-template.md` — runbook frontmatter and body schema.
- `references/role-prompts-rationale.md` — why the role split, why projections, why per-cycle commits.
- `references/planner-prompt.md` — planner role contract.
- `references/plan-reviewer-projection.md` — what the reviewer sees and why.
- `references/implementer-prompt.md` — implementer role contract; TDD cycle shape.
- `references/validator-prompts.md` — validator catalog (correctness, security, performance, style); contradiction handling.
- `references/conflict-resolution.md` — D7.0 rebase resolver; scoped pytest rules.
- `references/extraction-prompt.md` — code-extraction helper.
- `references/cadence-dispatch.md` — in-session cadence rules.
- `references/sidecar-contract.md` — sidecar v0 env vars, URL shape, error codes, resolver chain, and (v2.3.0) probe budget under sidecar mode.
- `references/generate-lifecycle.md` — G1..G8 including G1.5 repo-shape probe and G3.6 Subtask consolidation (v2.3.0).
- `references/drain-lifecycle.md` — D1..D8 including D1.0.4 batched-delta migration/recovery, D1.0.5 drift-notes hydration, D7.1a tracker-delta fold, and the D7.5 CI-poll dispatch table (v2.3.0).
- `references/tracker-delta-batching.md` — AP-23 in-tracker queue contract, `delta_kind:` catalog, flush semantics, recovery cases.

## Scripts

All scripts live in `scripts/` and are invoked by the dispatcher. They have no Claude-context side effects (no stdout other than declared outputs, no token echoing).

- `bitbucket.sh` — Bitbucket DC adapter. Subcommands (v2.3.0): pr-open, pr-state, pr-comment, pr-approve, pr-decline, pr-merge, pr-merge-strategies, build-status. UTF-8 sanitisation on all payloads; XSRF header on all mutating requests; 409 retry-with-fresh-version on pr-merge; LAST_STATE=<value> emitted on stderr before every non-zero exit.
- `ci_check.sh` — Poll CI verdict for a SHA/PR pair. Output: VERDICT=GREEN|RED|STUCK|UNDETERMINED|PR_DECLINED. v2.3.0 emits LAST_STATE=<value> on stderr before every non-zero exit for D7.5 dispatch.
- `detect_concurrent_drain.sh` — Tracker lock check. Detects another active session.
- `hot_file_audit.sh` — Find files touched by multiple subtasks.
- `secret_get.sh` — Resolve credential through sidecar→keychain→env chain. Output on stdout, nothing else. v2.3.0 probes a prioritised list of candidate service names (operator override → canonical → host-derived → `<service>-token` → bare `<service>`).
- `secret_set.sh` — One-time token install into OS keychain. Reads token from STDIN. v2.3.0 adds `--as-host` (host-scoped keychain names) and `--force` (bypass operator-owned credential detection).
- `sidecar_detect.sh` — Probe identity-proxy sidecar. Emits MODE=sidecar|local.
- `repo_shape_probe.sh` — (v2.3.0, AP-23) G1.5 probe. Detects TRUNK / CI_PRESENT / FORCE_PUSH_ALLOWED / JIRA_HOOK_ENFORCED via minimal git and Bitbucket API operations. Supports `--dry-run` and `--explain`. Cleans up temp branches via a trap.
- `repo_shape_probe_patterns.sh` — (v2.3.0, AP-23) Regex registry sourced by the probe. Provides `match_rejection <logfile> <outvar>` and a maintained catalogue of Bitbucket DC rejection strings for force-push and JIRA-hook signals.

## Migrating from v1

See `CHANGELOG.md` for the full migration checklist. The short version:

1. Manually remove any v1-installed crontab/launchd entries.
2. Store your Bitbucket token via `scripts/secret_set.sh bitbucket`.
3. Add `audited_sha:` to runbooks; remove `external_scheduler:`, `gh_cli_path:`, `consecutive_failures_cap:`.
4. Add `merge: { strategy: merge-commit }` and `ci: { platform: bitbucket-dc }`.
5. Archive v1 tracker files; v2 cannot read them.

## Migrating from v2.0 / v2.1 / v2.2

The first drain against a pre-v2.3 tracker triggers D1.0.4 migration:

- The `## Pending Tracker Deltas (batched)` section header is injected into the tracker body (idempotent no-op if already present).
- The `Repo constraints (detected)` block is written by G1.5 on the first drain (or on any drain with `--reprobe`).
- Legacy fields `tracker_pr.force_push` and `wait_for_ci` are ignored with a warning; replace with `branching.no_force_push` and `ci.skip_wait` respectively.
- The rolling tracker-PR pattern is unchanged for repos where `branching.no_force_push: false`; only the flag flip (auto by G1.5 or manual by the operator) switches to the batched-delta model.

## License

MIT. See LICENSE.
