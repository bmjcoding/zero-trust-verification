---
description: One command, end to end — run all seven specialist agents to measured full coverage, adversarially verify HIGH+ findings, write the report + implementation spec + state file, and render an offline HTML view.
argument-hint: "[subdir] [--focus <area>] [--no-html] [--spec-only]"
---

# /audit

The single entry point. Runs the **entire** Codebase Health Suite end to end and
produces four artifacts in `audit/`:

| Artifact | Purpose | Audience |
| --- | --- | --- |
| `audit/HEALTH_REPORT.md` | Every finding — dead code, incomplete logic, security, performance, architecture, journeys — tagged `file:line` · severity · evidence · fix, plus the **Not covered** section. | The source of truth. |
| `audit/SPEC.md` | The findings turned into an implementation-ready, wave-organized plan: each item has a fix, a regression-test seam, a Status field, and a fingerprint. | Whoever knocks out the findings (human or agent). |
| `audit/state.json` | Fingerprinted findings + run history + ratchet counts (see `references/audit-state-and-verify.md`). What makes the next `/verify` and `/audit` diffable against this one. | The loop. |
| `audit/HEALTH_REPORT.html` | Self-contained, offline-safe visual render (severity pills, sticky TOC). | The human reviewer. |

Detection only. This command **never** deletes or edits product code. The only
files it writes are under `audit/`.

Parse `$ARGUMENTS` before starting: an optional subdir narrows scope; `--focus
<area>` (e.g. `--focus security`) runs a subset of agents; `--no-html` skips the
render; `--spec-only` regenerates just `SPEC.md` from an existing report.

## Steps

### 1. Detect the stack
Identify language(s) and package manager from manifests (`pyproject.toml`/`setup.cfg`,
`package.json`, `Cargo.toml`, `go.mod`) — in the target directory for monorepos.
Load the matching tool pack from the `cleanup-audit` skill →
`references/cross-language-tooling.md`. Tools not in a locked-down internal index
are **optional**; fall back per that reference.

### 2. Orient (DANGER zones + priorities)
Map the public API surface, entry points, plugin registries, and dynamic-dispatch
points before running anything — DANGER zones where deterministic "unused" flags
are false positives. Read `audit/git_wip_commits.txt` and `git_churn.txt` (from
step 3) as priority hints: rushed and high-churn code first.

### 3. Deterministic pass
Run the skill's `scripts/run_audit.sh <target>` to collect raw evidence into
`audit/`: tool packs, marker + suppression greps, `counts.env` (ratchet input),
git-history signals, and any existing coverage report. Signal-gathering, not the
verdict. If a coverage data file exists it's ingested — uncovered public-API
branches are priority targets for the incomplete-logic agent.

The same pass also collects the 1.4.0 artifacts: `test_flakiness.txt` /
`test_vacuity.txt` / `test_skips.txt` (test-health candidates),
`stdout_logging.txt` (taxonomy Category LOG candidates — not verdicts),
`vital_candidates.txt` / `telemetry.txt` / `tx_guards.txt` / `tx_retries.txt` /
`alerting_config.txt` (business-vital and Category TX seeds — priority input,
never counted), and `giant_files.txt` / `commented_code.txt` / `dup_jscpd.json`
(navigability; jscpd optional on target repos, loud `[skip]` when absent).
Mutation reports are **ingested** like coverage when present — never run by
this command or any agent; absent → a loud note, not silence.

### 4. Build the coverage inventory
`git ls-files` (or a filesystem walk if not a git repo), minus vendored/generated
paths. This is the denominator for the coverage ledger — "audited the codebase"
means *this list*, not "the files the agents happened to open."

### 5. Dispatch the seven specialist agents — journey-walker first
Dispatch `journey-walker` FIRST, as one serialized stage: it writes
`audit/journeys.json` (schema: `references/journey-trace.md`), the single shared
trace. Then dispatch the remaining six in parallel.

**Proceed-on-failure rule:** journey-walker's head start is one dispatch turn,
not a blocking join — if it errors, or `audit/journeys.json` is missing or
fails schema validation when its turn completes, dispatch the remaining six
anyway WITHOUT the trace; consumers apply `references/journey-trace.md`'s
documented degrade rules (no trace → say so, skip journey-scoped facets or cap
at MED needs-verification, never guess criticality), and journey-walker's own
failure goes in the **Not covered** section. The other six never wait
indefinitely on the trace.

- `journey-walker` — documented user journeys traced (and where safe, executed)
  end to end; docs-vs-API drift. Writes `audit/journeys.json`, and in that same
  walk grades business-vital steps OBSERVED/LOG-ONLY/DARK with the alert-seam
  check (`references/business-vitals.md`), asks the taxonomy Category TX
  questions at critical steps (trace-only — never submit twice), and grades
  branching burden (`journey/path-complexity`).
- `dead-code-cleanup` — dead/unused/redundant code + doc hygiene + the deletion
  test. Consumes `dup_jscpd.json` and `commented_code.txt` as duty-5/6
  candidates.
- `incomplete-logic-detector` — stubs, placeholders, fake implementations, silent
  no-ops, and logging anti-patterns (taxonomy Category LOG). Feed it the
  suppressions file, coverage gaps, and `stdout_logging.txt`
  (candidates, not verdicts) as priority input.
