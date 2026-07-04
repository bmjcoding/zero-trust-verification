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
A prose document defining work — ADR, design doc, RFC, PRD. Written for humans; the input to Spec Generation review and to Autopilot GENERATE. Has a lifecycle: drafted → product-approved → merged to main → picked up (Pickup is the Claim event).
_Avoid_: requirements doc, plan, intent spec (same noun; use Spec)

**Runbook**:
GENERATE's output for a picked-up Spec: the Stories, Subtasks, and acceptance-behavior bindings that close the Spec out end-to-end. Its PR, opened at Pickup, publishes the Spec's predicted file surface as a prediction-tier Claim.
_Avoid_: technical implementation spec, tech spec

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

**Claim**:
A workstream's visible assertion of the file surface it is changing, derived from open PRs — never declared in a ledger or service. Strengthens through a lattice: prediction (Runbook PR) → in-progress (Story draft PR) → terminal (ready-for-review PR). Actuality beats prediction; first-visible wins; claims decay by observable inactivity.
_Avoid_: lock, reservation, ownership record

**Attended Session**:
A workstream a human is steering in real time (typically a person driving Claude Code). Wins ties against an Unattended Drain because a person is burning calendar time.
_Avoid_: human work, manual work (nearly all pod work is agentic; the axis is attendance, not authorship)

**Unattended Drain**:
An autopilot drain firing on cadence with no human watching. Yields ties to Attended Sessions — it serializes and re-plans at no one's cost.
_Avoid_: agent work, bot PR

**Merge Marshal**:
The serial, deterministic merge backstop: FIFO over ready PRs, verifying the composed state (build on the post-rebase head) before merging. Wiring, not a checker — it holds no quality opinion; every decision is a timestamp, sha, build state, or file-surface intersection. Shift-left machinery exists to make it boring, not absent.
_Avoid_: merge queue (implies speculation/batching/trains — deliberately excluded), merge train

**Textual Conflict**:
Two branches edit overlapping hunks; git cannot merge them. Fully preventable before code is written by ownership claims (file- or target-level), because the collision is visible in the claimed surface itself.
_Avoid_: merge conflict (ambiguous — used loosely for both failure classes)

**Composition Break**:
Two branches merge cleanly but the composed HEAD is broken — each green against its fork point, red together (e.g., a rename lands while another branch adds a call site to the old name). Not preventable by ownership claims; only detectable by verifying the composed state (build + test of the merged result).
_Avoid_: semantic conflict, logical conflict, evil merge

**Tier**:
One of the three independently runnable stages of the suite: Spec Generation, Autopilot, Audit. Together they cover the ADLC left-to-right.
_Avoid_: phase, stage, layer
