# Gap Closure Spec — codebase-health 1.2.0 → 1.3.0

Register of every gap identified in the 2026-07-02 plugin audit. Each item has an
acceptance criterion that a reviewer can check without trusting the author.
Status is filled in only by verification (self-test output or independent review),
never by the implementer's assertion.

Severity of the meta-risk this spec addresses: the plugin was a one-shot detector —
no memory between runs, no coverage accounting within a run, no dynamic evidence,
no journey dimension, no prevention between audits.

## LC — Loop closure (fixes verified, not assumed)

| ID | Gap | Acceptance criterion |
|---|---|---|
| LC1 | No stable finding identity across runs | `references/audit-state-and-verify.md` defines fingerprint = `sha1(path:symbol:slug)` (no line numbers; category is metadata — revised in round 2 after the original `category:path:symbol` scheme collided on same-category defects and broke cross-agent dedup), schema-versioned `audit/state.json`; `/audit` writes it |
| LC2 | No fix-verification mode | New read-only `/verify` command grades each prior finding OPEN / FIXED / PARTIAL / REGRESSED / STALE with file:line or test evidence per verdict |
| LC3 | SPEC items have no completion tracking | `spec-format.md` per-item `Status` field + `docs/FIX_LOG.md` discipline (finding → commit → test) |
| LC4 | No ratchet | `state.json` persists marker/suppression counts; `/verify` and the prevention check compare against them |

## CV — Coverage / completeness within a run

| ID | Gap | Acceptance criterion |
|---|---|---|
| CV1 | No record of which files agents read | Every agent's output contract includes a files-examined ledger; `/audit` diffs it against `git ls-files` inventory |
| CV2 | Single pass, no loop-until-dry | `/audit` re-dispatches agents over the unexamined remainder until empty or two consecutive rounds add nothing new |
| CV3 | Report can't distinguish clean from unread | `HEALTH_REPORT.md` has a mandatory **Not covered** section (may be "none") |
| CV4 | No sharding for large codebases | `/audit` includes per-directory fan-out guidance keyed to repo size |
| CV5 | Only incomplete-logic findings require confirmation | All agents' HIGH+ findings pass an adversarial verification step before the consolidated table |

## DY — Dynamic evidence (code is executed, not only read)

| ID | Gap | Acceptance criterion |
|---|---|---|
| DY1 | No coverage-report ingestion | Coverage tools in `cross-language-tooling.md` all four packs + `run_audit.sh` ingests an existing coverage report if present |
| DY2 | Perf agent never measures | `performance-analyzer` has an explicit measure-first step (timing harness / profile) and must attach numbers to HIGH findings or downgrade |
| DY3 | IL detector can't run anything | `incomplete-logic-detector` tools include Bash; reachability confirmation may execute a test/REPL probe |
| DY4 | Examples never executed | journey-walker (JW1) executes runnable examples/quickstarts where feasible |

## JW — Journey dimension (docs as spec)

| ID | Gap | Acceptance criterion |
|---|---|---|
| JW1 | No agent walks documented user journeys | New `journey-walker` agent: takes README/docs/examples as the spec, traces each workflow entry→outcome, executes where safe |
| JW2 | docs/ never audited against API surface | journey-walker contract includes docs-vs-code drift findings |
| JW3 | Not wired into orchestration | `/audit` and `/health-audit` dispatch six agents; README/CHANGELOG updated |

## PR — Prevention between audits

| ID | Gap | Acceptance criterion |
|---|---|---|
| PR1 | New debt lands unchecked | `scripts/check_new_debt.sh`: given a diff range, flags newly *introduced* markers/suppressions; exit code signals but never mutates |
| PR2 | No hook wiring | Plugin `hooks/hooks.json` runs the check warn-only after Edit/Write; documented |
| PR3 | Loop-safety invariants implicit | `references/loop-safety.md`: detection/verify never mutate; hooks warn only; corrupt state degrades to first-run; every automated action idempotent + revertable |

## DT — Detection blind spots

| ID | Gap | Acceptance criterion |
|---|---|---|
| DT1 | Marker grep misses taxonomy's own markers | grep is case-insensitive, word-boundary anchored, and covers TODO/FIXME/XXX/HACK/STUB/WIP/TBD/PLACEHOLDER/@todo/"for now"/"fix later"/"implement later"/"temporary hack·fix·workaround·solution·implementation"/stopgap/unimplemented — fixture-verified. (Bare "temporary" is deliberately excluded: "temporary file/directory" makes it precision-hostile; the phrase forms cover the debt sense.) |
| DT2 | No path exclusions; audit/ self-poisoning on run 2 | node_modules/.venv/vendor/dist/build/.git/audit excluded — fixture-verified |
| DT3 | Suppressions invisible | `run_audit.sh` scans noqa / type: ignore / ts-ignore / ts-expect-error / eslint-disable / allow(...) / #nosec / nolint → `audit/suppressions.txt` — fixture-verified |
| DT4 | Taxonomy Python-only; no suppression category | Category G (suppressed diagnostics) + TS/Rust/Go example rows for categories A–F |
| DT5 | Git history unused | `run_audit.sh` emits WIP-ish commit messages + top-churn files; Phase 0 orient references them |
| DT6 | Coverage gaps not findings | Uncovered public-API branches feed IL agent priority (via DY1 output) |

## MX — Mechanical bugs in the suite itself

| ID | Gap | Acceptance criterion |
|---|---|---|
| MX1 | Stack detected in cwd, tools run on TARGET | Detection reads manifests under TARGET (fallback cwd); explicit if/elif, no `\|\| &&` chain — fixture-verified in a monorepo layout |
| MX2 | knip stderr corrupts JSON | stderr split to `.err` file — verified by test |
| MX3 | gitleaks ignores TARGET | gitleaks invoked against TARGET path |
| MX4 | Dead `run()` helper | Removed |
| MX5 | Redundant ruff select | `--select F,C901` |
| MX6 | Renderer pills only in tables; wrong annotation; pipe-paragraph misparse | Pills render for `### [SEVERITY] title` headings; `parse()` annotated `-> tuple[str, str]`; table detection requires separator row — verified by renderer test |
| MX7 | Command flags are prose, not wired | Every command has `argument-hint` frontmatter and references `$ARGUMENTS` |
| MX8 | Three severity scales | One rubric (CRITICAL/HIGH/MED/LOW + arch strength labels) defined once in `references/severity-rubric.md`; all agents/commands cite it |
| MX9 | Cross-agent duplicates inflate counts | Consolidation step dedups by fingerprint; merged finding keeps both lenses |

## MV — Meta-verification (how this spec itself is checked)

