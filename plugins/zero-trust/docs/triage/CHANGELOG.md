# Changelog — triage (Production-Telemetry Triage)

All notable changes to this plugin are documented here.

## Unreleased — Config Profiles removed (2026-07-21, ADR 0033)

TR-04's vendored-resolver acceptance path is deleted with the Config Profile
seam (ADR 0033): the run has no profile step, no `profile_resolve.py` /
`profile_resume.sh` calls, and no profile severity floor — incident severity
is purely evidence-derived (CH-08). Telemetry *adapter* selection (TR-01,
env/config-selected per deployment, ADR 0020) is unchanged.
`observability.profile` in a manifest is accepted and ignored.

## Unreleased — backref cross-check runs when given the audit artifact (2026-07-17, ADR 0029)

The 0.1.0 entry below records "CH-02 unbuilt" — false at its own merge (CH-02
shipped 2026-07-05; see ADR 0029 and the dated correction in
`docs/specs/prod-triage-register.md`). `correlate.py` now takes an optional
`--journeys <path>`: provided with an audit-produced journeys.json v2, the
backref cross-check RUNS — `agreed` / `disagreed` (contradicted ids named;
a spec-legal ABSENT backref is v2-optional and never a disagreement, MS §12
row 1) — and absent (the common prod-triage case), malformed, wrong-shaped,
or backref-less input reports `skipped` with the honest reason, never
"unbuilt". The result stays `{status, note}` (schema unchanged).

## 0.1.0 — initial release (register `docs/specs/prod-triage-register.md`, ADR 0020)

The sixth independently installable plugin: a read-only, bounded-window SOURCE that
turns an emitted production incident into a resumable incident-Spec feeding spec-gen's
RESUME path. NOT a fourth Tier, NOT a new quality opinion — wiring at the ADLC left edge.

- **TR-01** vendor-neutral `telemetry.sh` adapter surface (`backend`/`probe`/`window`)
  with a mechanical BOUNDED-WINDOW guard (absent/oversized/unscoped window → REFUSE —
  the mutation-testing cost analog). Backends: `otel_file` (default, hermetic OTLP-JSON),
  `cloudwatch` (Logs Insights), `dynatrace` (Grail/DQL) — selections behind one surface,
  each producing schema-valid TR-02 from canned fixtures. Secrets via `secret_get.sh`
  on the live path only.
- **TR-02** vendored `incident-window.schema.json` carrying the §12 discovered-side field
  names verbatim (`event_name` join key) plus `emitter`; env-reserved-set + `vital_class`
  Norway-guards; a record missing `event_name` validates but buckets DARK-in-prod.
- **TR-loop-guard** self-emitter exclusion + open-incident dedupe (timestamp-free key;
  `host.sh pr-state` on a triage-owned ledger catches a still-DRAFT incident-Spec).
- **TR-03** incident↔manifest correlation on the §12 `event_name` key, journey DERIVED
  (not a backref — CH-02 unbuilt; cross-check is a labeled [det-cond] SKIP). Reuses the
  vendored validator (exit 0/3/4/5). Idempotent, schema-versioned `correlation.json`.
- **TR-04** profile resume reusing the vendored `profile_resolve.py`; profile as a
  severity FLOOR, never a ceiling past the ladder cap.
- **TR-05** incident-Spec emitter: `completeness: incomplete` BY CONSTRUCTION (validator
  exit 3), references EXISTING behavior IDs and mints none; REFUSES a no-join; honors
  the dedupe.
- **TR-06** the triage SKILL + `/triage` command (vendors the ADR 0002 escalation block
  verbatim; agent-first, no dashboard in path).
- **TR-07** spec-gen resume handoff reusing the vendored `resume_projection.py` + a DRAFT
  PR via the vendored host adapter — report-only first (ADR 0020), never auto-merged.
- **TR-08** hermetic self-test on the OTLP-JSON default backend + lint extensions
  (V5 escalation set → five prompts, V6 → six plugins, V9 telemetry-contract byte-identity).
