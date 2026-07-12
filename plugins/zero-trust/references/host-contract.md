# The host adapter surface the Merge Marshal drives

The Marshal is host-agnostic by contract (ADR 0013): it issues **every** PR and
build operation as `host.sh <subcommand>` and never branches on the host. It
drives exactly one adapter entrypoint — `$MARSHAL_HOST`, which defaults to the
sibling `skills/autopilot/scripts/host.sh` (same plugin) — and works unchanged on GitHub, Bitbucket
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

### Reference backend mappings

Trunk resolution is shared by both backends: `--base <b>` (explicit) →
`$AUTOPILOT_TRUNK` → the repo's default branch. The Marshal need not pass a base;
set `$AUTOPILOT_TRUNK` only when the merge trunk is not the default branch.

- **GitHub (`github.sh`)** — `gh pr list --state open --base <trunk>
  --json number,headRefName,headRefOid,reviewDecision,createdAt,isDraft`; drafts
  are excluded client-side on `isDraft` (`gh --draft` filters to drafts-ONLY, not
  the inverse). `reviewDecision == "APPROVED"` → `APPROVED`, else `PENDING`. The
  ready-for-review timestamp is the most recent `ReadyForReviewEvent` (GraphQL
  `timelineItems`, one lookup per PR), falling back to `createdAt` for PRs opened
  non-draft; ISO→epoch is done in `jq` (`strptime|mktime`, UTC) for BSD/GNU
  stability.
- **Bitbucket DC (`bitbucket.sh`)** — paginated `GET /rest/api/1.0/projects/{k}/
  repos/{s}/pull-requests?state=OPEN&order=NEWEST&withProperties=false`, filtered
  client-side to `toRef == <trunk>`. Approval is `reviewers[].approved` (≥1
  reviewer and ALL approved → `APPROVED`, else `PENDING`). Drafts are excluded via
  `AUTOPILOT_BITBUCKET_DRAFT_MODE` (native `draft` flag / `[DRAFT] ` title prefix).
  Ready timestamp: `createdDate` (epoch millis ÷ 1000) — DC's REST surface exposes
  no draft→ready transition timestamp, so `createdDate` is the contract's
  documented fallback for this backend.

## Status of `pr-list-ready` on main

`pr-list-ready` is **implemented on main** across `host.sh` + `github.sh` +
`bitbucket.sh`, matching this contract in its observable output and covered by a
real-backend contract matrix in `skills/autopilot/scripts/self_test.sh` (gh argv shim
for GitHub, the loopback DC mock server for Bitbucket) plus an end-to-end
`marshal.sh`-through-`github.sh` run in this plugin's `scripts/self_test.sh`
(section `MG`). The hermetic mock (`scripts/mock_host.py`) remains the canonical
reference implementation the Marshal loop's own self-test drives. The Marshal
therefore runs end-to-end against GitHub, Bitbucket DC, and the mock alike.
