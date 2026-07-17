# Severity Rubric (the only one)

Every agent, command, report, and spec uses this exact scale. Do not invent
per-agent scales — cross-agent consolidation and the HIGH-and-above table
depend on severities meaning the same thing everywhere.

## Scale

| Severity | Meaning | Examples |
|---|---|---|
| CRITICAL | Exploitable security flaw, or data-loss/corruption path, reachable in production | auth bypass, SQL injection on a public endpoint, silent data-dropping write path |
| HIGH | Confirmed-reachable correctness defect, broken documented journey, or measured hot-path performance problem | fake validator on the API path, quickstart that errors, N+1 with numbers attached, wire-transfer/money-movement path emitting no business event (DARK, traced CORE journey), convoluted control flow on a CORE journey step (metric line attached) |
| MED | Real defect not confirmed reachable, or reachable with limited blast radius; suppressed diagnostics hiding unknown risk | stub on an internal path, needs-verification findings, `type: ignore` clusters, uninstrumented vital on an untraced flow (needs-verification), LOG-ONLY vital |
| LOW | Hygiene: dead code, stale docs/comments, style-level debt | unused helper, "we used to..." comments |

## Confirmation gates (apply to every agent, not just incomplete-logic)

- **HIGH and CRITICAL require confirmation**: a traced call path from a
  public/security/data surface, an executed repro, or measured numbers (perf).
  Unconfirmed suspicion caps at MED with a **needs-verification** mark — never
  inflate.
- **CRITICAL additionally requires** naming the trust boundary crossed and why
  the path is reachable by an attacker/user, not just by code inspection.
- Downgrading for want of evidence is correct behavior, not timidity; `/verify`
  and the adversarial pass re-promote when evidence lands.

### 1.4.0 amendments (NEW rules — cite as "the 1.4.0 amendment", never as pre-existing)

- **Absence findings** (missing instrumentation, structured logging,
  correlation IDs — the defect is that nothing exists) have no repro by
  definition; a traced path is the only possible confirmation. Two halves:
  - `journey/uninstrumented` reaches HIGH ONLY with a traced CORE-journey
    money-movement or auth path attached as evidence (the wire-transfer
    exemplar above).
  - ALL other absence findings — module-level logging/correlation-ID absences
    (taxonomy Category LOG), DARK or LOG-ONLY vitals off traced CORE
    money/auth paths, LOG-ONLY vitals even ON one (HIGH is DARK-only), any
    absence lacking the trace — **hard-cap at MED**. No judgment escape above
    the cap. The **needs-verification** mark follows the confirmation gate
    above: it rides on every capped absence whose path is untraced or
    unconfirmed (module-level absences and anything lacking the trace); a
    capped absence on a traced path is confirmed MED, no mark.
    `business-vitals.md`'s severity mapping cites this list rather than
    restating it (ADR 0031) — this is the single copy.
- **`journey/path-complexity`** weights severity by journey criticality, never
  by raw metric value. HIGH requires a CORE step in `audit/journeys.json` AND
  an attached deterministic metric line (e.g. C901) or quoted structural
  redundancy; the same metric off-journey is LOW hygiene; judgment-only caps
  at MED; missing/corrupt `journeys.json` caps at MED needs-verification.
- **`test-health/*`** findings are never CRITICAL (no trust boundary — a
  rubber stamp blessing a reachable security defect yields a separate,
  cross-linked security finding). HIGH requires **(demonstrated
  nondeterminism via the bounded probe OR vacuity-by-construction) PLUS
  sole-coverage of a public-API/security/data-write symbol** — the
  sole-coverage qualifier binds to BOTH routes: a demonstrated-flaky test
  that is not the only cover on such a symbol caps at MED like any other
  test-health finding below the gate. Sole-coverage is traced, or evidenced
  by a survived mutant on that symbol in an ingested report; the survived
  mutant is evidence of sole-coverage, not a third route to HIGH.


## Escalation boundary (ADR 0002 — the one rule, vendored verbatim)

The audit is **read-only**: it *reports*, it never resolves or acts. The one autonomous judgment it makes is severity, and the same ADR 0002 boundary governs it — the audit may settle a severity itself only within these limits; anything past them surfaces to a human (a **needs-verification** mark or an escalation note), never a silent HIGH/CRITICAL. The block below is a pointer to the canonical `references/escalation-criterion.md` (single copy since ADR 0025); for this read-only tier read "resolve a decision" as "settle a severity/finding" and the "decision-log entry" as the finding's evidence line.

<!-- vendored:escalation-criterion:begin (ADR 0002 pointer — byte-identical across all sites; do NOT edit one copy; the criterion itself lives in the canonical file) -->
**Escalation criterion (ADR 0002).** At this decision point, load and apply the canonical escalation criterion from `references/escalation-criterion.md` at the zero-trust plugin root (`plugins/zero-trust/references/escalation-criterion.md`). It defines the only two conditions under which you may decide autonomously, and the three decision classes you MUST escalate.
<!-- vendored:escalation-criterion:end -->

## Architecture strength labels

Architecture findings carry severity AND a recommendation strength:
**Strong / Worth exploring / Speculative**. Severity says how much it hurts;
strength says how confident the recommendation is. Both are required.

## Grade words

Deletion grading (SAFE / CAUTION / DANGER) is a separate axis defined in
`safe-deletion-workflow.md` — it grades *deletion risk*, not defect severity.
Don't mix the vocabularies. Same rule for OBSERVED / LOG-ONLY / DARK
(`business-vitals.md`): it grades *instrumentation placement*, a separate axis
from severity.
