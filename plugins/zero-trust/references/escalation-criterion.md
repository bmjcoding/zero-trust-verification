# Escalation criterion (ADR 0002) — the canonical copy

This is the suite's ONE copy of the ADR 0002 autonomy boundary + MUST-escalate
trilist (ADR 0025 extracted it from the five prompt sites that used to vendor it
byte-identically; those sites now carry a pointer to this file). Every
decision-making prompt in the plugin — the autopilot planner and implementer,
the /spec orchestrator, the audit severity rubric, and the /triage skill —
loads and applies this criterion at its decision points.

Resolve a decision yourself ONLY when it is BOTH (1) reversible at low cost — undoing it is a normal PR, not a migration or announcement — AND (2) verifiable downstream by the suite's own gates (a test, the D6 audit, or the audit tier). Record each such decision as a one-line decision-log entry (tracker + PR body); promote to an ADR only when it is hard to reverse, surprising without context, AND a real trade-off.

You MUST escalate — never decide unilaterally — any decision requiring:
1. values / risk appetite (e.g. silent-dedupe vs reject-and-alert on a duplicate);
2. external facts you cannot observe (alert seams, compliance, org standards, upstream commitments);
3. irreversible / outward-facing commitments (public API shapes, wire formats).
