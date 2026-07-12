# Cadence dispatch (Step D8)

Last action of every fire. The drain runs in-session under Claude Code's adaptive cron, re-armed per end-of-fire state; there is no external-scheduler path since v2.0.0 (AP-19, `references/role-prompts-rationale.md`). Two tool calls per fire-end:

```
CronDelete <previous-cron-id>
CronCreate(cron=<new>, recurring=True, durable=False,
           prompt='/autopilot --drain @.autopilot/runbooks/<slug>.md')
```

The prompt MUST carry the `/autopilot --drain` invocation — a bare `@file` reference gives the next fire no instruction to run the DRAIN lifecycle.

## Cadence table

| End state | Cron expression | Why |
|---|---|---|
| Subtask completed + queue has more eligible | `*/5 * * * *` | fast active-drain |
| `awaiting_ci: true` written | `*/10 * * * *` | give CI room |
| `[BLOCKED: ...]` (any domain) written | `*/30 * * * *` | back off; human triage probably coming |
| `STATUS: DRAINED \| PAUSED \| HUMAN_NEEDED \| STOPPED` | No re-arm — `CronDelete` only | terminal |

## Counter-aware deferral

When either block counter reaches its cap minus one (`budget.max_impl_blocks` / `budget.max_ci_blocks`, defaults 3 / 2), the next re-arm uses `*/60` instead of `*/30` — **this deferral takes precedence over the `*/30` the [BLOCKED] rows and D7.5 specify for the same event.** Escalation still trips at the cap regardless; halving the cadence buys the human a window to intervene and has been observed to cut wasted compute on drains clearly heading to HUMAN_NEEDED.

## PAUSED no-op

On `STATUS: PAUSED` (operator-triggered manual pause): `CronDelete`; do NOT `CronCreate`; release the `session_lock` so a future `--resume` claims cleanly. `--resume` re-arms at the appropriate cadence from tracker state (lifecycle.md §Resume step 5).

## Terminal cleanup

On `STATUS: DRAINED | HUMAN_NEEDED | STOPPED`:

1. `CronDelete` the previous cron.
2. Release the session lock (clear `session_lock` and `session_lock_expires_at`).
3. Commit the terminal tracker state to the Runbook PR (`autopilot/<slug>/runbook`, AV3-08) one last time — under `branching.no_force_push: true`, append a `status_change` delta to the batched queue for the final D7.1a flush instead (`references/tracker-delta-batching.md`).
4. For `DRAINED`: render `MERGE-ORDER.md` with stacked-PR merge-strategy annotations (AP-10 — every stacked PR merges as a merge commit, not squash).

Exit fire.
