# PR granularity: PRs are Stories, Subtasks are commits

---
status: accepted
date: 2026-07-03
amended-by: 0012 (48-hour Story sizing invariant under trunk-based development)
---

Autopilot's original shape — one PR per Subtask (Hard Contract 1) — produces too many PRs; per the 2026 AI Engineer World's Fair framing Bailey is building against: "you don't have too many PRs, you have too many bad PRs — reviewing good PRs is fun." The canonical granularity becomes: **one Story = one worktree/branch = one PR; Subtasks are the commit series inside it** (each Subtask still lands as its TDD RED/GREEN commit pairs, so D6's git-log audit is unchanged). One-Subtask-per-fire survives as the *pacing* contract (one tracker delta per fire); it no longer implies one PR per fire. The Story PR opens as a draft at the Story's first Subtask (progress is visible, CI runs early) and flips ready-for-review when the Story's last Subtask completes.

## Consequences

- Hard Contracts 1 and 4 get rewritten; `branching.single_branch_single_pr` (whole-drain collapse) remains as the coarser option; MERGE-ORDER.md and stacked-PR logic (AP-10) simplify — merge order is now across Story PRs only.
- Non-overlapping file ownership stays per-Subtask within a Story and becomes per-Story across the drain.
- Human review effort scales with feature count, not task count — the review unit is a coherent, spec-traceable Story with its behavior IDs and docs in one diff.
