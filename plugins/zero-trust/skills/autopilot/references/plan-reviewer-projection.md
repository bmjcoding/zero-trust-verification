# Plan Reviewer Projection (AP-3)

What the plan-reviewer agent is allowed to see, and what it is deliberately not shown. Enforced by the orchestrator at G3.5 and D3.2: the projection is built from the planner's output; the full plan is never passed.

## Why projection

Given the planner's full output — `evidence` quotes, `contract:` prose, rationale — reviewers anchor on the narrative and concur ~95% even when prompted to disagree. The fix is structural, not prompt-engineering: strip at the orchestrator boundary so the reviewer must form its own judgment from the schema's structural fields. (Same problem class and fix as the audit tier's adversarial-reviewer pattern.)

## Allowed fields (full list)

The SINGLE canonical allow-list — G3.5, D3.2, and the rationale doc reference it rather than restating it. The reviewer's input contains EXACTLY these keys, in this order, per Subtask:

```yaml
- id: <slug>
  parent_story: <story_id>
  behavior_ids: [<B-...>]         # AV3-02: mapping completeness is reviewable structure
  kind: <code | test-only | refactor | docs | config>
  owned_files:
    - <repo-relative-path>
  invalidated_seams: [<test-file-path>]  # seam-invalidation completeness is reviewable structure
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

Deliberately absent — each would anchor the reviewer on the planner's framing:

- `source_ref` — implies verified provenance; the reviewer forms its own feasibility view.
- `interface_change.contract` — the planner's argument for the API shape, not the shape itself.
- `acceptance_criteria` — the reviewer asks "are these the RIGHT success conditions" without seeing the planner's.
- `evidence` — the verbatim quote that anchored the planner.
- `jira_key` — irrelevant to plan quality.
- `test_name_hint` (AP-9) — names of yet-to-be-written tests anchor the reviewer on the planner's implicit assertion order.

## Reviewer's NO-GO conditions

Return `NO-GO` when ANY of:

1. **Feasibility.** An `owned_files[]` path looks impossible (cross-package leakage, deprecated tree, frozen module).
2. **File-path verification.** A non-`# NEW` path doesn't exist at HEAD (run `Glob` to check).
3. **Dependency gaps.** A `depends_on[]` entry references a Subtask ID not in this drain, or creates a cycle (G4 also catches cycles; flag early).
4. **Ownership overlap.** Two Subtasks share an `owned_files[]` entry without a `depends_on[]` edge.
5. **Behaviors-to-test thinness.** A `kind: code` Subtask with fewer than 2 behaviors — too thin for vertical-slice TDD to mean anything — or with only happy-path behaviors and no error cases.
6. **Inappropriate kind.** `kind: refactor` with non-empty `behaviors_to_test[]` (refactor means no behavior change); `kind: code` with empty `interface_change`.
7. **Public-API shape.** A `public_api` signature using leading-`_` names — private symbols promoted to "public" leak implementation.
8. **Validator selection.** Missing `security` for a Subtask matching the security trigger patterns (`*/auth*`, `*/secret*`, `*/token*`, `*/cookie*`), or missing `sre` for an operational-hot-path Subtask.
9. **Missing seam inventory.** A `kind: refactor` Subtask (or one whose `public_api` implies moved/re-imported symbols) OMITS the `invalidated_seams` field entirely. (`invalidated_seams: []` is a legal explicit declaration — it asserts the planner ran the inventory grep and found nothing; an ABSENT field means the inventory was never run.)

## Reviewer's NEVER-GO conditions

NO-GO with no second chance — straight to `[GENERATE-FAILED: plan-review-ungated]`, no planner re-spawn:

- The projection contains a field outside the allow-list: the orchestrator's stripper has a bug. Surface the offending key name.
- The projection contains zero Subtasks for THE STORY UNDER REVIEW: a planner failure no review re-prompt can recover. **Scope: each review is per-Story** — the projection deliberately contains ONLY the reviewed Story's Subtasks, so the absence of OTHER Stories (whose Subtask IDs may appear in the orchestrator-supplied drain-wide ID list for condition 3) is expected and NEVER matches this clause.

## Output format

```yaml
verdict: <GO | NO-GO | NEVER-GO>
findings:
  - subtask_id: <id>
    issue: <one of the NO-GO categories above, by short name>
    detail: <one-sentence specifics>
    severity: <high | medium | low>
```

`GO` → `findings: []`; `NO-GO` → ≥1 finding; `NEVER-GO` → exactly one finding at the contract violation. No prose. Max return: 600 tokens — slightly more than the planner's 500 because findings must be specific enough for the planner re-spawn to act on.

## What the orchestrator does with NO-GO

Re-spawn the original planner ONCE with the projection + findings verbatim; the planner re-emits the full schema; the orchestrator re-strips and re-spawns the reviewer. A second NO-GO → `[GENERATE-FAILED: plan-review-ungated]` for that Story — two NO-GOs mean the underlying spec is ambiguous and needs human eyes. No third attempt.

## Contract-invalid verdicts

A reviewer return that violates the output contract — a verdict outside `GO | NO-GO | NEVER-GO`, unparseable YAML, or a NEVER-GO grounded on a Story other than the one under review — is NOT a plan verdict and never fails the drain by itself. Re-prompt THAT reviewer ONCE with the scope clarified ("you are reviewing Story `<id>` only; the projection intentionally omits other Stories"). Still contract-invalid → treat as NO-GO and enter the normal planner re-spawn loop above.
