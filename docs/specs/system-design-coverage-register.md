# System-Design Coverage Tier — Change Register (Declare-then-Verify, SD-01..SD-12)

> Shipped posture (Bailey 2026-07-06): report-only/advisory first — declare-then-verify findings
> report; only a `locus: app` + deterministic-in-join + present-declaration finding is ever
> gate-eligible, and even then ships comment-only through the soak.
> Governing: ADR 0021 (manifest control locus — honest silence about the gateway/mesh), ADR 0022
> (out-of-scope-by-declaration report class, never blocks), plus ADR 0003/0004/0006/0008/0002.
> Defaulted human questions (async-promotable, SD-AMEND): (A) all in-repo-assessable SD principles are
> in scope by default; the Config Profile narrows per LOB. (B) locus declaration is optional-with-degrade
> — making it completeness-gating for CORE money/auth is a per-repo promote-later risk call, not applied.
> Status: IMPLEMENTED 2026-07-07 (branch feat/system-design-coverage; SD-01..SD-12). The [det] half lands as
> schema fields + validator fixtures (SD-01/02), the four declare-then-verify §12 rows on the CH-03 join engine
> manifest_join.py (SD-03..10), the sd_seeds.sh in-repo candidate seeds (SD-09/11), and lint V12 + scripts/
> sd_self_test.sh (SD-12). Every [audit-run] item (declared/discovered VALUE quality, shed-priority, breadth,
> deadlock) stays comment-only, blind-eval scored — never automated coverage. Suite green ZERO-skip on bash 3.2.57.
> Prior status — DRAFT r1 (hardened from an empty stub against the governing sources; adversarial pass applied across HONESTY / FEASIBILITY / [det]-[drain] / CONTRADICTION / ESCALATION).
> Style: GAPS_SPEC register.
> Acceptance tags (honest about their home, per the 1.4.0 convention):
>   `[det]` = hermetic self_test.sh / lint assertion — grep / fixture / golden-JSON / exit-code provable, no network, NO agent judgment. Legal ONLY over a mechanical claim (field presence, exact match, join-lattice truth table, exit code). NEVER over a criticality/locus/priority VALUE or any recall/relevance claim.
>   `[audit-run]` = measured only in real audit / PR-Gate runs + the manual blind-corpus eval (the 1.4.0 honest-residual convention). Every agent-DERIVED value and every declared-value-quality claim lives here, never presented as automated coverage.
> Sources: verification-manifest-v1.md (§4 journey/step schema, §10 completeness rules, §11 degrade table, §12 the join); ADR 0003 (PR-Gate placement), ADR 0004 (ratcheted blocking + the agent-opinion-never-blocks invariant), ADR 0006 (profiles are data, name-only in the manifest), ADR 0008 (straight-through drains), ADR 0002 (escalation criterion). Reuses codebase-health CH-01 ingestion and the CH-03 §12 comparator (not re-implemented).
> Baseline: codebase-health v1.4.0 + the CH-01..CH-10 manifest-integration deltas (this register CONSUMES CH-01 ingestion and CH-03's §12 comparator; it is the 1.7.0-train work the CH register's non-goals defer to it). Nothing here is greenfield and nothing re-implements a detector.

## 0. Position and posture (read first — this is the honesty spine)

The System-Design Coverage tier answers the SD assessment's central finding: a static in-repo audit CANNOT honestly assess controls that live at the gateway / WAF / service mesh / sidecar / k8s / IAM. The SD doc §3 already names nine such classes and the correct mechanism for each: **declare-then-verify**. This register makes that mechanism the tier's law, not a per-item footnote.

