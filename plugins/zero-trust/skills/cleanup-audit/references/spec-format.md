# Spec Format — findings → implementation plan

`HEALTH_REPORT.md` says *what's wrong*. `SPEC.md` says *what to do, in what order, and how to prove it's fixed*. The audience is whoever knocks out the findings — a human, or a coding agent executing wave by wave. Every item must be executable without re-reading the whole report.

The two non-negotiables that separate a spec from a to-do list:
1. **Waves are ordered so nothing breaks a later wave.** SAFE/reversible first, structural last.
2. **Every item carries a regression-test seam** — the exact place a test can assert the fix and catch the regression. If a finding has no correct test seam, that absence is itself a finding (cross-link it to the architecture section). Don't paper over it.

## Document shape

```markdown
# Implementation Spec — <repo>

## Summary
- N findings: X CRITICAL, Y HIGH, Z MED/LOW.
- Highest-leverage first fix: <one line>.
- Stack / constraints: <language, internal-index limits, CI seams available>.

## Wave 1 — SAFE & reversible (no behavior change)
Dead code removal, doc hygiene, inlining shallow pass-throughs. Each is independently revertable.

## Wave 2 — Confirmed correctness bugs (HIGH)
Reachable incomplete logic, silent no-ops. Lock each with a red test BEFORE fixing (see `/diagnose-bug`).

## Wave 3 — Security
`verify=False`, SSRF via env-driven URLs, secret handling. Often needs a config/interface change — sequence after correctness so tests are trustworthy.

## Wave 4 — Performance
Per-request construction, redundant cold-start work, hot-path complexity. Measure-then-change; include the before/after signal to capture.

## Wave 5 — Architecture (structural)
Shallow modules, leaky seams, speculative abstractions. Highest blast radius, lowest reversibility — last. Each as a before/after of the **interface**.
```

## Per-item template

Every finding becomes one item with all of these fields:

```markdown
### [TAG] <short title>
- **Status**: Todo | In progress | Done | Verified   ← only `/verify` may write "Verified"
- **Fingerprint**: `a1b2c3d4e5f6` (from `audit/state.json` — keeps spec ↔ state ↔ verify joined)
- **Severity / strength**: HIGH · (Strong | Worth exploring | Speculative for arch items)
- **Location**: `path/to/file.py:120-148`
- **What's wrong**: one or two sentences, concrete.
- **Fix**: the actual change — interface before/after for structural items, not just "refactor this".
- **Regression-test seam**: the exact test entry point + assertion that proves it. When the path touches time, randomness, or the network, also name the **injection point** (clock / seed / transport) the test will use — a seam that forces sleeps or live calls produces a flaky closing test, which `/verify` grades PARTIAL. If none exists, say so and add "create seam" as a sub-task (and cross-link to ARCH).
- **Risk / reversibility**: blast radius, what could break, how to revert.
- **Depends on**: other TAGs that must land first (keeps wave ordering honest).
```

"Done" is the implementer's claim; "Verified" is `/verify`'s judgment with
evidence. The gap between the two is exactly where half-done fixes hide — never
collapse them. Determinism note: the evidence must itself be deterministic — a
closing test that cannot pass `/verify`'s rerun gate (N=5 fresh-process runs,
fixed, no override) is not evidence, however green a single run looked. A
nondeterministic pass never rounds "Done" up to "Verified".

Carry the **tags verbatim** from the report (e.g. `IL-H1`, `SEC-H1`, `PERF-H1`, `DC-H1`, `ARCH-H1`) so the spec and report stay cross-referenceable.

## Rules
- **No fix without a test seam.** If the only way to test is to change the design, that's a Wave 5 architecture item the bug fix depends on — make the dependency explicit rather than shipping an untestable patch.
- **One item = one revertable change.** If it can't be reverted alone, split it or move it later.
- **Order by reversibility, not by severity within a wave.** A reversible HIGH can precede an irreversible MED.
- **Don't restate evidence** — link back to the report tag. The spec is for *doing*, not re-diagnosing.

## `docs/FIX_LOG.md` (the DELETION_LOG for fixes)

Whoever executes a spec item records, per fix: the **tag + fingerprint**, the
**commit SHA**, the **regression test** added/updated (path + what it asserts,
plus **rerun evidence** — e.g. `5/5`, matching `/verify`'s fixed N=5 gate), and
anything intentionally left out of scope. `/verify` reads this log to explain
removed symbols and to grade FIXED vs PARTIAL. No log entry + no test = at best
PARTIAL, regardless of how the code looks.
