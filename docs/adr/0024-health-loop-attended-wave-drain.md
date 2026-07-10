# /health-loop: attended wave drain — merge-before-verify, delegated approval, stateless position

---
status: accepted
date: 2026-07-10
---

The first e2e field drain (audit-w345, autopilot 3.1.0) surfaced the question
this ADR answers: *"why do I need to run a verify after every wave? I want
audit → drain → verify to run end-to-end from one prompt, continuing until the
original audit is drained."* The suite had every seam — `/audit` emits a
wave-structured `SPEC.md` joined to `state.json` by fingerprint, autopilot
drains specs autonomously, `/verify` re-judges fingerprints with evidence, the
Marshal merges approved PRs after a composed-state build — but no owner for the
sequence, and three open policy questions: wave awareness, machine-consumable
verification, and merge authority.

`/health-loop` is that owner: an operator-initiated, wave-granular drain
campaign homed in codebase-health (the `/remediate` precedent — wiring, not a
checker; no marketplace entry, six plugins unchanged).

## Decision

**1. Merge-before-verify is a correctness requirement, not review ceremony.**
`/verify` grades the *checkout*: it re-reads symbols at `path:symbol` and reruns
closing tests in the working tree. A wave's fixes living on unmerged Story
branches would all grade OPEN. Therefore the loop's unit is: drain wave N →
merge wave N → `/verify --strict` → gate → wave N+1. This also means every wave
is GENERATE'd fresh against post-merge trunk, so autopilot's AP-5 audited-SHA
gate holds naturally and cross-wave merge conflicts structurally cannot occur.
Composed-state verification of unmerged waves is rejected — it would duplicate
the Marshal's composed build to shave latency off a correctness boundary.

**2. No autopilot changes.** Waves are markdown sections; slicing them is a
deterministic text operation, not an extraction behavior. `spec_wave.sh`
(codebase-health) slices `SPEC.md` into per-wave docs fed to
`/autopilot --generate @audit/waves/wave-<N>.md --slug=audit-w<N> --yolo` as
ordinary bare-markdown input. A `--wave` flag inside autopilot was rejected: it
would touch the pinned flag registry, the extractor prompt, the self-test, and
the lint of the suite's most safety-critical plugin to save one awk script, and
wave *ordering* belongs to the loop, not to the drain's intra-wave DAG.
Per-wave slugs give free per-wave trackers, session locks, budgets, and
concurrent-drain refusal. `--yolo` here is exactly its documented semantics —
the operator's explicit drain-autonomy authorization, granted once at loop
kickoff; it is not merge authority.

