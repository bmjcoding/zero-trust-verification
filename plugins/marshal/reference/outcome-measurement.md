# Outcome measurement modes (Marshal side; ADR 0023, report-only)

The Marshal hosts two report-only outcome modes (a first-arg dispatch before any
merge-pass setup, so the no-arg pass is unchanged):

- `marshal.sh outcome-capture` (OM-03) — derives the four DORA-family metrics
  Class-D over a trailing window (deploy-freq / lead-time from `git log`;
  change-failure via reverts + `host build-status`; build-MTTR via `build-status`),
  routes build-status through the host adapter (ADR 0013), appends ONE runs[] row.
  Read-only on the target + on every PR; opens no PR, files no finding.
- `marshal.sh outcome-digest` (OM-08) — an added per-fire step on the Marshal's
  EXISTING single-fire cron entry (see `marshal-loop.md`): capture + (emit IF a
  journeys.json exists, read-only, NO fresh audit) + render, posted via the
  Marshal host write scope OR an artifact. Exits 0 always.

The store contract below is vendored VERBATIM from
`docs/specs/outcome-store-contract.md` (pinned byte-identical by lint V11) so the
Marshal and the audit never drift on what a stored row means.

<!-- vendored:outcome-store-contract:begin -->
Store shape (schema_version 1): append-only `runs[]` + one frozen `baseline`.

Every metric row carries, MANDATORY:
- `name` — the metric id (deploy_frequency, lead_time, change_failure_rate,
  mttr_build, emission_share, defect_escape_rate, incident_count, mttr_incident,
  paged_share).
- `honesty_class` — one of exactly THREE values:
    - `deterministic`   (Class-D): git-log / host build-status provable, no agent.
    - `agent-graded`    (Class-A): input is journeys.json, written by the
      journey-walker AGENT — NOT hermetic; the projection arithmetic over a fixed
      fixture is [det], the number on a real repo is [audit-run].
    - `human-annotated`: an operator-entered external fact.
  NOTHING is model-estimated. A row without `honesty_class` is schema-invalid — no
  unlabeled number can enter the store.
- `provenance` — a non-empty string naming the derivation (e.g. `git-log ...`,
  `journeys.json@<sha>`, `external-tracker:<file>`, `annotated:operator (...)`).

Optional: `value` (number | null; ABSENT/null means "no comparable value", NEVER
read as 0), `unit`, `detail`, `note`, `source_absent`.

Renderer badge mapping (the honesty badge is NOT droppable):
- `deterministic`   -> `[det]`
- `agent-graded`    -> `[agent-graded]`   (a Class-A row can NEVER render `[det]`)
- `human-annotated` -> `[annotated]`

Degrade (mirrors state.json): absent store -> first observation; corrupt / unknown
schema_version -> refuse to write, report, NEVER overwrite; frozen baseline present
-> deltas computed against it; no frozen baseline -> [OUTCOME-NO-BASELINE], absolute
only. Report-only permanently (ADR 0004): no gate, no hook, opens no PR, files no
finding, triggers no drain / fresh audit; every scheduled path exits 0.
<!-- vendored:outcome-store-contract:end -->
