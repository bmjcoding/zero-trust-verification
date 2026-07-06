# System-Design Coverage Assessment — 2026-07-04

> Provenance: produced by a 26-agent adversarially-verified coverage map of the
> 1.4.0 audit surface against 41 system-design principles (5 cluster mappers →
> per-claim refuters → synthesis). Commissioned by Bailey to answer: beyond
> idempotency and observability, what does the audit workflow watch for?
> Status: assessment only — nothing below is implemented. Candidate input to a
> 1.5.0 spec.

# System-Design Coverage Assessment — codebase-health suite (post-adversarial, final)

Scope: 41 mapped system-design principles, adversarially corrected 2026-07-04. Domain frame: a regulated payments platform — money movement, regulatory exposure. Corrections applied verbatim: 6 of 7 "covered" verdicts downgraded to partial (all for the same root cause: mandate-without-fixture fails the suite's own closed-loop standard), 2 "absent" upgraded to partial (least privilege via bandit B103/B104 + the IDOR bullet; timeout budgets via bandit B113), 5 "absent" upheld. Input note: the MAPPED entry for event-schema evolution and the CORRECTIONS entry for circuit breakers arrived truncated, but both statuses (absent; upheld-absent) were extractable before the cut and are used as-is.

---

## 1. Corrected coverage matrix

### COVERED — 1 of 41

| Principle | Basis | Flag |
|---|---|---|
| Pagination / unbounded queries | performance-analyzer.md:12-14 mandated checklist ("missing batching/pagination, queries inside loops") + taxonomy Category D pagination clause | No refuter targeted it, so it stays covered per instructions — but it has no fixture and no seed, the identical profile that downgraded the other six. Treat as covered-on-notice; the PG1 fixture in Pack 1 below makes it honest. |

### PARTIAL — 29 of 41

| Principle | What exists / what's missing (one line) | Δ |
|---|---|---|
| TOCTOU / check-then-act | TX `double-submit-window` slug + security-auditor bullet cover the money-submission slice only; general filesystem/auth check-then-use absent, no TX fixture plants the window | — |
| Shared mutable state | Test-scope only (T2, TF2/TF6 fixtures); zero production-code mandate | — |
| Missing locks / atomicity | TX catches submission-path atomicity; no mandate for non-atomic read-modify-write generally | — |
| Transaction isolation levels | Only the double-submit neighbor; zero isolation/row-locking vocabulary anywhere | — |
| Unjoined concurrency | Test-scope full (T6/TF6); production side is one half-async table row, not a mandate | — |
| Connection / file-handle leaks | Real checklist mandate (performance-analyzer.md:19) but zero fixture, zero seed, no per-checklist ledger; MED-capped by the measurement gate whose sanctioned probes can't measure leaks | ↓ from covered |
| Unbounded memory growth | Mandate real (:16, :19); GAPS_SPEC:294 already queues the `_SESSIONS`/`_FULFILLED` extra for miss-to-fixture; structurally MED-capped | ↓ from covered |
| Resource exhaustion | Leak/growth-driven symptoms only; no adversarial/DoS bullet in security-auditor | — |
| Input validation at trust boundaries | Line-20 mandate is real but fixture-orphaned; B1/Category B citations belong to the AuthN/AuthZ bullet, not this one; deleting line 20 turns nothing red | ↓ from covered |
| Per-object authz / IDOR | Line-13 mandate real; IDOR substrate exists (get_order_status) and an agent found it in the 2026-07-04 eval — but only as an unregistered extra; zero scored fixtures | ↓ from covered |
| Secrets management | Hardcoded creds fully closed-loop (gitleaks + SEC2); rotation absent | — |
| Least privilege | bandit B103/B104 land deterministically in mandated reading, and the IDOR/ownership bullet is horizontal-privilege review; entitlement-breadth (grants, IAM, root) never named, zero fixtures | ↑ from absent |
| Injection classes | Mandate at both layers + CRITICAL exemplar; but bandit/semgrep are install-conditional, no injection-shaped code exists anywhere in the fixture tree, self_test asserts nothing | ↓ from covered |
| SSRF / unsafe deserialization | Lines 17-18 real mandates; two of four citations were passing mentions; zero plants, zero seeds, recall never measured | ↓ from covered |
| Backpressure | "Unbounded buffers" catches the symptom; producer/consumer rate mismatch never framed | — |
| Timeout budgets | bandit B113 (request_without_timeout) deterministically reaches security-auditor's mandated reading on Python+bandit installs; no checklist item to survive triage into, no fixture, no non-Python coverage, no deadline propagation | ↑ from absent |
| Retry policies (jitter/backoff) | TX unsafe-retry + tx_retries.txt seed exist; policy quality (no backoff/cap/jitter) never asked; N4 anchors only the correct-pattern side | — |
| Graceful degradation | Fail-open half mandated (security-auditor :15, Category B/LOG); designed-fallback half absent; the pervasive "degrade" vocabulary is all self-referential | — |
| Queue overflow behavior | Unbounded-buffer symptom + consumer idempotency covered; depth bounds/full-queue policy never asked | — |
| Schema standardization / naming | Misleading-name anchored (MN1 fixture); cross-surface naming-drift standardization absent | — |
| Nullable/optional discipline | Category D catches per-function None handling; schema/DTO-level null discipline absent | — |
| Timezone/date handling | Test-nondeterminism fully closed-loop (T4/TF4, FLAKY_RE); production date correctness explicitly gated OUT by TEST_PATH_RE | — |
| Data retention / PII lifecycle | PII-in-logs covered (CWE-532); retention/erasure-path absence never audited | — |
| Referential integrity | Dies-between-steps + missing-compensation cover walked vital steps only; FK/orphan/cascade never hunted | — |
| Cache correctness / invalidation | Suite hunts the inverse (missing caches); staleness/invalidation never asked; test-bleed slice only (TF2) | — |
| Partial-failure between services | Crash/compensation half solidly mandated (TX3 fixture); resilience half (timeouts, fallback, cascade) absent | — |
| API versioning / back-compat | Deprecation-cycle discipline + docs-drift diff exist; wire/endpoint versioning never checked | — |
| N+1 at service-call level | DB-vocabulary N+1 mandated; remote HTTP/RPC/SDK calls in loops never named | — |
| Multi-tenancy isolation | IDOR bullet covers the per-object slice at the wrong altitude; tenant-scoping-by-construction, tenant-unscoped caches/queues absent | — |

### ABSENT — 11 of 41

| Principle | Refuter disposition |
|---|---|
| Deadlock | Upheld; only literal repo hit is a dispatch metaphor (SPEC_1.4.0.md:249); all adjacent concurrency coverage targets races/stalls, never acquisition order |
| Single-point-of-failure security controls | Upheld; every "single/sole" mandate in the suite is about tests or over-abstraction, and the only structural single-X test is the inverse concern |
| Rate limiting | Upheld (with evidence correction: zero hits even in CHANGELOG); closed slug registry has no abuse category to even file it under |
| Circuit breakers | Upheld; TX_RETRY_RE seeds the right call sites but the attached question is idempotency-only; N4 blesses correct backoff with no positive counterpart |
| Bulkheads | Uncorrected; no failure-domain-isolation mandate anywhere |
| Load shedding | Uncorrected; nothing on behavior at saturation |
| Thundering herd | Uncorrected; only jitter mention is the N4 precision trap |
| Money-as-float / precision | Uncorrected; money paths are first-class everywhere and the numeric type is asked nowhere — the sharpest single gap in the matrix |
| Schema-evolution / migration safety | Uncorrected; migrations modeled exclusively as excluded/untouchable, never as audit subject |
| Ordering / clock-skew | Uncorrected; TX asks "arrives twice?" and "dies between steps?", never "arrives out of order?" |
| Event-schema evolution | Uncorrected; the suite practices the discipline internally (schema_version pinning) and never audits target code for it |

**Meta-finding the corrections force:** the suite's real coverage boundary is not the checklist text — it is EXPECTED_FINDINGS.yaml. Every downgrade had the same shape: prompt-text mandate, zero fixtures, zero seeds, invisible-if-deleted. Any new pack that adds mandates without Wave-0 fixtures reproduces the defect the refuters just spent a pass exposing.

---

## 2. Ranked gap packs (domain risk × machinery fit)

Six packs. Rank reflects (payments blast radius) × (how much of the machinery already exists). Riders — one-line widenings too small for a pack — are assigned to the pack that already touches their file.

### Pack 1 — Enforcement-debt repayment (rank 1: max fit, zero new mandates, the classes are payments's worst)
Not new coverage — closing the mandate/fixture gap for everything already instructed. This is the pack the adversarial pass itself specified: 8 of its 12 verdicts are exactly this defect, and GAPS_SPEC's extras list already queues four of the plants under the miss-to-fixture rule.

| Gap | Home (all existing mandates — fixture layer only) | Deterministic vs judgment |
|---|---|---|
| Injection | Plant f-string SQL in planted_pkg; EXPECTED_FINDINGS INJ1; self_test asserts the bandit/semgrep path when tools present | Seed honest (bandit B608/semgrep); agent corroborates |
| IDOR | Register the already-found get_order_status extra (GAPS_SPEC:293) as fixture AZ1 per miss-to-fixture | Agent-scored (ownership is semantic); no honest grep |
| SSRF + deserialization | requests.get(user_url) and pickle.loads plants; SSRF1/DES1 | Deser seed honest (bandit B301/B506); SSRF agent-scored |
| Input validation (line 20) | Unvalidated raw-dict webhook/handler plant, IV1 — distinct from B1's fake-validator | Agent-scored; no honest validation grep |
| Connection/file-handle leaks | open()/connect() without with/close plant, PL1 + a leak-shaped seed grep in debt_patterns.sh | Seed honest (medium precision, candidates-not-verdicts) |
| Unbounded memory growth | Register `_SESSIONS`/`_FULFILLED` (already queued, GAPS_SPEC:294) as MEM1; rubric language admitting a counting probe as the HIGH-gate "number" | Substrate exists; agent-scored |
| Pagination | .all()/no-LIMIT plant on a walked journey, PG1 — converts the matrix's last "covered" from on-notice to eval-locked | Agent-scored |
| Rider | must_not_flag negatives per plant (parameterized query, allowlisted fetch, bounded cache) to protect precision | — |

### Pack 2 — Money & data-integrity lens (rank 2: canonical payments defect classes, seams and even regex vocabulary already exist)
Mostly extensions of Categories TX/D/E — no new word-key needed except where noted. Owner agents unchanged.

| Gap | Home | Deterministic vs judgment |
|---|---|---|
| Money-as-float (absent) | TX bullet + security-auditor checklist ("float arithmetic/lossy rounding on a money step") | Seed honest and cheap: float-literal/round() hits ∩ VITAL_RE hits — the highest-value single grep the suite doesn't have |
| Timezone/date in production | Category D row; invert the existing FLAKY_RE gate (same regexes OUTSIDE TEST_PATH_RE → new audit artifact) | Seed honest — vocabulary already written; date-rule/DST reasoning stays agent |
| Referential integrity | Fifth TX critical-step question ("what keeps these rows linked?"), journey-walker + security-auditor | Seed honest-ish (relations declared without FK/cascade clauses); orphan reasoning agent |
| Cache invalidation/staleness | Category E bullet ("populated on read, never invalidated on write") owned by incomplete-logic-detector; cross-ref so perf's add-caching recs must name the invalidation seam | Agent-judgment; no honest grep |
| Nullable/optional discipline | Category D extension (schema/DTO optionality) | Agent-judgment |
| Ordering / clock-skew (absent) | Fifth TX question at webhook/queue steps ("arrives out of order/late?"); out-of-order PSP-webhook plant in billing.py | Agent-scored; trace-only discipline already in place |

### Pack 3 — Concurrency lens (rank 3: highest single-incident severity — double-payment, lost update, cross-borrower bleed; fit strong for the TX-adjacent half, weak for deadlock)

| Gap | Home | Deterministic vs judgment |
|---|---|---|
| TOCTOU (general) + double-submit fixture debt | New security-auditor bullet (CWE-367) + slugs in TX; plant the double-submit-window fixture the taxonomy already mandates | Fixture yes; grep low-precision — agent-owned |
| Missing atomicity | `missing-atomicity` slug on the TX bullet ("name the concurrent writer" generalizes the existing gate); TX-adjacent seed beside TX_GUARD_RE | Seed honest for RMW-on-money candidates |
| Transaction isolation | TX question for journey-walker + seed grep (FOR UPDATE, isolation_level, version columns) | Seed honest as candidates; verdict needs runtime — see §3 cap |
| Shared mutable state (production) | New word-key taxonomy category (Category STATE), owner incomplete-logic-detector; module-level-mutable-global seed in debt_patterns.sh | Seed honest; cross-request reachability agent |
| Unjoined concurrency (production) | Promote the Category D half-async row to a named sub-bullet (fire-and-forget) | Agent-judgment; idiom grep optional, low precision |
| Deadlock (absent) | performance-analyzer Concurrency bullet (shared with security-auditor on money paths); agent-eval-only exemplar, no fixture assertion pretense | Pure agent-judgment — per determinism-first, no grep is honest here |

### Pack 4 — Security-mandate growth (rank 4: regulator-visible classes; fit medium — checklist bullets cheap, but SPOF/tenancy need a journeys.json schema bump)

| Gap | Home | Deterministic vs judgment |
|---|---|---|
| Multi-tenancy isolation | Widen the AuthN/AuthZ bullet from per-object to scoping-by-construction; tenant-key seed beside VITAL_RE; tenant-propagation field on journey-walker's step schema | Seed honest (tenant_id column greps as candidates); scoping verdict agent |
| Least privilege (breadth) | New checklist bullet (over-privileged execution) scoped to in-repo evidence; seeds: GRANT ALL, AdministratorAccess/`"*"`, USER root — written to an audit/ candidates file; register the incidental B103/B104 coverage explicitly in self_test | Seeds honest; breadth judgment agent; see §3 scope caution |
| Secrets rotation | Sub-bullet of the Secrets item with the honest "unknown — rotation lives outside the repo" degrade mirroring alert_seam | Agent-owned; grep low-precision by the mapping's own admission |
| PII lifecycle | Checklist bullet (no erasure path = reportable absence, like DARK vitals) + `pii_touched` facet on the step schema | Agent-scored; absence-gated MED |
| SPOF security controls (absent) | journey-walker records an enforcement-point per walked step (journeys.json schema_version bump + consumer degrade edits); security-auditor flags one symbol solely guarding multiple CORE journeys | Structural cross-path judgment; the enforcement-point FIELD is deterministic, the SPOF verdict is agent |
| Resource exhaustion (adversarial half) | New security-auditor bullet (CWE-400, request-driven fan-out/missing metering) — absence-gated | Agent; see §3 for the rate-limit boundary |

### Pack 5 — Resilience lens (rank 5: real availability risk but the largest honesty exposure — half this pack is only assessable against a declared contract; ship the honest half, defer the rest per §3)

| Gap | Home | Deterministic vs judgment |
|---|---|---|
| Timeout budgets (per-call half) | Register B113 as load-bearing (self_test assertion + fixture TB1 requests-no-timeout); new taxonomy bullet beside TX; journey-walker gains the "hangs forever?" sibling question | Seed honest (B113 + timeout-kwarg grep for non-requests clients); budget decomposition deferred (§3) |
| Retry policy quality | TX extension: no-backoff/no-cap/no-jitter/retry-on-non-retryable slugs; tx_retries.txt already harvests the sites; N4 anchors precision | Seed honest (jitter/backoff-absence over tx_retries.txt); retryability judgment agent |
| Queue overflow | performance-analyzer buffer row + taxonomy queue-consumer policy question; Queue()-without-maxsize seed | Seed honest; drop-policy semantics agent |
| Backpressure (rider) | Extend the unbounded-buffers row into an explicit flow-control item | Measurable per the existing measure-before-HIGH discipline |
| Graceful degradation (fallback half) | journey-walker per-step "dependency errors → then what?" note, absence-gated MED | Agent, trace-only |
| Circuit breakers / bulkheads / load shedding / thundering herd (absent) | Only the honest slivers ship now: jitterless-fan-out inspection over tx_retries.txt (herd), shared-pool seam notes at architecture-reviewer strength labels (bulkhead, "Worth exploring" ceiling). Breaker/shed verdicts deferred to the manifest (§3) | Herd-jitter seed honest; everything else agent-or-deferred |
| N+1 service-call (rider) | One-line widening of the Data-access row ("queries OR remote calls in loops") + per-item-vendor-call plant | Agent; fixture locks it |

### Pack 6 — Contract-evolution pack (rank 6: highest blast-radius-per-event, lowest event frequency; smallest pack)

| Gap | Home | Deterministic vs judgment |
|---|---|---|
| Migration safety (absent) | New trace-only reference (sibling to business-vitals.md), read-never-run per loop-safety invariant 1; seed grep for migration paths + DROP/ALTER/NOT-NULL-add | Seed honest; reversibility/lock-impact judgment agent |
| Event-schema evolution (absent) | New word-key Category EVT (letters frozen at A–G; TX/LOG precedent), owned security-auditor + journey-walker at the webhook/queue seam | Agent; single-repo fixtures can only simulate producer/consumer as two modules — say so in the fixture note |
| API versioning | journey-walker step-5 docs-vs-API diff grows the endpoint/payload check; versionless-route seed beside the vital seeds | Seed honest as candidates; breaking-change semantics agent |
| Schema naming drift (rider) | New navigability anchor beside misleading-name in architecture-and-strictness.md; optional case-convention lint row in cross-language-tooling.md | Lint-tool deterministic where available; drift judgment agent |

---

## 3. What should NOT be added (frank)

A static repo audit cannot honestly assess these, and pretending would recreate — in reverse — the exact mandate-without-enforcement defect the corrections just purged. The suite already has the right degrade idiom (alert_seam: `paged | dashboard-only | unknown`); the answer for each of these is `unknown — lives outside the repo`, or a new Verification Manifest field that turns guessing into declared-vs-found verification. Per CONTEXT.md, the Verification Manifest already carries the journey map with criticality, required vitals, and idempotency requirements; journey-walker already verifies intended-vs-as-built against it; every consumer pins schema_version and degrades when it's absent. That is precisely the pattern these need — and the Config Profile (the payments profile is CONTEXT.md's own example) is where the LOB-specific values live as pure data.

