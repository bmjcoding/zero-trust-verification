# ADR 0030 — Contract prose is single-copy; the H1 anti-laundering pins outlive the copies

- **Status:** Agent-decided (2026-07-17; adjudicates architecture review #04 against the simplification review's §6 trust inventory)
- **Date:** 2026-07-17
- **Supersedes/amends:** finishes ADR 0025 §2 (retire vendoring enforcement with the vendoring) for the three prose blocks that survived consolidation.

## Context

Three vendored prose blocks remain post-consolidation, each byte-identical to
its canonical source and pinned by lint: the telemetry contract
(`references/backends.md:22-55` ← `references/telemetry-contract.md`) and the
outcome-store contract (`references/outcome-measurement.md:20-55` and
`skills/cleanup-audit/references/outcome-emit.md:17-52` ←
`docs/specs/outcome-store-contract.md`) — ~105 duplicated lines plus the lint
and red-test machinery that polices them.

The architecture review recommended deleting the copies *and* the
"copy-policing lints (V9/V11)". The simplification review's trust inventory
warned V11's grep-inputs are trust-critical. Adversarial verification against
the live lint resolved the apparent conflict: **V9 is pure copy-police, but
V11 is compound.** V11(a)/(b) police copies; V11(a2) pins the single canonical
outcome schema's name↔honesty_class binding, and V11(c) greps the
outcome-measurement register for `[audit-run]` presence and `[det]`/agent-graded
laundering — the H1 anti-laundering guards. Neither (a2) nor (c) reads any
prose copy. Deleting rule V11 wholesale would lose anti-laundering protection;
deleting the copies loses nothing.

## Decision

1. **Delete the three vendored blocks**; each carrier keeps a one-line
   citation to its canonical doc — and the citation carries **no marker
   pair** (a retained begin/end pair around a citation is "well-formed" to
   the lint and would compare non-equal to canon: an instant drift
   violation; a lone unpaired marker is skipped as prose). The canonical
   docs' "vendored VERBATIM into each producer's reference" prose is
   corrected (it sits outside the marker blocks, so canon text is
   unperturbed); their marker pairs stay (the lints' well-formedness checks
   continue to pass unedited).
2. **Rule ids V9 and V11 are retained** (never renumber; a retired id stays
   retired). Their copy-scan bodies stay as dormant, zero-cost tripwires
   against future re-vendoring — on a copy-free tree they find nothing.
   **V11(a2) and V11(c) are untouched.**
3. **Red tests are retargeted, not deleted — all THREE live-tree drift
   tests and all three false-positive guards.** The suite red tests that
   plant drift in live-tree copies (`seed_tel` telemetry drift; the v11b
   append-only mutation) *and triage's TR-08* (`self_test_triage.sh:~370-388`,
   which seds live `backends.md` and asserts `LINT-FAIL [V9]`) move to the
   sandbox-synthesized-copy pattern the suite already uses for V9's helper
   tests. The false-positive guards that append benign prose to the carriers
   (v9p, v11p2, TR-08's byte-identical guard) retarget the same way — left
   as-is they would pass vacuously once the carrier has no block, keeping
   the count but losing the teeth. The H1 red test (planted `[det]`
   laundering line) and the schema-copy red test are untouched. Assertion
   count does not decrease.

## Considered and rejected

- **Keep the copies for standalone readability.** The copies existed so a
  dispatched agent could read one producer reference without following a
  cross-tree pointer. Post-ADR-0027 the install is a full clone; the pointer
  target is always present, one file-read away. ~105 duplicated lines plus
  live-tree-mutating red tests is the wrong price for saving that read.
- **Delete lint V9/V11 wholesale** (the architecture review's framing):
  refuted — V11(a2)/(c) are semantic pins on *single* canonical artifacts,
  not copy police. H1 protection would be lost for zero line savings.

## Consequences

- The vendoring class ADR 0025 targeted is now fully extinct: zero prose
  copies, zero live-tree-mutating red tests, tripwires retained.
- Anti-laundering enforcement is unchanged: schema binding (V11 a2), register
  grep (V11 c), and the store-boundary schema-invalid rejection all operate on
  single canonical files exactly as before.
- Producer references get shorter and point at one source of truth.
