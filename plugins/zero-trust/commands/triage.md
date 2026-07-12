---
description: Triage a fired production incident into a resumable incident-Spec. Probe a vendor-neutral telemetry backend, take a BOUNDED window, drop self-emitted events, correlate the runtime event_name to the Verification Manifest's journey + behavior IDs (§12 key, DERIVED), and emit a completeness:incomplete incident-Spec for spec-gen's RESUME path as a DRAFT PR proposal. Read-only; never a patch; never an auto-merge.
argument-hint: "--since <ts> --until <ts> [--service S] [--event E] --manifest <path>"
---

# /triage

Run the production-telemetry triage flow (register
`docs/specs/prod-triage-register.md`; governing ADR 0020). Load the `triage`
skill (`skills/triage/SKILL.md`) and follow it exactly — it carries the hard
invariants, the seven-step run (probe → window → loop-guard → correlate →
profile → emit → hand off, each a deterministic script call), and the
judgment boundary.

The deliverable is a **Spec, not a patch**: the incident becomes a
`completeness: incomplete` manifest that re-enters spec-gen's resume path,
drafted as a DRAFT PR proposal for human review. Never mutates prod, never
authors a fix, never auto-merges. Degrade to LESS action on any gap (no
manifest / unknown profile / empty window): say so, escalate the gap, and do
not fabricate a join.
