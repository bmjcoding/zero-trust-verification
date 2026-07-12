---
description: One command, end to end — run all seven specialist agents to measured full coverage, adversarially verify HIGH+ findings, write the report + implementation spec + state file, and render an offline HTML view.
argument-hint: "[subdir] [--focus <area>] [--no-html] [--spec-only]"
---

# /audit

The single entry point. Runs the entire audit end to end and produces four
artifacts in `audit/`: `HEALTH_REPORT.md` (every finding + the **Not covered**
section — the source of truth), `SPEC.md` (the implementation-ready plan),
`state.json` (fingerprinted findings + run history + ratchet counts — what
makes the next `/verify` and `/audit` diffable against this one), and
`HEALTH_REPORT.html` (self-contained offline render).

Detection only: this command **never** deletes or edits product code; the only
files it writes are under `audit/`.

Parse `$ARGUMENTS` before starting: an optional subdir narrows scope; `--focus
<area>` runs a subset of agents; `--no-html` skips the render; `--spec-only`
regenerates just `SPEC.md` from an existing report.

## Steps

### 1. Detect the stack
Identify language(s) and package manager from manifests — in the target
directory for monorepos. Load the matching tool pack from the `cleanup-audit`
skill's `references/cross-language-tooling.md`; missing tools are optional,
degrade per that reference.

### 2. Orient (DANGER zones + priorities)
Map the public API surface, entry points, plugin registries, and
dynamic-dispatch points before running anything — DANGER zones where
deterministic "unused" flags are false positives. Read
`audit/git_wip_commits.txt` and `git_churn.txt` (from step 3) as priority
hints: rushed and high-churn code first.

### 3. Deterministic pass
Run the skill's `scripts/run_audit.sh <target>` to collect the raw evidence
into `audit/` (the script is the executable inventory of what gets collected;
the skill's Phase 1 lists the categories). Everything is
signal, not verdict. Coverage and mutation reports are **ingested** when
present — never run by this command or any agent; absent → a loud note, not
silence.

### 4. Build the coverage inventory
`git ls-files` (or a filesystem walk if not a git repo), minus
vendored/generated paths. This is the denominator for the coverage ledger —
"audited the codebase" means *this list*, not "the files the agents happened
to open."

### 5. Dispatch the seven specialist agents — journey-walker first
Dispatch `journey-walker` FIRST, as one serialized stage: it writes
`audit/journeys.json` (`references/journey-trace.md`), the single shared
trace. Then dispatch the remaining six in parallel — each agent's own file
states its duties and inputs: `dead-code-cleanup` (fed `dup_jscpd.json` +
`commented_code.txt`), `incomplete-logic-detector` (fed suppressions, coverage
gaps, `stdout_logging.txt`), `test-health-auditor` (fed the three test-health
artifacts + any ingested mutation report), `security-auditor` (fed the
vitals/TX seeds), `performance-analyzer` (consumes `journeys.json` CORE
journeys as confirmed hot paths), `architecture-reviewer` (triages
`giant_files.txt`).

**Proceed-on-failure rule:** journey-walker's head start is one dispatch turn,
not a blocking join — if it errors, or `audit/journeys.json` is missing or
fails schema validation when its turn completes, dispatch the remaining six
anyway WITHOUT the trace; consumers apply `references/journey-trace.md`'s
degrade rules, and journey-walker's own failure goes in the **Not covered**
section. The other six never wait indefinitely on the trace.

Focus mapping: `--focus tests` → test-health-auditor; `--focus transactions`
→ security-auditor + journey-walker; `--focus journeys` → journey-walker.

**Every agent must return a coverage ledger**: what it examined and what it
skipped. On a large codebase (≳2K files), shard: dispatch multiple instances
of the same agent over per-directory slices rather than trusting one context
to hold everything.

### 6. Loop until dry (the completeness loop)
Diff the union of the agents' ledgers against the step-4 inventory. Files no
agent examined → re-dispatch agents scoped to exactly that remainder. Repeat
until the remainder is empty **or** two consecutive rounds produce zero new
findings. Whatever is still unexamined goes in the report's **Not covered**
section verbatim — "clean" and "unread" must be distinguishable to the reader.

### 7. Adversarial verification of HIGH+ (all agents' findings)
Every HIGH/CRITICAL finding gets an independent check before the consolidated
table: a fresh agent (or a second pass with an explicit refute-this mandate)
attempts to show the finding is wrong, unreachable, or intentional — and
checks the rubric's confirmation evidence (a HIGH `journey/uninstrumented`
must carry its traced CORE money/auth path; a HIGH test-health finding its
bounded-probe or sole-coverage evidence). Findings that fail verification are
downgraded to MED needs-verification per `references/severity-rubric.md` —
never silently dropped.

### 8. Consolidate → `audit/HEALTH_REPORT.md` + `audit/state.json`
- Compute each finding's **fingerprint** and **dedup** per
  `references/audit-state-and-verify.md` (category by the precedence chain —
  defined there and ONLY there; cite it, never restate it).
- One section per agent; each finding: `file:line` · severity (one scale,
  `references/severity-rubric.md`) · evidence · suggested fix.
- **Consolidated HIGH-and-above table** at the top (verified findings only);
  mandatory **Not covered** section (even if "none"); cross-link a confirmed
  bug with no correct test seam into BOTH the correctness and architecture
  sections.
- Write/update `audit/state.json` per `references/audit-state-and-verify.md`:
  run entry (`kind: "audit"`, git SHA, target, the eight counts from
  `counts.env`, severity tallies), every finding keyed by fingerprint with
  status OPEN — carry forward prior statuses (a previously-FIXED finding that
  reappears becomes REGRESSED; respect WONTFIX). A previously-OPEN finding
  this run did NOT re-detect stays OPEN and is listed under "open findings not
  re-confirmed this run" — `/audit` never closes findings. Corrupt/missing
  prior state → say so, treat as first run. Include `audit/excluded_dirs.txt`
  contents in Not covered.

### 9. Derive → `audit/SPEC.md`
Per `references/spec-format.md`: SAFE-first waves, one revertable change per
item, regression-test seam per item, Status field, fingerprint carried from
state. For confirmed HIGH correctness bugs, point the item at `/diagnose-bug`.

### 10. Render → `audit/HEALTH_REPORT.html`
```bash
python3 "$CLAUDE_PLUGIN_ROOT/skills/cleanup-audit/scripts/render_report.py" \
  audit/HEALTH_REPORT.md -o audit/HEALTH_REPORT.html --title "Codebase Health Report"
```
Optionally also render `SPEC.md`. Skip under `--no-html`.

### 11. Hand off
Report to the user: findings by severity, the single most important fix, the
**coverage line** ("N of M files examined; K not covered"), and the artifact
paths. Then the loop: fixes land → `/verify` grades every finding with
evidence and runs the debt ratchet. An audit whose findings are never verified
is half a loop.
