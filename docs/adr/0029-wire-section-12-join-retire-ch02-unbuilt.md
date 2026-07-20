# ADR 0029 — The §12 join fires when its inputs exist; the "CH-02 unbuilt" claim is retired as false

- **Status:** Agent-decided (2026-07-17; resolves the simplification review's §5 open question and the architecture review's finding #03)
- **Date:** 2026-07-17

## Context

Two composed-truth defects, verified against the live tree:

1. **The advertised manifest-coverage join never fires.** `ingest_manifest.sh`
   (CH-01, manifest→MODE token) and `manifest_join.sh/.py` (CH-03, the
   MS §12 intended↔discovered comparator) are invoked by self-tests only.
   `pr_gate.sh:140-142` prints `[not-covered] manifest-coverage (§12 join)`
   when a manifest is *absent*; when one is *present* the other facets
   (CH-05/06/09) receive it but the §12 join is never dispatched and nothing
   says so. No self-test runs `pr_gate.sh --manifest`, so the missing dispatch
   is invisible to a green suite. CH-01's own header says its MODE token
   exists for "the orchestrator" to gate facet dispatch — an orchestrator
   that exists nowhere in the tree.
2. **Triage asserts a falsehood about its sibling.** `correlate.py:89-94`
   hardcodes `backref_cross_check: skipped — "CH-02 unbuilt"`, the schema
   repeats it (`correlation.schema.json:5,:73`), and `self_test_triage.sh:259-260`
   asserts the false note verbatim. CH-02 (journeys.json v2 `manifest_journey_id`
   backref) shipped 2026-07-05 (880cc0d); the triage hardcode merged 2026-07-07
   (3d83048) — the claim was already false at its own merge.
   `verification-manifest-v1.md:287` still says "Until it ships."

A suite whose thesis is zero-trust verification must not stay green while
asserting a false composed behavior.

## Decision

**Wire it — minimally, through the existing doors.**

1. `pr_gate.sh` gates on CH-01's MODE token when a manifest is present (the
   MODE gate is load-bearing, not optional: `manifest_join.py` never
   schema-validates — CH-01 alone implements MS §11's schema-invalid-is-a-
   DEFECT row), then dispatches `manifest_join.sh` when journeys.json is also
   present, on MODE=COMPLETE only (MS §11: an incomplete manifest is treated
   as absent for facet purposes — the CH-01 not-covered line stands as the
   honest non-dispatch record; both scripts live in the same directory). The
   join is a reporter, so the gate's warn-only posture is untouched. Honest
   `[not-covered]` lines cover every non-dispatch branch (no manifest /
   incomplete manifest / no journeys / unparseable manifest), and *malformed
   or wrong-shaped journeys.json degrades loudly instead of crashing* (the
   MT-06 precedent — today `manifest_join.py` would traceback on bad JSON). A
   new self-test exercises `pr_gate.sh` with a manifest — the class of gap
   that let this go unnoticed.
2. `correlate.py` gains an optional `--journeys <path>`. When provided, the
   backref cross-check runs (a ~5-line exact-match comparison per MS §12
   row 1); when absent — the common production case, since a prod-triage run
   has no audit artifact — the status stays `skipped` with the *honest* note
   ("no journeys.json provided"), never "unbuilt". The result stays
   `status`+`note` only: `backref_cross_check` is `additionalProperties:
   false` in `correlation.schema.json`, so mismatch detail rides in the note
   string — no structured field, no schema version bump. Same-PR updates:
   schema notes, the triage self-test assertions, `emit_incident_spec.py:196`
   (its emitted-Spec header hardcodes "CH-02 unbuilt" — the same falsehood in
   every emitted artifact), `fixtures/journeys/journeys-v2.json:3`'s
   `_triage_note`, and `verification-manifest-v1.md:287` — dropping only
   "Until it ships" while KEEPING the exact-name-match fallback clause (that
   fallback is live, red-tested behavior; the backref is v2-optional).
   `docs/specs/prod-triage-register.md` gets a dated correction note citing
   this ADR (append-only — its `[det-cond]` definition and :209-212 pin the
   old note string; the historical entries are not rewritten). Assertion
   counts grow (new provided-journeys path).

## Considered and rejected

- **A shared correlation kernel** (architecture review #03's shape): a new
  module + audit/triage adapters + composed contract test. Rejected — the
  cross-check is ~5 lines given journeys.json; `manifest_join.py` emits
  greppable text rows, not structured data, so "reuse" would mean parsing ROW
  lines; and the defect is a missing input plus a stale string, not a missing
  abstraction. Simplicity default: map the need onto existing doors.
- **Declare it out of scope** (the simplification review's other branch):
  rejected — README advertises the join, the machinery is built and tested,
  and declaring-out would leave CH-01/CH-03 as dead tested code plus a
  permanently false triage note.

## Consequences

- The §12 join becomes a live behavior of the ambient audit, not machinery
  without a driver; CH-01 finally serves its stated design purpose.
- Triage's output tells the truth in both directions (check ran / check
  skipped for a stated reason), and the suite gains its first
  `pr_gate --manifest` coverage.
- No new module, no schema version bump, no gate semantics change.
