# Zero-Trust Verification Suite

The three-tier software-quality suite: spec generation (shift-left), autopilot implementation drain, and codebase-health audit. Tiers run independently but integrate through a shared machine-readable contract.

## Language

**Story**:
The unit of review: one feature-scale slice of a Spec = one worktree/branch = one PR (draft from first Subtask, ready when the last completes). Composed of Subtasks.
_Avoid_: feature branch, epic

**Subtask**:
The unit of implementation inside a Story: one TDD vertical slice landing as RED/GREEN commits on the Story branch. Never its own PR.
_Avoid_: task, ticket

**Spec**:
A prose document defining work — ADR, design doc, RFC, PRD. Written for humans; the input to Spec Generation review and to Autopilot GENERATE.
_Avoid_: requirements doc, plan

**Verification Manifest**:
The machine-readable companion a Spec ships with: acceptance behaviors with stable IDs, the journey map with criticality, required vitals, and idempotency requirements. Produced by the Spec Generation tier; consumed by Autopilot (planner maps Subtasks to behavior IDs) and by the Audit (journey-walker verifies against it). Every consumer pins a `schema_version` and degrades gracefully when the manifest is absent.
_Avoid_: spec metadata, sidecar spec, contract file

**Acceptance Behavior**:
One observable, RED-testable behavior in the Verification Manifest: a stable ID plus structured Given/When/Then fields written in this glossary's canonical terms. Bound to native test IDs, never to a Gherkin runtime.
_Avoid_: requirement, user story, scenario (Gherkin connotation)

**Journey**:
A user-visible flow through the product, tied to a criticality (CORE / SUPPORTING / DEV). Exists in two forms: the *intended* journey declared in the Verification Manifest at spec time, and the *as-built* journey documented alongside the implementation. The Audit verifies the two against the code and reports drift; it never authors either.
_Avoid_: user flow, path, scenario

**PR Gate**:
The per-PR quality checkpoint: the audit tier's diff-scoped mode plus manifest behavior-ID coverage verification (proof from tests/git log that what the PR claims was implemented actually was). Runs on every PR regardless of author (autopilot or human).
_Avoid_: quality gate (ambiguous — D6 is autopilot's internal gate), pre-PR check

**Memory Rot**:
Repo-resident memory (glossary, ADRs, as-built docs, journey maps, manifest) that the code no longer agrees with — a term describing deleted symbols, a journey step through a removed path, an ADR the code now violates. Detected incrementally at the PR Gate (diff-scoped) and ambiently by scheduled audits; never silently tolerated.
_Avoid_: stale docs, doc drift

**Config Profile**:
A named observability preset layered over the vendor-neutral defaults, encoding one line of business's vitals taxonomy, event vocabulary, and alert seams (e.g., a Payments profile for a payment-processing workflow). Pure data — adding an LOB means writing a profile, never forking a tier.
_Avoid_: LOB config, template

**Vital**:
A business-significant emission point on a Journey: a money movement, state transition, external side effect, or auth event. Graded by the Audit as OBSERVED, LOG-ONLY, or DARK. Written primarily for agent triage of logs; dashboards are a human compatibility layer.
_Avoid_: metric, KPI, business event

**Decision Log**:
The complete, cheap record of agent-resolved decisions — one line per decision in the tracker and PR body. ADRs are the promoted subset (hard to reverse, surprising, real trade-off), not the whole record.
_Avoid_: decision register, audit trail (that term is taken by the tracker section)

**Tier**:
One of the three independently runnable stages of the suite: Spec Generation, Autopilot, Audit. Together they cover the ADLC left-to-right.
_Avoid_: phase, stage, layer
