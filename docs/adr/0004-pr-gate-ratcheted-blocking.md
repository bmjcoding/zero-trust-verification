# PR Gate merge policy: ratcheted blocking on new debt, never on inherited debt

---
status: accepted
date: 2026-07-03
---

The PR Gate blocks merge per the ratchet philosophy: pre-existing debt never blocks (brownfield repos are not punished for their past); NEW debt introduced by the diff blocks, phased in per repo — report-only during an initial soak (2–4 weeks), then blocking. Decided by Bailey (risk-appetite call) 2026-07-03.

**Merge-blocking classes:** manifest behavior-IDs claimed but unproven; new DARK vitals on CORE money/auth journeys; new missing-idempotency on money-path writes; new flaky-pattern tests; deterministic memory-rot hits (deleted/renamed symbol still referenced by manifest, journeys, docs, or ADRs).

**Comment-only classes:** complexity flags; SUPPORTING/DEV journey findings; semantic-drift judgments. Invariant candidate formalized here: **an agent opinion without deterministic evidence never blocks a human's merge** — only deterministic findings (grep/git-log/test-provable) can gate.

## Consequences

- Alternatives rejected: advisory-everywhere (no teeth, rot accumulates with a paper trail) and blocking-from-day-one (fastest path to org-wide uninstall).
- The soak window and the blocking-class list are per-repo configuration with these as shipped defaults.
