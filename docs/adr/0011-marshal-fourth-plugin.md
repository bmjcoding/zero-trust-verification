# Coordination machinery is a fourth plugin (Marshal): wiring, not a checker; the suite's smallest-logic, biggest-write surface ships alone

---
status: accepted
date: 2026-07-04
---

The Merge Marshal loop (ADR 0010), the claim-overlap check, and the staleness/branch-age watcher (ADRs 0009, 0012) package as a **fourth independently installable marketplace plugin — Marshal** — not as a mode of autopilot or the audit tier. This passes ADR 0003's test: what that ADR rejected was a fourth *checker* (a fourth quality opinion to keep consistent); the Marshal is the carved-out exception made concrete — **wiring, not a checker**. It invokes the PR Gate and `build-status` and never forms its own opinion about quality, so there is no C-class contradiction risk.

Its contract: **deterministic-only decisions** (timestamps, shas, build states, file-surface intersections — everything git/API-provable; no agent judgment in the merge path), and the **smallest possible write scope** (rebase-push and merge, nothing else).

## Considered Options

- **Inside autopilot**: rejected — the Marshal serves every PR in the pod, including Attended Sessions that never run autopilot, and bundling merge rights into autopilot forces the union permission surface on installers (the exact reason ADR 0001 rejected the mega-plugin).
- **Inside the audit tier / PR Gate**: rejected — the audit's adoption pitch is read-only, warn-only, "installable without granting anything"; putting the suite's largest write authority inside it poisons that pitch.

## Consequences

- Independent installability is the company-wide extensibility story: most repos would install the Marshal *alone* — claims plus serial merge safety with zero Bazel, zero autonomous drains, zero spec tier.
- The claim-overlap check is vendored into both consumers (autopilot G4 and the Marshal) with the byte-identical repo lint, per the ADR 0001 manifest-schema pattern.
- The Marshal is the natural future home of ADR 0003's long-running PR-event agent: both are quality-logic-free wiring over the same PR event stream.
