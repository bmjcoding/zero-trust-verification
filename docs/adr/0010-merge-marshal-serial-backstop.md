# The merge queue survives as the Merge Marshal: a serial, deterministic composed-state verifier — shift-left makes it boring, not absent

---
status: accepted
date: 2026-07-04
---

Shift-left conflict avoidance (derived claims, ADR 0009; sizing, ADR 0012) can fully prevent **Textual Conflicts** but cannot prevent **Composition Breaks** — two branches merging cleanly yet broken together. The only deterministic verifier of the composed state is building and testing the composed state. Therefore the queue is not eliminated; it is reduced to its irreducible job and named the **Merge Marshal**: a cron-driven loop (same CI-cron pattern as the ADR 0003 ambient audit) over primitives the suite already ships in `bitbucket.sh`:

1. List approved, green, ready-for-review PRs; take the queue head — **strict FIFO by ready-for-review timestamp** (the claim lattice's "terminal tier merges next" *is* FIFO).
2. Rebase onto current main — or refuse per D7.0's hunk/file budget and kick back with a comment: an oversized rebase is a planning failure, not a merge-time problem.
3. Wait for `build-status` on the **post-rebase sha** — the composed-state verification. Bitbucket DC's semi-linear merge does not do this (it merges on the strength of the pre-rebase build), which is exactly the Composition Break hole; and Bitbucket DC has no native merge queue, so this loop is the whole build.
4. Green → merge. Red → comment, evict, next in line. One PR in flight; no speculation, no batching.

The only override: a human may pin a hotfix PR to the queue head, logged to the decision log (Force Audit pattern). No agent judgment exists anywhere in the merge path — every decision is a timestamp, a sha, a build state, or a file-surface intersection (ADR 0004's invariant at its strongest point).

## Considered Options

- **Eliminate the queue entirely** (the original stress-test position): rejected — ownership claims are checkable before code is written and kill Textual Conflicts, but Composition Breaks live in the *interaction* between disjoint surfaces; predicting them (even with Bazel rdeps) is probabilistic, and the suite's zero-trust principle demands the composed state be verified, not predicted safe.
- **Speculative merge trains / batching** (Bors-style): rejected *now* — with no remote cache or RBE, every speculative batch is another cold build, so the machinery multiplies the scarcest resource, and batch-failure bisection multiplies it again. Pod throughput (Story-granularity PRs, ADR 0007) sits inside serial capacity. Revisit order: remote cache → RBE → then trains, and only if merge demand × CI latency exceeds the working day.
- **Priority scheduling** (criticality, size, attended-first): rejected — reintroduces judgment into the one component that must stay purely deterministic.

## Consequences

- "Build our own merge-queue infrastructure" deflates to ~150 lines of orchestration over the existing hardened adapter plus a cron entry — comparable in size to `detect_concurrent_drain.sh`.
- Nothing in the loop knows about Bazel: the Marshal works on every ordinary shared repo in the company; the monorepo pilot just gets faster composed-state verification when cache/RBE arrive.
- Accepted residual: at ~20-minute cold builds the Marshal merges ~3/hour, so an end-of-day merge burst queues into the evening. Tolerable precisely because the Marshal is unattended; shrinks when remote cache lands.
- ADR 0012's merge-when-Story-completes preference spreads merges across the day, reducing the EOD burst at the source.
