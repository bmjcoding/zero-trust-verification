# autopilot

Autonomous TDD-driven implementation loop for Claude Code. Plans, implements, validates, and ships PRs through the host adapter (Bitbucket Data Center or GitHub) with per-cycle commits, multi-validator review, and human-in-the-loop escape hatches.

## Status

v3.1.0 (2026-07-10), shipped inside the single `zero-trust` plugin since ADR 0025. Verification-Manifest consumption (mode inference, Behavior-ID mapping, union + revision-drift gates), PR-per-Story granularity, cross-drain claim coordination, and quality shift-left (anti-flakiness contract, N=5 determinism gate) — all on the host-agnostic adapter (`scripts/host.sh`, Bitbucket DC + GitHub). Every behavioral claim is proven by an executed self-test assertion or lint rule (`scripts/self_test.sh`, `scripts/lint_consistency.sh` L1–L23). See CHANGELOG.md for history and per-version migration checklists.

## What it does

Given a runbook (a YAML+Markdown file describing a unit of work, its goal, its constraints, and the audit handoff that motivates it), autopilot:

1. Plans the work into a DAG of subtasks with disjoint file ownership and explicit test gates.
2. Reviews the plan structure (not its content) for ownership disjointness, dependency acyclicity, and test coverage.
3. Implements each subtask via TDD cycles: `test: <id>.<n> RED — ...` commit, then `feat: <id>.<n> GREEN — ...` commit, per cycle.
4. Runs all configured validators in parallel on each subtask's diff. Spawns fix subtasks for findings; escapes contradictions to a human.
5. Opens one draft PR per Story, flips it ready when the Story is done, polls CI, and stacks cross-Story dependencies with the `merge-commit` strategy to preserve cycle history — through the host adapter.
6. Logs every step to an append-only tracker with session lock and heartbeat.

## When to use

- The work is well-scoped enough to write a runbook for (goal, constraints, non-goals, ideally an audit handoff).
- The repo lives in Bitbucket Data Center or GitHub (the host adapter detects which from `origin`).
- You want machine-verifiable TDD evidence in git history, not just "the tests pass at the end".

## When NOT to use

- One-off scripts or single-file edits; exploratory refactoring where the plan emerges as you work.
- Work that cannot tolerate stacked PRs (teams that strictly squash-merge; autopilot's TDD history is destroyed by squash).
- Fully unattended overnight runs: the drain is autonomous only while the Claude Code session is alive (in-session adaptive cron; no headless mode — AP-19).

## Setup

The skill ships inside the `zero-trust` plugin — install that plugin; nothing autopilot-specific to copy. Dependencies on PATH: `git >= 2.30`, `jq >= 1.6`, `bash >= 3.2` (macOS default; the scripts are bash-3.2 + BSD-userland safe), `curl`, `uv` (ADR 0015). The GitHub backend additionally needs `gh`.

- **macOS / Linux local mode**: store your Bitbucket DC token in the OS keychain — `echo -n "<token>" | scripts/secret_set.sh bitbucket`. The token is read from STDIN; it never enters argv, shell history, or trace output.
- **Workspace container / sidecar mode**: nothing to do — the identity-proxy sidecar handles credentials via session-scoped OBO. Verify with `scripts/sidecar_detect.sh` (prints `MODE=sidecar …`).

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

## Where everything is defined

- `SKILL.md` — the dispatcher: modes, hard contracts, step graphs GENERATE G1..G8 and DRAIN D1..D8, and the full reference index (role prompts, lifecycle, loop safety, sidecar contract, tracker-delta batching, conflict resolution, cadence). Each design choice traces to an adversarial-review finding (AP-1 .. AP-23); rationale in `references/role-prompts-rationale.md`.
- `scripts/` — the deterministic substrate the dispatcher calls: `host.sh` (the single PR/build surface, ADR 0013 — Bitbucket DC `bitbucket.sh` / GitHub `github.sh` behind one byte-identical contract), `ci_check.sh`, `detect_concurrent_drain.sh`, `secret_get.sh`/`secret_set.sh`/`sidecar_detect.sh`, `repo_shape_probe.sh`, `claim_overlap.sh`, `mutation_gate.sh`, and friends. Every script's header documents its own surface; none echoes tokens or writes to Claude context beyond declared outputs.
- `scripts/self_test.sh` — hermetic self-test (mock Bitbucket DC server + `gh` argv shim, local bare repos with deny-hooks, table-driven pattern tests); runs `lint_consistency.sh` (L1–L23) as its final section. Run after any change.

## License

MIT. See LICENSE.