**Do not add as hunted categories (recommend against pretending):**

1. **Rate limiting** — enforcement is at the gateway/WAF/mesh in an enterprise-shaped estate; an in-repo "missing rate limit" finding is unfalsifiable and will be wrong often enough to burn precision credibility. *Assessable via:* manifest per-journey `abuse_controls` field declaring the throttle locus (gateway | app | none-declared); the audit then verifies "app" claims and reports "gateway" as out-of-scope-by-declaration.
2. **Circuit breakers / load shedding / bulkheads** — resilience posture lives in sidecars, mesh config, k8s limits, pool config in env. Code-side absence is a MED-capped shrug at best. *Assessable via:* manifest per-external-dependency `resilience_posture` (breaker | fail-fast | none-declared) and per-journey shed-priority derived from the criticality ladder the manifest already carries; journey-walker grades declared-vs-found exactly like OBSERVED/LOG-ONLY/DARK.
3. **Transaction isolation verdicts** — the seed grep (Pack 3) honestly surfaces explicit-locking candidates, but actual isolation is a DB/session config the repo may never mention. Ship the question, hard-cap the finding, mandate the `unknown — isolation configured outside repo` degrade. *Assessable via:* manifest per-money-write `isolation_requirement` next to the existing idempotency requirements — the natural extension of a field family that already exists.
4. **Key rotation** — policy lives in Vault/KMS/ops calendars. The checklist sub-bullet (Pack 4) must carry the honest degrade; never grade rotation compliance from code. *Assessable via:* Config Profile credential inventory with declared `rotation_seam` per credential class.
5. **Least-privilege breadth beyond the repo** — IAM/Terraform typically live elsewhere; the in-repo seeds (Dockerfile root, GRANT ALL in checked-in DDL) are honest, but the mandate must state it is not an access review and never imply audit-grade entitlement coverage.
6. **HIGH-severity leak/growth grading** — the measurement gate is correct and statically unsatisfiable; keep the MED cap. *Assessable via:* the manifest's required-vitals — a declared counting vital on the suspect structure gives the runtime number the HIGH gate demands, closing the loop through observability rather than pretense.
7. **Timeout budget decomposition** — per-call timeouts are greppable (Pack 5); whether budgets compose across hops needs topology. *Assessable via:* per-step `timeout_budget_ms` on the manifest journey map; the walker then checks each step's configured timeout against the declared budget.
8. **Thundering herd as a category** — stampedes are emergent multi-instance behavior under real traffic. Ship only the jitter-absence inspection (honest); do not grade stampede risk.
9. **Deadlock as anything deterministic** — keep it pure agent-judgment (Pack 3); a Lock/acquire regex would be precision-hostile and violate the determinism-first rule's own "only where honest" clause.

