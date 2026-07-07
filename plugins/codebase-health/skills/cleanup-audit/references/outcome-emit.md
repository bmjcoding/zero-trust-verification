# Outcome emission-share step (audit side; ADR 0023, OM-04, report-only)

`scripts/outcome_emit.sh` projects the LAST `journeys.json` the journey-walker
AGENT produced into the suite-unique metric: on CORE journeys, the share of
money/auth vital steps graded OBSERVED (vs LOG-ONLY / DARK). Because the input is
agent judgment, every emitted row is `honesty_class: agent-graded` with provenance
`journeys.json@<sha>` — it can NEVER be laundered as `[det]`. The step is a
projection of grades already recorded: it does NOT re-walk, does NOT trigger a
fresh audit (H6), is READ-ONLY on the target, writes ONLY the store, and posts
NOTHING (H5). It emits NO alert_seam / paged-share (H2 — alert seams are external,
ADR 0006). Absent / corrupt / unknown-schema journeys.json -> a loud [note] + no
row, exit 0.

The store contract below is vendored VERBATIM from
`docs/specs/outcome-store-contract.md` (pinned byte-identical by lint V11) so the
audit and the Marshal never drift on what a stored row means.

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
