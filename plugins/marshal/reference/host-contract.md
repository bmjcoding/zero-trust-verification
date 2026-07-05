# The host adapter surface the Merge Marshal drives

The Marshal is host-agnostic by contract (ADR 0013): it issues **every** PR and
build operation as `host.sh <subcommand>` and never branches on the host. It
drives exactly one adapter entrypoint — `$MARSHAL_HOST`, which defaults to the
sibling `autopilot/scripts/host.sh` — and works unchanged on GitHub, Bitbucket
Data Center, or the hermetic mock (`scripts/mock_host.py`).

## Subcommands the Marshal calls

All but the first already ship in `host.sh` / `github.sh` / `bitbucket.sh` on
main (the AV3-15 host adapter). The Marshal uses:

| Subcommand | Direction | Used for |
|---|---|---|
| `pr-list-ready` | **NEW — see below** | enumerate the queue (FIFO + approval) |
| `build-status --sha <sha>` | existing | composed-state verification on the post-rebase head |
| `pr-comment --num <n> --body-file <path>` | existing | kickback comments (budget / conflict / Composition Break) |
| `pr-merge --num <n> [--strategy <s>]` | existing | the merge (smallest write scope, with rebase-push) |

The Marshal deliberately does **not** call `pr-open`, `pr-ready`, `pr-approve`,
or `pr-decline` in the merge path — its write scope is rebase-push + merge only
(ADR 0011). Rebase-push is a plain `git push --force-with-lease` to the PR's
source branch, not a host subcommand.

## The one new primitive: `pr-list-ready`

The queue cannot be enumerated with the adapter's current surface — `pr-state`
answers only for a PR you already name, and there is no way to list ready PRs,
read their ready-for-review timestamp, or read their approval state. FIFO by
ready-for-review timestamp over *approved* PRs (ADR 0010, step 1) needs all
three. So the Marshal requires one new host subcommand:

```
pr-list-ready
  -> TSV on stdout, one ready PR per line, columns TAB-separated:
       <ready_ts>   integer epoch seconds of the ready-for-review transition
                    (the FIFO key; the claim lattice's terminal tier)
       <pr_num>     PR number / id
       <src_branch> source branch name
       <head_sha>   current head sha of the source branch
       <approval>   APPROVED | PENDING   (the Marshal keeps only APPROVED,
                    except a human hotfix pin, which may override)
  Selection: OPEN, non-draft (ready-for-review) PRs targeting the trunk. Draft,
  merged, and declined PRs are omitted. Order is unspecified — the Marshal sorts.
  Empty queue -> no output, exit 0.
```

### Reference backend mappings (to implement on main)

- **GitHub (`github.sh`)** — `gh pr list --state open --draft=false --base <trunk>
  --json number,headRefName,headRefOid,reviewDecision,...`. `reviewDecision ==
  "APPROVED"` → `APPROVED`, else `PENDING`. The ready-for-review timestamp is the
  most recent `ReadyForReviewEvent` (GraphQL `timelineItems`), falling back to
  `createdAt` for PRs opened non-draft.
- **Bitbucket DC (`bitbucket.sh`)** — `GET /rest/api/1.0/projects/{k}/repos/{s}/
  pull-requests?state=OPEN&order=NEWEST&withProperties=false`. Approval is
  `reviewers[].approved` (all required reviewers approved → `APPROVED`). Honour
  the same `AUTOPILOT_BITBUCKET_DRAFT_MODE` (native `draft` flag / `[DRAFT] `
  title prefix) the other subcommands use to exclude drafts. Ready timestamp:
  the draft→ready transition, falling back to `createdDate`.

## Status of `pr-list-ready` on main (READ THIS)

`pr-list-ready` is **not yet on main.** This plugin ships:

1. the **canonical spec** (this file), and
2. a **reference implementation in the hermetic mock** (`scripts/mock_host.py`),
   which is what the self-test drives.

Adding `pr-list-ready` to `host.sh` + `github.sh` + `bitbucket.sh` — matching
this contract byte-for-byte in its observable output, and covered by the T01-
class mock matrix in `autopilot/scripts/self_test.sh` for both backends — is a
follow-up in the autopilot host-adapter, deliberately kept out of this plugin's
diff to preserve the AV3-15 adapter's byte-identical backend guarantees. This
mirrors how ADR 0009's claim-overlap check is authored canonically here and
vendored into its consumers under a byte-identity lint. Until that lands, the
Marshal runs end-to-end only against the mock (and any host whose adapter
implements `pr-list-ready`).
