# ADR 0022 — Out-of-scope-by-declaration is a new report class that never blocks a merge

---
status: agent-decided
date: 2026-07-06
---

When the manifest declares a control lives at a non-`app` locus (gateway, mesh, sidecar, db-config, vault, etc.), the audit emits a distinct report line — out-of-scope-by-declaration — separate from both `finding` and `not-covered`. It names the class and the declared locus and states "verified elsewhere by declaration — not assessed in-repo." It is NEVER a violation, NEVER counted against the target, and DELIBERATELY never a member of the ADR-0004 blocking-class set. Rationale: ADR 0004's invariant is that an agent opinion without deterministic in-repo evidence never blocks a human's merge; an in-repo verdict about an out-of-repo control is exactly such an opinion, so it cannot gate. Only a `locus: app` finding that is deterministic-in-the-join AND has a present declaration is even gate-eligible, and even then it ships comment-only through the ADR-0004 soak.

## Considered Options
- **Fold out-of-scope into `not-covered`** (adversarial position): rejected — `not-covered` implies the audit tried and couldn't; out-of-scope-by-declaration means the org declared it is verified elsewhere. Conflating them loses the honesty signal and risks a future edit promoting a `not-covered` gap into a finding.
- **Emit nothing for non-app loci**: rejected — silent skip is invisible-if-deleted (invariant 6); the explicit line makes the declared boundary auditable.
- **Let a strongly-declared elsewhere-locus block if the app-side evidence contradicts it**: rejected — that is still an in-repo verdict about an out-of-repo control; it stays comment-only.

## Consequences
- Downstream report consumers (Merge Marshal, remediation loop) must treat out-of-scope-by-declaration as informational, never as a finding — recorded for their registers.
- A self_test red-test guards the invariant: any item emitting a raw "missing X" finding on a non-`app`/absent locus fails the suite (⟨SD-AMEND-C⟩; the unfalsifiability guard).