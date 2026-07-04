# Test-Health Taxonomy (nondeterminism + vacuity)

This is the detection catalog for the test suite audited **as its own subject** —
owned by the test-health-auditor. Two failure families share one letter space,
category namespace `test-health/T*`: **nondeterminism** (a flaky test trains
humans to ignore red) and **vacuity** (a green test that constrains nothing is
coverage theater). Framing that governs both: **coverage % measures execution,
not constraint** — a line can be 100% covered by tests that would pass no matter
what the line did. You (the LLM) are the detector; the deterministic layer only
hands you candidates.

Scan priority order:
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
- `audit/test_flakiness.txt` — `FLAKY_RE` hits (sleeps, unseeded randomness, wall-clock, retry markers, real-network calls).
- `audit/test_vacuity.txt` — `TEST_VACUOUS_RE` hits (literal tautologies only).
- `audit/test_skips.txt` — `TEST_SKIP_RE` hits (skip/only/xit and friends).

Every line is a **candidate to judge, never a verdict to relay**. A sleep can be
a bounded poll; a skip can carry a linked ticket; a `print` in a test is nobody's
business here. Equally, the artifacts are not the ceiling: order-dependence,
over-mocking, and identity tautologies have no regex — read for them. Empty
artifacts plus the run log's "[note] no test files detected" means *no tests*,
not a clean suite. If a mutation report was ingested into `audit/`, its survived
mutants go to the **top of the queue** — each is deterministic proof that no
test constrains that code.

---

## Family 1 — Nondeterminism (T1–T7)

- **T1 — Timing waits / sleep-based synchronization**: `time.sleep`, `setTimeout`,
  `thread::sleep` standing in for a real readiness condition. Passes on a fast
  machine, fails under CI load. Fix: wait on the condition/event, or bounded
  poll with timeout (see guardrails).
- **T2 — Order-dependence / shared mutable state**: tests that pass in file
  order and fail shuffled — module-level caches, class attributes, leftover
  files/rows, one test consuming another's setup. No regex catches this; the
  shuffled-order probe demonstrates it.
- **T3 — Uncontrolled randomness**: module-level `random.*` / `Math.random()` /
  `rand::random` feeding inputs or assertions without a seed. Seeded instances
  (`random.Random(1234)`) are the fix, not the finding.
- **T4 — Wall-clock / timezone dependence**: `datetime.now()`, `Date.now()`,
  `new Date()`, `time.Now()` in test logic — passes today, fails at midnight,
  on Dec 31, or in another TZ. Fix: inject/freeze the clock.
- **T5 — Real external I/O in unit tests**: live HTTP, DNS, real databases,
  real queues. Both flaky (network) AND potentially unsafe — see the probe
  protocol: a test that performs a real mutation is **traced, never executed**;
  the unsafety IS the finding. Fix: fake transport / recorded fixtures.
- **T6 — Concurrency races**: threads/goroutines/tasks started and asserted on
  without join/await/synchronization. Thread-lifecycle reasoning is the
  finding — a missing `join()` next to the assert is only the hint.
- **T7 — Retry-until-pass**: `@pytest.mark.flaky`, `reruns=N`,
  `jest.retryTimes()` — the tooling agreeing to ignore nondeterminism. This is
  the Category G analog (taxonomy Category G routes test-scope suppressions
  here): institutionalized flakiness, and each one hides a T1–T6 root cause.

## Family 2 — Vacuity / coverage theater (T8–T12)

- **T8 — Assertion-free (call-and-pray)**: the test calls the code and asserts
  nothing; only an exception can fail it. Whole-function judgment — helper
  assertions (`assert_valid(x)`), context-manager asserts, and framework
  matchers count as real assertions.
- **T9 — Tautological**: assertions true by construction. The literal slice
  (`assert True`, `expect(true).toBe(true)`) mirrors `TEST_VACUOUS_RE` exactly —
  **change them together**. Identity forms (`assert result == result`,
  `expect(x).toBe(x)`) and mock-echo forms (asserting a mock returns what the
  mock was told to return) are yours to read — ERE lacks the backreferences.
- **T10 — Over-mocked / mocks the unit under test**: so much is patched that
  the subject's logic never runs, or the mock replaces the very function the
  test claims to cover. What "the unit under test" is is semantic — read for it.
