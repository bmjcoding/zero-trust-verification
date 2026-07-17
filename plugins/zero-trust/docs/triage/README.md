# triage — Production-Telemetry Triage

> The sixth Zero-Trust Verification plugin (register `docs/specs/prod-triage-register.md`,
> ADR 0020). A read-only, bounded-window **source** that turns an emitted production
> incident into a resumable **incident-Spec** feeding spec-gen's RESUME path.

This is **not a fourth Tier** (CONTEXT.md fixes *Tier* at three) and **not a new
quality opinion**. It is a new SOURCE feeding the ADLC left edge — the way a
human-authored incident report already can. Prod telemetry becomes a first-class
*input* to spec generation.

## What it does

```
telemetry.sh window (BOUNDED) → loop_guard exclude-self → correlate (§12 event_name)
   → profile_resume → emit_incident_spec (completeness: incomplete) → resume_handoff (DRAFT PR)
```

An emitted vital is correlated to the Verification Manifest's journey + behavior IDs
via the §12 `event_name` join key (the journey is **DERIVED** from the match, not read
from a backref — telemetry carries none; when an audit-produced journeys.json v2 is
supplied via `--journeys`, its CH-02 backref is cross-checked, ADR 0029). A confident
join becomes a partial, `completeness: incomplete` manifest that
references EXISTING behavior IDs (minting none) and re-enters spec-gen's resume path
as a DRAFT PR **proposal** for human review.

## Hard invariants (release blockers)

- **read-only** on prod and on the repo target; writes one artifact class + a DRAFT PR.
- **Spec, not a patch** — never a fix, never an auto-merge, never merge-blocking
  (report-only first, ADR 0020).
- **vendor-neutral** — backends behind one `telemetry.sh`; default OTEL/OTLP-JSON;
  CloudWatch/Dynatrace are backend selections, never caller branches.
- **bounded-window only** — a mechanical guard refuses an absent/oversized/unscoped
  window (never a full-retention or whole-fleet scan).
- **no self-ingestion** — self-emitted events are excluded; a second incident-Spec is
  suppressed while a prior one's PR is still open.
- **degrade to less action** — no manifest / unknown profile / empty window → say so,
  escalate the gap, never fabricate a join.

## Backends

Select with `$TRIAGE_TELEMETRY_BACKEND` (`OTEL_FILE | CLOUDWATCH | DYNATRACE`) or
`triage.config.yaml telemetry.backend`. If neither is set the tier REFUSES — a
telemetry vendor is an external fact (ADR 0002), never guessed. See
`references/telemetry-contract.md` (the single-source observable contract, lint V9)
and `references/backends.md`.

## Install & standalone

Independently installable: ships its own `.claude-plugin/plugin.json` and vendors the
canonical `validate_manifest` toolchain + manifest schema (byte-identical, lint V1/V3)
and the spec-gen `profile_resolve.py` / `resume_projection.py`. The host adapter is
reused via `$TRIAGE_HOST` (default: the sibling autopilot `host.sh`); Python runs
through `uv` against the repo `pyproject.toml`, falling back to an ambient `python3`
with the deps (ADR 0015).

## Self-test

```
bash plugins/zero-trust/scripts/self_test_triage.sh
```

Hermetic on the OTLP-JSON default backend (the default IS the test backend). Every
`[det]` acceptance is grep/fixture/exit-code provable; the CloudWatch/Dynatrace
backends are jsonschema-asserted from canned responses (no live call); live queries,
join precision on real incidents, and agent judgment are honest `[drain]` residuals.
