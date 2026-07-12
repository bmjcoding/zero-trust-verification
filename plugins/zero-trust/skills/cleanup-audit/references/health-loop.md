# Health-loop — the attended wave drain (ADR 0024)

`/health-loop` owns the sequence: `/audit` → per-wave `/autopilot` drain →
merge → `/verify --strict` → gate → next wave, until the original audit is
drained. It is **wiring, not a checker** (the `/remediate` posture): it holds
no quality opinion, runs no detector, and every advance/pause decision is a
deterministic script's exit code or an explicit operator authorization.

The invariant that shapes everything: **merge-before-verify is a correctness
requirement.** `/verify` grades the checkout — unmerged Story-branch fixes
grade OPEN — so a wave must be merged before it can be verified, and each wave
is GENERATE'd fresh against post-merge trunk (AP-5 holds naturally; cross-wave
conflicts cannot occur).

## Position is computed, never stored

The loop persists no state machine. Its position is a pure function of three
records that already exist, re-derived on every invocation:

| Record | Question it answers |
|---|---|
| `audit/SPEC.md` waves (`spec_wave.sh waves`) | what work exists, in what order |
| `audit/state.json` statuses (`wave_gate.sh`) | which waves are proven done |
| `.autopilot/runbooks/audit-w<N>.tracker.md` `STATUS:` | what the drain is doing right now |

Re-invoking `/health-loop` in a fresh session — after a crash, a context
limit, or a week — is the resume story. There is no other resume story.

`audit/loop_log.md` is an **append-only journal**: kickoff authorizations
verbatim, every delegated approval, every drift-regen retry, the campaign
start line. It is never read to compute *position* (that would make it a
second source of truth) — but it IS the authoritative record for the three
things only it can know: the campaign wall-clock anchor
(`budget.max_wall_minutes`), the per-wave regen-retry count, and whether — and
for exactly which waves — the key-2 kickoff grant was given. A fresh session
enforcing budgets or exercising delegated approval MUST read those journal
entries first; a missing/unreadable journal means no grant and no regen budget
(fail closed).

## One invocation, step by step

