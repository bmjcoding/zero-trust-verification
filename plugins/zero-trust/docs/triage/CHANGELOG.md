# Changelog — triage (Production-Telemetry Triage)

All notable changes to this plugin are documented here.

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