| ID | Gap | Acceptance criterion |
|---|---|---|
| MV1 | No ground truth to measure detection against | `test-fixtures/planted/` mini-package with ≥1 instance per taxonomy category A–G, dead code, a must-NOT-flag dynamic-dispatch trap, broken documented journey, perf defect, suppressions, fake secret; `EXPECTED_FINDINGS.yaml` manifest |
| MV2 | Deterministic layer untested | `scripts/self_test.sh` runs run_audit.sh + render_report.py against fixtures; asserts marker/suppression recall, exclusion behavior, monorepo detection, renderer pills; exits non-zero on any miss |
| MV3 | Misses recur | Documented rule: every real-world miss is planted into the corpus (red) before the gap is fixed (green) |
| MV4 | Self-review grades itself | This spec is verified by independent author-blind review, evidence per ID, before 1.3.0 is tagged |

## Closure status (written from verification evidence only)

**Round 1 (2026-07-02):** three independent author-blind agents (closure auditor,
adversarial new-gap hunter, consistency checker) reviewed the implementation.
Closure verdicts: 26 VERIFIED, 8 PARTIAL (LC4, DY1, DT1, DT4, MX2, MX8, MV1, MV4),
0 MISSING. The adversarial pass additionally found 9 loop-affecting defects the
acceptance criteria hadn't anticipated — most seriously: an inert prevention hook
(stdout invisible to the model; untracked files unscanned), vacuous self-test
passes (the answer-key manifest lived inside the scanned tree), missing word
boundaries making ratchet counts noise, fingerprint collisions (5 same-category
markers on one symbol = 1 fingerprint), scope-mismatched ratchet comparisons, and
`/verify` rounding removals up to FIXED off bare git-log hits.

**Round 2 (same day):** all 8 PARTIALs and all adversarial findings addressed;
self-test grew 25 → 38 assertions, each regression planted red-first per the
miss-to-fixture rule (hook JSON + untracked-file scan, unresolvable-BASE
loudness, word-boundary precision fixtures, answer-key isolation, knip-stderr
shim test, backtick-pipe table cells, `# nosec` spacing). Design docs updated:
fingerprint = path:symbol:slug with category as metadata + precedence dedup,
same-target audit-baseline ratchet, FIXED-via-removal requires a FIX_LOG entry,
un-redetected findings stay OPEN. Verified by a fresh author-blind re-check
before tagging (see CHANGELOG 1.3.0).

Accepted residual risks (explicit WONTFIXes): bare "temporary" excluded from the
marker grep (precision); `--exclude-dir` basename semantics retained but made
loud via `audit/excluded_dirs.txt` → Not-covered; Rust pack builds the crate
(documented exception to read-only); agent-level detection quality is evaluated
against the blind corpus, not guaranteed by prompts.

---

# Gap Closure Spec — codebase-health 1.3.0 → 1.4.0

Register of every gap closed by the 1.4.0 release, per the accepted spec
(`docs/SPEC_1.4.0.md`, decisions locked 2026-07-02). Registers are append-only:
the 1.2.0 → 1.3.0 register above is history and is never edited.

Two scoring instruments, per the spec's honesty clause (§selfTestPlan). Every
acceptance criterion states BOTH halves explicitly:

- **Deterministic half** — scored by `scripts/self_test.sh` output (section
  numbers cited in Status). Current run: **131/131 green** — 128 unconditional
  + 3 ruff-conditional, with jscpd a REQUIRED dev dependency per Decision 8.
- **Blind half** — scored ONLY by the MANUAL blind-corpus eval
  (`make_blind_corpus.sh` → `/audit` over the blind copy → hand-scored against
  `test-fixtures/EXPECTED_FINDINGS.yaml`; `expected_noise:` entries EN1–EN4 are
  a hand-scoring exclusion list, counted as neither recall nor precision).

Nothing agent-level is presented as automated coverage; rows whose defect is
judgment-by-construction say "none by design" and cite the spec §12 sweep
reason. Status is filled in only by verification (self-test output or
independent review), never by the implementer's assertion. Every blind half
stays **Pending blind eval** until Wave 6 of this release records
recall/precision + date + git SHA in the closure status below.

Severity of the meta-risk this register addresses: the 1.3.0 loop trusted the
target's own safety net — a flaky closing test could round a finding up to
FIXED, a green test could constrain nothing, money could move with no emitted
event, a webhook could arrive twice unnoticed, journeys were walked for
correctness only, and the highest-volume maintainer (the coding agent) paid an
unmeasured navigation tax.

## TH — Test health (the suite audited as its own subject)

