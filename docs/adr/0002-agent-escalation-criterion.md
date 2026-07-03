# Agent autonomy boundary: the two-part escalation criterion and the two-level decision record

---
status: accepted
date: 2026-07-03
---

All three tiers maximize agent autonomy: tradeoffs are resolved agent-vs-agent (adversarial round) before anything is surfaced to a human, because human confirmation of a recommended default is rubber-stamping, not scrutiny. An agent may resolve any decision that is BOTH (1) reversible at low cost — undoing it is a normal PR, not a migration or announcement — and (2) verifiable downstream by the suite's own gates (test, D6 audit, or audit tier). An agent MUST escalate decisions requiring: values/risk appetite; external facts it cannot observe (alert seams, compliance, org standards, upstream commitments); or irreversible/outward-facing commitments (public API shapes, wire formats). This one rule is vendored into all three tiers' prompts — spec-gen interrogator, autopilot planner/implementer, audit severity judgment — and kept in sync by the repo lint.

Decision recording is two-level to avoid ADR spam: every agent-resolved decision gets a decision-log line (tracker + PR body — cheap, greppable, complete); only decisions meeting the three ADR criteria (hard to reverse, surprising without context, real trade-off) are promoted to an ADR with `status: agent-decided`, meaning binding now, human may overturn asynchronously. The adversarial round's dissent is recorded in the ADR's Considered Options so the *how* of the decision is auditable, not just the *what*.

## Consequences

- Illustrative cut: *whether* a wire transfer needs an idempotency key is agent-decidable (manifest schema forces it mechanically); *what happens on a duplicate* (silent dedupe vs reject-and-alert) is risk appetite — escalates.
- Spec-gen's `[SPEC-INCOMPLETE: <field>]` exits are exactly the MUST-escalate set; everything else resolves in the adversarial round.
