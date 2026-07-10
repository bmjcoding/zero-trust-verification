---
description: Run the audit → drain → verify loop end-to-end from one prompt — slice audit/SPEC.md into waves, drain each through autopilot, merge (operator-approved, or delegated for auto-class waves under the double-keyed hatch), verify with evidence, and continue until the original audit is drained. Attended sibling of /remediate; pauses wherever judgment is required.
argument-hint: "[--auto-waves <list>] [--pause-waves all] [--use-existing-audit] [--from-wave <N>] [--dry-run]"
---

# /health-loop

The **campaign** counterpart to `/remediate`'s drip (ADR 0024): one prompt runs
`/audit` → per-wave `/autopilot` drain → merge → `/verify --strict` → gate →
next wave, until the audit is drained. Wiring, not a checker — the command
orchestrates; every judgment is a deterministic script call
(`spec_wave.sh` · `wave_gate.sh` · `wave_preauth_check.sh`), an autopilot/
Marshal/verify verdict relayed verbatim, or an explicit operator authorization.

Read the `cleanup-audit` skill → `references/health-loop.md` first — it is the
canonical loop text (position function, the per-invocation walk, merge step,
gate routing, failure ownership). This command adds only invocation modes and
posture.

## Posture (read first)

- **Merge-before-verify is a correctness rule.** `/verify` grades the checkout;
  a wave verifies only after its PRs merge. The wave-boundary stop is not
  ceremony — it is where the loop's evidence comes from.
- **The loop never merges and never self-authorizes.** Default (`merge: pause`
  in `loop.config.yaml`): one approval question per drained wave; the Marshal
  or the operator merges. Under the **double-keyed hatch** (`merge:
  preauthorized` AND a per-run kickoff confirmation) the loop may
  `host.sh pr-approve` auto-class waves as the operator's **logged delegate**,
  only after `wave_preauth_check.sh` proves P1–P4 on disk per Story PR. The
  Marshal's composed-state build still executes every merge. Autopilot HC §4
  untouched.
- **Depth 0.** PARTIAL/STALE pause, REGRESSED or a ratchet increase halts;
  nothing is ever re-fixed by the loop.
- **Stateless.** Position is recomputed from `SPEC.md` × `state.json` ×
  tracker `STATUS` on every invocation; ending the session mid-campaign is
  safe. `audit/loop_log.md` journals authorizations/approvals/retries,
  append-only. It is never read to compute position — but it IS the
  authoritative record for budgets and the key-2 grant (which waves may be
  delegation-approved); a missing journal means no grant, fail closed.

## Modes

| Invocation | Behavior |
|---|---|
| `/health-loop` | Start or resume the campaign: run/reuse the audit, then act on the first non-complete wave (see the reference's dispatch table). |
| `/health-loop --dry-run` | Print the wave plan, per-wave policy routing, and what the next invocation WOULD do. Touches nothing. The safe first look. |
| `/health-loop --auto-waves 1,4` | Per-run override of `wave_policy` for GENERATE-time pauses (journaled). It can never widen merge delegation by itself: under `merge: preauthorized`, adding a wave to the delegated set requires a fresh key-2 confirmation naming it (see the reference's auto-class definition). `--pause-waves all` forces every wave to ask. |
| `/health-loop --use-existing-audit` | Skip the kickoff freshness check and drain the `SPEC.md` on disk (journaled). |
| `/health-loop --from-wave 3` | Treat waves < 3 as out of scope for this campaign (journaled). Their fingerprints are not gated and the final verify reports them as out-of-scope, never as failures. |

There is no `--resume` flag because every invocation is a resume.

## What one invocation does

1. **Refuse-checks** — state readable, spec wave-structured, no live drain
   lock, no `remediation/*` PR overlap, budget not exhausted. Fail closed,
   loudly, before any action.
2. **Kickoff** (first run only) — `/audit` unless fresh-at-trunk-SHA or
   `--use-existing-audit`; under `merge: preauthorized`, ask the ONE kickoff
   question naming the auto-class waves (key 2) and journal it verbatim.
3. **Dispatch on the first non-complete wave** — per the reference table:
   generate (`spec_wave.sh slice` → `/autopilot --generate @audit/waves/wave-<N>.md
   --slug=audit-w<N> --yolo`), or relay a live/blocked drain, or run the merge
   step, or run `/verify --strict` + `wave_gate.sh` and route 0/2/3/4 →
   advance / Pause B / halt / stop.
4. **End the turn at every pause and at drain-in-flight** — autopilot's cadence
   owns the drain; the operator owns approvals; the next invocation recomputes.
5. **Campaign end** — final `/verify --strict` over the campaign's fingerprint
   set (out-of-scope waves under `--from-wave` reported, never failed); report
   DRAINED per-wave. Re-running a drained campaign is a no-op that says so.

Requires autopilot (drain, `host.sh`, lock checks) and marshal (merge
execution) installed; the loop refuses and names the missing plugin rather
than improvise either role. See the reference's "Cross-plugin dependencies".

## Which loop?

| | `/remediate` | `/health-loop` |
|---|---|---|
| Cadence | ambient / cron drip | operator-initiated campaign |
| Granularity | one finding | one wave |
| Filtering | severity floor + deterministic provenance (ADR 0004) | whole wave; HIGH+ already adversarially verified; per-wave pause gates |
| Merges | never | never executes; delegated *approval* only under the double-keyed hatch |
| Verification | none (files PRs) | `/verify --strict` + `wave_gate.sh` at every wave boundary |
| Unattended | yes, by design | no — unattended firing must go through /remediate's eligibility path |

Anti-collision: the loop stamps drained fingerprints into the `remediation`
sub-object via `remediation_state.py stamp --status PR_OPEN --ref
health-loop:<host-pr-ref>` (provenance rides the `ref` prefix; the additive
Guard-1 write is the loop's ONLY state.json mutation, same as `/remediate`'s)
so a cron `/remediate` pass SKIPs them, and the loop refuses to start while
open `remediation/*` PRs overlap the spec.

## Non-goals (v1)

No autopilot/`/verify`/Marshal changes, no auto-merge execution, no auto-refix,
no mid-loop re-audit, no headless scheduler, no `loop_state.json`, no new
plugin. Full list + rationale: `references/health-loop.md` and ADR 0024.
