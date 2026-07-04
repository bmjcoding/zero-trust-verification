# Trunk-based development with a 48-hour Story sizing invariant (amends ADR 0007); feature flags are the deliberate later pivot

---
status: accepted
date: 2026-07-04
---

The pod practices strict trunk-based development: short-lived branches — under 48 hours, ideally merged at end of day or when a Story completes mid-day — implementation branch → main, no release cuts, no exceptions. This collided with ADR 0007 (one Story = one branch = one PR, ready only when the *last* Subtask completes): a multi-day Story means a multi-day branch. Resolution, decided by Bailey 2026-07-04: **sizing bends, atomicity holds.** The planner (G4) gains a hard invariant — no Story may be *predicted* to exceed 48 hours wall-clock; anything larger is split into sequential Stories, each independently mergeable to main. Enforcement is deterministic at both ends: predicted duration checked at G4; actual branch age watched by the Marshal, with a branch older than 48h flagged as a **planning failure** — mirroring exactly how D7.0 treats an oversized rebase.

Features that span several sequential Story PRs must keep main safe in intermediate states (compiling, tested, journey not yet reachable end-to-end). The Runbook records which acceptance-behavior IDs land in which Story, so the audit tier can distinguish *intentionally not yet wired* from Memory Rot.

**Planned pivot:** when feature-flag infrastructure is built (a deliberate future investment, not a side effect of this decision), atomicity may bend too — incomplete Stories merging daily behind flags. That pivot reopens this ADR and requires the audit tier to grade flag state (intentionally-dark vs rotted paths) before adoption.

## Considered Options

- **Atomicity bends now — incomplete Stories merge daily behind flags** (adversarial position): maximal TBD. Rejected *for now*: it breaks ADR 0007's core claim (the review unit stops being one coherent spec-traceable diff), and it drags in flag-retirement discipline — in a regulated Payments codebase, a new class of auditable state — as a side effect of a merge-policy decision rather than a chosen investment.
- **Exempt long Stories from the 48h rule**: rejected — "no exceptions" is the point; exemptions rot into the default.

## Consequences

- ADR 0007 is amended, not superseded: PR-per-Story stands; it gains the sizing invariant.
- Unattended Drains sail under 48h (agent-speed Stories complete in hours); the invariant mostly disciplines attended work, where it enforces standard TBD slicing.
- Short-lived branches shrink every window downstream: claim staleness decay drops to ~2 business days (ADR 0009), divergence stays inside D7.0's rebase budget, and per-merge risk falls — further starving the case for speculative merge trains (ADR 0010).
