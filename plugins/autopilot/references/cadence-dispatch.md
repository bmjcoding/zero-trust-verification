# Cadence dispatch (Step D8)


Last action of every fire. The drain runs in-session under Claude Code's adaptive cron (`CronCreate(durable: false)`), re-armed with a new cadence per end-of-fire state. There is no external-scheduler path since v2.0.0 — see `references/role-prompts-rationale.md` AP-19 for the deletion rationale.


Two tool calls per fire-end:


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


When `consecutive_impl_blocks` or `consecutive_ci_blocks` hits its cap minus one (caps come from `budget.max_impl_blocks` / `budget.max_ci_blocks`, defaults 3 / 2), the next fire's re-arm should use `*/60` instead of `*/30` to give human triage room to land. **This deferral takes precedence over the `*/30` that the [BLOCKED] rows in the cadence table and D7.5 specify for the same event.** The drain still self-escalates at the cap, but slowing the cron by half buys the human a window to intervene without missing fires.


This isn't strictly necessary for correctness (escalation will trip regardless), but it's been observed to reduce wasted compute on drains that are clearly heading toward HUMAN_NEEDED.


## PAUSED no-op


On `STATUS: PAUSED` (user-triggered manual pause), the orchestrator:


1. `CronDelete` the previous cron.
2. Do NOT `CronCreate` a new one.
3. Release the `session_lock` so a future `--resume` can claim cleanly.


The `--resume` command (see SKILL.md "Resume mode") re-arms the cron at the appropriate cadence based on the tracker's last state.


## Terminal cleanup


On `STATUS: DRAINED | HUMAN_NEEDED | STOPPED`:


1. `CronDelete` the previous cron.
2. Release the `session_lock` (clear both `session_lock` and `session_lock_expires_at`).
3. Commit the terminal tracker state to the Runbook PR (`autopilot/<slug>/runbook`, AV3-08) one last time (under `branching.no_force_push: true`: append a `status_change` delta to the batched queue for the final D7.1a flush instead — see `references/tracker-delta-batching.md`).
4. For `DRAINED`: render `MERGE-ORDER.md` with stacked-PR merge-strategy annotations (AP-10 — every stacked PR must merge as a merge-commit, not squash).


Exit fire.
