# Test-Health Taxonomy (nondeterminism + vacuity)

The detection catalog for the test suite audited **as its own subject** — owned
by the test-health-auditor, category namespace `test-health/T*`. Two failure
families: **nondeterminism** (a flaky test trains humans to ignore red) and
**vacuity** (a green test that constrains nothing is coverage theater).
Framing that governs both: **coverage % measures execution, not constraint** —
a line can be 100% covered by tests that would pass no matter what the line
did. You (the LLM) are the detector; the deterministic layer only hands you
candidates.

Scan priority order (orders the queue, never truncates it):
1. CI-gating suites (a lie here blocks or falsely blesses every merge).
2. Tests covering security / auth / data-write paths.
3. Tests already wrapped in retries or skips (the tooling has confessed).
4. Everything else, largest/most-central test files first.

For every finding emit: `file:line` · category `test-health/T1–T12` · severity
(per `severity-rubric.md`) · evidence snippet · **determinism note**
(demonstrated / traced / unconfirmed) · concrete suggested fix (inject the
clock, seed the RNG, use tmp_path, fake the transport, join the threads,
rewrite the assertion).

## Candidates, not verdicts (the artifact contract)

`run_audit.sh` writes three deterministic artifacts, all gated to
`TEST_PATH_RE` paths (regexes live in `scripts/debt_patterns.sh` — one
definition so detection, prevention, and `/verify` can never drift):
- `audit/test_flakiness.txt` — `FLAKY_RE` hits (sleeps, unseeded randomness,
  wall-clock, retry markers, real-network calls).
- `audit/test_vacuity.txt` — `TEST_VACUOUS_RE` hits (literal tautologies only).
- `audit/test_skips.txt` — `TEST_SKIP_RE` hits (skip/only/xit and friends).

Every line is a **candidate to judge, never a verdict to relay**: a sleep can
be a bounded poll; a skip can carry a linked ticket. Equally, the artifacts are
not the ceiling: order-dependence, over-mocking, and identity tautologies have
no regex — read for them. Empty artifacts plus the run log's "[note] no test
files detected" means *no tests*, not a clean suite. Survived mutants from an
ingested mutation report go to the **top of the queue** — each is
deterministic proof that no test constrains that code.

## Family 1 — Nondeterminism (T1–T7)

- **T1 — Sleep-based synchronization** standing in for a real readiness
  condition.
- **T2 — Order-dependence / shared mutable state** — passes in file order,
  fails shuffled. No regex catches this; the shuffled-order probe demonstrates
  it.
- **T3 — Uncontrolled randomness** feeding inputs or assertions. Seeded
  instances are the fix, not the finding.
- **T4 — Wall-clock / timezone dependence** in test logic.
- **T5 — Real external I/O in unit tests** — flaky AND potentially unsafe: a
  test that performs a real mutation is **traced, never executed**; the
  unsafety IS the finding.
- **T6 — Concurrency races** — threads/tasks started and asserted on without
  join/await; the thread-lifecycle reasoning is the finding.
- **T7 — Retry-until-pass** (`@pytest.mark.flaky`, `reruns=N`,
  `jest.retryTimes()`) — the tooling agreeing to ignore nondeterminism.
  Taxonomy Category G routes test-scope suppressions here; each hides a T1–T6
  root cause.

## Family 2 — Vacuity / coverage theater (T8–T12)

- **T8 — Assertion-free (call-and-pray)** — only an exception can fail it.
  Whole-function judgment: helper assertions, context-manager asserts, and
  framework matchers count as real assertions.
- **T9 — Tautological** — true by construction. The literal slice
  (`assert True`, `expect(true).toBe(true)`) mirrors `TEST_VACUOUS_RE` exactly
  — **change them together**. Identity forms (`assert result == result`) and
  mock-echo forms are yours to read — ERE lacks the backreferences.
- **T10 — Over-mocked / mocks the unit under test** — the subject's logic
  never runs. What "the unit under test" is is semantic — read for it.
- **T11 — Snapshot rubber-stamp** — a snapshot blessed without review that now
  enshrines wrong output. Judge the snapshot content, not just its existence.
- **T12 — Skipped / focused** — the suite quietly shrank (`skip`, `xit`), or
  shrank to one (`.only`). Mirrors `TEST_SKIP_RE` — change them together.

**Assertion density is a triage heuristic, never a verdict.** A one-assert test
can be airtight; a ten-assert test can assert ten tautologies.

## Bounded-probe protocol (the confirm-before-HIGH gate)

Read-only, bounded, loop-safe (loop-safety.md invariant 1). To *demonstrate*
nondeterminism:
- **Read before you probe**: the test body, its fixtures, and any conftest /
  setUp/tearDown / module-level code it pulls in — all of it executes on a
  single-test probe, so the destructive-I/O gate below is applied to all of it,
  before the run.
- **Single test or single file** per probe, never the whole suite.
- **N ≤ 10 repeats, fixed in advance** — never while-until-fail.
- **Shuffled vs file order diff**: `pytest -p randomly`,
  `go test -shuffle=on -count=5`, `jest --ci --runInBand` vs `jest --ci`
  default order — a pass/fail diff between orders demonstrates T2.