Every field proposed above rides the existing contract mechanics: schema_version-pinned, graceful absence degrade, produced by the Spec Generation tier, verified — never authored — by the Audit. When the manifest is absent, these concerns report as `unknown`, which is the truthful answer today.

---

## 4. Sizing (1.4.0-style: fixtures-first Wave 0 red on two runs, scripts Wave 1, references Wave 2, agents Wave 3, commands/SKILL Wave 4, release checklist Wave 5, blind-eval recurrence Wave 6)

| Pack | Active waves | Fixtures (expected + traps) | Seeds/regexes | References touched | Agents touched | Notes |
|---|---|---|---|---|---|---|
| 1 Enforcement debt | 0, 5, 6 (+ thin 1 for the leak seed) — **~3–4 waves** | ~9 expected + ~4 must_not_flag | 1 | 0 | 0 | No mandate changes at all; four plants are pre-queued in GAPS_SPEC extras; cheapest recall-per-wave in the roadmap |
| 2 Data-integrity | 0–6 — **7 waves** | ~7 + 2 traps (Decimal-correct, tz-aware-correct) | 3 (float∩VITAL, FLAKY_RE-inverted, FK-less relations) | taxonomy (D/E/TX), business-vitals | incomplete-logic-detector, security-auditor, journey-walker | Vocabulary reuse keeps Wave 1 small |
| 3 Concurrency | 0–6 — **7 waves** | ~6 + 2 traps (correct locking, joined task) | 2–3 (mutable globals, isolation vocab, TX-adjacent RMW) | taxonomy (TX + new STATE), severity-rubric | security-auditor, incomplete-logic-detector, performance-analyzer, journey-walker | Deadlock is agent-eval-only — honesty clause applies, scored solely in Wave 6 |
| 4 Security growth | 0–6 — **7 waves** | ~7 + 2 traps | 2–3 (tenant keys, privilege patterns) | severity-rubric absence gate, journey-trace (schema bump), business-vitals | security-auditor, journey-walker + all trace consumers' degrade edits | journeys.json schema_version bump (enforcement_point, pii_touched, tenant propagation) is the cost center — every consumer's degrade rule gets edited, 1.4.0 collision-register discipline required |
| 5 Resilience | 0–6 — **7 waves** | ~6 + 3 traps (N4 pattern extended: bounded queue, breaker-present, capped retry) | 3 (B113 registration, Queue-maxsize, jitter-absence over tx_retries.txt) | taxonomy (new RES), business-vitals question ladder, severity-rubric | performance-analyzer, journey-walker, security-auditor, test-health boundary note | Ship only the §3-honest half; breaker/shed/bulkhead grading blocked on manifest fields |
| 6 Contract evolution | 0–6 — **7 waves, lightest** | ~4 + 1 trap (additive-migration correct) | 2 (migration DDL, versionless routes) | NEW migration-safety reference, taxonomy (new EVT), architecture-and-strictness anchor | security-auditor, journey-walker, architecture-reviewer | Producer/consumer fixtures are single-repo simulations — state the limitation in the fixture note |

