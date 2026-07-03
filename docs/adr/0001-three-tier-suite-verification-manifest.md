# Three-tier suite in one marketplace repo, integrated via the Verification Manifest

---
status: accepted
date: 2026-07-03
---

The spec-generation, autopilot, and codebase-health tiers consolidate into this repo, packaged as **one marketplace hosting three independently installable plugins** (the `.claude-plugin/marketplace.json` pattern; codebase-health-suite migrates in after its final polish). The tiers integrate through a shared machine-readable **Verification Manifest** produced by the spec tier: acceptance behaviors with stable IDs, journey map with criticality, required vitals, and idempotency requirements. Autopilot's planner maps every Subtask to manifest behavior IDs; the audit's journey-walker verifies the implementation against the same manifest — so verification is against the spec's ground truth, not the implementer's self-report. Every consumer pins `schema_version` and degrades gracefully when the manifest is absent, preserving each tier's ability to run standalone.

## Considered Options

- **One mega-plugin** — rejected: forces the union permission surface (autopilot's git/REST/cron Bash vs the audit's read-only warn-only posture) on every installer, and collapses the per-component CHANGELOGs/self-tests/release gates into one version number, re-opening the release-integrity failure class (autopilot GAPS_SPEC M3) that was just closed.
- **Loose coupling (human carries markdown between tiers)** — rejected: leaves "who checks the checker" unanswered; the audit would keep deriving journeys from README heuristics instead of the spec's declared intent.

## Consequences

- Installed plugins are copied independently; a consumer cannot read a sibling plugin's files at runtime. The manifest schema is therefore **vendored into each consuming plugin**, with a repo-level lint asserting the copies are byte-identical (extends the existing `lint_consistency.sh` pattern). `schema_version` in manifest instances protects users whose plugins were installed at different times.
- Autopilot's Hard Contract 2 (vanilla agents only, role-via-prompt) is **re-affirmed** despite plugin-hood making shipped agents possible: it works, and it is one less surface to test.
- Tier-by-tier adoption is the rollout strategy: the read-only audit is installable without granting an autonomous PR drain anything.
