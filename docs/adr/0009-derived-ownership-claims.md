# Cross-drain ownership: derived claims from open PRs, tiered by lifecycle stage — no ledger, no service

---
status: accepted
date: 2026-07-04
---

Cross-drain / cross-session file-ownership coordination (the gap left by per-tracker `session_lock`, which only prevents two sessions draining the *same* runbook) is solved by **derived claims**: the set of open PRs *is* the claim registry. There is no declared ownership ledger and no external coordination service. The claim event shifts left to **Spec pickup**: picking up an approved, merged Spec runs GENERATE, which opens the Runbook PR on behalf of the operator — publishing the whole Spec's predicted file surface before any implementation exists. From there, claims strengthen through a lattice as prediction converges to actuality:

| Tier | Artifact | Strength |
|---|---|---|
| Prediction | Runbook PR (whole-Spec predicted surface) | Advisory — planners route around; collisions warn |
| In-progress | Story draft PR (opened at first Subtask, per ADR 0007) | Binding |
| Terminal | Ready-for-review PR | Strongest — merges next; nothing schedules against it |

**Collision policy** (deterministic, actor-blind): (1) actuality beats prediction; (2) first-visible claim wins, by artifact timestamp; (3) sole tiebreak — an Attended Session beats an Unattended Drain, because a person is burning calendar time in real time while a drain re-queues for free. Yielding means **serialize and re-plan**: the yielding Story gains a dependency edge on the winning PR's merge (hot-file DAG semantics promoted from within-drain to cross-drain) and is re-planned against the new trunk — never blindly rebased, so D7.0's 3-hunk/2-file budget stays sufficient. A human may override the priority order (hotfix); overrides are logged to the decision log (Force Audit pattern).

**Staleness decays deterministically**: a binding claim with no commits in ~2 business days (trunk-based ceiling, ADR 0012) demotes to advisory and the watcher comments. Claim coverage is enforced by **nudge, not gate**: a server-side check comments when a first push arrives with no draft PR or when a new PR's surface overlaps an existing claim; work done outside the protocol degrades to today's D7.0 rebase-with-budget behavior — never worse than the status quo.

## Considered Options

- **Declared ledger on trunk** (adversarial position): claims committed to an ownership file. Rejected: the ledger file is itself contended (meta-conflict), claims are predictions that drift from actuality, and stale claims from abandoned work need reaping machinery — all problems the open-PR surface solves for free (self-releasing on merge/close, always actual).
- **External coordination service**: rejected — a separate service adds operational dependencies; open PR metadata already provides the required coordination surface.
- **Binding whole-Spec claims at pickup**: rejected — long-lived corridor locks recreate the ledger problem; a stalled drain can unnecessarily block unrelated work. The accepted cost: overlapping pickups both proceed and occasionally serialize mid-drain at Story granularity.
- **Human-beats-agent priority**: dissolved — attendance is the scheduling distinction; authorship does not establish whether an operator is waiting.

## Consequences

- One uniform claim surface — open PRs — covers both the plan-time window (Runbook PR) and the execution window (Story PRs); no tracker-scanning shim needed.
- The claim-overlap check (open-PR file-surface intersection) is consumed by autopilot's G4 planner and by the Marshal's nudge watcher; it is vendored into both with the byte-identical repo lint (ADR 0001 pattern).
- Claim-tier scheduling honors ADR 0004's invariant at full strength: overlap detection is git/API-provable, so it may gate — no agent opinion anywhere in the path.
- Bazel-target-graph claim precision (rdeps overlap) is an optional enhancement for repositories with a target graph, never the core mechanism — the canonical claim surface is file paths, the only substrate every repo shares.
- Optional issue-tracker integration creates one ticket per Story and includes its ID in Story commits. Spec-to-Story traceability lives in the Runbook and manifest behavior IDs, without requiring an epic hierarchy.
