# Zero-Trust Verification Suite

The zero-trust software-quality suite — one `zero-trust` plugin (ADR 0025) carrying three verification tiers: spec generation (shift-left), autopilot implementation drain, and codebase-health audit — plus the capabilities woven around them (merge marshal, production triage, org-wide memory, health-loop, outcome measurement). Tiers run independently but integrate through a shared machine-readable contract.

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

**Vital**:
A business-significant emission point on a Journey: a money movement, state transition, external side effect, or auth event. Graded by the Audit as OBSERVED, LOG-ONLY, or DARK. Written primarily for agent triage of logs; dashboards are a human compatibility layer.
_Avoid_: metric, KPI, business event

**Decision Log**:
The complete, cheap record of agent-resolved decisions — one line per decision in the tracker and PR body during drains, and in the Verification Manifest's `interrogation.log` during spec sessions. ADRs are the promoted subset (hard to reverse, surprising, real trade-off), not the whole record.
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
One of the three verification stages of the suite: Spec Generation, Autopilot, Audit. Together they cover the ADLC left-to-right. A workflow stage, not a packaging unit — since ADR 0025 all three ship inside the single `zero-trust` plugin; each still runs standalone.
_Avoid_: phase, stage, layer

**Triage**:
The production-telemetry capability (ADR 0020; a capability, not a fourth Tier): a read-only, bounded-window source that turns an emitted production incident into a resumable incident-Spec feeding Spec Generation's resume path. Report-only and DRAFT-PR-only by default — never a patch, never an auto-merge.
_Avoid_: incident bot, fourth tier

**Org-Wide Memory**:
The read-only, memory-glob-bounded index/crawler over repo-resident memory (glossaries, ADRs, manifests, decision logs), exposed via a refuse-by-default MCP query surface (ADR 0019). A derived view — every record carries a `{repo, commit_sha, path, line}` back-pointer to the authoritative bytes; never a second store of truth.
_Avoid_: knowledge base, memory store (it is an index over the repos' own files)

**Health-Loop**:
The attended wave-drain campaign (`/health-loop`, ADR 0024): from one operator prompt, drain audit wave N → merge wave N → `/verify --strict` → gate → wave N+1. Merge-before-verify is a correctness rule (the verifier grades the checkout), not review ceremony; merges are operator-approved or narrowly delegated.
_Avoid_: auto-remediation (it is operator-attended)

**Honesty Class**:
The mandatory label on every outcome-measurement metric row (ADR 0023): `deterministic`, `agent-graded`, or `human-annotated`. The schema binds each metric name to its class, so an unlabeled or mislabeled (laundered) row is schema-invalid, and the renderer's badge (`[det]` / `[agent-graded]` / `[annotated]`) is never droppable.
_Avoid_: confidence level, quality score

**Locus**:
The Verification Manifest's declared home of a control (`locus: app | gateway | mesh | sidecar | db-config | vault | kms | ops | none-declared`; ADR 0021). The Audit verifies only `locus: app` — the sole locus whose evidence is in the repo — and reports every other locus as out-of-scope-by-declaration, never as a raw "missing X" finding.
_Avoid_: control location, scope tag
