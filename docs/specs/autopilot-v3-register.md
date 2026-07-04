# Autopilot v3 — Change Register

> Status: DRAFT r2 (adversarial round 1 applied: 20 findings — corpus-consistency and
> drain-executor lenses; 4 P0, 11 P1, all closed) · 2026-07-04
> Style: GAPS_SPEC register. Acceptance criteria are honest about their home: `[det]` =
> deterministic self_test/lint assertion; `[drain]` = M5-class, measured only in real
> drains + Drift Notes (the v2.4.0 honest-residual convention).
> Sources: verification-manifest-v1.md (§2, §6, §13.5–9, §13.11), ADRs 0002, 0007, 0008,
> 0009, 0012; session decisions on shift-left test quality.
> Baseline: autopilot v2.4.0 (self_test 96 assertions, lint L1–L15).

## Dependencies and landing order

`AV3-15 (host adapter) gates the self-hosted DELIVERY of everything` — draining this
register on this GitHub repo hits Hard Contract 11 at the first `pr-open`. No item's
*content* depends on AV3-15, but until it (or hand-draining) exists, nothing ships via
autopilot itself. Landing order for green-between-items:
**15 (if approved) → 06 → 07 → 01 → 02 → 03 → 04 → 08 → 09 → 10 → 05 → 11 → 12 → 13 →
14 → 16a → 16b → 17.** AV3-16 is split (16a rides 01/06; 16b is conditional on 15).

## A. Manifest consumption

### AV3-01 — Mode inference from the input artifact [ADR 0008, MS §13.5]
Input with a valid+complete manifest (validator exit 0, pinned schema_version) →
straight-through GENERATE→DRAIN, no pause, no flag; bare markdown → GENERATE+pause;
`--yolo` survives ONLY as the manifest-less override (Force-Audit-logged); runbook →
DRAIN/RESUME unchanged.
**Acceptance:** `[det]` mode-decision extracted to `scripts/detect_input_mode.sh`
(manifest path+validator exit → MODE token); fixture matrix incl. `--yolo`-on-complete
= no-op warning. `[drain]` the orchestrator honoring MODE.

### AV3-02 — Planner maps Subtasks to Behavior IDs [MS §13.6]
G3 schema gains `behavior_ids[]` per Subtask (AP-3 projection allow-list updated).
Required for kinds `code`/`test-only`; exempt: `refactor`/`config`/`docs`. Every active
behavior owned by ≥1 Subtask; violations `[GENERATE-FAILED: unmapped-subtask]` /
`[GENERATE-FAILED: unowned-behavior]`. Manifest-less inputs keep v2.4.0 semantics.
**Acceptance:** `[det]` new `scripts/validate_plan_mapping.sh <plan.json> <manifest>`
with fixtures for both refusals + refactor exemption; lint pins the AP-3 list update.

### AV3-03 — G4 union validation for multi-doc manifests [MS §2, §13.7]
Cross-manifest ID collision → `[GENERATE-FAILED: manifest-id-collision]`;
`observability.profile`/`environments` mismatch → `[GENERATE-FAILED:
manifest-union-mismatch]`.
**Acceptance:** `[det]` two-manifest fixtures for both refusals (script:
`validate_manifest.sh --union a.yaml b.yaml`).

### AV3-04 — Manifest-revision drift: pause, and a real path back [MS §6, §13.8]
D1 compares tracker-recorded `manifest_revision` (set at GENERATE) each fire. Drift →
in-flight Subtask completes its commit pair → `STATUS: PAUSED —
manifest-revision-drift` (no counter increment, not `--force`-bypassable, cron deleted,
draft Story PRs stay draft). **Path back (new, closes the v2.4.0 gap):** Resume mode
REFUSES a tracker with `status_reason: manifest-revision-drift` and points at
`--generate --merge` **revision-regen mode**: re-plans open Subtasks against the new
revision, preserves `[x] Done` history (Hard Contract 8 carve-out — regen is neither
overwrite nor plain merge), supersedes the old Runbook PR (see AV3-08) and closes
orphaned draft Story PRs it lists.
**Acceptance:** `[det]` drift detection + Resume refusal in script fixtures;
`[drain]` the regen re-plan quality.

### AV3-05 — Behavior-ID → test-ID binding at D7.3/D7.4, verified at D6 [MS §13.9, §13.11]
D6 verifies each Subtask's `behavior_ids[]` against git log + test run; D7.3 writes a
`## Behavior coverage` PR-body section (behavior ID → test node IDs, documented
grep-able format); D7.4 mirrors to tracker. Consumed by the PR Gate per MS §13.11
(the spec-gen SG-8 provenance check is a separate codebase-health entry).
**Acceptance:** `[det]` PR-body section format pinned by lint; a
`scripts/audit_behavior_binding.sh` checks a git-log fixture (RED commit naming a bound
test per behavior). `[drain]` end-to-end coverage fidelity.

