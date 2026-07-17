# Outcome store contract (single source; ADR 0023)

The outcome store (`outcome/outcomes.json`) is written by TWO producers — the
Marshal `outcome-capture` / digest modes and the codebase-health audit
`outcome-emit` step. They MUST agree on what a stored row means and on how the
renderer badges it, or the two would drift and a reader could be misled about an
agent-graded number's honesty. This file is the SINGLE copy of that contract
(ADR 0030): each producer's reference cites it instead of vendoring it, and the
lint V11 tripwire catches any re-vendored block copy (byte-identity or red). The
JSON Schema `schema/outcome/v1.schema.json` is the structural source of truth,
validated by the manifest's jsonschema toolchain (ADR 0014); any schema copy that
reappears in the tree must be byte-identical to it (V11).

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
  NOTHING is model-estimated. The schema BINDS each metric name to its class
  (`emission_share` => `agent-graded`; the four classic DORA delivery metrics
  (2021 taxonomy; the fifth — operational reliability — is deliberately out of
  scope: not deterministically derivable from git/host data) => `deterministic`; the
  external metrics => `deterministic`|`human-annotated`), so a row that is UNLABELED
  **or MISLABELED** (a laundered class) is schema-invalid — neither can enter the
  store, and the renderer badges a known metric by its authoritative class, never the
  stored string.
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

## Producers and honesty classes

| Metric | Producer | Honesty class | [det] slice / residual |
|---|---|---|---|
| deploy_frequency, lead_time, change_failure_rate, mttr_build | Marshal `outcome-capture` | deterministic | `[det]` on a fixture; `[drain]` on a live host |
| emission_share | audit `outcome-emit` | agent-graded | projection arithmetic `[det]`; real-repo number `[audit-run]` |
| defect_escape_rate | `outcome_external.sh` / `outcome_annotate.sh` | deterministic (from source) or human-annotated | `[det]` on a fixture source; else `[OUTCOME-SOURCE-ABSENT]` |
| incident_count, mttr_incident, paged_share | `outcome_external.sh` / `outcome_annotate.sh` | deterministic (from source) or human-annotated | external (ADR 0006); `[OUTCOME-SOURCE-ABSENT]` when unconfigured |
