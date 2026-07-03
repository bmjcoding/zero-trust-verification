# Observability config: OTEL-standard vendor-neutral core, LOB config profiles, agent-first log triage

---
status: accepted
date: 2026-07-03
---

Shipped observability defaults are vendor-neutral: structured JSON, OpenTelemetry-compatible field names, trace/span-ID correlation. OTEL is the standard; the suite is never tailored to one cloud or observability vendor (a representative enterprise environment — managed containers + serverless, a cloud-native logs/metrics stack, a commercial APM tool — is deliberately NOT encoded in the core). Tailoring happens through **config profiles**: a named preset layered over the defaults that encodes a line of business's vitals taxonomy, event vocabulary, and alert seams (first target: a Payments profile covering an entire payment-processing workflow end-to-end). Profiles are shippable by any LOB or company; environment (dev/test/prod deployment environment) is the primitive that profile values key off.

**Agent-first principle:** the primary consumer of emitted vitals is an agent triaging logs, not a human reading a dashboard. Instrumentation requirements therefore optimize for machine-parseable, correlated, semantically-named log/metric emission; dashboards are a necessary-for-now human compatibility layer, never the design target. Decided by Bailey 2026-07-03.

## Consequences

- The manifest's `observability:` block references a profile by name; the profile supplies the concrete field names, event taxonomy, and alert-seam targets the implementer emits against and the audit grades against.
- A profile is data (config), never code — adding an LOB requires writing a profile file, not forking a tier.