| ID | Gap | Acceptance criterion | Status |
|---|---|---|---|
| TH1 | No shared definition of test nondeterminism — detector, hook, and `/verify` could each invent their own and drift | ONE `TEST_PATH_RE` (bare paths AND `file:line:` prefixes) plus `FLAKY_RE` (case-sensitive; `asyncio.sleep` excluded; `\breruns=[1-9]` digit-anchored per fix H; literal-URL `fetch` residual documented) live in `scripts/debt_patterns.sh`, sourced by `run_audit.sh`, `check_new_debt.sh`, and `/verify`'s closing-test screen. **Self-test half:** classifier unit cases (tests/, .spec.ts, conftest.py positive; poller.py N4 and the .snap stamp negative); TF1/TF3/TF4/TF5/TF7/TF9/TF10 recall into `test_flakiness.txt`; N3/N4 zero-line exclusions; the `reruns=0` / `reruns=3` anchor pair; hook and CLI consuming the same regexes (flaky warn on a test file, silent on a prod-file sleep). **Blind half:** agent-judged flakiness forms TF2 (order dependence), TF6 (unjoined thread), TF8 (guarded assert), plus the documented residuals (template-literal / variable-URL network, long asyncio sleeps). | Self-test half **Verified** (§8 classifier units + recall + fix-H pins; §5b scoping assertions). Blind half **Verified** (2026-07-04 eval): TF2 order-dependence, TF6 unjoined-threads (both halves — missing join + unsynchronized increment), TF8 guarded/tautological assert all recalled by test-health at MED with exact file:line evidence; TF2 traced-not-probed — pytest absent from the eval environment, honestly declared (miss-to-fixture note 5). |
| TH2 | No artifacts or ratchet for test health — nondeterminism, vacuity, and shrinkage invisible between runs | `run_audit.sh` writes `audit/test_flakiness.txt` / `test_vacuity.txt` / `test_skips.txt` (TEST_PATH_RE-gated, candidates-not-verdicts) plus three report-only ratchet keys (`flaky_count`, `test_vacuity_count`, `test_skip_count`) in `counts.env`; a loud `[note]` keeps empty-because-no-tests distinguishable from empty-because-clean. **Self-test half:** the three artifacts written; the three keys present; `counts.env` holds exactly the 8 ratcheted keys; counts stable run-over-run (no self-poisoning). **Blind half:** agents treat the artifacts as candidates, not verdicts — no artifact line laundered into a finding without judgment. | Self-test half **Verified** (§8 artifacts + keys; §10 exactly-8-keys; §2 all-eight-counts stability guard + §11 run-3 recheck — §2 originally compared `marker_count` only, leaving the three test-health keys' stability asserted-not-verified; caught by the register review 2026-07-03 and the guard extended before this status was written). Blind half **Verified** (2026-07-04 eval): no artifact line laundered into a verdict — artifact-derived findings carried judgment (e.g. TQ1's sole-coverage grep trace) and expected-noise flags stayed hedged CAUTION/needs-verification; artifact spot-checks fully consistent with the upstream counts.env 8/8. |
| TH3 | No agent audits the test suite; the taxonomy actively exempts tests | Seventh agent `test-health-auditor` (Read/Grep/Glob/Bash, no `model:` pin per Decision 2) owns ALL test-subject findings under `test-health/T1–T12` per `references/test-health.md`; confirm-before-HIGH via bounded probes only (single test, N≤10, shuffled/TZ-varied, never destructive, never the whole suite); precedence slot after incomplete-logic; Category B stays scoped to non-test code (guardrail routes, never contradicts); loop-safety invariant 1 reads "all seven agents" + the bounded-probe clause. **Self-test half:** the deterministic candidate feed the agent consumes (§8 artifacts, recall, precision) — agent prose contracts carry no automated assertions by design. **Blind half:** recall on the agent-scored plants TF2/TF6/TF8 and TQ1/TQ4/TQ5/TQ8; agent-level precision on N3 (remedies conftest) and N5 (real behavior-constraining test); bounded-probe discipline observed in the transcript. | Self-test half **Verified** (§8 candidate feed). Blind half **Verified** (2026-07-04 eval): all seven agent-scored plants recalled — TF2/TF6/TF8; TQ1 at the HIGH gate with the sole-coverage trace, TQ4 mocks-the-SUT, TQ5 identity tautology read-detected, TQ8 cross-file snapshot rubber-stamp incl. the TQ7 linkage; N3 precision held (conftest cleared as "entirely remedies"), N5 held back; bounded-probe discipline unexercised — no runners present, all evidence trace-only and declared so (note 5). |
| TH4 | A flaky closing test could round a finding up to FIXED — a flaky gate is no gate | `/verify` step 3 determinism gate: closing test rerun 5× in fresh processes (N=5 FIXED per Decision 3, no override flag exists), order-randomized once, `FLAKY_RE` screen sourced from `debt_patterns.sh` (judged, not auto-fatal); 5/5 + clean-or-mitigated screen → FIXED with the rerun count in `verified_by`; any red, unrunnable, or missing test → PARTIAL, never FIXED. Loop-safety **invariant 9** ("a flaky gate is no gate"); `audit-state-and-verify.md` gains the "Closing-test determinism" section; miss-to-fixture step 1 amended to the two-consecutive-red rule. **Self-test half:** the screen's shared regex source and anchors (same sourced `FLAKY_RE`, §8 unit cases); the red-first two-run gate is encoded in the self-test's own section comments (§5b, §8–§11) and recorded in CHANGELOG 1.4.0. **Blind half:** `/verify`'s verdict behavior in practice — a nondeterministic pass never rounds up; flaky-closure grades PARTIAL. | Self-test half **Verified** (§8 shared FLAKY_RE + fix-H anchors; red-first gate per §5b/§8–§11 comments). Blind half **not exercised** by the 2026-07-04 eval (audit-only run — no `/verify` pass over the blind corpus, and no test runners to drive the 5× gate): stays **Pending blind eval**; not rounded up. Blind half **Verified** (2026-07-04, synthetic scratch fix loop in /tmp/th4_exercise — outside the repo; pytest 9.1.1 + pytest-randomly provisioned per note 5): one schema-2 finding (unclamped-discount, HIGH) fixed and gated per verify.md step 3 exactly — deterministic closing test red-first 2/2 without the fix, then **5/5 green** in fresh processes (run 3 order-randomized) with a clean FLAKY_RE screen sourced from debt_patterns.sh → FIXED, `verified_by` = `tests/test_pricing_regression.py::test_discount_clamped_regression (5/5)`; the flaky closing test for the same fix (raw wall-clock-parity gate) tallied **3 green / 2 red of 5** AND carried an unmitigated FLAKY_RE screen hit (line 12) — either trigger alone forces **PARTIAL, never FIXED**. Both prescribed outcomes matched; scratch dir removed after the run. |
| TH5 | Green tests that constrain nothing counted as coverage; mutation evidence absent | Vacuity slice: `TEST_VACUOUS_RE` (T9's literal-tautology greppable slice) and `TEST_SKIP_RE` (T12 suite-shrinkers) feed artifacts and the hook; mutation testing enters as an ingest-ONLY tier — mutmut/Stryker/cargo-mutants/go-mutesting reports copied into `audit/` when present, NEVER run (invariant 1), loud `[note]` when absent; survived mutants top the agent's queue. **Self-test half:** TQ2/TQ3 recall into `test_vacuity.txt`; N5/N3 zero-line exclusions; TQ6/TQ7 recall into `test_skips.txt`; N2's `queue.skip(3)` receiver-anchor exclusion; hook vacuous-warn section + non-test `.skip` silence. **Blind half:** agent-owned vacuity forms TQ1/TQ4/TQ5/TQ8 and survived-mutant triage; ingest-only discipline (no mutation tool ever executed) observed in the transcript. | Self-test half **Verified** (§8 vacuity/skip recall + precision; §5b warn/silence assertions). Blind half **Verified** (2026-07-04 eval) on the scored forms TQ1/TQ4/TQ5/TQ8 (see TH3); ingest-only discipline held — no mutation tool executed (vacuously: no mutation reports in the corpus, so survived-mutant triage remains unexercised). |

## OB — Observability (taxonomy Category LOG, per the logging capability)

| ID | Gap | Acceptance criterion | Status |
|---|---|---|---|
| OB1 | stdout/stderr as the production log channel invisible | `LOGGING_RE` (\b-anchored, case-sensitive; bare `echo` and `console.warn/error` documented residuals) in `debt_patterns.sh`; `run_audit.sh` writes `audit/stdout_logging.txt` with test paths gated OUT; taxonomy Category LOG (word-key — letters freeze at A–G) names stdout-as-log-channel; hits are candidates, not verdicts. **Self-test half:** LG1 (`print(` on a request path), LG2 (`sys.stdout.write(`), LG5 (`console.log` in render()) recall; N6 precondition (CLI prints ARE listed) + `pprint(` decoy never matches; N7 `game_console.log` and N2 `blueprint()/imprint()` exclusions; tests-path exemption. **Blind half:** the CLI-output-vs-log judgment — a Category-LOG finding on `report_cli.py` (N6) is the precision failure; severity grading (debug prints LOW, library/server paths MED). | Self-test half **Verified** (§9). Blind half **Verified** (2026-07-04 eval): N6 precision held — zero Category-LOG findings on `report_cli.py` (its lines correctly listed as candidates); N7 clean; journey-walker #19's prose loosely implied a widgets.ts artifact line but `stdout_logging.txt` verified at exactly the 6 expected lines — prose looseness only, no finding filed. |
| OB2 | Log-and-swallow: the log line makes an unhandled error LOOK handled | Category LOG names log-and-swallow as Category B's stricter cousin; HIGH requires confirmed reachability on data-write/auth/payment paths; LG3 fixture (service.py's swallowed except around the unconditionally-raising `_charge`). **Self-test half: none by design** — swallowing is decided by what FOLLOWS the log line in the handler block (return vs re-raise), block-level not line-level; kept agent-scored by the spec §12 sweep with the reason recorded. **Blind half:** LG3 recall with reachability-gated severity. | Self-test half: n/a by design (§12 sweep, LG3 entry). Blind half **Verified** (2026-07-04 eval): LG3 recalled at HIGH by incomplete-logic #1 with an EXECUTED reachability probe (order still marked fulfilled after the swallowed exception), the swallow-vs-reraise call made at block level as the row demands; corroborated by journey-walker #5 and security #4. |
| OB3 | Sensitive values in logs invisible — gitleaks scores hardcoded secrets, not logged variables | security-auditor checklist gains the Logging bullet: CWE-532 secrets/PII in log lines, fail-open log-and-swallow on security paths, unlogged security events CWE-778; precedence routes token-in-log to `security/logging` with lens `incomplete-logic/LOG`; SEC3 fixture continues the SEC series. **Self-test half: none by design** — dataflow semantics (a secret VALUE reaching a log call); lexical `log.*token` matching drowns in pagination-token/CSRF-token false positives (§12 sweep reason). **Blind half:** SEC3 recall with correct category routing. | Self-test half: n/a by design (§12 sweep, SEC3 entry). Blind half **Verified** (2026-07-04 eval): SEC3 recalled at HIGH (security #5, service.py:24, CWE-532) as dataflow rather than lexical matching, with the exact prescribed routing — `security/logging` by precedence, `incomplete-logic/LOG` as lens, stated explicitly by incomplete-logic #10. |
| OB4 | Observability absences either invisible or severity-inflated | Category LOG's absence class (missing structured logging / correlation IDs) is `<module>`-level, raised only on demonstrably request-serving paths, and HARD-capped MED needs-verification per the 1.4.0 rubric absence gate (Decision 4 — every citation names the amendment, never a pre-existing rule); LG4 fixture. **Self-test half: none possible** — an absence finding has nothing to grep (§12 sweep reason); the cap itself is rubric text. **Blind half:** LG4 recall at exactly MED needs-verification — an LG4 graded HIGH is a cap violation, a miss is a recall failure. | Self-test half: n/a by design (§12 sweep, LG4 entry). Blind half **PARTIAL** (2026-07-04 eval): the defect was hit and the cap held — security #9 filed service.py:31/:39 at MED citing the 1.4.0 absence cap, journey-walker graded every service.py step LOG-ONLY/DARK — but the `<module>`-scoped finding was never filed, the correlation/request-id half was never articulated, and the needs-verification mark was omitted ("confirmed"). Half-credit per the scoring; a miss stays a miss — miss-to-fixture note 1. |
| OB5 | New stdout logging lands unremarked; a wrong-often gate would get disabled | `check_new_debt.sh` gains the stdout warn section on non-test added lines, and stdout NEVER gates — report-only on every surface including the strict-default CLI (Decision 1's explicit carve-out); `stdout_logging_count` written to `counts.env`, report-only in `/verify`'s ratchet, never flips FAIL. **Self-test half:** stdout warn section fires on a non-test `print`; a print-only diff passes the strict-default CLI (exit 0); `stdout_logging_count` key present. **Blind half: none — this row is fully deterministic.** | **Verified** (§5b warn + never-gates assertions; §9 count key). No blind half. |

## BV — Business vitals (instrumentation placement)

| ID | Gap | Acceptance criterion | Status |
|---|---|---|---|
| BV1 | No inventory of money / state-transition / side-effect / auth operations to grade | `VITAL_RE` (merged superset verb list — the TX_CRITICAL_RE collision resolved into one regex; bare 'wire' excluded), `TELEMETRY_RE`, and the alerting-config `find` live in `run_audit.sh` (seeds, not debt — deliberately NOT in `debt_patterns.sh`, never counted, never hooked), writing `audit/vital_candidates.txt` / `telemetry.txt` / `alerting_config.txt`. **Self-test half:** V1 (`transfer_funds` def-site) and V2 (`approve_loan`) in `vital_candidates.txt`; V3 (`payment.charged`) in `telemetry.txt`; N2-ext decoys (recharge_battery_icon, AUTHORED_BY, turbocharged, wire_format, credits_remaining) and X1 vendored files excluded; `counts.env` exactly-8 (seeds never ratcheted). **Blind half:** journey-walker's second inventory source — undocumented handler/consumer flows walked from the seed list. | Self-test half **Verified** (§10). Blind half **Verified** (2026-07-04 eval): the seeds served as the walker's second inventory — the vitals table grades every service.py step, approve_loan walked as journey 5, and the priority-queue arithmetic (`vital_candidates ∩ tx_retries − tx_guards`) cited verbatim in security #12. |
| BV2 | Money can move with no emitted business event (dark money) | J3 `transfer_funds`, deterministic-PRIMARY per the spec §12 sweep: `transfer_funds ∈ vital_candidates.txt ∧ ∉ telemetry.txt` (DARK by seed arithmetic) plus the README `## Transfers` CORE anchor; the journey-walker's walk — criticality confirmation and HIGH grading per the Decision-4 gate (DARK + traced CORE money path) — is the corroborating lens. **Self-test half:** the full seed arithmetic and the README anchor. **Blind half:** the walk and the HIGH grade. | Self-test half **Verified** (§10 seed arithmetic; §12 README anchor). Blind lens **Verified** (2026-07-04 eval): journey-walker #6 — slug dark-money-movement, HIGH per the Decision-4 gate (DARK on the traced CORE money path, README '## Transfers', trace attached in journeys.json), with the charge_card `payment.charged` contrast drawn. |
| BV3 | Dark state transitions off the money path invisible | J4 `approve_loan`, deterministic-PRIMARY per the §12 sweep: same seed arithmetic (`∈ vital_candidates.txt ∧ ∉ telemetry.txt`); the agent walk with its MED needs-verification grading (untraced flow — Decision 4 cap) is the lens. **Self-test half:** the seed arithmetic. **Blind half:** the walk and the MED needs-verification grade. | Self-test half **Verified** (§10). Blind lens **Verified** (2026-07-04 eval): DARK grade + MED absence cap corroborated (journey-walker vitals row; security #10 "capped absence"); the needs-verification mark was omitted, acceptable per the scoring because the flow was actually walked as journey 5 — no longer untraced. |
| BV4 | A prose log line could pass for instrumentation | `references/business-vitals.md` defines an emission (structured event with a stable dot-namespaced name + identifiers, metric, or span — a prose log line does NOT count) and the OBSERVED/LOG-ONLY/DARK axis. J5 `refund_payment` stays agent-primary (§12 sweep: LOG-ONLY vs DARK is a semantic emission judgment) with its seed halves deterministically asserted. **Self-test half:** `refund_payment ∈ vital_candidates.txt ∧ ∉ telemetry.txt`; the `_LOG.info`-is-not-an-emission TELEMETRY_RE precision pin. **Blind half:** the LOG-ONLY (not DARK) grade at MED. | Seed halves **Verified** (§10). Blind half **Verified** (2026-07-04 eval): journey-walker #13 — slug log-only-refund at exactly MED, graded LOG-ONLY (not DARK) on the prose `_LOG.info` at :62 ("no stable name, nothing alertable") — the exact semantic emission judgment this row exists to test. |
| BV5 | Absence findings could inflate to HIGH on judgment alone; instrumented vitals could be re-flagged | The 1.4.0 rubric absence gate, both halves of Decision 4: (a) `journey/uninstrumented` reaches HIGH ONLY with a traced CORE money-movement or auth path attached; (b) ALL other absence findings hard-cap at MED needs-verification, no judgment escape. OBSERVED/LOG-ONLY/DARK enters the rubric's grade-words section as a separate axis; alert-seam checks answer honestly ("unknown — no alert config in repo"); TRACE-ONLY rule (money/auth paths never executed); N9 `charge_card` is fully instrumented and must grade OBSERVED, never `journey/uninstrumented`. **Self-test half:** N9's deterministic precondition — its `payment.charged` emission present in `telemetry.txt` (V3). **Blind half:** no uninstrumented flag on `charge_card`; OBSERVED grading; cap adherence across every absence finding; trace-only conduct in the transcript. | Precondition **Verified** (§10, V3). Blind half **Verified** (2026-07-04 eval): no `journey/uninstrumented` flag on charge_card (N9 held); every absence finding capped at MED (J4, J5, LG4 — zero cap violations); trace-only conduct held on money/auth walks (the run's executed probes were the IL agent's bounded DY3 probes, never a journey submission). Borderline logged, not counted: security #14's TX MED-nv on charge_card is N9-letter-clean but spirit-adjacent — extend N9 or register in 1.4.1 (note 6). |

## TX — Transactional integrity (taxonomy Category TX)

| ID | Gap | Acceptance criterion | Status |
|---|---|---|---|
| TX1 | Nothing asks "what if this arrives twice?" — a duplicate-delivered webhook charges twice | Taxonomy Category TX (word-key) names missing idempotency-key/dedup guards on non-GET handlers and webhook/queue consumers; priority queue = `vital_candidates ∩ tx_retries − tx_guards`; owners security-auditor (file-scoped) + journey-walker (journey-scoped), mirroring Category G sharing; CRITICAL requires naming who can deliver the duplicate, grep hits alone cap MED needs-verification; TX1 fixture `handle_payment_webhook`. Agent-primary per the §12 sweep (idempotent-by-construction cannot be excluded lexically). **Self-test half:** the seed corroboration — `tx_guards.txt`/`tx_retries.txt` written and N8's guard line (`if event_id in _PROCESSED_EVENTS`) present in `tx_guards.txt` (the subtraction leg of the queue). **Blind half:** TX1 recall (slugs non-idempotent-handler / missing-dedup-guard); N8 agent-level precision (no TX flag on the guarded `handle_refund_webhook`); severity discipline. | Seed corroboration **Verified** (§10). Blind half **Verified** (2026-07-04 eval): TX1 at CRITICAL with the duplicate deliverer NAMED (PSP webhook redelivery) and the N8 guard contrast at :113 (journey-walker #3, slug non-idempotent-handler; security #1 independently CRITICAL); N8 precision held — no Category-TX flag on the guarded handler (security #15's authn MED-nv on it is letter-clean; borderline logged, note 6). |
| TX2 | Retry wrappers around non-idempotent calls double-execute silently | Category TX names unsafe retry; TX2 fixture `submit_payout` (`for attempt in range(3)` around a keyless POST); idempotent-by-construction guardrails (pure reads, PUT-style upserts, ON CONFLICT, key-checked handlers, SDK `idempotency_key=`) recorded so correct code is never flagged. **Self-test half:** TX2's retry loop present in `tx_retries.txt`; N4 `poller.py` contributes nothing (no attempt-loop shape, so bounded backoff never seeds TX). **Blind half:** TX2 recall as unsafe-retry with the guardrails respected. | Seed **Verified** (§10). Blind half **Verified** (2026-07-04 eval): recalled as unsafe-retry by security #12 + journey-walker #12 with the guardrails respected, graded MED needs-verification — a defensible cap given the honest extra observation that LedgerTimeout is unreachable from the in-memory ledger; deterministic seed corroborated (the sole tx_retries.txt entry, exactly the priority-queue subtraction). |
| TX3 | Multi-step money sequences can die between steps with no compensation or audit trail | Category TX names double-submit windows, missing compensating actions, and missing audit trails on money-like transitions; canonical slugs (double-submit-window, missing-compensation, missing-audit-trail) added to the slug examples; TX3 fixture `transfer_batch` (renamed from the colliding `transfer`); journey-walker asks the dies-between-steps question at critical steps, TRACE-ONLY — never answered by submitting twice. **Self-test half: none by design** — partial-failure reasoning over a step sequence is pure judgment (§12 sweep, TX1–TX3 entry); fixture presence is corpus-level only. **Blind half:** TX3 recall via the walk, with trace-only conduct. | Self-test half: n/a by design (§12 sweep). Blind half **Verified** (2026-07-04 eval): journey-walker #4 at CRITICAL, slug missing-compensation, with the guard-after-side-effect sequencing exact (debit posts :101, validation raises :104-105, no compensating action, no audit trail); security #7 HIGH; IL probe P9 confirmed the ledger left debited after a mid-batch ValueError (a bounded DY3 probe — the walk itself stayed trace-only, nothing submitted twice). |

## JC — Journey complexity and the one shared trace (continues the JW family)

| ID | Gap | Acceptance criterion | Status |
|---|---|---|---|
| JW4 | Journeys were walked for correctness only; three 1.4.0 capabilities would each re-walk them, and a C901 in a debug helper outranked nothing | ONE shared trace: journey-walker dispatched FIRST writes `audit/journeys.json` per `references/journey-trace.md` (schema_version 1; CORE/SUPPORTING/DEV criticality ladder with written derivation rules; degrade-to-no-trace rule; proceed-on-failure stated AT the dispatch site — the other six never wait indefinitely and consume documented degrade rules trace-less). Vitals grades, TX critical-step questions, and branching burden are graded in that single walk; performance-analyzer consumes CORE journeys as confirmed hot paths. Findings are criticality-weighted: `journey/path-complexity` HIGH requires a CORE step in `journeys.json` AND an attached deterministic metric line or quoted structural redundancy (JC1 `submit_order`); metric-invisible redundancy stays judgment-capped MED (JC2 `format_receipt`); the same metric off-journey is LOW hygiene (N10 `dump_state`). **Self-test half:** fixture-integrity anchors — README names `transfer_funds`, `submit_order`, `format_receipt` on documented journeys and never `dump_state`; the C901 profile pinned (fires for submit_order and dump_state, absent for format_receipt — 3 ruff-conditional assertions, loud `[skip]` without ruff). **Blind half:** the walk itself (`journeys.json` written once, schema-valid); JC1 HIGH with quoted metric + CORE anchor; JC2 MED cap; N10 criticality-weighting precision (LOW ceiling, no `journey/path-complexity` HIGH); performance-analyzer consuming the trace. | Self-test half **Verified** (§12 README anchors; C901 profile green on the ruff-equipped run). Blind half **PARTIAL** (2026-07-04 eval): the trace was written once and consumed (journeys.json cited inside the BV2 finding; perf consumed CORE ownership); JC1 Verified at HIGH with the quoted C901 metric line + CORE anchor (journey-walker #10 and perf #1 — double-filed, dedup wrinkle → note 3); N10 Verified at LOW with explicit off-journey calibration (lens-name letter wrinkle → note 6); JC2 recalled, but the MED cap was broken by one lens — perf #2 graded HIGH with no metric line existing to attach, while journey-walker independently held the correct MED. Never round up: the JC2 cap clause failed → miss-to-fixture note 2. |

## NV — Navigability (the machine reader as first-class maintainer)

| ID | Gap | Acceptance criterion | Status |
|---|---|---|---|
| NV1 | File size taxed the machine reader unmeasured (token burn, missed edits) | Built-in non-blank-line ladder — rungs 400 [attention] / 800 [warn] / 1600 [god-file], threshold justification recorded in `cross-language-tooling.md` — writes `audit/giant_files.txt` + `giant_file_count`; architecture-reviewer triages (cohesive generated file ≠ finding; accreted god module → seam-based split recommendation with strength label). **Self-test half:** GF1 `megamodule.py` listed at the 400 rung; fixture integrity (400–799 non-blank lines); X1 vendored exclusion; count key + run-over-run stability. **Blind half:** the triage judgment; EN1 (megamodule's unused helpers flagged by dead-code layers) scored as expected noise — neither recall nor precision. | Self-test half **Verified** (§11). Blind half **Verified** (2026-07-04 eval): GF1 carried deterministically (giant_files.txt 1/1); EN1 fired exactly as registered — dead-code #2 CAUTION on the unreferenced megamodule with its stale "every job already imports this" docstring — and was scored as expected noise, neither recall nor precision. |
| NV2 | Diverged clones are latent missed edits; no duplication signal existed | jscpd row in `cross-language-tooling.md`: optional with loud `[skip]` degrade on TARGET repos (Decision 5), REQUIRED dev dependency for this suite's own `self_test.sh` (Decision 8 — no shim-only pass); output normalized to `audit/dup_jscpd.json` with a `.err` sidecar (knip precedent). ND1 is deterministic-PRIMARY: the byte-identical `format_report_rows` pair asserted in REAL jscpd output; the dead-code agent's extract-vs-intentional-fork judgment demoted to a corroborating lens. **Self-test half:** the §0 hard-requirement gate (fails loudly without jscpd); `dup_jscpd.json` valid JSON; ND1 pair recall; `megamodule.py` absent (varied bodies / `--min-tokens` precision); byte-identical fixture-integrity check; the PATH-stripped degrade run produces the loud `[skip]` miss line. **Blind half:** the extract-vs-fork lens; EN2 (extra dead-code/duplication chatter on the pair) scored as expected noise. | Self-test half **Verified** (§0 + §11). Blind lens **Verified** (2026-07-04 eval): dead-code #13 makes the exact registered call — the `build_*` pair is an intentional per-channel fork (keep separate), `format_report_rows` is shared logic under two copies (extract to one module both import) — architecture A6 concurs; EN2 fired as registered, hedged CAUTION/needs-verification, scored as expected noise. |
| NV3 | Commented-out code blocks — dead code in comment form — were grep-invisible | Leader-anchored `COMMENT_LINE_RE`/`CODE_COMMENT_RE` + `CO_MIN_RUN=3`/`CO_MIN_CODE=2` in `debt_patterns.sh` (code token IMMEDIATELY after the comment leader, so prose never matches); awk pass writes `audit/commented_code.txt` + `commented_code_count`; `check_new_debt.sh` warns on newly added blocks and the class gates the strict-default CLI. **Self-test half:** CO1 recall (block above `apply_discount`); N11 precision (zero `metrics.py` lines + the leader-anchoring regex unit); fixture integrity (≥ CO_MIN_CODE code-shaped lines in checkout.py); vendored exclusion; count key + stability; hook commented-block warn + prose-only silence. **Blind half:** dead-code-cleanup's delete-vs-genuine-spec-comment judgment on CO1. | Self-test half **Verified** (§11 + §5b). Blind half **not scored** by the 2026-07-04 eval — CO1's delete-vs-keep lens is not among the 17 agent-scored expected entries, and no adverse event was observed; deterministic half consistent (commented=1; zero metrics.py lines per N11). The lens stays **Pending blind eval**; not rounded up. Not exercisable by the 2026-07-04 TH4-style scratch loop — the delete-vs-genuine-spec-comment call is agent judgment with no rerunnable gate behind it, so the exercising event is the next manual blind-corpus eval (recurrence per pre-flight fix E) in which dead-code-cleanup is dispatched over the blind copy and its CO1 delete-vs-keep verdict is hand-scored against EXPECTED_FINDINGS.yaml. |
| NV4 | A name that lies (`get_user_count` returning active sessions) poisons every reader's context | MN1 fixture; `architecture-and-strictness.md`'s machine-reader subsection anchors misleading-name at MED. Agent-scored: name-vs-behavior semantics has no lexical form (§12 sweep reason — recorded so the honesty clause stays checkable). **Self-test half: none by design.** **Blind half:** MN1 recall at MED. | Self-test half: n/a by design (§12 sweep, MN1 entry). Blind half **Verified** (2026-07-04 eval): MN1 recalled at MED by four independent lenses — dead-code #12 (misleading-name anchor = MED, bodies byte-identical), incomplete-logic #15 (executed probe: 1 user, 2 sessions → returns 2), architecture A5, journey-walker #26 — name-vs-behavior semantics captured exactly. |
| NV5 | Navigability debt had no severity home and no between-audit prevention | `architecture-and-strictness.md` gains "Locality includes the machine reader" (token burn, missed edits, hallucinated context, definition-of-done erosion) with severity anchors inside the ONE rubric: giant file / near-dup / commented block LOW–MED, MED on churn hotspots, misleading name MED, HIGH only via existing confirmation gates. The two new ratchet keys (`giant_file_count`, `commented_code_count`) are compared report-only by `/verify` (pre-1.4 baselines say "no comparable baseline", never 0); of the navigability classes only commented-out blocks join the strict-default CLI gate (fixture-locked; size/dup counts are audit-time ratchets only). **Self-test half:** the two count keys + run-over-run stability; the strict-contract behavior split (gated class warns and gates, non-gated classes never do; escape hatches `--no-strict` / `WARN_ONLY=1` exit 0; `--hook` exits 0 unconditionally). **Blind half:** severity-anchor adherence in agent output (no HIGH without a confirmation gate). | Self-test half **Verified** (§11 counts/stability; §5b strict-contract assertions). Blind half **Verified** (2026-07-04 eval): no navigability HIGH anywhere without a confirmation gate — giant/dup/commented/misleading-name findings all landed LOW–MED or hedged CAUTION; the run's one HIGH-cap deviation (perf #2 on JC2) is a JW4 path-complexity gate issue, recorded there, not a navigability-anchor violation. |

## Closure status (written from verification evidence only)

**Deterministic halves (2026-07-03):** `scripts/self_test.sh` — **131/131 green**
(128 unconditional + 3 ruff-conditional) on a machine with the required dev
dependencies (jscpd, per Decision 8; ruff optional). A deliberately
deps-stripped run degrades loudly rather than passing silently: without jscpd
exactly the four §0/§11 jscpd-dependent assertions fail (the FATAL startup gate
plus the `dup_jscpd.json`/ND1-pair checks), and without ruff the three §12 C901
profile checks emit a loud `[skip]` — both behaviors are themselves part of the
contract (Decision 8 / Decision 5). The Wave-0 red-first gate (every new
deterministic assertion failing on two consecutive runs before Wave 1) is
encoded in the self-test's own section comments (§5b, §8–§11) and recorded in
CHANGELOG 1.4.0.

**Blind halves (manual blind-corpus eval):** Wave 6 executed per SPEC_1.4.0
§10 — `make_blind_corpus.sh` → `/audit` over the blind copy → hand-scored
against `test-fixtures/EXPECTED_FINDINGS.yaml`, scored by the manual
blind-corpus process. Eval record: date — not stamped by the run harness;
recorded 2026-07-04 from session context. Git SHA — re-stamped 2026-07-04: the
evaluated 1.4.0 tree is committed as `4e9e275` ("feat: migrate codebase-health
plugin into the suite (v1.4.0)", merged via PR #7, `707cc3e`) in
zero-trust-verification. At eval time the same content sat uncommitted on
`codebase-health-suite` HEAD `5a3463a` — `4e9e275` is the pin. The post-eval
fixture registrations documented below entered the answer key AFTER this eval
(separate commit); the next blind eval scores them fresh.

**Recall 20/20.** All 17 agent-scored plants hit — TF2, TF6, TF8, TQ1, TQ4,
TQ5, TQ8, LG3, LG4 (partial — see OB4), SEC3, TX1, TX2, TX3, J5, JC1, JC2,
MN1 — plus all 3 corroboration lenses (J3 dark-money DARK/HIGH with exact
slug, J4 DARK + MED absence cap, ND1 extract-vs-fork). Severity calibration
was strong: TX1 CRITICAL with the named deliverer and N8 contrast, TQ1 at the
HIGH-gate exemplar, J5 at exactly MED/log-only-refund, JC2 held at the MED cap
by journey-walker (perf #2 over-graded it HIGH — the one calibration
deviation, scored against JW4).

**Precision: 0 violations** across N1–N11 plus the X1/N2 extensions — every
trap was either explicitly held back (N4 poller, N5 test_transform, N6
print-as-product, N7 HUD console, N8 idempotent-by-construction, N9 OBSERVED,
N2 marker bait) or correctly graded (N1 DANGER via dynamic dispatch, N10 LOW
off-journey). Three letter-vs-spirit borderlines logged, none counted: N10's
off-journey lens naming, and security #14/#15 sitting adjacent to N9/N8's
spirit. Expected noise: EN1, EN2, EN4 fired exactly as registered (scored as
neither recall nor precision); EN3 came back cleaner than registered — no
event to score. Deterministic layer 8/8 upstream (`counts.env`), artifact
spot-checks fully consistent, every trap exclusion holding.

Two rows do not round up despite the clean totals — a miss stays a miss:
**OB4 is PARTIAL** (LG4 hit at the MED cap via security #9, but the
`<module>` scope, the correlation/request-id half, and the needs-verification
mark were all missing) and **JW4 is PARTIAL** (perf #2 graded JC2 HIGH against
the MED cap; the owning journey-walker lens held MED). **TH4's blind half and
NV3's lens were not exercised** (audit-only eval; no test runners provisioned)
and stay Pending blind eval.

Miss-to-fixture notes (each planted red-first / prompt-fixed before its gap is
called closed):

1. LG4 residual — journey/security prompts gain "request-serving module
   absence checks include correlation ids" plus the `<module>`-scoped filing;
   needs-verification-mark discipline re-asserted (security #9 said
   "confirmed").
2. JC2 cap — performance-analyzer prompt must require the ATTACHED metric
   line, not just quoted structural redundancy, before granting the
   path-complexity HIGH.
3. JC1 double-ownership — the orchestrator dedup rule gains one unambiguous
   owner for convoluted-CORE-step findings (journey-walker #10 and perf #1
   each claimed it, citing the precedence chain in opposite directions).
4. Stripper — `make_blind_corpus.sh` must strip whole annotation BLOCKS.
   Single-line stripping broke registry.py/config.py/markers.py/auth.py
   (SEC1's MD5 substrate is absent from the blind corpus — unscoreable, not a
   miss; the unimportable-package findings are stripper artifacts, scored as
   neither plants, traps, extras, nor failures) and leaked grading prose into
   1.3.0-plant files. Grep-verified: zero leaks in the 17 scored 1.4.0 lanes,
   so this eval's recall/precision stands; 1.3.0-era items (B1, B2, C1, D2,
   G4, N1, SEC2) were hint-assisted this run, and same-line A/G plants remain
   unscoreable blind (marker_count=0 is expected, not a 1.4.0 regression).
5. Environment — provision pytest/jest/node before the next eval: zero bounded
   probes ran in the test-health lane (TF2's shuffled-order probe, TF7's
   rerun check, and the T3/T4 probes were all trace-only, honestly declared),
   so probe-gated evidence grades went unexercised — also why TH4 stays
   Pending.
6. Taxonomy/trap hygiene for 1.4.1 — rename the off-journey C901 lens to plain
   "hygiene/path-complexity" so N10's letter can't be tripped by a correct LOW
   grade; extend N8/N9 or register the adjacent findings (charge_card
   idempotency key, webhook signature verification) as fixtures.

Extras feeding the miss-to-fixture pipeline, roughly in value order:
open_session authn bypass (service.py:18-25, never calls validate_api_key);
transfer_funds non-atomic debit/credit (billing.py:37-47); refund_payment
missing charge_id dedup (billing.py:59-63); IDOR in get_order_status
(service.py:28-34); unbounded `_SESSIONS`/`_FULFILLED` growth
(service.py:14-15) plus the non-durable `_PROCESSED_EVENTS` dedup store;
report_cli hardcoded `_ROWS` with ignored `--window` (extend N6 or plant);
ui.py's genuinely-empty side-effect bodies (extend N2 or plant); the conftest
frozen_clock monkeypatch-target question (QA the N3 remedies file); TF5's
module-level `import requests` breaking collection of its whole file.
Unregistered dead-module chatter (dead-code #3/#4/#6/#7/#9 on ui.py, slow.py,
metrics.py, poller.py, widgets.ts — all CAUTION, all factually correct in the
stripped corpus) is a candidate EN5 entry for 1.4.1 rather than
must_not_flag.

Per pre-flight fix E, this eval recurs before any future release in which
agent prompts, the taxonomy, or any reference a dispatched agent consumes
changed since the last recorded eval — the 17 agent-scored expected entries
(TF2/TF6/TF8, TQ1/TQ4/TQ5/TQ8, LG3/LG4, SEC3, TX1–TX3, J5, JC1–JC2, MN1), the
agent-level must_not_flag traps, and the EN1–EN4 noise exclusions are scored
nowhere else.

### Post-eval registrations (2026-07-04, entered AFTER the recorded eval)

Miss-to-fixture follow-through on the extras list above (this register's
2026-07-04 blind-eval record): the corpus-registration half is done. Every
item below entered `test-fixtures/EXPECTED_FINDINGS.yaml` AFTER the eval was
scored — the recall/precision totals above stand against the pre-registration
key, and the next blind eval scores these entries fresh (first-run recall,
never regression). Each new entry's note carries the provenance line
"Registered post-1.4.0-eval, found by blind eval."

- Registered `expected` (all `expected_by: agent` — no deterministic layer
  scores any of them): **SEC4** open_session authn bypass (`security/authn`,
  never calls validate_api_key), **SEC5** get_order_status IDOR
  (`security/authz`), **TX4** transfer_funds non-atomic debit/credit (slug
  missing-compensation; distinct defect from J3 on the same symbol), **TX5**
  refund_payment missing charge_id dedup (slug missing-dedup-guard), **TX6**
  non-durable/unbounded `_PROCESSED_EVENTS` dedup store (symbol `<module>`,
  slug non-durable-dedup-store, MED needs-verification), **TX7** charge_card
  keyless charge (slug missing-idempotency-key, MED needs-verification — the
  eval's borderline security finding 14), **B4** report_cli fake windowed
  report (hardcoded `_ROWS`, parsed-but-ignored `--window`;
  `incomplete-logic/B`), **P2** unbounded `_SESSIONS`/`_FULFILLED` growth
  (`performance/resource-growth`, symbol `<module>`).
- Folded, not registered: TF5's entry gains the module-level
  `import requests` collection-breakage facet (same plant, one defect —
  blast-radius evidence, not a second finding).
- Trap-scope note extensions (letters narrowed to their intent; no ID retired,
  every trap still scores): N8 → guard LOGIC only (store durability is TX6,
  signature chatter is EN5); N9 → journey/uninstrumented lens only (keyless
  charge is TX7); N6 → Category-LOG only (fake report is B4); N2 →
  deterministic artifacts only (empty side-effect bodies are EN6).
- New `expected_noise`: **EN5** webhook signature/authenticity absence on both
  billing webhook handlers (transport boundary out of frame — defensible,
  unscoreable), **EN6** ui.py genuinely-empty side-effect bodies (factually
  correct chatter in the blind corpus). The extras list's dead-module-chatter
  candidate (formerly floated as "EN5") remains unregistered and would take
  EN7.
- N3 QA closed with a fixture fix: frozen_clock's dotted-string monkeypatch
  target resolved to a namespace-package shadow of the running test module
  under pytest's default prepend import mode (verified by direct import
  probe; `raising=False` kept the miss silent, so the clock never froze).
  `tests/conftest.py` now patches via `sys.modules`; N3's precision contract
  is unchanged.
- `scripts/self_test.sh` gains §13, LOCK assertions only — already-green pins
  of the new entries' seed halves and fixture substrate (charge_card def-site
  in `vital_candidates.txt`, the module-level stores, the hardcoded `_ROWS` +
  `--window`, the module-level import, the sys.modules patch). No new
  detector assertions: every new entry is agent-scored, per the honesty
  clause. Self-test 131 → 141 green (the frozen 131 unchanged).
- Placement fix (2026-07-04 adversarial verification of this registration):
  TX7's original fixture annotation named its slug, whose token is itself a
  `TX_GUARD_RE` alternate — two PLANT comment lines leaked into the
  `tx_guards.txt` seed artifact (counts.env was untouched; seeds are never
  counted). Fixed by rewording the billing.py annotation (the slug now lives
  only in the manifest, per the TX1 "Slugs in the manifest" precedent), the
  constraint is recorded in TX7's manifest note (the N3 pytest-rerunfailures
  precedent), and §13 gains one already-green pin: no PLANT comment line in
  `tx_guards.txt`. Known pre-existing (pre-eval, unchanged): N8's
  "CORRECT idempotency guard" comment line was already listed in
  `tx_guards.txt` at the recorded eval and stays as-is — the eval's artifact
  spot-checks scored against it.
- Blind corpus regenerated via `make_blind_corpus.sh`; zero residue from the
  new PLANT/MUST-NOT-FLAG annotations verified by token grep over
  `test-fixtures/blind/`.

### Eval-currency note (2026-07-04, appended after the debt-closure pass)

The recorded 2026-07-04 blind eval PREDATES this session's debt-closure
changes: the miss-to-fixture corpus rework (note 4 — planted annotations moved
to whole-line strippable comments across
registry.py/config.py/markers.py/auth.py/storage.py/transform.py/slow.py/
web/app.ts + README, so the blind copy now compiles 27/27 with zero token
residue and blind counts equal planted counts — including `marker_count=7`
where the recorded eval saw the documented stripper-artifact 0) and the
JW4/OB4 prompt/reference edits (notes 1–3 — journey-walker sole-filer
ownership of `journey/path-complexity` with performance-analyzer demoted to
contribute-metrics-and-corroborate; Category LOG absence-bullet facet naming,
narrowest-honest-scope filing, and the needs-verification mark;
security-auditor and incomplete-logic-detector converted to citations of the
canonical bullets). These changes touch fixtures AND agent prompts, so per the
pre-flight fix E recurrence clause above the recorded eval does not certify
the current tree: every blind-half status above reading "Verified (2026-07-04
eval)" is verified against the PRE-change prompts and corpus, and the register
claims no currency beyond that. A fresh blind eval is queued this session and
is required before any release. Exception already exercised post-change:
TH4's blind half (the `/tmp/th4_exercise` scratch loop recorded in its row,
which supersedes the earlier "stays Pending blind eval" sentence in the
closure-status paragraph — that sentence is retained above per append-only
discipline, not because it is current).