**3. No `/verify` changes.** `audit/state.json` is already the machine-readable
record of `/verify`'s judgment. The gap was a *reader*, not a new verify mode:
`wave_gate.sh` maps a wave's fingerprints to ADVANCE / INCOMPLETE /
REGRESSION-or-RATCHET / UNREADABLE (exit 0/2/3/4), scanning REGRESSED globally
(a loop that regressed the codebase stops, wave-scoped or not) and mirroring
`/verify`'s own ratchet rules. A `verify --auto` that changed grading was
rejected: a second grading path is drift risk, and loop-safety invariant 7
(evidence or it didn't happen) is not negotiable. A consumer that re-grades a
verdict is a defect.

**4. Merge authority: the Marshal executes, the operator authorizes — with a
double-keyed delegation hatch.** Autopilot Hard Contract §4 (never merges its
own PRs) is untouched; this ADR is the only document permitted to relax the
suite's "no auto-merge" language, and it relaxes *approval*, never execution:

- Default (`merge: pause`): the loop stops at each drained wave, presents
  MERGE-ORDER.md, and one operator answer approves the wave's PRs; the Marshal
  (or the operator) merges. ≤5 interactions per audit, each a single
  approve/deny — the same review `/remediate` output already receives,
  amortized to wave boundaries.
- Hatch (`merge: preauthorized`, double-keyed): key 1 is the per-repo config
  flip; key 2 is an explicit per-run confirmation at kickoff naming the
  auto-class waves. **Auto-class for delegation** = wave_policy `auto` (after
  per-run overrides) ∩ the key-2-named set ∩ no item ≥
  `severity_ceiling_for_auto`; a mid-campaign `--auto-waves` override can
  never widen delegation past the grant — adding a wave requires a fresh,
  journaled key-2 confirmation. Under both keys, for auto-class waves only, the loop runs
  `host.sh pr-approve` as the operator's *logged delegate* — but only after
  `wave_preauth_check.sh` proves deterministic evidence on disk (P1 tracker
  DRAINED; P2 every Story Subtask `[x]`; P3 no `[BLOCKED:]` history for the
  story; P4 changed files ⊆ the Runbook PR's predicted file surface,
  exact-match allow-list). Every delegated approval is journaled. The Marshal
  still merges only APPROVED PRs after its composed-state build — zero-trust
  execution is never waived. This scales the SKILL.md carve-out ("a logged,
  operator-confirmed merge under operator-as-reviewer is the operator's own
  action") from one PR to one declared wave-class, which is exactly why it
  needs this ADR.

**5. Stateless position + append-only journal.** The loop persists no state
machine. Its position is a pure function of three records that already exist:
`SPEC.md` waves × `state.json` statuses × per-wave tracker `STATUS`. Every
invocation recomputes it from disk, so crash recovery, resume-in-a-fresh-session
(the loop spans hours; context exhaustion is expected), and re-invocation are
the same operation, and a `loop_state.json` that could drift from the three
real sources cannot exist. The one thing that needs memory — kickoff
authorizations, delegated approvals, the drift-regen retry count, the campaign
wall-clock anchor — goes to `audit/loop_log.md`, append-only. The invariant is
scoped precisely: the journal is never read to compute *position*, but it IS
read — as the only possible source — to enforce budgets and the key-2 grant.
A missing or unreadable journal means no grant and no regen budget: fail
closed, never a wider delegation.

**6. Depth 0: the loop never re-fixes.** PARTIAL, STALE, and REGRESSED verdicts
pause or halt; they are never re-sliced into a new drain. Remediation Guard 2
caps fix-of-a-fix at depth 1 for a drip-cadence loop; this loop is
higher-throughput, so its bound is stricter. Tail-chasing is impossible by
construction: each fingerprint drains at most once per campaign.

**7. Coexistence with `/remediate`: the drip and the drain.** `/remediate` is
ambient, finding-granular, cron-friendly, and filtered by ADR 0004 (agent-scored
findings never auto-drain). `/health-loop` is operator-initiated, wave-granular,
and *attended*: its HIGH+ items passed adversarial verification in `/audit`,
its per-wave gates pause on judgment calls, and (by default) a human approves
every merge. It therefore drains a whole wave without per-finding eligibility
filtering — but it is not a bypass of ADR 0004's boundary: any future
*unattended* firing of this loop must go through `/remediate`'s eligibility
path. Anti-collision: the loop stamps each fingerprint it drains into the same
`remediation` sub-object Guard 1 reads — `status: PR_OPEN`, `ref` prefixed
`health-loop:` (the sub-object's schema is `{status, ref, opened_at,
remediation_depth}`; provenance rides the free-form `ref`, the backend is not
extended) — so a cron `/remediate` pass SKIPs them; the loop refuses to start
while open `remediation/*` PRs overlap its fingerprints.

## Considered Options

- **`autopilot --wave N` flag** — rejected (decision 2): v3.2 churn of the
  safety-critical plugin for capability a slicer provides.
- **`verify --auto` / `--json` verdict artifact** — rejected (decision 3):
  state.json is the machine surface; second grading path is drift.
- **Autopilot merges under a flag** — rejected outright: HC §4 verbatim, and
  `--yolo`-is-not-merge-authority is load-bearing across the docs.
- **Always-pause with no delegation hatch** — rejected as the only mode: it
  fails the field ask for Wave-1-class changes; kept as the shipped default.
- **`loop_state.json` state machine** — rejected (decision 5): second source
  of truth; statelessness makes resume free.
- **Auto-refix of PARTIAL (`advance-and-carry`)** — rejected for v1: the only
  place the loop could outrun its verification.
- **Mid-loop re-audit** — rejected: detection firing during action churns the
  work queue; fingerprint aliases + STALE absorb drift, and the final
  `/verify --strict` is the refresh point.

## Consequences

- New deterministic substrate in codebase-health (`spec_wave.sh`,
  `wave_gate.sh`+`.py`, `wave_preauth_check.sh` — self-tested HL-01..03) and a
  new command `commands/health-loop.md` + `references/health-loop.md` +
  `loop.config.yaml`. No new plugin; no change to autopilot, marshal, spec-gen,
  or `/verify`.
- The operator experience: one prompt starts the campaign; the loop pulls the
  operator back only at wave-merge approvals (unless preauthorized), autopilot
  escalations, and PARTIAL/REGRESSED gates. Ending a session mid-campaign is
  safe by design.
- Root lint gains a presence/vocabulary pin for the loop's pieces (V13,
  follow-up PR) and the suite self-test gains an e2e loop fixture.
- `stdout_logging_count` remains report-only everywhere, including the gate;
  severity confirmation gates and adversarial verification of HIGH+ items are
  unchanged — the loop consumes their output, it never re-scores.
