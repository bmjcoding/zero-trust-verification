# Acceptance behaviors are Given/When/Then-shaped; no Cucumber/Gherkin runtime

---
status: agent-decided
date: 2026-07-03
---

The suite practices BDD in substance: the Verification Manifest's acceptance behaviors adopt structured Given/When/Then fields (not free prose), because a behavior that cannot be phrased GWT cannot be RED-tested — the shape is a testability gate applied at spec time, and GWT statements written in the glossary's canonical terms let the memory-rot facet lint spec language against CONTEXT.md mechanically. Behavior IDs bind to native tests (pytest/vitest/go test node IDs via `test_name_hint`), verified at D6 and the PR Gate from git log and test runs.

We do NOT adopt a Gherkin runtime (Cucumber, behave, SpecFlow): step-definition frameworks add a brittle regex translation layer between spec and test, require a per-language Cucumber stack in polyglot repos (contradicting the gates-template portability fix, autopilot GAPS_SPEC D3), and duplicate a linkage the suite already gets deterministically from behavior-ID ↔ test-ID binding. BDD's original goal — a shared, ubiquitous language between business intent and executable verification — is served by the manifest + glossary + native tests; the framework is the part of BDD that historically rots.

## Considered Options

- **Full Cucumber-style executable specs** (adversarial position): the .feature file is human-readable by non-engineers and directly executable. Rejected: the suite's spec tier already produces the human-readable artifact (the Spec + manifest), and execution is already bound through test IDs; the runtime buys a second execution path to keep consistent, at per-language cost.
- **Free-text behaviors** (status quo in the planner prompt): rejected — free text lets untestable behaviors ("handles errors gracefully") into the manifest; GWT structure forces the observable trigger and outcome to be named.
