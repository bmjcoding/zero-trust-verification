# marshal — the Merge Marshal

A serial, deterministic **composed-state merge backstop** for any ordinary shared
repo. The fourth Zero-Trust Verification plugin (ADR 0011), installable entirely
on its own: claims plus serial merge safety, with zero Bazel, zero autopilot, zero
spec tier.

## Status

v0.1.0 (2026-07-05), beta. The deterministic substrate (`scripts/`) is covered by
an executed hermetic self-test (`scripts/self_test.sh`, 62 assertions) that drives
the whole loop through a mock host backend. One host primitive it needs
(`pr-list-ready`) is specified here and implemented in the mock; wiring it into the
real GitHub / Bitbucket DC adapters is a tracked follow-up — see
[`reference/host-contract.md`](reference/host-contract.md).

## Why a merge queue still exists

Shift-left conflict avoidance — derived ownership claims (ADR 0009) and 48-hour
Story sizing (ADR 0012) — can fully prevent **Textual Conflicts** (two branches
edit overlapping hunks). It cannot prevent **Composition Breaks**: two branches
that merge cleanly yet are broken *together* — a rename lands on one branch while
another adds a call site to the old name; each is green against its own fork
point, red once composed. The only deterministic verifier of the composed state is
building and testing the composed state.

So the queue is not eliminated; it is reduced to its irreducible job and named the
**Merge Marshal** (ADR 0010): build the composed state on the post-rebase head,
and merge only what that build proves green. Shift-left makes the Marshal *boring*,
not *absent*.

## What it does — one serial pass

1. **List** ready, approved PRs via the host adapter; order them **strict FIFO by
   ready-for-review timestamp**.
2. **Rebase** the head PR onto the current trunk — **or refuse** per the D7.0
   file/hunk budget (an oversized or conflicting rebase is a planning failure,
   kicked back with a comment, not fixed at merge time).
3. **Verify the composed state**: `build-status` on the **post-rebase sha**.
4. **Green → merge. Red → comment, evict, next in line.** One PR in flight; no
   speculation, no batching. The only override is a human hotfix pin, logged to
   the Force Audit.

The full state machine, the cron entry, and every environment knob are in
[`reference/marshal-loop.md`](reference/marshal-loop.md).

## Wiring, not a checker

The Marshal holds **no quality opinion** (ADR 0011). It invokes the PR Gate and
`build-status` and never forms its own judgment — so there is no fourth checker to
keep consistent (it is ADR 0003's carved-out exception made concrete). Every
decision is a **timestamp, a sha, a build state, or a file-surface intersection** —
all git/API-provable, no agent judgment anywhere in the merge path. Its write
scope is the smallest possible: rebase-push and merge, nothing else.

## Host-agnostic

Every PR/build operation goes through one adapter entrypoint (`host.sh`, ADR
0013), so the loop is identical on GitHub and Bitbucket Data Center — and on the
hermetic mock. A new host is a new backend, never a new caller path. See
[`reference/host-contract.md`](reference/host-contract.md) for the exact surface.

## What's in the box

| Path | Role |
|---|---|
| `scripts/marshal.sh` | the serial backstop loop (ADR 0010/0011) |
| `scripts/claim_overlap.sh` | the vendored claim-overlap check (ADR 0009) — **byte-identical** with autopilot's copy; canonical source (autopilot has none on main yet) |
| `scripts/branch_age_watcher.sh` | the 48h staleness / planning-failure watcher (ADR 0012/0009) |
| `scripts/mock_host.py` + `mock_host.sh` | the hermetic mock host backend (Python via `uv`, ADR 0015) |
| `scripts/self_test.sh` | the hermetic self-test |
| `commands/marshal-pass.md` | `/marshal-pass` — run one serial pass by hand |
| `commands/marshal-staleness.md` | `/marshal-staleness` — the branch-age + claim-overlap sweep |
| `reference/*.md` | loop semantics + host contract |

## Usage

Cron drives it unattended (see `reference/marshal-loop.md`). To run one pass by
hand from the shared repo's working clone:

```bash
bash /path/to/plugins/marshal/scripts/marshal.sh
```

or `/marshal-pass` inside Claude Code. A human hotfix pin:

```bash
MARSHAL_HOTFIX_PIN=1234 bash …/scripts/marshal.sh   # logged to the Force Audit
```

The vendored kernels run standalone too:

```bash
# contended files across open PRs (feed "<pr-id>\t<file>" pairs)
bash scripts/claim_overlap.sh < claims.tsv
# branches past the 48h ceiling
bash scripts/branch_age_watcher.sh --refs 'refs/heads/story/*' --max-age-hours 48
```

## Tests

```bash
bash plugins/marshal/scripts/self_test.sh
```

Hermetic: a `mktemp -d` sandbox with local **bare** repos standing in for
`origin`, driving the loop through the mock host across FIFO / rebase-refuse
(budget and conflict) / compose-verify (green, red Composition Break, in-progress
wait) / merge-or-evict / hotfix-pin scenarios, plus claim-overlap and branch-age
fixtures. No network, no credentials, no writes outside the sandbox. The loop
sections require `uv` (ADR 0015); the pure kernels run with no external deps.

## Design

- ADR 0010 — the Merge Marshal serial backstop
- ADR 0011 — the Marshal as the fourth plugin (wiring, not a checker)
- ADR 0009 — derived ownership claims (the claim-overlap check)
- ADR 0012 — trunk-based Story sizing (the 48h branch-age watcher)
- ADR 0013 — host-agnostic autopilot (the host adapter)
- ADR 0015 — shell + Python-on-uv substrate

## License

MIT.
