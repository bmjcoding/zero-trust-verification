# Cross-drain ownership: derived claims from open PRs, tiered by lifecycle stage — no ledger, no service

---
status: accepted
date: 2026-07-04
---

Cross-drain / cross-session file-ownership coordination (the gap left by per-tracker `session_lock`, which only prevents two sessions draining the *same* runbook) is solved by **derived claims**: the set of open PRs *is* the claim registry. There is no declared ownership ledger and no external coordination service. The claim event shifts left to **Spec pickup**: picking up an approved, merged intent Spec runs GENERATE, which opens the Runbook PR OBO the picker-upper — publishing the whole Spec's predicted file surface before any implementation exists. From there, claims strengthen through a lattice as prediction converges to actuality:

| Tier | Artifact | Strength |
|---|---|---|
| Prediction | Runbook PR (whole-Spec predicted surface) | Advisory — planners route around; collisions warn |
| In-progress | Story draft PR (opened at first Subtask, per ADR 0007) | Binding |
| Terminal | Ready-for-review PR | Strongest — merges next; nothing schedules against it |

**Collision policy** (deterministic, actor-blind): (1) actuality beats prediction; (2) first-visible claim wins, by artifact timestamp; (3) sole tiebreak — an Attended Session beats an Unattended Drain, because a person is burning calendar time in real time while a drain re-queues for free. Yielding means **serialize and re-plan**: the yielding Story gains a dependency edge on the winning PR's merge (hot-file DAG semantics promoted from within-drain to cross-drain) and is re-planned against the new trunk — never blindly rebased, so D7.0's 3-hunk/2-file budget stays sufficient. A human may override the priority order (hotfix); overrides are logged to the decision log (Force Audit pattern).

**Staleness decays deterministically**: a binding claim with no commits in ~2 business days (trunk-based ceiling, ADR 0012) demotes to advisory and the watcher comments. Claim coverage is enforced by **nudge, not gate**: a server-side check comments when a first push arrives with no draft PR or when a new PR's surface overlaps an existing claim; work done outside the protocol degrades to today's D7.0 rebase-with-budget behavior — never worse than the status quo.

## Considered Options

- **Declared ledger on trunk** (adversarial position): claims committed to an ownership file. Rejected: the ledger file is itself contended (meta-conflict), claims are predictions that drift from actuality, and stale claims from abandoned work need reaping machinery — all problems the open-PR surface solves for free (self-releasing on merge/close, always actual).
- **External coordination service**: rejected — the solution must adopt with zero infrastructure on every ordinary shared repo in the company, and org merge safety must not depend on a service run by the one team piloting it.
- **Binding whole-Spec claims at pickup**: rejected — long-lived corridor locks recreate the ledger problem; a stalled drain freezes the repo and the pod routes around the claim system, killing it socially. The accepted cost: overlapping pickups both proceed and occasionally serialize mid-drain at Story granularity.
- **Human-beats-agent priority**: dissolved — nearly all pod work is a human driving Claude Code; the meaningful axis is attended vs unattended, not human vs agent.

## Consequences

- One uniform claim surface — open PRs — covers both the plan-time window (Runbook PR) and the execution window (Story PRs); no tracker-scanning shim needed.
- The claim-overlap check (open-PR file-surface intersection) is consumed by autopilot's G4 planner and by the Marshal's nudge watcher; it is vendored into both with the byte-identical repo lint (ADR 0001 pattern).
- Claim-tier scheduling honors ADR 0004's invariant at full strength: overlap detection is git/API-provable, so it may gate — no agent opinion anywhere in the path.
- Bazel-target-graph claim precision (rdeps overlap) is an optional enhancement profile for the monorepo pilot, never the core mechanism — the canonical claim surface is file paths, the only substrate every repo shares.
- Jira integration (escalated per ADR 0002, resolved by Bailey 2026-07-04): bot-created OBO Jiras are accepted, **one per Story only — no epics**. The Jira mirrors the PR unit and every commit on the Story branch carries its ID. Epics are deliberately not mapped: the org's epic practice is not followed rigorously today, so binding the design to epic hygiene would couple it to a discipline that doesn't exist; the Spec→Story linkage lives in the Runbook and manifest behavior IDs, not in Jira hierarchy.
