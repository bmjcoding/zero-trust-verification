# autopilot

Autonomous TDD-driven implementation loop for Claude Code. Plans, implements, validates, and ships stacked PRs against Bitbucket Data Center with per-cycle commits, multi-validator review, and human-in-the-loop escape hatches.

## Status

v2.4.0 (2026-07-02). Audit release: every script is now covered by an executed self-test (`scripts/self_test.sh`) and the doc corpus by a consistency lint (`scripts/lint_consistency.sh`); fixes several release-blocking script bugs (the Bitbucket adapter could never succeed; the force-push probe could never detect a denial; the concurrency guard could never detect a concurrent drain) and reconciles all cross-file contract contradictions. Full register: `docs/GAPS_SPEC.md`. See CHANGELOG.md for history.

## What it does

Given a runbook (a YAML+Markdown file describing a unit of work, its goal, its constraints, and the audit handoff that motivates it), autopilot:

1. Plans the work into a DAG of subtasks with disjoint file ownership and explicit test gates.
2. Reviews the plan structure (not its content) for ownership disjointness, dependency acyclicity, and test coverage.
3. Implements each subtask via TDD cycles: `test: <id>.<n> RED — ...` commit, then `feat: <id>.<n> GREEN — ...` commit, per cycle.
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
- Repos hosted on GitHub. Since v2.0.0 autopilot ships Bitbucket DC only.
- Fully unattended overnight runs: the drain is autonomous only while the Claude Code session is alive (in-session adaptive cron; no headless mode — see AP-19).

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
validators: [integration, design, quality, security]
cadence: { mode: in-session, step_pause_seconds: 0 }
gates: { test_scoped: "pytest -x -q {paths}", test_single: "pytest {test} -x", typecheck: "mypy {paths}", lint: "ruff check {paths}", precommit: "pre-commit run --files {files}" }
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

- `SKILL.md` — the dispatcher. Modes, hard contracts, step graphs GENERATE G1..G8 and DRAIN D1..D8, reference index.
- `references/loop-safety.md` — loop-safety invariants: what the loop may never do, and which mechanism enforces each.
- `references/runbook-template.md` — runbook frontmatter and body schema; canonical tracker schema.
- `references/role-prompts-rationale.md` — why the role split, why projections, why per-cycle commits.
- `references/planner-prompt.md` — planner role contract.
- `references/plan-reviewer-projection.md` — what the reviewer sees and why.
- `references/implementer-prompt.md` — implementer role contract; TDD cycle shape.
- `references/validator-prompts.md` — validator catalog (integration, design, quality + optional security, sre); contradiction handling.
- `references/conflict-resolution.md` — D7.0 rebase resolver; scoped pytest rules.
- `references/extraction-prompt.md` — code-extraction helper.
- `references/cadence-dispatch.md` — in-session cadence rules.
- `references/sidecar-contract.md` — sidecar v0 env vars, URL shape, error codes, resolver chain, and (v2.3.0) probe budget under sidecar mode.
- `references/generate-lifecycle.md` — G1..G8 including G1.5 repo-shape probe and G3.6 Subtask consolidation (v2.3.0).
- `references/drain-lifecycle.md` — D1..D8 including D1.0.4 batched-delta migration/recovery, D1.0.5 drift-notes hydration, D7.1a tracker-delta fold, and the D7.5 CI-poll dispatch table (v2.3.0).
- `references/tracker-delta-batching.md` — AP-23 in-tracker queue contract, `delta_kind:` catalog, flush semantics, recovery cases.

## Scripts

All scripts live in `scripts/` and are invoked by the dispatcher. They have no Claude-context side effects (no stdout other than declared outputs, no token echoing).

- `bitbucket.sh` — Bitbucket DC adapter. Subcommands: pr-open, pr-state (`--num` or `--branch`), pr-comment, pr-approve, pr-decline, pr-merge (409 retry + enabled-strategy discovery), pr-merge-strategies, build-status. UTF-8 sanitisation on request AND response payloads; XSRF header on all mutating requests; token via 0600 header file, never argv; LAST_STATE=<value> emitted on stderr before every non-zero exit.
- `ci_check.sh` — CI verdict for a SHA/PR pair. Dispatcher mode `--once` takes one observation (VERDICT=GREEN|RED|PENDING|PR_DECLINED, exits 0/1/5/4); blocking poll mode (STUCK/UNDETERMINED) is operator-only. LAST_STATE on stderr carries the actual last observed build state.
- `detect_concurrent_drain.sh` — Tracker session-lock check against the canonical `session_lock`/`session_lock_expires_at` fields; takes the tracker path; fail-closed (exit 4) on unreadable lock state.
- `hot_file_audit.sh` — `--churn`: 30-day churn top-20 (G4). `--subtasks <slug>`: files touched by multiple in-flight subtask branches (D7.0).
- `secret_get.sh` — Resolve credential through sidecar→keychain→env chain. Output on stdout, nothing else. Probes a prioritised candidate list (operator override → `autopilot-<service>` → `autopilot-<service>-<host>` → `<service>-token:<host>` → `<service>-token` → `<service>`); `--list-candidates` prints it.
- `secret_set.sh` — One-time token install into OS keychain. Reads token from STDIN. `--as-host` writes the host-scoped name; default mode aborts if ANY resolver candidate already holds a foreign entry; `--force` bypasses.
- `sidecar_detect.sh` — Probe identity-proxy sidecar (HTTP 200 + "ok" body). Emits MODE=sidecar|local.
- `repo_shape_probe.sh` — (AP-23) G1.5 probe. Detects TRUNK / CI_PRESENT / FORCE_PUSH_ALLOWED / JIRA_HOOK_ENFORCED via minimal git and Bitbucket API operations; the force-push probe performs a genuine history rewrite (fast-forwards prove nothing). Supports `--dry-run`, `--explain` (reasoning trace), `--show-patterns`. Cleans up temp branches via a trap; stdout is strictly KEY=VALUE.
- `repo_shape_probe_patterns.sh` — (AP-23) Regex registry sourced by the probe. Provides `match_rejection <logfile> <outvar>` (signal = text after the LAST `|`, so regexes may contain alternations) and a maintained catalogue of Bitbucket DC rejection strings with example messages.
- `self_test.sh` — Hermetic self-test: mock Bitbucket server, local bare repos with deny-hooks, table-driven pattern tests, call-signature contract tests. Runs `lint_consistency.sh` as its final section. Run after any change.
- `lint_consistency.sh` — Deterministic cross-file contract lint (L1–L15): one artifact-path scheme, one tracker schema, one step graph, one validator catalog, registered flags only, version refs pinned to CHANGELOG, no consumer-repo leakage.

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
