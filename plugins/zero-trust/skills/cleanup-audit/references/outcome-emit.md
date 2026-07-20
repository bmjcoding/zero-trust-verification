# Outcome emission-share step (audit side; ADR 0023, OM-04, report-only)

`scripts/outcome_emit.sh` projects the LAST `journeys.json` the journey-walker
AGENT produced into the suite-unique metric: on CORE journeys, the share of
money/auth vital steps graded OBSERVED (vs LOG-ONLY / DARK). Because the input
is agent judgment, every emitted row is `honesty_class: agent-graded` with
provenance `journeys.json@<sha>` — it can NEVER be laundered as `[det]`. The
step projects grades already recorded: no re-walk, no fresh audit (H6),
READ-ONLY on the target, writes ONLY the store, posts NOTHING (H5), emits NO
alert_seam / paged-share (H2 — alert seams are external, ADR 0006). Absent /
corrupt / unknown-schema journeys.json → a loud [note] + no row, exit 0.

The store contract is `docs/specs/outcome-store-contract.md` (the single canonical
copy, ADR 0030): row schema (name / honesty_class / provenance), the three honesty
classes and their renderer badges, and the append-only + degrade rules all live
there — lint V11 stands tripwire against any re-vendored copy.
