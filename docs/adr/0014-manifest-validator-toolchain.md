# Manifest validator toolchain: Python + ruamel.yaml (YAML 1.2) + jsonschema

---
status: accepted
date: 2026-07-04
---

The Verification Manifest validator is built in Python 3 with **ruamel.yaml** (YAML 1.2 core-schema parsing) and **jsonschema** (reference Draft validator), pinned in `requirements-dev.txt` and isolated in a project-local venv. `scripts/validate_manifest.sh` is a thin bash wrapper preserving the suite's shell exit-code contract (0/3/4/5); `scripts/validate_manifest.py` holds the logic so it is unit-testable. The JSON Schema file (`schema/verification-manifest/v1.schema.json`) is the single structural source of truth, validated by jsonschema — no hand-rolled structural checks that could drift from it.

## Considered Options

- **PyYAML** — rejected: it implements YAML 1.1, which coerces `no`/`on`/`yes` to booleans. The manifest spec (§2) mandates a YAML 1.2 core-schema parser precisely so a boolean in an enum position is a schema error, not a silent coercion (the Norway-problem guard). PyYAML would make that guard a no-op.
- **Pure-stdlib (json module + hand-rolled structural checks)** — rejected: YAML has no stdlib parser, and hand-rolling structural validation duplicates the JSON Schema and invites schema-vs-validator drift — the exact C-class contradiction the suite exists to prevent.
- **Node + ajv** — viable, but python3 is already the suite baseline (autopilot's mock server); adding a second language runtime to the shared substrate is avoidable cost.

## Consequences

- Dev dependency footprint grows by two pip packages, pinned and venv-isolated; the self-test bootstraps the venv, matching how codebase-health pins jscpd.
- Discovered while implementing (applied as manifest-spec amendment **MS-AMEND-4**, approved 2026-07-04): manifest spec §2's validation-layering list enumerated the schema's structural scope but did not explicitly exclude the PRESENCE conditionals (`alert_seam.default`/`event_name`/`required_emission` on a non-null vital step; `idempotency` on a money/external-side-effect step), so an implementer could reasonably have encoded them as JSON-Schema constraints — which would make a manifest missing them *schema-invalid* (exit 4) instead of *incomplete* (exit 3), breaking the resumable-incomplete guarantee. Those are completeness rules 1–2 and belong in the validator. Authoritative resolution (now written into §2): the schema enforces only structural shape, the ID/enum/type constraints, `spec_hash`-iff-complete, `incomplete_fields`-iff-incomplete, and the ABSENCE-when-null constraints (§4); all presence requirements are validator rules. Reconciled into the manifest spec in this same PR.
