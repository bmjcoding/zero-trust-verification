# Tracker delta batching (AP-23)

> Load this reference whenever `branching.no_force_push: true` (probe-flipped by
> G1.5 or declared manually). It supersedes the retired rolling tracker-PR
> pattern. This file is the data-and-rationale document; the lifecycle
> integration points (D1.0.4 injection + crash recovery, D1.0 hydrate, D2
> claim, D7.1a fold, D7.4 status queue) are defined in
> `references/lifecycle.md`, and THAT file is canonical wherever the two could
> be read to differ.

## Purpose

Repos with branch permissions frequently forbid force-push and re-opening a merged PR. All tracker bookkeeping lands on the **Runbook PR** (`autopilot/<slug>/runbook`, AV3-08) — the single bookkeeping home. Under `no_force_push: false` deltas commit directly to the runbook branch. Under `no_force_push: true`, per-fire tracker writes are replaced with an in-file queue that flushes at D7.1a as an **append** commit onto the runbook branch — never mixed into a Story PR, so Story code and bookkeeping never share a branch (one home, no self-intersecting claim surfaces for AV3-09).

## In-tracker section (canonical location)

Section header, verbatim:

```markdown
## Pending Tracker Deltas (batched)
```

Location: between `## Drift Notes` and the first Subtask section (injected by D1.0.4 on a pre-v2.3 tracker; the injection is a no-op against a tracker that already carries it).

## Delta entry format

Each entry is a top-level list item under the section header:

```markdown
- subtask_id: <STK-ID or synthetic id>
  delta_kind: <one of the values below>
  diff_summary: <one-line human summary>
  body: |
    <multi-line free-form body; preserved verbatim on flush>
```

## `delta_kind:` catalog

| Value              | Emitted from | Meaning                                                                 |
|--------------------|--------------|-------------------------------------------------------------------------|
| `subtask_done`     | D7.5 green / D1.4 merged | Subtask reached terminal Done; carries the status change and audit note |
| `in_progress_claim`| D2           | This fire claimed a Subtask (the `in_progress` block write)             |
| `drift_notes`      | D1.0.5 hydrate + D3 review | Drift-note appendages produced during Plan Reviewer projection |
| `status_change`    | D7.4 + D-various | Any STATUS/`in_progress` transition that is not the Done transition (e.g. `awaiting_ci`, PAUSED, claim-wait) |
| `session_lock`     | D1.0, D8     | Session-lock acquire/release records                                    |
| `crash_recovery`   | D1.0.4       | Audit entry when a prior drain aborted with unflushed deltas            |
| `other`            | escape hatch | Any non-catalogued delta (e.g. D4 heartbeat refresh); `diff_summary` required |

The catalog is closed: an addition requires a CHANGELOG entry and a runbook schema-version bump. `other` is the escape valve and never substitutes for an existing kind.

## Queue invariants

1. Append-only within a drain: never rewrite or reorder prior entries — a mis-emitted entry is corrected by a follow-on entry.
2. No wall-clock timestamps in the queue body; ordering is positional, and the flush commit's author-date is the effective flush time.
3. `subtask_id` may be synthetic (`AP-drift-<n>`, `AP-lock-<n>`) when no real Subtask applies.
4. `body:` is preserved verbatim and MUST NOT contain the string `## Pending Tracker Deltas (batched)` (guarded by a pre-flush lint).

## Flush point

D7.1a — after D7.0's rebase and D7.1's staging, BEFORE the D7.2 push and D7.3 PR creation. The fold procedure itself (commit-body `Tracker deltas folded in:` block, in-order apply, `_(empty)_` reset, the OWN append commit on the runbook branch, the PR-body H2) is defined once in `references/lifecycle.md` §D7.1a/§D7.3. Under `no_force_push: false` the queue is unused — deltas were committed directly at claim time (D2/D7.4).

## Recovery semantics (D1.0.4 handling)

- **A — clean start:** queue empty. No action.
- **B — queue empty, header missing:** inject the header (idempotent) and continue.
- **C — queue non-empty, no live session lock:** a prior drain aborted between enqueue and flush. Append a `crash_recovery` entry documenting the discovery, then flush the entire queue on the next fire as usual. Prior entries preserved verbatim.
- **D — queue non-empty, live foreign lock:** fall through to D1.0 concurrent-drain handling; do not mutate the queue.

## Interaction with `enforce_jira_key: true`

The D7.1a fold is its own commit on the runbook branch, so its subject MUST carry the `[<TRACKER-JIRA-KEY>]` prefix sourced from the tracker frontmatter (the runbook/tracker have no per-Subtask key), plus a `Refs: <TRACKER-JIRA-KEY>` body line — the bookkeeping commit's own compliance, never borrowed from a Story commit.

## Interaction with `branching.single_branch_single_pr: true`

The whole drain collapses to one feature branch and one PR, so there is no separate Runbook PR branch; queue mechanics are unchanged and the fold appends to that single shared branch.

## Failure modes

- Fold commit rejected by branch permissions at push: surface `LAST_STATE=queue_flush_blocked` in the tracker entry and escalate per the lifecycle failure table; no automatic retry.
- Queue body exceeds 64 KiB: emit `LAST_STATE=queue_oversize`; the next fire runs a `docs`-kind synthetic no-op Subtask (`AP-queue-drain-<n>`, owning only the tracker file) whose sole purpose is to fold and flush.

There is no override flag for this queue: an operator who wants direct-commit deltas flips `branching.no_force_push: false` in the runbook — logged via `## Force Audit` when it contradicts a probe finding.