## B. Granularity + trunk-based (ADRs 0007, 0012)

### AV3-06 — PR-per-Story: Hard Contracts 1 and 4 rewritten
One Story = one branch (`autopilot/<slug>/<story-id>`) = one PR; Subtasks are the commit
series. **Enumerated v2.4.0 surface this rewrites** (round-1 finding — none of this is
"unchanged"): D6.2's audit range becomes `in_progress.prev_pushed_sha..HEAD` (the Story
branch accumulates prior Subtasks' commits); D1.4 WIP rows and D4 branch table re-key
from Subtask-branches to Story-branches; D7.0 rebase base is the Story branch.
**Draft mechanics are a new host-surface deliverable:** `pr-open --draft`, `pr-ready`,
`pr-state` gains `DRAFT` emission, mock-server support, and a DC-version fallback
(title-prefix `[DRAFT]` convention when the server predates draft PRs).
**Story lifecycle rules:** ready-flip requires ALL Story Subtasks `[x] Done` (never
positional); D2 gains story-affinity (finish or block out the open Story before opening
another — at most one draft Story PR per drain at a time); on terminal STATUS the
end-of-drain output lists every dangling draft PR with required operator disposition.
`branching.single_branch_single_pr` remains the coarser collapse; MERGE-ORDER.md +
AP-10 re-scope to Story PRs.
**Acceptance:** `[det]` bitbucket.sh draft-surface tests (mock matrix incl. fallback);
D6-range script fixture (two-Subtask git-log, no false `tdd-scope-leak`); lint rewrites
the one-PR-per-Subtask phrasing rules. `[drain]` story-affinity discipline.

### AV3-07 — 48-hour Story sizing invariant at G4 [ADR 0012]
G3 planner schema gains `predicted_hours` (integer; AP-3 allow-list updated; normative
S/M/L sanity mapping S≤4, M≤16, L≤48 — an L-labeled Story predicting >48 is
schema-inconsistent). G4 refuses `predicted_hours > 48`: `[GENERATE-FAILED:
story-oversized: <story-id>]` → planner splits into sequential, independently mergeable
Stories. The gate is deterministic-over-a-declared-prediction; the Marshal owns actuals
(ADR 0012). Runbook records behavior-IDs-per-Story (audit distinguishes
intentionally-not-yet-wired from Memory Rot).
**Acceptance:** `[det]` schema validation + refusal fixture in
`validate_plan_mapping.sh`; runbook template shows the per-Story table.

## C. Coordination (ADR 0009)

### AV3-08 — Runbook PR at Pickup replaces the rolling tracker PR
G7 opens the Runbook PR immediately (runbook + tracker on `autopilot/<slug>/runbook`);
its body carries the predicted file surface (grep-able block). **It subsumes tracker
bookkeeping**: the rolling tracker PR pattern is retired (tracker-PR availability table
and D7.1a fold re-scope to the Runbook PR under both `no_force_push` settings) — one
bookkeeping home, no duplicate tracker copies, no self-intersecting claim surfaces.
**Merge actor:** the operator (or the Marshal once built) — the Runbook PR joins
MERGE-ORDER.md as its final entry; on `HUMAN_NEEDED`/`PAUSED` the end-of-drain output
lists it with disposition (autopilot NEVER merges its own PRs; Hard Contract 4 spirit).
**Acceptance:** `[det]` G7 script-level: file-surface block format lint; tracker-fold
fixture against the Runbook branch. `[drain]` claim usefulness to foreign planners.

