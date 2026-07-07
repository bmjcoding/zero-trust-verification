---
description: Triage a fired production incident into a resumable incident-Spec. Probe a vendor-neutral telemetry backend, take a BOUNDED window, drop self-emitted events, correlate the runtime event_name to the Verification Manifest's journey + behavior IDs (§12 key, DERIVED), and emit a completeness:incomplete incident-Spec for spec-gen's RESUME path as a DRAFT PR proposal. Read-only; never a patch; never an auto-merge.
argument-hint: "--since <ts> --until <ts> [--service S] [--event E] --manifest <path>"
---

# /triage

Run the production-telemetry triage flow (register `docs/specs/prod-triage-register.md`;
governing ADR 0020). Load the `triage` skill and follow it exactly.

**This is a SOURCE feeding the ADLC left edge, not a Tier and not a checker.** The
deliverable is a **Spec, not a patch**: an incident becomes a `completeness:incomplete`
manifest that re-enters spec-gen's resume path, drafted as a PR PROPOSAL for human
review (report-only first, ADR 0020). It never mutates prod, never authors a fix,
never auto-merges.

## Steps (the skill drives these; each honors a hard invariant)

1. `scripts/telemetry.sh backend` — resolve the backend (external-fact escalation if
   unset — never guess a telemetry vendor). `telemetry.sh probe` for reachability.
2. `scripts/telemetry.sh window --since <ts> --until <ts> [--service S] [--event E]`
   — a BOUNDED, scoped window only. The guard REFUSES an absent/oversized/unscoped
   window (never a whole-fleet scan).
3. `scripts/loop_guard.py exclude-self --window -` — drop self-emitted records.
4. `scripts/correlate.py --window - --manifest <m>` — join on `event_name`, DERIVE
   the journey (not a backref — CH-02 unbuilt), surface class-drift / unmapped-in-prod,
   bucket DARK-in-prod, treat a windowless CORE step as informational only.
5. `scripts/profile_resume.sh resolve --manifest <m>` — resume the profile (reuse).
6. `scripts/emit_incident_spec.py` — from a CONFIDENT join, emit the incident-Spec
   referencing EXISTING behavior IDs (mint none); REFUSE a no-join; honor the
   open-incident dedupe.
7. `scripts/resume_handoff.sh` — prove the manifest is resumable-incomplete
   (validator exit 3) and open the DRAFT PR proposal.

Degrade to LESS action on any gap (no manifest / unknown profile / empty window):
say so, escalate the gap, and do not fabricate a join.