**The unfalsifiability rule (SD-00, governs every item below):** For any principle that is not fully in-repo-assessable, the tier NEVER emits a raw "missing X" finding. Instead:
1. The manifest DECLARES a `locus` for the control (the spec tier authors it; ADR 0006 profile supplies the vocabulary).
2. The audit VERIFIES only `locus: app` declarations — the one locus whose evidence is in the repo.
3. Every other locus (`gateway | mesh | sidecar | none-declared`) is reported as **out-of-scope-by-declaration** — an informational line in the report's coverage section, NEVER a violation, NEVER a blocking-class finding, NEVER counted against the target.
4. When the manifest is absent, the whole class reports `unknown — lives outside the repo, no declaration to verify` (MS §11 degrade; the truthful answer today).

A raw in-repo "missing rate limit" / "no circuit breaker" / "unbounded entitlement" finding is precision-hostile and wrong often enough to burn the suite's credibility (SD §3.1). Any SD item that mints one is a defect this register exists to prevent — the same shape as codebase-health's mandate-without-fixture defect, in reverse.

**Reuse, not parallel infra (ADR 0003 / feasibility law):** This tier is NOT a fourth checker and adds no second join engine. It EXTENDS the CH-03 §12 comparator with new declared↔discovered rows and composes into the PR Gate through the existing `run_sibling` + `[ -x ]` + `[not-covered]` pattern (CH-04). One comparator, one manifest reader (CH-01), one degrade table (MS §11). Every new manifest field is an **additive optional** under `schema_version: 1` — consumers ignore-unknown (MS §8), an absent field is never a schema break, and ADR 0008 straight-through drains are preserved (the fields are not completeness-gating unless a flagged amendment makes one mandatory — see Escalations).

**The [det]/[drain] law (ADR 0004 invariant, MT-06 precedent):** For every SD item the JOIN (declared value vs discovered value, by the §12 lattice) is deterministic and `[det]`. The declared VALUE itself (which locus, which criticality, which shed-priority) is authored by the spec tier or derived by an agent — it is NEVER `[det]`. Therefore every finding CAPS AT COMMENT-ONLY whenever the declaration is absent, `none-declared`, degraded, or the discovered-side trace (journeys.json) is missing — exactly as MT-06 caps the CORE-survivor class. Agent judgment is never laundered as deterministic coverage.

## Dependencies and landing order

Consumes CH-01 (manifest ingestion + MODE token) and CH-03 (the §12 comparator + fingerprint scheme) — both `[det]`-live in the monorepo (the spec-gen `validate_manifest.sh` + vendored schema + join fixtures have landed). SD-01 (manifest field family) is authored by the SPEC-GEN drain (one-writer rule, MS §7) and vendored; every SD audit item CONSUMES it. Order:

**SD-01 (declared field family, spec-gen-authored) → SD-02 (schema + validator, additive) → SD-03 (locus reporting class) → SD-04 (comparator rows, extends CH-03) → SD-05..SD-10 (per-class declare-then-verify) → SD-11 (in-repo honest-seed half) → SD-12 (self-test + lint).**

## A. The contract: declared field family (SD-01/SD-02/SD-03)

### SD-01 — Declared `locus` field family on the manifest [MS §4, ADR 0006; spec-gen-authored, this tier CONSUMES]
The manifest gains a small, additive family of per-scope declarations, each carrying an explicit `locus` enum. All OPTIONAL under schema_version 1 (ignore-unknown for old consumers; absent = the `unknown` degrade). The spec tier authors them; ADR 0006's profile supplies the enum vocabulary and which classes matter for the LOB. Fields (per the SD §3 mapping, verbatim loci):
- Per-journey `abuse_controls: {locus: gateway|app|mesh|none-declared, note}` (SD §3.1 rate limiting).
- Per-external-dependency `resilience_posture: {locus: sidecar|mesh|app|none-declared, mechanism: breaker|fail-fast|bulkhead|shed|none-declared}` (SD §3.2 breakers/shed/bulkheads).
- Per-money-write `isolation_requirement: {locus: app|db-config|none-declared, level}` next to the existing `idempotency` family (SD §3.3 — the natural extension of a field family that already exists in §4).
- Config-Profile credential inventory with `rotation_seam: {locus: vault|kms|ops|app|none-declared}` per credential class (SD §3.4 — profile data, not a manifest field this tier vendors).
- Per-step `timeout_budget_ms` on the journey map (SD §3.7 — the walker checks each configured timeout against the declared budget).
- Per-journey shed-priority DERIVED from the existing criticality ladder (SD §3.2 — no new authored field; the ladder already carries it).
**HONESTY (attack 1):** every one of these declares a locus so the audit can be silent about elsewhere-loci. NONE licenses a raw "missing X" finding.
**Acceptance:** `[det]` the schema fixtures parse each field present/absent/`none-declared`; an old (field-unaware) consumer fixture ignores them (schema_version-1 additive proof). `[audit-run]` NONE — this item authors nothing here; it is the vendored contract SD-04..SD-10 read.

