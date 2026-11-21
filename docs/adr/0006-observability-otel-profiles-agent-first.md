# Observability config: OTEL-standard vendor-neutral core, LOB config profiles, agent-first log triage

---
status: accepted
date: 2026-07-03
---

## Context

Instrumentation needs a portable vocabulary and correlated evidence that automated consumers can inspect.

## Decision

Use structured JSON, OpenTelemetry-compatible fields, and trace/span correlation. Keep cloud and observability vendors outside the core contract. The original config-profile extension allowed data presets for event vocabulary, vital taxonomy, and alert seams; ADR 0033 retires that extension. Deployment environments remain explicit manifest data.

Prioritize machine-parseable, semantically named emissions for agent triage. Dashboards support human inspection.

## Consequences

Consumers can correlate evidence without depending on a particular vendor. Instrumentation requirements belong to the shared verification contract; downstream applications choose their own tooling.

See ADR 0033 for the current treatment of the profile field.