- **T11 — Snapshot rubber-stamp**: a snapshot blessed without review that now
  enshrines wrong output — the test asserts "output equals whatever it was",
  including the bug. Judge the snapshot content, not just its existence.
- **T12 — Skipped / focused**: `skip`, `xit`, `@pytest.mark.skip`, `t.Skip()` —
  the suite quietly shrank — and `.only` / focused variants, which shrink it to
  one. Mirrors `TEST_SKIP_RE` — change them together.

**Assertion density is a triage heuristic, never a verdict.** A one-assert test
can be airtight; a ten-assert test can assert ten tautologies.

---

## Bounded-probe protocol (the confirm-before-HIGH gate)

Read-only, bounded, loop-safe (loop-safety.md invariant 1). To *demonstrate*
nondeterminism:
- **Read before you probe**: the test body, its fixtures, and any conftest /
  setUp/tearDown / module-level code it pulls in — all of it executes on a
  single-test probe, so the destructive-I/O gate below is applied to all of
  it, before the run.
- **Single test or single file** per probe, never the whole suite.
- **N ≤ 10 repeats, fixed in advance** — never while-until-fail.
- **Shuffled vs file order diff**: `pytest -p randomly`,
  `go test -shuffle=on -count=5`, `jest --ci --runInBand` vs `jest --ci`
  default order (`--ci` per the runner-writes bullet below) — a pass/fail
  diff between orders demonstrates T2.
- **TZ-varied rerun** (e.g. `TZ=UTC` vs `TZ=Pacific/Kiritimati`) for T4.
- **Never destructive**: never execute a test whose body, fixtures, or
  collection-time setup performs real network mutation or destructive I/O —
  that unsafety IS the T5 finding; trace it only.
- **The runner writes too — probe writers in no-write mode**: snapshot and
  golden-file runners mutate the target repo BY DEFAULT — jest CREATES
  missing snapshot files unless `--ci` (or `CI=true`), Rust insta leaves
  `.snap.new` pending files on mismatch under plain `cargo test`
  (`INSTA_UPDATE=no` suppresses it), and golden suites often write on first
  run. The destructive-I/O gate above covers writes performed by the runner
  itself, not just the test body: probe snapshot/golden tests (T11
  candidates included) only in the runner's documented no-write mode; no
  such mode → trace only. A probe that leaves `__snapshots__/` artifacts
  behind violates invariant 1.
- **Never mutate or delete the implementation** to see if a test notices.
  Mutation testing is owner-run, out-of-band, **ingested only** (invariant 1:
  detection is mutation-free). No artifacts left behind.

A finding whose probe ran and reproduced is *demonstrated*; a finding argued
from code structure is *traced*; anything less is *unconfirmed*. Say which.

## Mutation-report ingestion (never run, gold-standard evidence)

`run_audit.sh` copies any pre-existing mutation report (mutmut cache query,
Stryker `mutation-report.json`, cargo-mutants `missed.txt`, go-mutesting) into
`audit/`; absent → a loud `[note]`, never a silent gap. A **survived mutant is
deterministic proof a test constrains nothing** — the strongest vacuity
evidence available, stronger than any reading of the assertions. No agent,
command, or script ever runs a mutation tool (it mutates the working tree).

## Severity (the gate lives in severity-rubric.md — cited, not restated)

Never-CRITICAL and both routes to HIGH, with their qualifiers, are defined
ONCE: `severity-rubric.md`, the 1.4.0 test-health bullet. Apply that text as
written — it is deliberately not copied here, because two copies of one gate
is how gates drift. Demonstrating nondeterminism for the HIGH route means the
bounded-probe protocol above; per the rubric, the survived-mutant clause is
evidence of sole-coverage, not a third route. Below the gate, this reference
adds the lower tiers:

- **MED needs-verification** otherwise — the default for unprobed candidates.
- **LOW** when real assertions elsewhere cover the same path (the vacuous test
  is clutter, not a hole in the net).
- The never-CRITICAL corollary (it rides with the rubric bullet): a
  rubber-stamp test blessing a *reachable security defect* yields a separate,
  cross-linked security finding on the production symbol; the two are never
  merged.

## Closure (what `/verify` accepts — strongest evidence first)