### SD-02 — Schema + validator: additive-only, absence-safe [MS §2/§8/§10]
The SD-01 fields land in `schema/verification-manifest/v1.schema.json` as OPTIONAL (structure only, MS §2). They are NOT completeness rules — an SD-field-free manifest stays `completeness: complete` and drains straight through (ADR 0008), UNLESS a flagged amendment (see Escalations) makes a specific locus declaration mandatory for a CORE money journey. The `none-declared` enum value is first-class and always legal (it IS the honest answer, not an omission).
**Acceptance:** `[det]` validator fixtures: field-absent-complete → exit 0 (straight-through preserved); `none-declared` → exit 0; a bool-in-`locus`-enum → exit 4 (Norway defense, MS §2); the schema copy is byte-identical across plugins (ADR 0001 vendoring lint). `[audit-run]` NONE.

### SD-03 — Out-of-scope-by-declaration reporting class [SD-00, ADR 0004]
A NEW report line class, distinct from both `finding` and `not-covered`: `out-of-scope-by-declaration`. When the comparator sees a non-`app` locus, it emits ONE informational line naming the class, the declared locus, and "verified elsewhere by declaration — not assessed in-repo." It is NEVER a violation, NEVER counted, NEVER blocking (ADR 0004: an agent opinion — here, an in-repo guess about an out-of-repo control — with no deterministic in-repo evidence never blocks). This is the mechanical embodiment of SD-00.
**Acceptance:** `[det]` a fixture manifest with `abuse_controls.locus: gateway` → the report carries exactly one out-of-scope-by-declaration line and ZERO findings for rate limiting; a `locus: app` → the verify path runs (SD-05). `[det]` a red-test: a planted SD item that emits a raw "missing rate limit" finding on a `gateway`-locus (or absent) declaration → self_test FAILS (the unfalsifiability guard — this is the defect the whole tier prevents). `[audit-run]` NONE.

## B. The verifier: comparator rows (SD-04) — REUSES CH-03

### SD-04 — Extend the CH-03 §12 comparator with declared↔discovered rows [CH-03, MS §12; NO parallel join]
This is NOT a new join engine. It adds rows to the CH-03 comparator (`scripts/manifest_join.sh`) and reuses its fingerprint scheme, precedence chain, and dedup. Each new row follows the §12 lattice form (paged←paged style): a declared value on the intent side, a discovered value from journeys.json on the audit side, a satisfaction rule, and the SD-03 out-of-scope short-circuit for non-`app` loci. New rows: `abuse-controls-drift` (app-locus only), `isolation-drift`, `timeout-budget-drift`, `resilience-posture-drift` (app-locus only), each journey- or step-scoped per the CH-03 ⟨CH-AMEND-A⟩ fingerprint form.
**FEASIBILITY (attack 2):** the acceptance below asserts the SAME truth-table shape CH-03 uses; if a future maintainer stands up a second comparator, SD-12's lint catches it (no-parallel-infra guard, MT-10 precedent).
**Acceptance:** `[det]` each new row gets a passing + failing fixture case against a shared manifest+journeys.json v2 pair (reusing tests/fixtures/join/); the out-of-scope short-circuit is asserted per row (non-`app` locus → SD-03 line, not a lattice compare). `[det]` a lint asserts these rows live in `manifest_join.sh`, not a sibling join. `[audit-run]` end-to-end drift quality on a real repo (the discovered-side derivation is agent-graded).

