# Cadence dispatch (Step D8)


Last action of every fire. The drain runs in-session under Claude Code's adaptive cron (`CronCreate(durable: false)`), re-armed with a new cadence per end-of-fire state. There is no external-scheduler path in v2.0.0 — see SKILL.md AP-19 for the deletion rationale.


Two tool calls per fire-end:


```
CronDelete <previous-cron-id>
CronCreate(cron=<new>, recurring=True, durable=False,
           prompt='@docs/design/AUTOPILOT-PROMPT-<slug>.md')
```


## Cadence table


| End state | Cron expression | Why |
|---|---|---|
| Subtask completed + queue has more eligible | `*/5 * * * *` | fast active-drain |
| `awaiting_ci: true` written | `*/10 * * * *` | give CI room |
| `[BLOCKED: ...]` (any domain) written | `*/30 * * * *` | back off; human triage probably coming |
| `STATUS: DRAINED \| PAUSED \| HUMAN_NEEDED \| STOPPED` | No re-arm — `CronDelete` only | terminal |


## Counter-aware deferral


When `consecutive_impl_blocks` or `consecutive_ci_blocks` hits 2 (one short of the escalation threshold), the next fire's re-arm should use `*/60` instead of `*/30` to give human triage room to land. The drain still self-escalates at N≥3, but slowing the cron by half buys the human a window to intervene without missing fires.


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
3. Commit the terminal tracker state via the rolling tracker PR one last time.
4. For `DRAINED`: render `MERGE-ORDER.md` with stacked-PR merge-strategy annotations (AP-10 — every stacked PR must merge as a merge-commit, not squash).


Exit fire.
