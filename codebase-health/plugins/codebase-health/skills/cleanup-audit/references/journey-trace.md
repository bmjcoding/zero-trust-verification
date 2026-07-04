# Journey Trace (`audit/journeys.json`)

One trace, three facets. `journey-walker` is dispatched **first** in `/audit` and
writes `audit/journeys.json` exactly once per run; business-vital steps
(`business-vitals.md`), the transactional-integrity critical-step questions
(taxonomy Category TX), and branching burden (`journey/path-complexity`) are all
graded **during that single walk** — the step schema below is the merged field
set all three facets read, so no journey is ever walked twice. After the walk,
`performance-analyzer` consumes CORE journeys as confirmed hot paths and
`security-auditor` uses the trace to confirm reachability of transactional
findings. Nothing else writes this file.

## Write rules

- **`audit/`-only, idempotent.** Regenerated whole on every run — never merged,
  never appended. Running the same audit twice produces the same file.
- **Schema-versioned.** `schema_version` is 1; consumers check it before reading
  anything else.
- **Line numbers are allowed here** — this is a per-run artifact, rebuilt every
  audit. They are still **never** allowed in finding fingerprints
  (`audit-state-and-verify.md`).

## Schema (`schema_version` 1)

```json
{
  "schema_version": 1,
  "source_run": {"kind": "audit", "date": "2026-07-03", "git_sha": "abc1234"},
  "journeys": [
    {
      "name": "Transfers",
      "source": "README.md:41",
      "criticality": "CORE",
      "criticality_reason": "README '## Transfers' quickstart; money-movement verbs",
      "verdict": "WORKS",
      "executed": true,
      "path_complexity": "CLEAN",
      "steps": [
        {
          "path": "src/billing.py",
          "symbol": "transfer_funds",
          "line": 12,
          "vital_class": "money",
          "emission_grade": "DARK",
          "alert_seam": null,
          "duplicate_guard": "absent",
          "compensation_note": "no compensating action if the ledger post fails mid-sequence",
          "complexity_flags": []
        },
        {
          "path": "src/billing.py",
          "symbol": "_format_memo",
          "line": 88,
          "vital_class": null,
          "emission_grade": null,
          "alert_seam": null,
          "duplicate_guard": "n/a",
          "compensation_note": null,
          "complexity_flags": ["nesting-ge-4", "re-tested-condition"]
        }
      ]
    }
  ]
}
```

Field notes:

- `verdict` — `WORKS` / `BROKEN` / `DEGRADED` / `UNDOCUMENTED-BEHAVIOR`, the
  existing journey-walker vocabulary, unchanged. Verdict and emission grade are
  **separate axes**: a journey can be `WORKS` and still carry DARK vitals.
- `executed` — whether the journey was actually run (docs quickstart executed
  green) vs. traced by reading. Money/auth paths are **trace-only** — for those,
  `executed` is honestly `false` (`business-vitals.md`).
- `vital_class` / `emission_grade` / `alert_seam` — the vitals facet;
  `business-vitals.md` is the normative vocabulary. All three are `null` on
  non-vital steps. `alert_seam` (`paged` / `dashboard-only` / `unknown`) is
  graded only where an emission exists to alert on — `null` on DARK steps (the
  DARK grade already says nobody would notice).
- `duplicate_guard` / `compensation_note` — the Category TX critical-step
  answers (questions in `business-vitals.md`, category in
  `incomplete-logic-taxonomy.md`). `duplicate_guard` is `present` when a guard
  exists **or** the step is idempotent by construction (PUT-style upsert,
  `ON CONFLICT`, key-checked handler); `n/a` when the question does not apply
  (pure reads, non-critical steps). `compensation_note` is prose or `null`.
- `complexity_flags` — branching-burden cues feeding `journey/path-complexity`:
  quoted deterministic metric lines (e.g. `c901-15` from the ruff artifact) and
  structural judgment cues (`identical-branches`, `re-tested-condition`,
  `nesting-ge-4`). Never re-derive metrics — quote artifact lines.
- `path_complexity` — `CLEAN` / `CONVOLUTED`, the per-journey roll-up.

## Criticality ladder (derivation rules, not vibes)

| Grade | Derived from |
|---|---|
| CORE | README quickstart, primary tutorials, any flow whose docs use money-movement / data-mutation / auth verbs |
| SUPPORTING | Secondary guides, documented optional features off the main path |
| DEV | Contributor/debug docs, internal tooling flows |

Criticality is derived from documentation evidence, and `criticality_reason`
quotes the source (e.g. `README '## Transfers'`). Flows discovered only from the
second inventory source (entry points/handlers seeded by
`audit/vital_candidates.txt`, walked even when undocumented) have no docs to
derive from: grade them SUPPORTING with a reason like "undocumented; walked via
vital candidates" — an undocumented flow is never CORE, which means its absence
findings cap at MED under the 1.4.0 absence-finding gate (`severity-rubric.md`).

## Consumer degrade rules (no trace → less action, never a block)

Missing file, unparseable JSON, or an unknown `schema_version` all mean the same
thing: **no trace**. All-or-nothing — never salvage partial journeys from a
corrupt file (same rule as `state.json`: degrade, never act).

- **Say so.** Every consumer that wanted the trace reports the degrade
  explicitly (Not-covered section, downgrade note) — silent truncation is a
  defect (loop-safety invariant 6).
- **Skip journey-scoped facets or cap at MED needs-verification. Never guess
  criticality.** Without the trace, `journey/uninstrumented` cannot reach HIGH
  (the 1.4.0 absence-finding gate requires the traced CORE path as evidence)
  and `journey/path-complexity` caps at MED needs-verification.
  `performance-analyzer` states the trace is missing and falls back to
  heuristics.
- **Never wait.** journey-walker's head start is one dispatch turn, not a
  blocking join. If it errors, or the file is missing/invalid when its turn
  completes, the remaining six dispatch anyway and consume these degrade
  rules; journey-walker's own failure goes in the Not-covered section. (The
  rule is also stated at the dispatch site in `/audit`.)
