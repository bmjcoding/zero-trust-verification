# The host adapter surface the Merge Marshal drives

The Marshal is host-agnostic by contract (ADR 0013): it issues **every** PR
and build operation as `host.sh <subcommand>` and never branches on the host.
It drives exactly one adapter entrypoint — `$MARSHAL_HOST`, defaulting to the
sibling `skills/autopilot/scripts/host.sh` — and works unchanged on GitHub,
Bitbucket Data Center, or the hermetic mock (`scripts/mock_host.py`).

## Subcommands the Marshal calls

| Subcommand | Used for |
|---|---|
| `pr-list-ready` | enumerate the queue (FIFO + approval) — defined below |
| `build-status --sha <sha>` | composed-state verification on the post-rebase head |
| `pr-comment --num <n> --body-file <path>` | kickback comments (budget / conflict / Composition Break) |
| `pr-merge --num <n> [--strategy <s>]` | the merge (smallest write scope, with rebase-push) |
| `repo-list --org <org>` | org repo enumeration (org-memory OWM-09, ADR 0028) — **not** a Marshal call; defined below |

The Marshal deliberately does **not** call `pr-open`, `pr-ready`,
`pr-approve`, or `pr-decline` in the merge path — its write scope is
rebase-push + merge only (ADR 0011). Rebase-push is a plain
`git push --force-with-lease` to the PR's source branch, not a host
subcommand.

## `pr-list-ready`

FIFO by ready-for-review timestamp over *approved* PRs (ADR 0010, step 1)
needs three things `pr-state` cannot give (it answers only for a PR you
already name): a listing, the ready timestamp, and the approval state. Hence
this contract:

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
`$AUTOPILOT_TRUNK` → the repo's default branch. Set `$AUTOPILOT_TRUNK` only
when the merge trunk is not the default branch.

- **GitHub (`github.sh`)** — `gh pr list --state open --base <trunk>
  --json number,headRefName,headRefOid,reviewDecision,createdAt,isDraft`;
  drafts excluded client-side on `isDraft` (`gh --draft` filters to
  drafts-ONLY, not the inverse). `reviewDecision == "APPROVED"` → `APPROVED`,
  else `PENDING`. Ready timestamp: the most recent `ReadyForReviewEvent`
  (GraphQL `timelineItems`, one lookup per PR), falling back to `createdAt`
  for PRs opened non-draft; ISO→epoch in `jq` (`strptime|mktime`, UTC) for
  BSD/GNU stability.
- **Bitbucket DC (`bitbucket.sh`)** — paginated `GET /rest/api/1.0/projects/
  {k}/repos/{s}/pull-requests?state=OPEN&order=NEWEST&withProperties=false`,
  filtered client-side to `toRef == <trunk>`. Approval is
  `reviewers[].approved` (≥1 reviewer and ALL approved → `APPROVED`, else
  `PENDING`). Drafts excluded via `AUTOPILOT_BITBUCKET_DRAFT_MODE` (native
  `draft` flag / `[DRAFT] ` title prefix). Ready timestamp: `createdDate`
  (epoch millis ÷ 1000) — DC's REST surface exposes no draft→ready
  transition timestamp, so `createdDate` is the contract's documented
  fallback for this backend.

`pr-list-ready` ships across `host.sh` + `github.sh` + `bitbucket.sh`,
covered by the real-backend contract matrix in
`skills/autopilot/scripts/self_test.sh` and the end-to-end marshal run in
this plugin's `scripts/self_test_marshal.sh` (section `MG`); the hermetic mock
(`scripts/mock_host.py`) is the canonical reference implementation.

## `repo-list` (org enumeration — ADR 0028)

Org-memory's optional enumeration primitive (OWM-09), implemented by both
backends behind the same `host.sh` surface — never a parallel transport.
Not called by the Marshal.

```
repo-list --org <org>
  -> TSV on stdout, one repository per line, columns TAB-separated:
       <slug>              repository slug/name
       <clone-or-api-url>  ssh clone link preferred, else the first clone/api link
  --org is REQUIRED: the GitHub organization login / Bitbucket DC project key.
  Repo coordinates are NOT derived (--org is the target), so repo-list runs
  outside a repo when $AUTOPILOT_HOST_BACKEND steers backend detection; on
  Bitbucket DC a REST host is still required (origin-derived, or
  $AUTOPILOT_BITBUCKET_HOST / sidecar) — with no host source it dies
  LAST_STATE=no-host-source.
  Empty org -> no output, exit 0. Failure = die_state: LAST_STATE + reason on
  stderr, exit 1 — NEVER an empty TSV masquerading as an empty org.
```

Backend mappings: **GitHub** — `gh api --paginate /orgs/<org>/repos` (`gh repo
list` has no `--paginate`); gh owns credentials, its exit status and stderr are
surfaced. **Bitbucket DC** — paginated `GET /rest/api/1.0/projects/<org>/repos`
through `bb_curl` (secret resolver chain, `-H @file` — the token is never on
curl's argv) with the `has()`-guarded `isLastPage`/`nextPageStart` cursor.
Covered by the contract matrix + `HD14`/`HG34`–`HG36`/`HR01`–`HR04` in
`skills/autopilot/scripts/self_test.sh` and OWM-09 in
`scripts/self_test_org_memory.sh`.
