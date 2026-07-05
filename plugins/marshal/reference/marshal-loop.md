# The serial backstop loop, in detail

`scripts/marshal.sh` is one serial pass of the merge queue (ADR 0010). Shift-left
machinery — derived ownership claims (ADR 0009) and 48h Story sizing (ADR 0012) —
prevents **Textual Conflicts**. It cannot prevent **Composition Breaks**: two
branches that merge cleanly yet break together (a rename lands on one branch while
another adds a call site to the old name; each is green at its own fork point, red
composed). The only deterministic verifier of the composed state is building and
testing the composed state. That is the whole job of this loop, and the reason the
merge queue survives shift-left as a boring backstop rather than disappearing.

## One pass, step by step

1. **Enumerate + order.** `git fetch origin`, then `host pr-list-ready`
   (see `host-contract.md`). Keep the `APPROVED` rows; order them **strict FIFO
   by `ready_ts`** (tie-break: PR number). The terminal claim tier "merges next"
   *is* FIFO (ADR 0009).

2. **Hotfix pin (the only override).** If `MARSHAL_HOTFIX_PIN=<n>` names a PR
   that appears in `pr-list-ready`, that PR is moved to the head, ahead of FIFO
   and regardless of its approval state — a human is vouching for a hotfix. The
   pin is appended to the **Force Audit** log (`MARSHAL_FORCE_AUDIT_LOG`, default
   `.marshal/force-audit.log`): `<iso8601>  hotfix-pin  pr=<n>  actor=<actor>
   by=marshal`. The pin overrides *ordering and approval only*; it never bypasses
   the composed-state build gate (zero-trust is never waived). A pin naming a PR
   that is not ready is logged `ignored=not-ready` and writes no audit line.

3. **Rebase or refuse (D7.0 budget).** For the head PR, compute the rebase's
   reconciliation surface: the **file-surface intersection** of the branch's
   changes and the trunk's changes since their merge-base (ADR 0011 — a
   git-provable set). If a branch already contains the trunk, it is
   `already-current` (no rebase, no push). Otherwise:
   - overlap `> MARSHAL_REBASE_FILE_BUDGET` files (default **2**) or
     `> MARSHAL_REBASE_HUNK_BUDGET` hunks (default **3**) → **refuse** with a
     kickback comment. An oversized rebase is a planning failure — re-plan the
     Story against the current trunk (ADR 0012), never blind-rebase.
   - within budget → rebase on a scratch branch. A rebase **conflict** is also a
     refuse (ownership claims should have prevented the Textual Conflict) — abort,
     kickback, evict.
   - clean → `git push --force-with-lease` the rebased head to the PR branch
     (the Marshal's entire write scope beyond the merge itself).

4. **Verify the composed state.** Poll `host build-status --sha <post-rebase-sha>`
   (bounded by `MARSHAL_BUILD_POLL_MAX` × `MARSHAL_BUILD_POLL_INTERVAL`):
   - `SUCCESSFUL` → `host pr-merge`. **The pass stops** — one PR in flight, no
     speculation, no batching. The trunk has advanced; the next fire re-evaluates
     the rest against the new trunk.
   - `FAILED` → kickback comment (a Composition Break on the composed head),
     **evict**, move to the next PR in line.
   - `INPROGRESS` / `UNKNOWN` (poll budget exhausted) → **wait**: never merge an
     unverified composition. Leave the PR in place; the pass stops (it is the one
     in flight) and the next fire re-checks.

A pass may evict several red/oversized PRs before it finds a green head to merge;
it merges at most one.

## What the loop is NOT

No agent judgment anywhere (ADR 0011): no priority scheduling, no "importance,"
no quality opinion. Every branch is `candidates … / consider … / rebase … /
build … / merge|kickback|wait / done …` in the decision log, and every decision
reduces to a timestamp, a sha, a build state, or a file-surface intersection. The
Marshal invokes the PR Gate + `build-status`; it *is* those checks' wiring, never
a fourth checker (ADR 0003's carved-out exception).

## Running it on cadence (cron)

The Marshal is unattended, driven on the same CI-cron pattern as the ADR 0003
ambient audit. One entry, firing on a short cadence, from the shared repo's
working clone:

```cron
# Merge Marshal — one serial pass every 10 minutes.
*/10 * * * *  cd /srv/repos/<repo> && \
  /path/to/plugins/marshal/scripts/marshal.sh >> /var/log/marshal.log 2>&1
```

Cold builds bound throughput (ADR 0010's accepted residual: ~3 merges/hour at
~20-minute builds); a shorter cron cadence does not speed a single build, it just
re-checks a waiting composition sooner. Each fire is stateless — it re-derives the
queue and the post-rebase sha from the host and git, so a missed or overlapping
fire is harmless.

## Environment knobs

| Var | Default | Meaning |
|---|---|---|
| `MARSHAL_HOST` | sibling `autopilot/scripts/host.sh` | host adapter entrypoint |
| `MARSHAL_MAIN` | `main` | trunk branch |
| `MARSHAL_REBASE_FILE_BUDGET` | `2` | D7.0 file budget |
| `MARSHAL_REBASE_HUNK_BUDGET` | `3` | D7.0 hunk budget |
| `MARSHAL_HOTFIX_PIN` | — | PR number to pin to the head (Force Audit) |
| `MARSHAL_FORCE_AUDIT_LOG` | `.marshal/force-audit.log` | Force Audit path |
| `MARSHAL_MERGE_STRATEGY` | host default | `pr-merge --strategy` |
| `MARSHAL_BUILD_POLL_MAX` | `30` | build-status poll attempts |
| `MARSHAL_BUILD_POLL_INTERVAL` | `20` | seconds between polls (tests use `0`) |
| `MARSHAL_ACTOR` | `$USER` | actor recorded in the Force Audit |
| `MARSHAL_NOW` | — | epoch override for the Force Audit timestamp (tests) |
