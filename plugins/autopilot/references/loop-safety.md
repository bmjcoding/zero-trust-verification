# Loop-safety invariants

> Binding on every GENERATE/DRAIN/RESUME step. A loop that acts on flawed logic
> is worse than no loop: it damages the codebase at machine speed. These
> invariants bound the blast radius of any orchestrator or script defect so a
> wrong loop costs wrong reports or a stalled drain — never damaged code, lost
> history, or a stolen lock. Each invariant names its enforcement mechanism;
> an invariant without an enforcement point is a wish, not an invariant.

## 1. Probes never mutate operator-visible state

The G1.5 repo-shape probe may create/delete ONLY branches matching
`autopilot/probe-*-<PID>`, never touches trunk or operator branches, restores
the original HEAD via its EXIT/INT/TERM trap, and requires the G1 clean-tree
refusal to have passed first. `--dry-run` previews every operation.
*Enforced by:* `repo_shape_probe.sh` (trap + fixed branch names); G1 ordering.

## 2. `unknown` never auto-flips a flag

Probe results of `unknown` never seed runbook frontmatter; they surface as G8
review warnings and the operator decides. A failed probe therefore degrades to
"operator decides", never to "loop guesses".
*Enforced by:* generate-lifecycle G1.5 auto-seed rules; runbook-template
auto-seed table.

## 3. Guards fail closed

Any guard that cannot read the state it guards must refuse, not proceed:
`detect_concurrent_drain.sh` exits 4 (refuse) on unreadable/corrupt lock
state; D1 refuses the fire when `STATUS` is unreadable or not `ACTIVE`;
D3.0 blocks on any staleness ambiguity; the D2 claim-eligibility gate routes
`claim_overlap.sh eligibility` exit 64 (an unresolvable `host.sh pr-state` —
`UNKNOWN` from a read that succeeded but returned an unmappable state, or an empty
state when the read itself died) to `HUMAN_NEEDED — claim-eligibility-usage-error`
rather than run a Subtask against an unresolved claim. The one deliberate fail-open is a
MISSING tracker file at GENERATE time (nothing exists to collide with).
*Enforced by:* `detect_concurrent_drain.sh` exit-code contract (self-tested);
`claim_overlap.sh` eligibility exit-64 contract (self-tested, AV3-09.8);
D1/D2/D3.0 step text.

## 4. Detection and verification paths never edit product code

G1–G8 write only the runbook + tracker (and probe temp branches). D1–D3, D5,
D6, D7.5, D8 write only tracker/runbook state. Product-code edits happen ONLY
in D4 (implementer subagent) and D7.0 (conflict resolution), both inside the
Subtask's `owned_files[]` ownership window. (The D1.2 foreign-dirty stash is
state preservation, not an edit: foreign paths are stashed under a label and
popped at D8 — or, on pop conflict, preserved in the stash and drift-noted —
never modified, never dropped.)
*Enforced by:* Hard Contract §10 (orchestrator-direct allow-list) + the
implementer's file-ownership rules + the integration validator's out-of-scope
check (high, blocking).

## 5. History is append-only during a drain

No `--no-verify`, no trunk rebases, no amend/squash of per-cycle commits, no
force-push except a consolidating force-push of the Runbook PR branch
(`autopilot/<slug>/runbook`, AV3-08) where the repo allows it — under
`no_force_push: true` even that is disabled and bookkeeping appends only.
The TDD evidence D6 audits is immutable once written.
*Enforced by:* Hard Contracts §5/§7; implementer prompt critical rules 5–6;
conflict-resolution DO-NOT list.

## 6. Every override is audited

`--force` and every operator override that contradicts a refusal or a probe
finding is logged to `## Force Audit` with timestamp + flag + reason (AP-11).
The dispatcher reads the audit trail for humans, never for control flow.
*Enforced by:* AP-11 logging at each refusal site.

## 7. Terminal states always release the loop's resources

Every terminal STATUS (`DRAINED | PAUSED | HUMAN_NEEDED | STOPPED`) deletes
the cron and releases the session lock, in that fire. A crashed fire's lock
self-expires (`session_lock_expires_at`, 30 min) and its unflushed deltas are
preserved (never silently dropped) by D1.0.4 crash recovery.
*Enforced by:* D8 session-lock release; cadence-dispatch terminal cleanup;
D1.0.4 recovery cases.

## 8. Counters cannot be starved or masked

Impl and CI failures escalate on separate counters with runbook-configured
caps; external faults route straight to HUMAN_NEEDED without touching
counters, so an environmental outage can neither mask nor inflate a real
implementation failure streak. Wall-clock is independently capped by
`budget.max_runtime_minutes`.
*Enforced by:* AP-2 routing rules (every `[BLOCKED]` carries a domain tag);
D1.2 runtime budget check.

## 9. Secrets never enter the model's context or the process table

Tokens flow sidecar → keychain → env, are never positional args, never echoed,
never in curl argv (0600 header file via `-H @file`), never in `set -x`
traces, and response bodies of auth-failure statuses are never logged.
*Enforced by:* `secret_get.sh` / the host-adapter backends (`bitbucket.sh`,
and `github.sh` which delegates auth to `gh`) implementation (self-tested);
sidecar-contract hard rules. Secret handling is a per-backend property behind
the `host.sh` surface (ADR 0013).

## 10. The skill's own changes are gated by executed evidence

Every behavioral claim in a CHANGELOG release entry must cite a
`self_test.sh` assertion id (or be tagged `[doc-only]`), and any drain failure
attributable to the skill must land a failing self-test assertion before or
with its fix — a gap found once cannot recur silently. Cross-file contract
drift is caught by `lint_consistency.sh`.
*Enforced by:* CHANGELOG release-gate header; `scripts/self_test.sh` +
`scripts/lint_consistency.sh` (run before tagging any release).

## Known limitations (honest residuals)

- The orchestrator contract (delegation, step ordering, first-action gate)
  binds an LLM through prose; the self-test proves the deterministic substrate
  only. Internal consistency (invariant 10) removes the worst failure
  injector — contradictory instructions — but drain-time compliance is
  measured only by real drains and Drift Notes.
- Under `branching.no_force_push: true`, the AP-4 session lock is
  checkout-local until the next D7.1a fold lands (see drain-lifecycle D1.0
  note); cross-clone concurrency relies on the branch-namespace check.
- Bitbucket DC behavior is verified against a mock in the self-test;
  DC-version quirks remain field-verified.
