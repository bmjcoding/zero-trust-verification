# Manifest-bearing specs drain straight through; the GENERATE review pause is the degrade path

---
status: accepted
date: 2026-07-03
---

The GENERATE→review→DRAIN pause existed because input specs were unvetted; in practice Bailey only ever uses `--yolo`. With the spec tier upstream (adversarial rounds, escalation rule, `[SPEC-INCOMPLETE]` refuse-to-finalize), vetting has shifted left — re-reviewing a manifest-complete spec at GENERATE time is the rubber-stamping ADR 0002 abolished. Therefore: **input with a valid, complete Verification Manifest (schema_version pinned, no unconfirmed required fields) drains straight through in a single invocation** — no flag needed, no pause. The review pause remains ONLY for manifest-less input (arbitrary markdown), where autopilot is the first gate the work has ever met. `--yolo` survives solely as the manifest-less override, logged to Force Audit.

## Consequences

- The mode table simplifies: mode is inferred from the input artifact (manifest-complete spec → straight-through; bare markdown → GENERATE+pause; runbook → drain/resume).
- The safety argument moves upstream: the spec tier's refusal gate is now load-bearing for autonomous drains, which is exactly the zero-trust intent — verify at the source, not repeatedly downstream.
