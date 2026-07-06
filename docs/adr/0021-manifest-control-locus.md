# ADR 0021 — Manifest declares a control `locus` so the audit can be honestly silent about the gateway and mesh

---
status: agent-decided
date: 2026-07-06
---

Controls that live outside the repo — rate limiting at the gateway/WAF, circuit breakers and load shedding in the mesh/sidecar, key rotation in Vault/KMS, transaction isolation in DB/session config, entitlement breadth in IAM/Terraform — cannot be honestly assessed by a static in-repo audit. Emitting a raw "missing X" finding for them is unfalsifiable and wrong often enough to burn the suite's precision credibility (SYSTEM_DESIGN_COVERAGE_2026-07-04.md §3). The mechanism is declare-then-verify: the Verification Manifest declares a per-scope `locus` (app | gateway | mesh | sidecar | db-config | vault | kms | ops | none-declared) for each such control, authored by the spec tier (one-writer rule, MS §7) with the enum vocabulary supplied by the ADR-0006 Config Profile. The audit VERIFIES only `locus: app` declarations — the sole locus whose evidence is in the repo — and reports every other locus as out-of-scope-by-declaration. When the manifest is absent, the class reports `unknown — lives outside the repo`, the truthful answer today.

The field family is additive-only under schema_version 1 (consumers ignore-unknown per MS §8; an absent field is never a schema break) and NOT completeness-gating by default, so ADR-0008 straight-through drains are preserved. `none-declared` is a first-class enum value — the honest answer, not an omission.

## Considered Options
- **Raw in-repo "missing X" findings** (adversarial position): rejected — recreates, in reverse, the mandate-without-enforcement defect the codebase-health corrections purged; unfalsifiable against out-of-repo controls; precision-hostile.
- **Silently skip out-of-repo controls**: rejected — invisible-if-skipped is itself a defect (invariant 6); the declaration makes the boundary explicit and auditable.
- **A separate infrastructure-scanning tier (Terraform/IAM/mesh config)**: rejected as out of scope for the in-repo audit; the manifest declaration is the zero-infrastructure seam, and cross-repo IAM assessment is a different tool.

## Consequences
- The manifest gains an additive `locus` field family (authored by spec-gen; ⟨SD-AMEND-A⟩); the audit consumes it via the existing CH-01 reader and CH-03 comparator — no new join engine.
- Whether any locus declaration is MANDATORY for a CORE money journey is a risk-appetite call escalated to Bailey (⟨SD-AMEND-B⟩); the shipped default is optional-with-`unknown`-degrade.