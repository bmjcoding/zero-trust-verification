# Codebase Health

A Claude Code plugin to audit and clean up any large codebase — as a **closed
loop**, not a one-shot report. Deterministic tools find the evidence; LLM agents
make the judgment; coverage is measured, not assumed; findings get stable
fingerprints; and `/verify` grades every fix with evidence before it counts.

## What it does

| Area | How |
|---|---|
| Dead / unused / redundant code | `dead-code-cleanup` agent + per-language tool pack (vulture/knip/cargo-udeps/deadcode) |
| **Incomplete logic** (stubs, fake implementations, silent no-ops, suppressed diagnostics) | `incomplete-logic-detector` agent — LLM judgment + coverage/suppression/git-history evidence |
| Doc / comment hygiene | `dead-code-cleanup` agent (Phase 4) |
| **Documented user journeys** (does what the docs promise actually work?) | `journey-walker` agent — traces (and where safe, executes) every documented workflow entry→outcome; docs-vs-API drift |
| Security vulnerabilities | `security-auditor` agent + bandit/semgrep/audit/gitleaks |
| Performance issues | `performance-analyzer` agent — **measure-first**: HIGH findings carry numbers |
| **Architecture / shape** (shallow modules, leaky seams, over-abstraction) | `architecture-reviewer` agent — the strictness layer for code that passes lint/types but still feels off |
| Verified bug fixing | `/diagnose-bug` — red-capable feedback loop before hypothesizing, regression test at a correct seam |
| **Fix verification** | `/verify` — grades every prior finding OPEN/PARTIAL/FIXED/REGRESSED/STALE with evidence; runs the debt ratchet |
| Safe deletion | graded SAFE/CAUTION/DANGER workflow + deletion test + `DELETION_LOG.md` |
| Prevention between audits | warn-only hook flags newly introduced markers/suppressions (`check_new_debt.sh`) |
| End-to-end orchestration | `/audit` — seven agents to measured coverage → report + spec + state + offline HTML |

The architecture and diagnosis layers adapt Matt Pocock's engineering skills
([mattpocock/skills](https://github.com/mattpocock/skills), MIT).

Language-agnostic methodology with tool packs for **Python, TypeScript/JS, Rust,
and Go**. Adding a language only touches the tool pack — the judgment phases are
prompt-driven and unchanged.

## Commands

- `/audit` — **the one command.** Seven agents (journey-walker first — it
  writes the shared trace — then six in parallel), coverage ledger +
  loop-until-dry (a mandatory **Not covered** section — "clean" and "unread" are
  never conflated), adversarial verification of HIGH+ findings, then:
  `audit/HEALTH_REPORT.md` + `audit/SPEC.md` + `audit/state.json` +
  `audit/HEALTH_REPORT.html`.
- `/verify` — the back half of the loop. Re-judges every fingerprinted finding
  after fixes land: FIXED needs evidence (a regression test or explained
  removal); "looks fixed, no test" is PARTIAL by definition. Closing tests are
  rerun 5x in fresh processes — a flaky closing test grades PARTIAL, never
  FIXED. Runs the marker/suppression ratchet; the CI debt check is strict by
  default (`--no-strict`/`WARN_ONLY=1` to relax — the edit-time hook always
  warns only).
- `/health-audit` — report-only audit (all seven agents).
- `/dead-code` — find + safely remove dead/unused/redundant code.
- `/incomplete-logic` — find partially-implemented logic only.
- `/architecture` — review shape: shallow modules, leaky seams, over-abstraction.
- `/diagnose-bug` — verify + fix a bug with a feedback loop and regression test.

### The loop

```
/audit   →  evidence (tools+markers+suppressions+coverage+git history)
         →  7 agents to measured coverage (ledger; re-dispatch until dry)
         →  adversarial check of HIGH+  →  report + SPEC + state.json (fingerprints)
fixes    →  humans or agents execute SPEC waves; FIX_LOG per item
/verify  →  every finding re-judged with evidence: OPEN/PARTIAL/FIXED/REGRESSED
         →  ratchet: marker/suppression counts must not creep
(hook)   →  between audits, new debt is flagged the moment it's introduced
```

## Loop safety

An automated loop with flawed logic must cost you wrong reports, never damaged
code. The invariants (detection never mutates; hooks warn, never block; corrupt
state degrades to first-run; FIXED requires evidence; nothing silently truncates)
live in `skills/cleanup-audit/references/loop-safety.md` and bind every command,
agent, and script.

## Self-test & ground truth

`scripts/self_test.sh` (repo root) runs the deterministic layer against a
**planted-defect corpus** (`test-fixtures/planted/` + `EXPECTED_FINDINGS.yaml`):
one instance of every taxonomy category, exclusion traps, a must-not-flag
dynamic-dispatch decoy, a broken documented journey. Agent-level detection is
evaluated by running `/audit` on the corpus and comparing to the manifest.
**The miss-to-fixture rule:** every real-world miss is planted into the corpus
*before* the detection gap is fixed — red first, so no gap can recur silently.

## Install

codebase-health ships inside the one `zero-trust` plugin (ADR 0025), installed
via the skills-dir clone (ADR 0027 — no marketplace; see the root `README.md`):

```bash
git clone <repo> zero-trust-verification
ln -s "$(pwd)/zero-trust-verification/plugins/zero-trust" ~/.claude/skills/zero-trust
```

Install the language tools you use (each auto-skips if absent), e.g. Python:
```bash
pip install vulture ruff deptry bandit   # deadcode/radon optional; ruff covers complexity (C901)
```
For uncovered-branch evidence, run your test suite with coverage before auditing.

## Core principle

Tools find evidence; agents make the judgment; **nothing counts until verified**.
Nothing is deleted on tool output alone — especially a library/SDK's public API,
which tools falsely flag as "unused" because only external consumers reference it.

## Extending

Fork it. Add agents under `agents/`, commands under `commands/`, a new language
tool pack in `skills/cleanup-audit/references/cross-language-tooling.md` + a
branch in `scripts/run_audit.sh` — and plant fixtures for anything you add.
License: MIT.
