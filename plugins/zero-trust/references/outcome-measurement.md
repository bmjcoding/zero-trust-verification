# Outcome measurement modes (Marshal side; ADR 0023, report-only)

The Marshal hosts two report-only outcome modes (a first-arg dispatch before any
merge-pass setup, so the no-arg pass is unchanged):

- `marshal.sh outcome-capture` (OM-03) — derives the four classic DORA delivery
  metrics (2021 taxonomy; the fifth — operational reliability — is deliberately
  out of scope: not deterministically derivable from git/host data)
  Class-D over a trailing window (deploy-freq / lead-time from `git log`;
  change-failure via reverts + `host build-status`; build-MTTR via `build-status`),
  routes build-status through the host adapter (ADR 0013), appends ONE runs[] row.
  Read-only on the target + on every PR; opens no PR, files no finding.
- `marshal.sh outcome-digest` (OM-08) — an added per-fire step on the Marshal's
  EXISTING single-fire cron entry (see `marshal-loop.md`): capture + (emit IF a
  journeys.json exists, read-only, NO fresh audit) + render, posted via the
  Marshal host write scope OR an artifact. Exits 0 always.

The store contract is `docs/specs/outcome-store-contract.md` (the single canonical
copy, ADR 0030): row schema (name / honesty_class / provenance), the three honesty
classes and their renderer badges, and the append-only + degrade rules all live
there — lint V11 stands tripwire against any re-vendored copy.