- **Nondeterminism**: deterministic replacement (seed injected, clock frozen,
  transport faked, threads joined) **plus** the standard closing-test
  determinism gate — the 5/5 fresh-process reruns, one order-randomized, as
  defined in `audit-state-and-verify.md` ("Closing-test determinism"). That
  gate IS the stability probe; no separate rerun budget exists here (N=5 is
  fixed, no override — Decision 3).
- **Vacuity**: a fresh **owner-run** mutation report showing the
  previously-survived mutants killed; or the re-read assertion is now
  substantive plus a passing run.
- **Deletion** of the test requires a FIX_LOG/DELETION_LOG entry naming the
  fingerprint — otherwise the disappearance grades **STALE**.
- A rewrite that still constrains nothing grades **PARTIAL** — never rounds up.

---

## Per-language idiom equivalents

| Pattern | pytest / unittest | jest / vitest | Go `testing` | Rust `#[test]` |
|---|---|---|---|---|
| Sleep-sync (T1) | `time.sleep(2)` before assert | `setTimeout` / un-awaited timer | `time.Sleep` before check | `thread::sleep` |
| Order-dependence (T2) | module global mutated across tests | shared `let` outside `beforeEach` | package-level var across `TestXxx` | `static mut` / `lazy_static` state |
| Unseeded randomness (T3) | `random.random()` input | `Math.random()` input | `rand.Intn` without seed | `rand::random` |
| Wall-clock (T4) | `datetime.now()` in assert | `Date.now()` / `new Date()` | `time.Now()` | `Instant::now()` |
| Real I/O (T5) | `requests.get(...)` in a unit test | `fetch("https://...")` | `http.Get` / `net.Dial` | `reqwest::blocking::get` |
| Retry-until-pass (T7) | `@pytest.mark.flaky(reruns=3)` | `jest.retryTimes(3)` | rerun loop in test script | `#[retry]`-style macros |
| Assertion-free (T8) | body with no `assert` | no `expect()` call | no `t.Error/Fatal` path | no `assert!`/`assert_eq!` |
| Tautology (T9) | `assert True` | `expect(true).toBe(true)` | `if false { t.Fatal(...) }` | `assert!(true)` |
| Over-mocked (T10) | `patch` on the subject itself | `jest.mock` of the module under test | interface stub replacing the SUT | mocked trait impl replacing the SUT |
| Snapshot stamp (T11) | golden-file blindly regenerated | `toMatchSnapshot()` on wrong output | `.golden` updated with `-update` | insta snapshot accepted unreviewed |
| Skipped/focused (T12) | `@pytest.mark.skip` | `it.skip` / `it.only` / `xit` | `t.Skip()` | `#[ignore]` |

---

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

- **Remedies are fixes, not findings**: seeded RNG (`random.Random(1234)`),
  frozen/injected clocks, `tmp_path`, fake timers, faked transports are what
  correct tests look like.
- **Canned fixture data consumed by a real assertion is correct** — vacuity is
  about the assertion, not the data.
- **Integration/e2e suites are judged by their own contract**: real I/O and
  longer waits can be the point there; T5 is about *unit* tests.
- **Bounded polling-with-timeout is not a bare sleep** — a capped retry loop
  waiting on a real condition is legitimate synchronization.
- A skip with a linked issue and a stated re-enable condition is documented
  debt (still report T12, grade LOW); a bare skip is the finding.

## Ownership seam (routing, not overlap)

- The incomplete-logic taxonomy owns **non-test code**; Category B stays scoped
  exactly as its guardrail says. **A test that constrains nothing is test-health
  territory** — every test-subject finding (flaky, vacuous, over-mocked,
  rubber-stamp, skipped) is category `test-health/*`, owned by the
  test-health-auditor, never Category B.
- **Wrong-seam-but-real** tests (well-asserted, testing at the wrong boundary)
  stay with architecture-reviewer strictness test #2. Both-at-once — wrong seam
  AND constrains nothing — is ONE finding, category `test-health/T*` per the
  precedence chain in `audit-state-and-verify.md`, with architecture in
  `lenses`.
- Test-scope suppressions of nondeterminism (`@pytest.mark.flaky`, retry
  wrappers) are graded here as T7, not as taxonomy Category G.