## C. Per-class declare-then-verify (SD-05..SD-10) — each caps at comment-only per MT-06

### SD-05 — Rate limiting → `abuse_controls` [SD §3.1]
Verify ONLY `locus: app` declarations (an app-side limiter is in-repo evidence: a decorator, a token-bucket call on the journey's entry step). `gateway`/`mesh`/`none-declared` → SD-03 out-of-scope line. NEVER a raw "missing rate limit" finding.
**Acceptance:** `[det]` `locus: app` + a discovered limiter on the step → satisfied; `locus: app` + no discovered limiter on a traced step → a finding, COMMENT-ONLY (the discovered side is agent-traced, MT-06 cap); `locus: gateway`/absent → out-of-scope line, ZERO findings. `[audit-run]` limiter-presence detection quality (agent).

### SD-06 — Circuit breakers / load shedding / bulkheads → `resilience_posture` [SD §3.2]
Verify ONLY `locus: app` + `mechanism` claims (an in-repo breaker library call). `sidecar`/`mesh`/`none-declared` → out-of-scope. Shed-priority is DERIVED from criticality (agent) → any shed finding caps at comment-only always (MT-06: criticality is agent-derived). The honest in-repo sliver from SD §2 Pack-5 (jitterless-fan-out inspection over tx_retries.txt for thundering herd) ships here as a `[det]` SEED (candidates, not verdicts) — see SD-11.
**Acceptance:** `[det]` `locus: sidecar` → out-of-scope, zero findings; `locus: app`+`mechanism: breaker` + no discovered breaker → comment-only; the shed-priority path is comment-only regardless of soak state (criticality is agent-derived, MT-06). `[audit-run]` breaker-presence + posture quality (agent).

### SD-07 — Transaction isolation → `isolation_requirement` [SD §3.3]
Verify `locus: app` (an explicit `FOR UPDATE` / `isolation_level=` / version-column at the money write). `db-config`/`none-declared` → out-of-scope (isolation is DB/session config the repo may never mention — SD §3.3). The Pack-3 seed grep surfaces explicit-locking CANDIDATES honestly (SD-11); the VERDICT needs runtime, so hard-cap comment-only and mandate the `unknown — isolation configured outside repo` degrade when the declaration is `db-config`/absent.
**Acceptance:** `[det]` `locus: db-config`/absent → out-of-scope + the `unknown` degrade line; `locus: app` + discovered explicit-lock candidate → comment-only finding (candidate, not verdict). `[audit-run]` isolation-correctness (never gradable from static code — stays honest-`unknown`).

### SD-08 — Key rotation → Config-Profile `rotation_seam` [SD §3.4]
NEVER grade rotation compliance from code (policy lives in Vault/KMS/ops calendars — SD §3.4/§3.5). The in-repo checklist sub-bullet carries the honest degrade; the profile credential inventory declares the seam. Every rotation report is out-of-scope-by-declaration OR the `unknown` degrade — there is no `app`-locus verify path that grades rotation (only credential-PRESENCE, which is the existing secrets facet, not rotation).
**Acceptance:** `[det]` any rotation declaration → out-of-scope/`unknown` line, ZERO rotation-compliance findings (the guard against pretending to grade rotation). `[audit-run]` NONE — nothing in-repo grades rotation.

### SD-09 — Least-privilege breadth → in-repo seeds only, NOT an access review [SD §3.5]
The honest in-repo seeds (Dockerfile `USER root`, `GRANT ALL` in checked-in DDL, `"*"` in checked-in IAM JSON) ship as `[det]` candidate seeds (SD-11) written to an `audit/` candidates file — NOT verdicts. The mandate MUST state it is not an access review and NEVER imply audit-grade entitlement coverage (SD §3.5). IAM/Terraform elsewhere → out-of-scope-by-declaration.
**Acceptance:** `[det]` the seed greps produce candidates-not-verdicts on a fixture (medium precision, labeled candidate); a fixture with IAM-elsewhere declaration → out-of-scope line; a self_test asserts the report text disclaims access-review scope. `[audit-run]` breadth judgment (agent, comment-only).
> **Reconciliation (IMPLEMENTED 2026-07-07):** the breadth seeds (`Dockerfile USER root`, `GRANT ALL` in DDL, IAM `"*"`/`AdministratorAccess`) + must_not_flag negatives + the access-review-disclaimer assertion are implemented (`sd_seeds.sh` seed 7 → `audit/sd_least_privilege.txt`; SD-09 section of `sd_self_test.sh`). The "IAM-elsewhere declaration → out-of-scope line" acceptance is subsumed by that disclaimer rather than a manifest row: SD-01's declared locus family (abuse_controls / resilience_posture / isolation_requirement / timeout_budget_ms; rotation_seam is Config-Profile data) defines NO least-privilege locus field, so there is no declaration to drive a per-scope out-of-scope-by-declaration row. The seed's disclaimer states verbatim that IAM/Terraform breadth living elsewhere is out of the repo's reach — the honest equivalent, without inventing a field SD-01 does not carry. Adding a least-privilege locus field is a future SD-01 amendment, not applied here.

### SD-10 — Timeout budget composition → `timeout_budget_ms` [SD §3.7]
Per-call timeouts are greppable (the honest Pack-5 half, SD-11); whether budgets COMPOSE across hops needs topology. Verify each step's configured timeout against the declared per-step `timeout_budget_ms` (in-repo, `[det]`-in-the-join). Cross-hop composition is agent/topology → comment-only. Absent budget → the per-call grep still runs (honest), composition reports `unknown`.
**Acceptance:** `[det]` a step with a discovered timeout > declared `timeout_budget_ms` → a join finding; absent budget → per-call candidate only, composition `unknown`. `[audit-run]` cross-hop composition (agent/topology).

## D. The honest in-repo half (SD-11) and meta (SD-12)

### SD-11 — Honest deterministic seeds (candidates, never verdicts) [SD §2 packs, determinism-first]
The in-repo-assessable slivers the SD doc §2/§3 explicitly bless as honest: money-as-float (`float-literal/round()` ∩ VITAL_RE — the highest-value single grep the suite lacks, SD §2 Pack-2), tz-in-production (FLAKY_RE inverted outside TEST_PATH_RE), timeout-kwarg-absence (B113 + non-requests clients), jitter-absence over tx_retries.txt (thundering-herd sliver), Queue-without-maxsize, migration DDL + DROP/ALTER/NOT-NULL-add. Each is a `[det]` SEED emitting CANDIDATES to an `audit/` file — the VERDICT (money-path reasoning, DST/date-boundary, reversibility) stays agent. Deadlock stays PURE agent-judgment — a `Lock/acquire` regex is precision-hostile and violates the determinism-first "only where honest" clause (SD §3.9); NO `[det]` seed for deadlock.
**Acceptance:** `[det]` each seed produces a golden candidate set on a fixture (labeled candidate, not finding) + a must_not_flag negative (Decimal-correct, tz-aware, bounded queue, capped retry) protecting precision; deadlock has NO seed (a self_test asserts none exists — the honesty guard). `[audit-run]` every verdict layer (agent).

### SD-12 — Self-test + no-parallel-infra lint [1.4.0 house rules, MT-10]
Every `[det]` acceptance lands as a fixture + self_test assertion (red-first). The consistency lint gains: (a) the unfalsifiability guard (SD-03 red-test — a raw "missing X" on a non-`app`/absent locus fails); (b) the no-parallel-comparator guard (SD-04 rows must live in `manifest_join.sh`); (c) the byte-identical vendored SD-01 field schema (ADR 0001). EXPECTED_FINDINGS entries tagged `expected_by: deterministic` (joins, seeds) vs `expected_by: agent` (every verdict/derivation).
**Acceptance:** `[det]` self_test green with SD sections; the three lint guards red-tested (planted violation fails, revert greens); blind-eval extended per the 1.4.0 recurrence rule for the agent-scored rows (date + SHA in GAPS_SPEC). `[audit-run]` the extended blind eval.

## Flagged amendments (Bailey must approve — no silent ADR/manifest edits)
- **⟨SD-AMEND-A⟩** — the SD-01 `locus` field family is an additive manifest-schema change authored by the spec-gen tier (one-writer rule). Recorded for the spec-gen register; not applied here.
- **⟨SD-AMEND-B⟩** — whether ANY locus declaration is MANDATORY (a completeness rule) for a CORE money journey, or all stay optional-with-`unknown`-degrade. Default shipped: all optional (preserves ADR 0008 straight-through). Making one mandatory is a risk-appetite call — escalated.
- **⟨SD-AMEND-C⟩** — SD-03 out-of-scope-by-declaration is a NEW report class; it is DELIBERATELY never in the ADR-0004 blocking set (SD-00). Recorded so no future edit promotes it.

## The `[det]` / `[audit-run]` split (honesty note)
`[det]` (mechanical, hermetic, gate-eligible on CI only): schema parse + additive-safety (SD-02), out-of-scope short-circuit + unfalsifiability red-test (SD-03), the §12 join truth tables for the new rows (SD-04), each class's join lattice + cap (SD-05..SD-10), the candidate seeds + must_not_flag negatives (SD-11), lint guards (SD-12). `[audit-run]` (agent, never automated coverage): every declared VALUE quality, every discovered-side derivation (limiter/breaker/lock presence), criticality-derived shed-priority, budget composition, breadth judgment, deadlock — all comment-only, blind-eval scored. No hermetic coverage is claimed for any LLM judgment, and no in-repo finding is minted for any control the manifest declares lives at the gateway, mesh, sidecar, or nowhere.

## Non-goals
- Authoring the manifest/journeys/as-built docs (VERIFY-only, MS §7).
- A raw "missing X" finding for any non-`app`-locus control (the tier's central prohibition).
- Grading rotation, isolation-correctness, entitlement breadth, or stampede risk from static code (SD §3 — honest `unknown`).
- A second comparator or a fourth checker (ADR 0003; reuses CH-03 + run_sibling).
- Merge-blocking on any out-of-scope-by-declaration line (ADR 0004).

## Correction note — 2026-07-21 (ADR 0033): Config Profiles removed

> **Dated correction (2026-07-21), append-only — the entries above are history and are not
> rewritten.** ADR 0033 removes Config Profiles from the suite; every profile clause above
> reads historically:
>
> - Defaulted question (A)'s "the Config Profile narrows per LOB" scoping mechanism no
>   longer exists — all in-repo-assessable SD principles stay in scope by default with no
>   per-LOB narrowing seam; narrowing, if ever wanted, needs a new ADR.
> - SD-00's / SD-01's "ADR 0006 profile supplies the (enum) vocabulary" clauses are
>   retired: the `locus` enum vocabulary is fixed by ADR 0021 and the vendored schema
>   itself, which is where it already lived in the shipped code — no profile ever
>   supplied it.
> - SD-01's Config-Profile credential inventory and SD-08's/SD-09's "rotation_seam is
>   Config-Profile data" framing lose their carrier: no profile exists to hold a
>   credential inventory. SD-08's posture is UNCHANGED — rotation compliance is never
>   graded from code, and every rotation report stays out-of-scope-by-declaration or the
>   honest `unknown` degrade; that guarantee never depended on profile data. A credential
>   inventory, if it ever ships, enters by its own contract under a future ADR.
> - The declare-then-verify mechanics (SD-00 law, SD-03 report class, SD-04 comparator
>   rows, the [det]/[audit-run] split) are untouched — none of them read a profile.