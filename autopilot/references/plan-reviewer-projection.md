# Plan Reviewer Projection (AP-3)


This file defines what the plan-reviewer agent is allowed to see, and what it is deliberately not shown. The contract is enforced by the orchestrator at Step G3.5 and DRAIN Step D3.2.


## Why projection (not full schema)


In autopilot v1 the plan reviewer received the planner's full output verbatim — including the planner's prose justifications (`evidence` quotes, `contract:` semantic-guarantee paragraphs, the `behaviors_to_test` rationale buried in commit-bodies). This made the reviewer anchor on the planner's narrative. Concur rates were ~95% even when the reviewer was explicitly prompted to disagree: agents read confident prose and absorb its conclusions.


The fix is structural, not prompt-engineering. Strip the projection at the orchestrator boundary so the reviewer cannot anchor on prose. The reviewer must form its own judgment from the schema's structural fields.


This mirrors the audit plugin's adversarial-reviewer pattern (see codebase-health-suite v1.3.0, `agents/adversarial-reviewer.md`). Same problem class, same fix.


## Allowed fields (full list)


This list is the SINGLE canonical allow-list — G3.5, D3.2, and the rationale doc reference it rather than restating it. The reviewer's prompt input contains EXACTLY these keys, in this order, for each Subtask in the planner's output:


```yaml
- id: <slug>
  parent_story: <story_id>
  behavior_ids: [<B-...>]         # AV3-02: mapping completeness is reviewable structure
  kind: <code | test-only | refactor | docs | config>
  owned_files:
    - <repo-relative-path>
  depends_on: [<other-subtask-ids>]
  test_gates: [<unit | contract | integration>]
  validators: [<integration | design | quality | security | sre>]
  interface_change:
    public_api: <signature only — no contract prose>
  behaviors_to_test:
    - <behavior string only — no test_name_hint, no rationale>
  estimated_size: <S | M | L>
  predicted_hours: <int>          # AV3-07: sanity-vs-size and 48h/Story are reviewable structure
```

(`branch_pattern` was removed from the planner schema in v2.4.0 — branch names are dictated by AP-7 (`autopilot/<slug>/<subtask-id>`), so the field contradicted the D1.1 shape check and was consumed by nothing.)


Notably absent from the reviewer's input:


- `source_ref` — implies the planner has verified provenance. Reviewer must form its own view of whether the file plan is feasible.
- `interface_change.contract` — the semantic-guarantee paragraph. This is the planner's argument for the API shape, not the API shape itself.
- `acceptance_criteria` — these are the planner's success conditions. The reviewer should ask "are these the RIGHT success conditions" without seeing the planner's framing.
- `evidence` — the verbatim doc quote that anchored the planner. Cannot be shown without anchoring the reviewer.
- `jira_key` — irrelevant to plan quality.
- `test_name_hint` (AP-9) — names of yet-to-be-written tests. Mentioning them anchors the reviewer on the planner's implicit assertion order.


## Reviewer's NO-GO conditions


The reviewer's prompt instructs it to return `NO-GO` when ANY of:


1. **Feasibility.** An `owned_files[]` path looks impossible (cross-package leakage, file in a deprecated tree, file in a frozen module the planner shouldn't be modifying).
2. **File-path verification.** A non-`# NEW` path doesn't exist in the repo at HEAD (reviewer runs `Glob` to check).
3. **Dependency gaps.** A `depends_on[]` entry references a Subtask ID that doesn't exist in this drain, or creates a cycle (orchestrator catches cycles at G4 too, but reviewer flags early).
4. **Ownership overlap.** Two Subtasks in this drain list the same file in `owned_files[]` without a `depends_on[]` edge between them.
5. **Behaviors-to-test thinness.** A `kind: code` Subtask has fewer than 2 entries in `behaviors_to_test[]` — too thin for vertical-slice TDD to mean anything. Or a `kind: code` Subtask has only happy-path behaviors and no error cases.
6. **Inappropriate kind.** `kind: refactor` but the Subtask has a non-empty `behaviors_to_test[]` (refactor means no behavior change). `kind: code` with empty `interface_change` (code means there IS an interface, even if internal-ish).
7. **Public-API shape.** A `public_api` signature uses leading-`_` names (private symbols promoted to "public" interface) — that's a sign of leaking implementation.
8. **Validator selection.** The planner did NOT include `security` for a Subtask whose `owned_files[]` matches the security trigger patterns (`*/auth*`, `*/secret*`, `*/token*`, `*/cookie*`), or did NOT include `sre` for an operational-hot-path Subtask.


## Reviewer's NEVER-GO conditions


These trigger NO-GO with no second chance (the orchestrator does NOT re-spawn the planner). They go straight to `[GENERATE-FAILED: plan-review-ungated]`:


- The projection contains a field outside the allow-list. This is a contract violation: the orchestrator's stripper has a bug. Surface with the offending key name.
- The projection contains zero Subtasks for a Story. The planner emitted nothing; this is a planner failure that no review re-prompt can recover.


## Output format


The reviewer emits ONLY this:


```yaml
verdict: <GO | NO-GO | NEVER-GO>
findings:
  - subtask_id: <id>
    issue: <one of the NO-GO categories above, by short name>
    detail: <one-sentence specifics>
    severity: <high | medium | low>
```


On `GO`, `findings: []`. On `NO-GO`, at least one finding. On `NEVER-GO`, exactly one finding pointing at the contract violation.


No prose, no narrative. Max return: 600 tokens (vs the planner's 500). Reviewer is allowed slightly more room because findings need to be specific enough for the planner re-spawn to act on.


## What the orchestrator does with NO-GO


1. Re-spawn the original planner agent ONCE.
2. Pass it the projection + the reviewer's findings verbatim.
3. The planner re-emits the full Subtask schema (not the projection) addressing the findings.
4. The orchestrator re-strips to projection and re-spawns the reviewer.
5. If the second review is also NO-GO → `[GENERATE-FAILED: plan-review-ungated]` for that Story.


No third attempt. Two NO-GOs means the planner can't satisfy the reviewer's structural objections, which means the underlying spec is ambiguous and needs human eyes.