- **TZ-varied rerun** (e.g. `TZ=UTC` vs `TZ=Pacific/Kiritimati`) for T4.
- **Never destructive**: never execute a test whose body, fixtures, or
  collection-time setup performs real network mutation or destructive I/O —
  that unsafety IS the T5 finding; trace it only.
- **The runner writes too — probe writers in no-write mode**: snapshot and
  golden-file runners mutate the target repo BY DEFAULT — jest CREATES missing
  snapshot files unless `--ci` (or `CI=true`); Rust insta leaves `.snap.new`
  pending files on mismatch under plain `cargo test` (`INSTA_UPDATE=no`
  suppresses it); golden suites often write on first run. The destructive-I/O
  gate covers writes performed by the runner itself, not just the test body:
  probe snapshot/golden tests (T11 candidates included) only in the runner's
  documented no-write mode; no such mode → trace only. A probe that leaves
  `__snapshots__/` artifacts behind violates invariant 1.
- **Never mutate or delete the implementation** to see if a test notices.
  Mutation testing is owner-run, out-of-band, **ingested only**. No artifacts
  left behind.

A finding whose probe ran and reproduced is *demonstrated*; a finding argued
from code structure is *traced*; anything less is *unconfirmed*. Say which.

## Mutation-report ingestion (never run, gold-standard evidence)

`run_audit.sh` copies any pre-existing mutation report (mutmut cache query,
Stryker `mutation-report.json`, cargo-mutants `missed.txt`, go-mutesting) into
`audit/`; absent → a loud `[note]`, never a silent gap. A **survived mutant is
deterministic proof a test constrains nothing** — stronger vacuity evidence
than any reading of the assertions. No agent, command, or script ever runs a
mutation tool (it mutates the working tree).

## Severity (the gate lives in severity-rubric.md — cited, not restated)

Never-CRITICAL and both routes to HIGH, with their qualifiers, are defined
ONCE: `severity-rubric.md`, the 1.4.0 test-health bullet. Apply that text as
written — two copies of one gate is how gates drift. Demonstrating
nondeterminism for the HIGH route means the bounded-probe protocol above; per
the rubric, the survived-mutant clause is evidence of sole-coverage, not a
third route. Below the gate:

- **MED needs-verification** — the default for unprobed candidates.
- **LOW** when real assertions elsewhere cover the same path (the vacuous test
  is clutter, not a hole in the net).
- The never-CRITICAL corollary: a rubber-stamp test blessing a *reachable
  security defect* yields a separate, cross-linked security finding on the
  production symbol; the two are never merged.

## Closure (what `/verify` accepts — strongest evidence first)

- **Nondeterminism**: deterministic replacement (seed injected, clock frozen,
  transport faked, threads joined) **plus** the standard closing-test
  determinism gate — the 5/5 fresh-process reruns, one order-randomized, as
  defined in `audit-state-and-verify.md` ("Closing-test determinism"). That
  gate IS the stability probe; N=5 is fixed, no override (Decision 3).
- **Vacuity**: a fresh **owner-run** mutation report showing the
  previously-survived mutants killed; or the re-read assertion is now
  substantive plus a passing run.
- **Deletion** of the test requires a FIX_LOG/DELETION_LOG entry naming the
  fingerprint — otherwise the disappearance grades **STALE**.
- A rewrite that still constrains nothing grades **PARTIAL** — never rounds up.

## Reporting template (per finding)

```
### [SEVERITY] <short title>
- Location: tests/test_payments.py:41
- Category: test-health/T4 — wall-clock dependence
- Evidence:
    expires = datetime.now() + timedelta(hours=1)
    assert token.valid_until > expires   # fails within the last hour of any day
- Determinism note: demonstrated — 3/10 red with TZ=Pacific/Kiritimati, 10/10 green with TZ pinned to UTC.
- Suggested fix: inject the clock (freezegun / fake timer fixture); assert against the frozen instant.
- Risk if unfixed: intermittent red trains the team to rerun-until-green; the assert stops gating.
```

## Judgment guardrails

- **Remedies are fixes, not findings**: seeded RNG, frozen/injected clocks,
  `tmp_path`, fake timers, faked transports are what correct tests look like.
- **Canned fixture data consumed by a real assertion is correct** — vacuity is
  about the assertion, not the data.
- **Integration/e2e suites are judged by their own contract**: real I/O and
  longer waits can be the point there; T5 is about *unit* tests.
- **Bounded polling-with-timeout is not a bare sleep.**
- A skip with a linked issue and a stated re-enable condition is documented
  debt (still report T12, grade LOW); a bare skip is the finding.

## Ownership seam (routing, not overlap)

- The incomplete-logic taxonomy owns **non-test code**; Category B stays scoped
  exactly as its guardrail says. **A test that constrains nothing is
  test-health territory** — every test-subject finding is category
  `test-health/*`, owned by the test-health-auditor, never Category B.
- **Wrong-seam-but-real** tests (well-asserted, testing at the wrong boundary)
  stay with architecture-reviewer strictness test #2. Both-at-once — wrong seam
  AND constrains nothing — is ONE finding, category `test-health/T*` per the
  precedence chain in `audit-state-and-verify.md`, with architecture in
  `lenses`.
