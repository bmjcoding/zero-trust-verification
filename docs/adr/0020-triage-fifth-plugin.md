# ADR 0020 — The production-telemetry triage capability is the fifth plugin (`triage`); it closes prod→spec by emitting into the remediation loop

---
status: accepted
date: 2026-07-06
amends: 0001, 0011
---

> **Reconciliation note (2026-07-07, added at triage build/merge).** This ADR predates org-wide memory (ADR 0019) landing first as the fifth registered plugin, so `triage` is the **SIXTH** registered plugin in the root marketplace — the title's "fifth" is the ADR-0011 *not-a-tier* packaging sense (the fifth non-tier plugin, after Marshal), and the code/lint V6 correctly assert six plugins. Two framing claims in the prose below were superseded by the hardened register (docs/specs/prod-triage-register.md r2) and the shipped code: (1) triage emits an incident-Spec into **spec-gen's RESUME path** (a Draft-Spec input that a resumed spec-tier session interrogates), NOT directly "into the remediation loop"; (2) the journey link is **DERIVED from the `event_name`→step match**, not read from a `manifest_journey_id` backref "by construction" (that audit backref is codebase-health CH-02, unbuilt — so the cross-check ships as `[det-cond]`, skipped with a loud note). The report-only posture and the vendor-neutral adapter below are accurate as written.

The production-telemetry triage capability packages as a **fifth independently installable marketplace plugin, `triage`** — not a mode of an existing tier and not a fourth "Tier" (CONTEXT.md fixes *Tier* at three: Spec Generation, Autopilot, Audit; a plugin is a packaging unit, not a tier). It ingests emitted vitals through a vendor-neutral telemetry adapter (default OTEL/OTLP-JSON; CloudWatch/Dynatrace behind the same adapter interface, config-profile-selected per deployment — never hardcoded, ADR 0006), correlates an incident to the manifest's journey + behavior IDs via the §12 join keys (`event_name`/`vital_class`/`manifest_journey_id` — the runtime↔design-time link exists by construction), and emits an **incident-Spec into the remediation loop** (ADR 0017), which drains it to a Story PR for human review. This is the payoff of agent-first observability (ADR 0006) and of the manifest being the universal join key: an incident becomes a spec, closing prod→spec, the end of the ADLC.

Decided by Bailey 2026-07-06. Shipped posture (Bailey 2026-07-06): **report-only first** — the triage agent emits incident-Specs as *proposals* for human review; autonomous emission-to-drain is a per-deployment opt-in, never on by default.

## Considered Options
- **A mode of the audit tier** — rejected: the audit is read-only over source at rest; triage reads runtime telemetry, a different input and trust surface, and would poison the audit's "installable without granting anything" adoption pitch.
- **Inside autopilot** — rejected: triage serves an ops function distinct from the drain; bundling it forces the union permission surface (the ADR 0001 mega-plugin rejection).

## Consequences
- The suite grows to **five plugins**; the root marketplace.json (ADR 0011 packaging) registers `triage`; the vendoring lints extend to any contract it shares (the manifest §12 join lives in codebase-health — triage consumes it, does not re-implement).
- Telemetry ingestion source/format, read credentials, and org approval for automated read access to prod telemetry are **deployment-time external facts** (escalated in the register), deferred as config; the adapter interface is designed so they never block the build.
- Triage holds NO quality opinion of its own (it emits Specs; the spec-gen tier interrogates them, the loop drains them, the human reviews) — so it is wiring at the ADLC boundary, not a sixth checker.