**0. Refuse-checks** (any failure stops before any action):
`audit/state.json` readable; `spec_wave.sh waves audit/SPEC.md` succeeds (exit
3 → this repo's spec has no waves; the tool is wrong, not the doc); no live
session lock on any `audit-w*` tracker (`detect_concurrent_drain.sh`); no open
`remediation/*` PRs overlapping the spec's fingerprints (Guard-1 collision);
campaign wall-clock inside `budget.max_wall_minutes` (anchored on the first
journal line).

**1. Kickoff** (only when no `audit-w*` tracker exists yet): run `/audit`
unless `state.json` holds a same-target `kind:"audit"` run at the current
trunk SHA, or `--use-existing-audit` was passed (journaled). If `merge:
preauthorized`, ask ONE kickoff question naming the auto-class waves this run
may approve (key 2 of the hatch) and journal the answer verbatim.

**2. Walk waves 1..N; act on the FIRST wave that is not complete:**

| Observation | Action |
|---|---|
| `wave_gate.sh` exit 0 for the wave's fingerprints | Wave complete — next wave. |
| No tracker for `audit-w<N>` | `spec_wave.sh forward-deps` (exit 1 → refuse, name the deps); policy gate: `wave_policy` `auto` → proceed, `pause` → one question ("Wave 3 — Security, 4 items, proceed?"); any item ≥ `severity_ceiling_for_auto` forces the question. Then `spec_wave.sh slice` → `/autopilot --generate @audit/waves/wave-<N>.md --slug=audit-w<N> --yolo`. |
| Tracker `ACTIVE`, live lock | A drain fire is running. Report and END THE TURN — autopilot's own cadence drives it; the loop never idle-waits. |
| Tracker `ACTIVE`, stale lock + dead-session signal | `/autopilot --resume @.autopilot/runbooks/audit-w<N>.md` — the RUNBOOK path, not the tracker (autopilot's RESUME contract derives the slug from the runbook filename and refuses otherwise). |
| Tracker `PAUSED — manifest-revision-drift` | One `--generate --merge` regen per wave (journaled; `budget.max_wave_regen_retries`), else stop. |
| Tracker `HUMAN_NEEDED` / `STOPPED` / other `PAUSED` | Relay the tracker's own escalation VERBATIM and stop. Never retry past autopilot's caps — retrying a HUMAN_NEEDED launders an escalation into a loop. |
| Tracker `DRAINED`, PRs unmerged | **Merge step** (below). |
| PRs merged, gate not yet green | `git pull` trunk → `/verify --strict` → `wave_gate.sh` → route (below). |

**3. The merge step** at a drained wave.

**Auto-class is defined once, here:** a wave is auto-class for *delegated
approval* iff ALL of — (a) `wave_policy` says `auto` after per-run overrides,
(b) the wave was NAMED in this run's key-2 kickoff grant (journaled), and
(c) no item in the wave is at or above `severity_ceiling_for_auto` (the
ceiling disqualifies a wave from delegation exactly as it forces the
generate-time question). A mid-campaign `--auto-waves` override can therefore
never widen delegation past the key-2 grant: adding a wave to the delegated
set requires a FRESH key-2 confirmation naming it, journaled like the first.
Everything else is pause-class.

- *Pause-class wave, or `merge: pause`* — **Pause A**: print `MERGE-ORDER.md`,
  ask one approval question. Operator approves → the Marshal (or the operator)
  merges; operator declines → stop, campaign resumes whenever they return.
- *Auto-class wave under the double-keyed hatch* — for each Story PR:
  `wave_preauth_check.sh --tracker <t> --story <id> --branch <ref> --base
  <trunk> --pr-body <runbook-pr-body>`; ALL pass → `host.sh pr-approve` each
  (one journal line per approval) → invoke `/marshal-pass` ONCE; if
  `host.sh pr-state` does not yet report MERGED for every wave PR, report and
  END THE TURN like any other in-flight work — the loop never idle-waits.
  ANY preauth refusal or Marshal kickback (Composition Break, rebase budget)
  → pause with the PR and the named reason. Delegation covers approval only;
  the Marshal's composed-state build is never waived.

**4. The verify gate** after a merged wave — `wave_gate.sh <state.json>
<wave-fingerprints>`:

| Exit | Meaning | Route |
|---|---|---|
| 0 | every fingerprint FIXED/WONTFIX, no REGRESSED anywhere, ratchet flat | Next wave. |
| 2 | OPEN/PARTIAL/STALE in this wave | **Pause B**: report the worst PARTIAL verbatim. Never auto-refix (depth 0). |
| 3 | REGRESSED anywhere, or ratchet increase | **Halt**: the drain damaged the codebase; a human decides. |
| 4 | state unreadable or spec↔state desync | Stop, fail closed, never guess. |

**5. Campaign end**: all in-scope waves gated → final `/verify --strict` over
the campaign's fingerprint set (all waves, or waves ≥ `--from-wave N` when
scoped — excluded waves' fingerprints are reported as *out of campaign scope*,
never graded as failures) → report DRAINED with the per-wave summary. A
re-invocation over a drained campaign is a no-op that says so.

## Cross-domain dependencies

The loop is codebase-health wiring over the same plugin's **autopilot** domain
(drain, `host.sh`, `detect_concurrent_drain.sh` — resolved at
`skills/autopilot/scripts/`, overridable the `RUNBOOK_PR_SH` way) and its
**marshal** domain (`/marshal-pass` merge execution). Absent either, the loop
refuses at the step that needs them and names the missing component — it never
degrades to merging or draining by other means. The presence pin is root lint
V13.

## Failure routing (who owns what)

- **Drain-side faults** (impl blocks, CI reds, validator contradictions,
  foreign commits): autopilot's counters and HUMAN_NEEDED routing own them;
  the loop relays and stops.
- **Merge-side faults** (compose breaks, rebase budget): the Marshal's
  kickback comments own them; the loop relays and pauses.
- **Verification faults** (PARTIAL/REGRESSED/ratchet): the gate owns them; the
  loop pauses or halts and never re-fixes.
- **Loop-side faults** (missing waves, forward deps, desync, corrupt state,
  budget exhaustion): refuse loudly before acting; broken state degrades to
  less action (loop-safety invariant 4, `references/loop-safety.md`).

## Non-goals (v1)

No autopilot or `/verify` changes; no auto-merge execution under any config;
no auto-refix of PARTIAL/REGRESSED (`advance-and-carry` rejected); no mid-loop
re-audit; no composed-state verification of unmerged waves; no headless
daemon/external scheduler (AP-19); no `loop_state.json`; no new plugin; no
eligibility filtering re-implemented (unattended firing belongs to
`/remediate`, ADR 0004).
