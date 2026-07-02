# Tracker delta batching (AP-23)

> Loading preamble reminder: this reference must be loaded whenever the operator
> is on Bitbucket Data Center in a repo whose shape probe (G1.5) has flipped
> `branching.no_force_push: true`, or when the runbook declares that flag
> manually. It supersedes the rolling tracker-PR pattern for tracker deltas.
> Never inline this contract into SKILL.md; SKILL.md carries only the summary.

## Purpose

Bitbucket Data Center repositories with branch permissions frequently forbid
force-push and disallow re-open of a merged PR. The pre-2.3 pattern of a rolling
tracker PR (single long-lived branch that receives one force-push per Subtask
completion) fails on such repos. Tracker delta batching replaces per-Subtask
tracker pushes with an in-file queue that flushes on the next successful
Subtask PR as a single atomic commit alongside the implementation change.

## In-tracker section (canonical location)

Section header, verbatim:

```markdown
## Pending Tracker Deltas (batched)
```

Location: immediately above `## Audit trail` inside the tracker file body.

Migration: D1.0.4 injects this header on the first drain against a v2.1 or
v2.2 tracker that lacks it. The injection is a no-op edit against a tracker
that already carries the header.

## Delta entry format

Each delta entry is a top-level list item under the section header. Format:

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
| `subtask_done`     | D7.1a fold   | Subtask reached terminal Done; carries the status change and audit note |
| `in_progress_claim`| D1.0.6 claim | Operator has claimed a Subtask (session lock write)                     |
| `drift_notes`      | D1.0.5 hydrate + D3 review | Drift-note appendages produced during Plan Reviewer projection |
| `status_change`    | D-various    | Any STATUS state-machine transition that is not `subtask_done`          |
| `session_lock`     | D1.0.6, D8   | Session-lock acquire/release records                                    |
| `crash_recovery`   | D1.0.4       | Audit entry emitted when a prior drain aborted with unflushed deltas    |
| `other`            | escape hatch | Any non-catalogued delta; must set `diff_summary` explicitly            |

The catalog is closed: additions require a CHANGELOG entry and a runbook
schema-version bump. `other` is the operator-visible escape valve and must
never be used for deltas that fit an existing kind.

## Queue invariants

1. Entries are append-only within a drain. Never rewrite or reorder prior
   entries; a mis-emitted entry is corrected by a follow-on entry, not by
   in-place edit.
2. Entries carry no wall-clock timestamps in the queue body; ordering is
   positional. The flush commit's author-date is the effective flush time.
3. `subtask_id` may be synthetic (`AP-drift-<n>`, `AP-lock-<n>`) when no real
   Subtask id applies (e.g. `drift_notes` for a Plan Reviewer observation
   made outside any single Subtask context).
4. `body:` is preserved verbatim and MUST NOT contain the string
   `## Pending Tracker Deltas (batched)` (guarded by a pre-flush lint).

## Flush point

Flush occurs at D7.1a, immediately after a Subtask PR is confirmed merged and
before D7.2 tracker-PR cadence check. The flush is a single commit against the
tracker branch containing:

- The Subtask's own tracker updates (status = Done, audit entry, checklist
  toggles) merged with all queued `Pending Tracker Deltas (batched)` entries.
- Removal of the flushed entries from the queue (the section header remains,
  body becomes empty until the next enqueue).

Commit message shape:

```
tracker: fold Subtask <STK-ID> + <N> batched deltas
```

Under `branching.no_force_push: true` the flush commit is pushed to the
tracker branch as a normal fast-forward. Under `branching.no_force_push: false`
the pre-existing rolling-tracker-PR pattern still applies and this queue is a
staging buffer only.

## Recovery semantics (D1.0.4 handling)

Case A — clean start: queue is empty. No action.

Case B — tracker exists, queue is empty, section header missing:
inject the header (idempotent no-op edit) and continue.

Case C — tracker exists, queue is non-empty, no in-progress drain lock:
prior drain aborted between enqueue and flush. Append a `crash_recovery`
entry documenting the discovery, then fold the entire queue on the next
Subtask PR as usual. Preserve prior entries verbatim.

Case D — tracker exists, queue is non-empty, live drain lock held by another
operator: fall through to D1.0.6 concurrent-drain handling; do not mutate the
queue.

## Interaction with `enforce_jira_key: true`

Flush commit messages must satisfy the JIRA-key regex when the flag is on.
The template above (`tracker: fold Subtask <STK-ID> + <N> batched deltas`)
inherits the Subtask id which is either a JIRA key or a synthetic id; when
the anchor Subtask id is synthetic, the flush commit MUST additionally carry
a body-line `Refs: <TRACKER-JIRA-KEY>` sourced from the tracker frontmatter.

## Interaction with `branching.single_branch_single_pr: true`

When this flag is on, the tracker branch and the Subtask branch are the same
branch. The flush commit is then part of the Subtask PR itself; there is no
separate tracker push. The queue mechanics are unchanged; only the push
target differs.

## Failure modes and operator overrides

- Flush commit rejected by branch permissions: emit `LAST_STATE=queue_flush_blocked`
  on stderr from D7.1a and escalate per the D-escalation table. Do not retry
  automatically.
- Queue body exceeds 64 KiB: emit `LAST_STATE=queue_oversize` and force a
  synthetic `subtask_done` no-op Subtask PR to drain the queue.
- Operator override `--force-rolling-tracker` bypasses the queue for a single
  drain; this is an emergency valve and must be logged in the runbook's
  Audit trail.
