---
description: Run the audit → drain → verify loop end-to-end from one prompt — slice audit/SPEC.md into waves, drain each through autopilot, merge (operator-approved, or delegated for auto-class waves under the double-keyed hatch), verify with evidence, and continue until the original audit is drained. Attended sibling of /remediate; pauses wherever judgment is required.
argument-hint: "[--auto-waves <list>] [--pause-waves all] [--use-existing-audit] [--from-wave <N>] [--dry-run]"
---

# /health-loop

The **campaign** counterpart to `/remediate`'s drip (ADR 0024): one prompt
runs `/audit` → per-wave `/autopilot` drain → merge → `/verify --strict` →
gate → next wave, until the audit is drained.

Read the `cleanup-audit` skill → `references/health-loop.md` FIRST and follow
it as written — it is the canonical loop text: wiring-not-a-checker posture,
computed position (derived from three records, none of them the journal —
the journal holds only its three exclusive facts and is never read to compute
position), the refuse-checks, the per-invocation dispatch table, the merge step
with the auto-class definition and double-keyed hatch, the verify-gate
routing, failure ownership, and the non-goals. This command adds only
invocation modes and the posture summary below.

## Posture (read first)

- **Merge-before-verify is a correctness rule.** `/verify` grades the
  checkout; a wave verifies only after its PRs merge. The wave-boundary stop
  is where the loop's evidence comes from.
- **The loop never merges and never self-authorizes.** Default (`merge:
  pause`): one approval question per drained wave; the Marshal or the
  operator merges. Under the **double-keyed hatch** (`merge: preauthorized`
  AND a per-run kickoff confirmation) the loop may `host.sh pr-approve`
  auto-class waves as the operator's **logged delegate**, only after
  `wave_preauth_check.sh` proves P1–P4 on disk per Story PR. The Marshal's
  composed-state build still executes every merge.
- **Depth 0.** PARTIAL/STALE pause; REGRESSED or a ratchet increase halts;
  nothing is ever re-fixed by the loop.
- **Stateless.** Position is recomputed on every invocation; ending the
  session mid-campaign is safe. End the turn at every pause and at
  drain-in-flight — the loop never idle-waits.

## Modes

| Invocation | Behavior |
|---|---|
| `/health-loop` | Start or resume the campaign: run/reuse the audit, then act on the first non-complete wave per the reference's dispatch table. |
| `/health-loop --dry-run` | Print the wave plan, per-wave policy routing, and what the next invocation WOULD do. Touches nothing. The safe first look. |
| `/health-loop --auto-waves 1,4` | Per-run override of `wave_policy` for GENERATE-time pauses (journaled). It can never widen merge delegation by itself: adding a wave to the delegated set requires a fresh key-2 confirmation naming it. `--pause-waves all` forces every wave to ask. |
| `/health-loop --use-existing-audit` | Skip the kickoff freshness check and drain the `SPEC.md` on disk (journaled). |
| `/health-loop --from-wave 3` | Treat waves < 3 as out of scope (journaled): not gated, reported by the final verify as out-of-scope, never as failures. |

There is no `--resume` flag because every invocation is a resume.

Requires the autopilot domain (drain, `host.sh`, lock checks) and the marshal
(merge execution); the loop refuses and names the missing component rather
than improvise either role.

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
health-loop:<host-pr-ref>` (the additive Guard-1 write is the loop's ONLY
state.json mutation) so a cron `/remediate` pass SKIPs them, and the loop
refuses to start while open `remediation/*` PRs overlap the spec.
