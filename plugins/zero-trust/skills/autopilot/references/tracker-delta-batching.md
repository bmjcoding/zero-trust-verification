# Tracker delta batching (AP-23)

> Loading preamble reminder: this reference must be loaded whenever the operator
> is on Bitbucket Data Center in a repo whose shape probe (G1.5) has flipped
> `branching.no_force_push: true`, or when the runbook declares that flag
> manually. It supersedes the rolling tracker-PR pattern for tracker deltas.
> Never inline this contract into SKILL.md; SKILL.md carries only the summary.
>
> This file is the data-and-rationale document. The lifecycle integration
> points (D1.0.4 injection + crash recovery, D1.0 hydrate, D2 in_progress
> claim, D7.1a fold, D7.4 status-change queue) are defined in
> `references/lifecycle.md`, and THAT file is canonical wherever the two
> could be read to differ.

## Purpose

Repositories with branch permissions frequently forbid force-push and disallow
re-open of a merged PR. All tracker bookkeeping lands on the **Runbook PR**
(`autopilot/<slug>/runbook`, AV3-08) — the single bookkeeping home (the pre-v3
rolling tracker PR is retired). Under `branching.no_force_push: false` deltas
commit directly to the runbook branch. Under `branching.no_force_push: true`,
force-push is unavailable, so per-fire tracker writes are replaced with an
in-file queue that flushes at D7.1a as an **append** commit onto the runbook
branch — never mixed into a Story PR, so a Story's code and the tracker's
bookkeeping never share a branch (one home, no self-intersecting claim surfaces
for AV3-09).

## In-tracker section (canonical location)

Section header, verbatim:

```markdown
## Pending Tracker Deltas (batched)
```

Location: between `## Drift Notes` and the first Subtask section (as injected
by D1.0.4; see `references/lifecycle.md`).

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
| `subtask_done`     | D7.5 green / D1.4 merged | Subtask reached terminal Done; carries the status change and audit note |
| `in_progress_claim`| D2           | This fire claimed a Subtask (the `in_progress` block write)             |
| `drift_notes`      | D1.0.5 hydrate + D3 review | Drift-note appendages produced during Plan Reviewer projection |
| `status_change`    | D7.4 + D-various | Any STATUS/`in_progress` transition that is not the Done transition (e.g. D7.4 `awaiting_ci`, PAUSED, claim-wait) |
| `session_lock`     | D1.0, D8     | Session-lock acquire/release records                                    |
| `crash_recovery`   | D1.0.4       | Audit entry emitted when a prior drain aborted with unflushed deltas    |
| `other`            | escape hatch | Any non-catalogued delta (e.g. D4 heartbeat refresh); must set `diff_summary` explicitly |

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

Flush occurs at D7.1a — after D7.0's rebase and D7.1's staging, BEFORE the
D7.2 push and D7.3 PR creation. The fold procedure itself (the commit-body
`Tracker deltas folded in:` block, the in-order apply of each entry's `body:`,
the `_(empty)_` queue reset, the OWN append commit on the Runbook PR branch
(`autopilot/<slug>/runbook`, AV3-08), and the PR-body
`## Tracker deltas folded in` H2) is defined once in
`references/lifecycle.md` §D7.1a/§D7.3 — canonical there, not restated here.

Under `branching.no_force_push: false` (default) this queue is unused — D7.1a
is a no-op because the deltas were already committed directly to the Runbook PR
branch at claim time (D2/D7.4).

## Recovery semantics (D1.0.4 handling)

Case A — clean start: queue is empty. No action.

Case B — tracker exists, queue is empty, section header missing:
inject the header (idempotent no-op edit) and continue.

Case C — tracker exists, queue is non-empty, no live session lock:
prior drain aborted between enqueue and flush. Append a `crash_recovery`
entry documenting the discovery, then flush the entire queue onto the Runbook
PR branch on the next fire as usual. Preserve prior entries verbatim.

Case D — tracker exists, queue is non-empty, live session lock held by another
session: fall through to D1.0 concurrent-drain handling; do not mutate the
queue.

## Interaction with `enforce_jira_key: true`

The D7.1a fold is its own commit on the Runbook PR branch (AV3-08), so under
`enforce_jira_key: true` its subject MUST carry the `[<TRACKER-JIRA-KEY>]`
prefix sourced from the tracker frontmatter (the runbook/tracker have no
per-Subtask JIRA key), plus a `Refs: <TRACKER-JIRA-KEY>` body line. This is the
bookkeeping commit's own compliance — it does not borrow a Story commit's key.

## Interaction with `branching.single_branch_single_pr: true`

When this flag is on, the whole drain collapses to one feature branch and one PR
(the coarser collapse — AV3-06), so there is no separate Runbook PR branch. The
queue mechanics are unchanged; the fold appends to that single shared branch.

## Failure modes

- Fold commit rejected by branch permissions at D7.2 push: surface
  `LAST_STATE=queue_flush_blocked` in the tracker entry and escalate per the
  lifecycle.md failure table. Do not retry automatically.
- Queue body exceeds 64 KiB: emit `LAST_STATE=queue_oversize`; the next fire
  runs a `docs`-kind synthetic no-op Subtask (`AP-queue-drain-<n>`, owning
  only the tracker file) whose sole purpose is to fold and flush the queue.

There is no override flag for this queue (the v2.3.0 draft of this file named
one, but it was never registered in SKILL.md's flag table): an operator who
wants tracker deltas committed directly to the Runbook PR branch instead of
batched flips `branching.no_force_push: false` in the runbook — an edit that is
logged via the standard `## Force Audit` process when it contradicts a probe
finding.