- `test-health-auditor` — the test suite audited as its own subject
  (`references/test-health.md`: nondeterminism + vacuity, all findings
  `test-health/*`) — fed `test_flakiness.txt` / `test_vacuity.txt` /
  `test_skips.txt` + any ingested mutation report.
- `security-auditor` — vulnerabilities, unsafe patterns, secret handling, and
  transactional integrity (taxonomy Category TX) — fed `vital_candidates.txt` /
  `tx_guards.txt` / `tx_retries.txt`.
- `performance-analyzer` — hot paths, complexity, redundant work — **measured**,
  not just pattern-matched. Consumes `journeys.json` CORE journeys as confirmed
  hot paths (missing trace → say so, fall back to heuristics).
- `architecture-reviewer` — shallow modules, leaky seams, speculative abstractions;
  vocabulary from `references/architecture-and-strictness.md` exactly. Triages
  `giant_files.txt`.

Focus mapping: `--focus tests` → test-health-auditor; `--focus transactions` →
security-auditor + journey-walker; `--focus journeys` unchanged
(journey-walker).

**Every agent must return a coverage ledger**: the files (journeys, for
journey-walker) it examined, and what it skipped. On a large codebase (≳2K files),
shard: dispatch multiple instances of the same agent over per-directory slices
rather than trusting one context to hold everything.

### 6. Loop until dry (the completeness loop)
Diff the union of the agents' ledgers against the step-4 inventory. Files no
agent examined → re-dispatch agents scoped to exactly that remainder. Repeat
until the remainder is empty **or** two consecutive rounds produce zero new
findings. Whatever is still unexamined goes in the report's **Not covered**
section verbatim — never silently truncate. "Clean" and "unread" must be
distinguishable to the reader.

### 7. Adversarial verification of HIGH+ (all agents, not just IL)
Every HIGH/CRITICAL finding from any agent gets an independent check before the
consolidated table: a fresh agent (or a second pass with an explicit
refute-this mandate) attempts to show the finding is wrong, unreachable, or
intentional. Findings that fail verification are downgraded to MED
needs-verification, per `references/severity-rubric.md` — never silently dropped.
The mechanism is unchanged in 1.4.0 and covers the new categories the same way:
`test-health/*`, taxonomy Category LOG and Category TX, `navigability/*`, and
`journey/*` HIGH+ findings all pass this gate — the refuter checks the rubric's
confirmation evidence too (e.g. a HIGH `journey/uninstrumented` must carry its
traced CORE money/auth path; a HIGH test-health finding its bounded-probe or
sole-coverage evidence).

### 8. Consolidate → `audit/HEALTH_REPORT.md` + `audit/state.json`
- Compute each finding's **fingerprint** (`references/audit-state-and-verify.md`:
  path + symbol + defect slug; category is metadata) and **dedup**: two agents
  flagging the same defect on the same symbol become ONE finding — category by
  the precedence chain in `references/audit-state-and-verify.md` (defined there
  and ONLY there — cite it, never restate it), other lenses kept in evidence.
  Distinct defects on one symbol keep distinct slugs and stay separate findings.
- One section per agent; each finding: `file:line` · severity (per
  `references/severity-rubric.md` — one scale, no per-agent inventions) ·
  evidence · suggested fix.
- **Consolidated HIGH-and-above table** at the top (verified findings only).
- **Not covered** section (mandatory, even if "none").
- **Cross-link** correctness ↔ architecture: a confirmed bug with no correct test
  seam appears in BOTH sections.
- Write/update `audit/state.json`: run entry (`kind: "audit"`, git SHA, target,
  counts from `counts.env` — including the six 1.4.0 keys `flaky_count`,
  `test_vacuity_count`, `test_skip_count`, `stdout_logging_count`,
  `giant_file_count`, `commented_code_count` — severity tallies), every finding keyed by
  fingerprint with status OPEN (carry forward prior statuses — a finding
  previously FIXED that reappears becomes REGRESSED; respect WONTFIX). A
  previously-OPEN finding this run did NOT re-detect stays OPEN with
  `last_seen` unchanged and is listed in the report under "open findings not
  re-confirmed this run" — `/audit` never closes findings; only `/verify` (with
  evidence) or a human does. Corrupt/missing prior state → say so, treat as
  first run. Include `audit/excluded_dirs.txt` contents in Not covered.

### 9. Derive → `audit/SPEC.md`
Per `references/spec-format.md`: SAFE-first waves, one revertable change per item,
regression-test seam per item, Status field, fingerprint carried from state.
For confirmed HIGH correctness bugs, point the item at `/diagnose-bug`.

### 10. Render → `audit/HEALTH_REPORT.html`
```bash
python3 "$CLAUDE_PLUGIN_ROOT/skills/cleanup-audit/scripts/render_report.py" \
  audit/HEALTH_REPORT.md -o audit/HEALTH_REPORT.html --title "Codebase Health Report"
```
Optionally also render `SPEC.md`. Skip under `--no-html`.

### 11. Hand off
Report to the user: findings by severity, the single most important fix, the
**coverage line** ("N of M files examined; K not covered"), and the artifact
paths. Then the loop: fixes land → run `/verify` — it grades every finding
OPEN/PARTIAL/FIXED/REGRESSED with evidence and runs the debt ratchet. An audit
whose findings are never verified is half a loop.