### AV3-09 — Claim-overlap consultation at G4 + D2, with self-claim exclusion
One vendored primitive (`scripts/claim_overlap.sh <files...>` — open-PR file-surface
intersection via the host adapter), two consumers: **G4** (plan-time): overlap with a
foreign binding claim → tracker-schema `blocked_by_pr: <host>/<pr#>` edge on the
affected Subtask (new field; D2-evaluable). **D2** (fire-time): a Subtask whose
`blocked_by_pr` PR is not yet MERGED/DECLINED is ineligible (checked via `pr-state`
poll, same cadence as D7.5); if ALL open Subtasks are claim-blocked → **wait state**:
re-arm at `*/30`, re-check next fire; escalate to `HUMAN_NEEDED — claim-deadlock` only
after `budget.max_claim_waits` (default 16) consecutive claim-blocked fires. NEVER
terminal-pause on first blockage (ADR 0009: a drain re-queues at no one's cost).
**Self-claim exclusion:** branches under this drain's own `autopilot/<slug>/*` namespace
are never foreign claims (closes the re-GENERATE self-deadlock).
**Acceptance:** `[det]` `claim_overlap.sh` fixture matrix (foreign draft = binding,
foreign ready = terminal, own-namespace excluded, stale >2bd = advisory); D2
eligibility fixture with `blocked_by_pr`. `[drain]` end-to-end serialization.

### AV3-10 — Serialize-and-replan on claim-loss divergence
When D7.0's budget trips (`[BLOCKED: rebase-too-large]`) AND `hot_file_audit.sh
--subtasks` attributes the divergence to a claim collision, route to D3 re-plan against
new trunk instead of the impl-block escalation path; tracker records
`replanned-after-claim-loss` (bounded: 2 re-plans per Subtask, then normal escalation).
**Acceptance:** `[det]` the attribution decision extracted to a script predicate
(overlap file list ∩ conflicting hunks) with fixtures. `[drain]` re-plan quality.

## D. Quality shift-left

### AV3-11 — Implementer anti-flakiness contract
Implementer prompt gains hard rules: no sleeps for synchronization, seeded randomness,
injected clock, faked transport, order-independent tests. Violations are **design
validator** findings (test quality is design's remit per the validator catalog),
`severity: high, blocking: true`.
**Acceptance:** `[det]` prompt text + validator-catalog routing pinned by lint.
`[drain]` detection recall (agent-judged residual, stated honestly).

### AV3-12 — D6 closing-test determinism gate (N=5)
D6 runs the Subtask's changed tests 5× via `gates.test_scoped` ({paths} = the Subtask's
test files); one round order-randomized via new optional `gates.test_random` — when the
repo has no randomization mechanism, that round is skipped with a loud `[note]` (never
silently). Any inconsistency → `[BLOCKED: flaky-test]` (impl-block counter). Bounded:
the Subtask's own test selection, never the full suite.
**Acceptance:** `[det]` gate-template resolution + skip-note behavior in script
fixtures; the 5×-loop lives in `scripts/determinism_gate.sh` (runner-agnostic: takes
the resolved command, compares 5 exit codes + failure sets) with deterministic and
planted-flaky fixtures. `[drain]` orchestrator invoking it at D6.

### AV3-13 — Escalation rule vendored into role prompts [ADR 0002]
Planner + implementer prompts carry the ADR 0002 criterion + MUST-escalate trilist
verbatim (same block as spec-gen S4); lint enforces byte-identical vendored copies.
**Acceptance:** `[det]` lint rule diffs the vendored blocks; planted drift red.

### AV3-14 — As-built docs are Story deliverables
Story plans include as-built doc edits (journey docs, README deltas) in the SAME Story
PR; the integration validator checks presence when the Story's behaviors are
journey-bearing per the manifest.
**Acceptance:** `[det]` runbook-template deliverable slot + validator-prompt rule
pinned by lint. `[drain]` the check firing (agent-judged).

## E. Host adapter — FLAGGED FOR BAILEY (priority call)

### AV3-15 — Host adapter: GitHub backend behind the existing subcommand surface
`scripts/host.sh` dispatch (BITBUCKET_DC | GITHUB) exposing the current surface
(`pr-open[-–draft]`, `pr-ready`, `pr-state`, `pr-comment`, `pr-merge`, `build-status`,
…); `bitbucket.sh` becomes the DC backend; a `gh`-CLI backend implements the same
contract; probe detects host from `origin`. Hard Contract 11 rewrites to "the host
adapter is the single PR/build surface." Exists to let the suite drain its own
registers here; DC remains the enterprise target.
**Acceptance:** `[det]` the T01-class mock matrix runs against both backends (gh argv
shim). Decision recorded in the PR review, either way.

## F. Meta

### AV3-16a — SKILL.md rewrite, host-independent half
Hard Contracts 1/4 rewritten (AV3-06), mode table (AV3-01), flag registry (`--yolo`
scope narrowed; `--merge` revision-regen mode documented), reference index updated.
CHANGELOG v3.0.0 cites assertion IDs (M3 gate).
**Acceptance:** `[det]` lint: planted one-PR-per-Subtask phrasing red.

### AV3-16b — SKILL.md rewrite, host half [conditional on AV3-15]
Hard Contract 11 → host-adapter wording; L-rule for legacy host phrasing.
**Acceptance:** `[det]` planted "Bitbucket DC is the source-of-truth host" red.

### AV3-17 — Self-test growth accounting
Every `[det]` acceptance lands in `self_test.sh` (96 → ~125) / `lint_consistency.sh`
(L16+); every register item's FIXED status cites its `[det]` assertion IDs, with
`[drain]` residuals listed under Honest Residuals per the v2.4.0 convention.
**Acceptance:** `[det]` suite green; register statuses cite real IDs.

## Non-goals for v3
Marshal implementation (ADRs 0010/0011 — but AV3-08's merge-actor slot is
Marshal-ready); PR Gate provenance/coverage checks (codebase-health register);
remediation-loop wiring; headless mode (AP-19 stands); Jira epics (ADR 0009: one Jira
per Story — G6 update rides AV3-06).