**Aggregates:** ~39 new expected + ~14 trap/negative entries (EXPECTED_FINDINGS 39 → ~78 expected); self_test ~113 → ~185–195 assertions (+~12–15/pack, Pack 1 heaviest per-fixture, Pack 6 lightest); agent-scored manual-eval list grows from 17 to roughly 35 — which doubles Wave-6 hand-scoring cost and is the binding constraint.

**Release-train recommendation:** because the blind-eval recurrence is a hard per-release checklist item and its cost scales with the agent-scored list, do not ship six release cycles. Three trains: **1.5.0** = Packs 1+2+3 (repay the enforcement debt in the same eval that scores the new money/concurrency lenses — one Wave 6 covers all three); **1.6.0** = Packs 4+5 (bundled because both bump/extend the journeys.json step schema — one schema_version change, one consumer-degrade sweep, one collision register); **1.7.0** = Pack 6 + the manifest-integration fields from §3 (timeout budgets, resilience posture, isolation requirements, abuse controls, retention classes), landing alongside whatever Spec-Generation-tier release starts emitting them.

Key artifacts: /Users/bailey/Developer/zero-trust-verification/CONTEXT.md (Verification Manifest / Config Profile / Vital definitions grounding §3); /Users/bailey/Developer/zero-trust-verification/docs/specs/codebase-health-spec-1.4.0.md (wave template, word-key freeze, honesty clause, determinism sweep precedent); /Users/bailey/Developer/zero-trust-verification/docs/specs/codebase-health-gaps-spec.md:290-310 (miss-to-fixture extras pre-queuing four Pack-1 plants; the 17 agent-scored entries defining Wave-6 cost); /Users/bailey/Developer/zero-trust-verification/tests/codebase-health/test-fixtures/EXPECTED_FINDINGS.yaml (the enforcement boundary every pack must land in at Wave 0).