# Suite Outcome Measurement — Change Register (report-only, baseline-at-adoption) — HARDENED r2

> Headline metric (Bailey 2026-07-06): **journey-instrumentation share** — % of CORE money/auth
> journeys that are OBSERVED (not DARK) — leads the pitch. It is deterministic (manifest + audit),
> uniquely enabled by this suite, and needs no external defect source of truth. Other metrics
> (defect-escape, DORA) are secondary/supporting, gated on their deployment-time external sources.
> Status: HARDENED r2 (post-adversarial) · 2026-07-06
> Style: GAPS_SPEC register. Acceptance tags are honest about their home,
> using the suite's three-tag convention verbatim:
>   [det]       = deterministic self_test.sh / lint assertion — grep / git-log /
>                 fixture / exit-code provable, hermetic (green in CI, no network,
>                 no host, NO agent in the loop).
>   [drain]     = measured only in a real run against a live host / the org rollout
>                 itself; never presented as automated coverage.
>   [audit-run] = measured only in a real AUDIT run whose input is AGENT-produced
>                 (journeys.json). Introduced here EXPLICITLY to stop laundering the
>                 journey-walker's judgment as [det] (adversarial finding H1).
> Sources (normative): CONTEXT.md (Vital, Journey, Merge Marshal = 'wiring not a
> checker; every decision a timestamp/sha/build-state/file-surface intersection');
> ADR 0023 (this design); ADR 0002 (escalation), 0003 (no fifth checker; the
> scheduled ambient audit is DESIGN INTENT, not yet wired), 0004 (report-only,
> deterministic-evidence-only gating), 0006 (OTEL profiles; ALERT SEAM LIVES OUTSIDE
> THE REPO — 'unknown' is the honest grade), 0010/0011 (Marshal = single-fire cron
> loop over pr-list-ready, wiring not a checker, the FUTURE home of the not-yet-built
> long-running PR-event agent), 0013 (host.sh adapter contract), 0014 (validator
> 0/3/4/5/64 exit codes + jsonschema single-source-of-truth), 0015 (shell+python+uv).
>
> Consolidation note (2026-07-17): the "V1-V10 (V11 is the next free rule)" reuse line below is
> historical — V11 was indeed allocated to this register's outcome rules, and ADR 0025 later
> retired the byte-identity vendoring rules V1/V3/V4/V5/V7/V8 along with the vendored copies
> (surviving root rules: V2, V6, V9–V13). The six plugins are one `zero-trust` plugin (ADR 0025)
> and the root marketplace is retired (ADR 0027). Entries below stand as written (append-only).
> Machinery REUSED (verified present in-tree, not assumed): scripts/host.sh subcommand
> set INCLUDING pr-list-ready (host.sh:93), autopilot mock host (T01-class), audit
> journeys.json (agent-written by journey-walker) + state.json append-only degrade-
> never-act pattern, scripts/lint_consistency.sh V1-V10 (V11 is the next free rule),
> scripts/suite_self_test.sh component_skips skip-honesty, validate_manifest.py
> EXIT_COMPLETE/INCOMPLETE/SCHEMA_INVALID/UNSUPPORTED = 0/3/4/5, the Marshal's
> operator-wired single-fire cron entry (the marshal domain of plugins/zero-trust — docs/marshal/README.md §cron entry).
>
> This register delivers a NEW capability as MODES of two existing plugins plus one
> shared store + renderer. NOT greenfield, NOT a fifth plugin (ADR 0023). Every
> item preserves report-only, never-blocking, zero-hook, opens-no-PR, files-no-finding
> (ADR 0004/0023).
>
> ===== WHAT CHANGED FROM r1 (DRAFT), and WHY (adversarial hardening) =====
>  H1 HONESTY: journeys.json is written by the journey-walker AGENT (agents/journey-
>     walker.md frontmatter: tools Read/Grep/Glob/Bash). Its OBSERVED/LOG-ONLY/DARK,
>     criticality, and alert_seam grades are JUDGMENTS, not hermetic. r1 tagged the
>     journey-instrumentation share [det] and called it 'causally attributable /
>     defensible as THE headline'. FIX: the projection ARITHMETIC over a FIXED fixture
>     is [det]; the metric ON A REAL REPO is [audit-run] (agent-graded input). The
>     share is now labeled 'suite-produced but agent-graded', NOT presented as a
>     hermetic number. It can NO LONGER be the un-caveated [det] headline.
>  H2 HONESTY + ADR 0006 CONTRADICTION: r1's headline included 'paged share (vs
>     dashboard-only/unknown)'. ADR 0006 + journey-walker rule: alerting lives OUTSIDE
>     the repo, so the honest grade is almost always 'unknown — no alert config in
>     repo'. A repo-derived paged-share is near-zero-signal and is the SAME external-
>     fact class as incident/MTTR (ADR 0002). FIX: paged-share is REMOVED from the
>     repo-derivable core; it moves behind the OM-06 external-alert adapter and
>     degrades to [OUTCOME-SOURCE-ABSENT: alert-config]. The suite-unique repo metric
>     is now ONLY the OBSERVED-vs-DARK emission share (still agent-graded → [audit-run]).
>  H3 FEASIBILITY + ADR 0003 CONTRADICTION: r1's OM-08 claimed to 'reuse the ambient-
>     cron surface the audit's ambient run already uses — no new scheduler'. That
>     surface DOES NOT EXIST: ADR 0003 point 2 is design intent; autopilot DELETED
>     external schedulers (AP-19, no headless, does not survive session death). The
>     only real cron loop is the Marshal's operator-wired SINGLE-FIRE pass. FIX: OM-08
>     rides the Marshal's EXISTING operator-wired cron entry as an added per-fire step,
>     OR is a manual/CI-invoked mode. It claims NO reuse of an unbuilt audit ambient
>     cron.
>  H4 FEASIBILITY accuracy: r1 repeatedly called the Marshal 'the long-running PR-
>     event agent it already watches / watches every merge and build already'. The
>     Marshal is a STATELESS per-fire pass over pr-list-ready (the ready-to-merge
>     queue). ADR 0011 names it the FUTURE home of that agent. FIX: DORA is derived by
>     querying git log + host API RETROACTIVELY at each capture — a NEW read, honestly
>     described, not 'the stream it already watches'.
>  H5 ADR 0001/0011 CONTRADICTION: r1's OM-08 posted the digest via host.sh pr-comment.
>     For the read-only audit that breaks the 'installable without granting anything'
>     pitch. FIX: digest POSTING is the Marshal's job (it already holds write scope) OR
>     an artifact write; the audit's outcome-emit is read-only-on-target, writes ONLY
>     the store, posts nothing.
>  H6 LOOP-SAFETY: made explicit — the scheduled digest NEVER triggers a fresh audit
>     run to obtain a share (that would make a report-only layer cause autonomous heavy
>     work and recurse into the audit it measures); it consumes the LAST audit's
>     journeys.json if present, else degrades. And a hard non-goal: outcome-measurement
>     opens no remediation PR, files no finding, triggers no drain — it observes only.

## 0. Position and posture (read first)

Outcome measurement is **wiring, not a checker** (ADR 0023, passing ADR 0003's test as
the Marshal did in ADR 0011). It forms NO quality opinion of its own. But — sharpened
from r1 — its numbers are of TWO honesty classes, and the register never conflates
them:
  - **Class-D (deterministic):** the four DORA-family metrics (deploy frequency, lead
    time, change-failure rate, MTTR-from-build) — each git-log / host-API provable,
    NO agent in the loop. These are [det] on fixtures and [drain] on a live host.
  - **Class-A (agent-graded input):** the journey emission share, because its input
    journeys.json is written by the journey-walker AGENT. The projection code is [det];
    the metric on a real repo is [audit-run]. It is 'suite-produced' (the suite is what
    grades emission) but it is NOT hermetic, and the register/renderer label it so.
Everything is deterministic-OR-agent-graded-OR-human-annotated; NOTHING is model-
ESTIMATED (no LLM 'code-quality score'). Zero exit-code authority, zero hook, opens no
PR, files no finding, triggers no drain; the scheduled run always exits 0.

Producers attach to the plugin that already owns each datum:
  - DORA + defect-escape + incident capture → **Marshal** (holds host write scope;
    already fires on the operator-wired cron; ADR 0011 future-home of the PR-event
    agent). DORA is a NEW retroactive git-log + host-API read at capture time — NOT
    'the stream it already watches' (H4).
  - Journey emission share → **codebase-health audit** outcome-emit step, READ-ONLY on
    target, consumes the LAST journeys.json the walker produced, writes only the store,
    posts nothing (H5).

**Invariants this register does NOT touch:** report-only never-blocking (ADR 0004; no
item adds a gate or hook); detection-never-mutates (producers write outcome/ only,
idempotent, schema-versioned; never touch target repo or diff); broken-state-degrades-
to-LESS-action (audit invariant 4); adoption posture preserved (measurement mode grants
nothing; audit side stays read-only).

**The load-bearing constraint (ADR 0023):** the BEFORE baseline MUST be captured at
the adoption event or the before/after is lost. Because deploy/merge cadence, post-merge
build-failure rate, and lead time are reconstructable from trailing git + host history,
the baseline is captured RETROACTIVELY at adoption (not by a forward wait). NOTE the
asymmetry sharpened in H1: the DORA baseline is fully retroactive (git+API history
exists); the journey emission-share baseline requires ONE audit run at adoption and is
agent-graded, so it is captured but tagged Class-A, never as retroactive [det] history.

## Dependencies and landing order

**OM-01 → OM-02 → OM-03 → OM-04 → OM-05 → OM-06 → OM-07 → OM-08 → OM-09.**
OM-01 (store schema + degrade table) is the substrate. OM-02 (baseline capture + freeze
+ refuse-second) is the load-bearing constraint. OM-03 (DORA, Class-D, Marshal) and
OM-04 (emission share, Class-A, audit) parallelize after OM-02. OM-05 (defect-escape)
and OM-06 (incident/MTTR AND alert-seam/paged, all external per H2) sit behind the
external-source adapter and degrade to annotated. OM-07 (renderer + delta/significance
+ honesty-class labeling) consumes the store. OM-08 (scheduled digest) rides the
Marshal's EXISTING cron entry (H3). OM-09 (V11 lint + self_test growth) locks every
[det] above and asserts the [audit-run]/[drain] tags are NOT dressed as [det].

## Non-goals (explicit)

- **No gating, no ratchet, no hook, ever.** Not even soak-then-block. Report-only is
  permanent (ADR 0004).
- **No new plugin.** Modes of Marshal + audit (ADR 0023). No fifth marketplace
  entry, no fifth self-test root.
- **No autonomous action of ANY kind.** Outcome-measurement opens NO PR, files NO
  finding, triggers NO drain or remediation, requests NO fresh audit. It reads history
  and the last audit output, writes the store, renders a report. This closes the
  remediation-loop / prod-triage / self-remediation attack surface at the design level:
  there is no autonomous path to be infinite, because there is no autonomous path.
- **No model-estimated metric.** Every number is Class-D (deterministic), Class-A
  (agent-graded, and LABELED so), or human-annotated. No LLM 'quality score' — that
  would make the checker check itself, the circularity this layer exists to break.
- **No paged-share from repo data (H2).** Alert seams live outside the repo (ADR 0006);
  paged-share is external-fact, behind the OM-06 adapter, degrading to
  [OUTCOME-SOURCE-ABSENT: alert-config]. The repo-derivable suite metric is the
  OBSERVED-vs-DARK EMISSION share only.
- **No fresh-audit trigger from the digest (H6).** The digest consumes the LAST
  journeys.json; it never launches an audit to freshen the share.
- **No dashboard product.** Machine-parseable artifact + markdown digest (agent-first,
  ADR 0006); a pretty dashboard is a later human-compat layer.
- **No forward-only baseline.** No captured baseline → absolute-value reporting, never a
  fabricated 'before'.
- **No causal claim beyond attribution honesty.** DORA/defect/incident deltas are
  reported CORRELATED-with-adoption with confounders named; the emission share is
  'suite-produced but agent-graded', never dressed as a hermetic causal proof.
- **Deciding WHICH metric headlines the pitch, whether an agent-graded share is
  admissible AS pitch evidence to this audience, the incident source, the defect-escape
  source, the significance window** — escalated (ADR 0002), not built here.

---

## A. Shared store + baseline (the substrate)

### OM-01 — Outcome store schema + degrade table [ADR 0023; mirrors state.json]
A new `outcome/outcomes.json`, schema_version 1, append-only `runs[]`, plus a single
frozen `baseline` object. Optional fields do not break the schema (state.json rule: an
absent metric = 'no comparable baseline', never read as 0, never a fabricated
regression). EVERY metric row carries a mandatory `honesty_class` enum
(`deterministic` | `agent-graded` | `human-annotated`) and `provenance` string —
added in hardening so the renderer can NEVER present a Class-A number as [det] (H1).
One writer path shared by both producers; `schema/outcome/v1.schema.json` is the single
structural source of truth, validated by the SAME jsonschema toolchain as the manifest
(ADR 0014) — no hand-rolled checks. Degrade table (loop-safety invariant 4):
  | store state | behavior |
  | absent | first run creates it; report says 'first observation, no history'. |
  | corrupt / unknown schema_version | refuse to write; report the read error; NEVER
    overwrite (state.json 'degrade, never act'). |
  | frozen baseline present | after-reports compute deltas against it. |
  | no frozen baseline | after-reports print [OUTCOME-NO-BASELINE] + absolute only. |
**Acceptance:**
- [det] `scripts/outcome_store.sh {read|append-run|write-baseline}` round-trips a
  fixture store; jsonschema validation rejects a malformed row reusing the manifest
  validator's 0/4/64 contract (0 ok, 4 schema-invalid, 64 usage). Fixture matrix covers
  absent / valid / corrupt / unknown-version.
- [det] a row written WITHOUT a `honesty_class` is rejected schema-invalid (asserts the
  H1 guard: no unlabeled number can enter the store).
- [det] append-run with an optional field absent emits NO delta for that field (the
  'absent != 0' rule).
- [det] a write against a corrupt store exits non-zero and leaves the file byte-identical
  (byte-compare before/after).

### OM-02 — Baseline capture at adoption, frozen, refuse-second [ADR 0023 — LOAD-BEARING]
`scripts/outcome_baseline.sh capture` computes the BEFORE snapshot. The four DORA-family
fields (Class-D) are reconstructed retroactively from `git log` + `host.sh` over a
configurable trailing window (default 8 weeks, OM-07 significance rule). The emission-
share field (Class-A) is captured from ONE baseline audit run at adoption and stored
with `honesty_class: agent-graded` — never as retroactive history (H1). Writes
`baseline` with `captured_at`, `git_sha`, `window`, `frozen: true`. Adoption = the commit
that first introduces a suite plugin manifest, OR an explicit `capture` call. A second
`capture` on a store with `frozen: true` is REFUSED (exit non-zero, file byte-untouched).
**Acceptance:**
- [det] against a fixture git repo + mock host, `capture` produces a baseline with all
  four DORA fields populated from trailing history (retroactive capture works, no forward
  wait), each tagged `honesty_class: deterministic`.
- [det] the emission-share field, when a fixture journeys.json is present, is stored
  `honesty_class: agent-graded` (asserts it is NOT laundered as deterministic history).
- [det] a second `capture` on a frozen store exits non-zero, file byte-identical; the
  message names the existing `captured_at`.
- [det] `capture` on a repo whose trailing window is shorter than the minimum emits the
  baseline with `window_short: true` (OM-07 renders it directional).
- [drain] on the real rollout, the baseline is captured within the adoption PR (the
  measured proof the constraint held — needs the real adoption event).

## B. The two producers (co-located with the data owner)

### OM-03 — DORA derivation, a Marshal mode [ADR 0011, 0013; host.sh; ALL Class-D]
Marshal gains `marshal.sh outcome-capture`: a NEW retroactive read (H4) over git log +
the host API for a window, deriving four DORA metrics DETERMINISTICALLY:
  - deploy frequency = merges-to-trunk per window (git log first-parent on trunk);
  - lead time = first-commit → merge timestamp distribution (git + host);
  - change-failure rate = fraction of merges whose post-merge `build-status` is red OR
    followed by a revert/hotfix-labeled merge within the window;
  - MTTR (build) = time from a red post-merge build to the merge that greens it. (Note:
    incident-based MTTR is OM-06, external.)
All route through `host.sh` (ADR 0013) so Bitbucket DC and GitHub yield the same
assertion set. Appends one `runs[]` row, every field `honesty_class: deterministic`.
Read-only on the target repo and on every PR (touches only outcome/).
**Acceptance:**
- [det] against the T01-class mock host (reused), a fixture history yields the four DORA
  numbers matching a hand-computed expected file; runs against BOTH mock backends
  (byte-identical-contract assertion).
- [det] a window with zero merges yields deploy-freq 0 and lead-time null (no divide-by-
  zero, no fabricated value).
- [det] `outcome-capture` writes ONLY outcome/: asserts no write to the target repo, no
  PR comment, no finding file (H5/non-goal: opens no PR, files no finding).
- [drain] on a live host the four numbers match the host's own PR/build API for the
  window (real-host fidelity).

### OM-04 — Journey EMISSION share, an audit emit step [ADR 0006; journeys.json; Class-A]
The audit gains an `outcome-emit` step that reads the LAST `journeys.json` the journey-
walker AGENT already produced and computes the suite metric: on CORE journeys, the share
of money/auth vital steps graded OBSERVED (vs LOG-ONLY/DARK). **Paged-share is NOT
computed here (H2)** — alert seams are external (ADR 0006), so paged-share lives behind
the OM-06 adapter. This step is a projection of grades already recorded; it does NOT re-
walk and does NOT trigger a fresh audit (H6). Every row is `honesty_class: agent-graded`,
`provenance: journeys.json@<git_sha>`. Read-only on target, writes only the store, posts
nothing (H5). Honors the audit degrade rules verbatim: absent/corrupt/unknown-schema
journeys.json → emit nothing + a loud [note], NEVER a guessed share.
**Acceptance:**
- [det] (projection arithmetic only) a `journeys.json` FIXTURE with a known mix of
  OBSERVED/LOG-ONLY/DARK yields the exact emission-share number (hand-computed); every
  emitted row carries `honesty_class: agent-graded` (asserts the H1 label is not
  droppable).
- [det] the step emits NO `alert_seam`/paged field (asserts H2: paged-share is not a
  repo-derived metric here).
- [det] a v1 (pre-CH-02) journeys.json still parses and yields a share from present
  fields — a missing optional field is not a corrupt file (reuses the CH-02 degrade
  fixture).
- [det] absent/corrupt journeys.json → no share row + the [note] (no fabricated metric,
  no fresh-audit trigger).
- [audit-run] on a REAL repo the emission share reflects the walker's actual grades —
  tagged [audit-run], NOT [det], because the input is agent judgment (the H1 honesty
  residual made explicit).

## C. External-source metrics (behind ONE adapter; degrade to annotated)

### OM-05 — Defect-escape rate, adapter + annotated fallback [ADR 0002 external fact]
Defect-escape = a defect that reached production, attributed to the introducing merge
within an attribution window. SOURCE and window are org-policy (escalated). v1 ships an
adapter interface: if a source is configured (hotfix-labeled PRs via host.sh labels, or
an external-tracker adapter), derive the rate DETERMINISTICALLY (`honesty_class:
deterministic`); else the field is human-annotated (`outcome_annotate.sh defect-escape
--count N --window W`, `honesty_class: human-annotated`), never model-estimated.
**Acceptance:**
- [det] with the hotfix-label adapter + mock host, a fixture label set yields a hand-
  computed escape rate tagged `deterministic`.
- [det] with no source configured, the field renders `[OUTCOME-SOURCE-ABSENT: defect-
  escape]` and the digest omits the delta (no fabrication).
- [det] an annotated value round-trips tagged `honesty_class: human-annotated` (asserts
  it is never presented as derived).

### OM-06 — Incident/MTTR + alert-seam(paged) share on instrumented-vs-dark journeys, adapter [ADR 0006/0002]
Expanded from r1 to ABSORB paged-share (H2): alert config AND incident data both live
outside the repo (ADR 0006), both are unobservable external facts (ADR 0002). v1 ships
the adapter interface + annotated fallback ONLY; the concrete backend (PagerDuty /
Opsgenie / ServiceNow / org tooling, AND the alerting config source) is NAMED by human
escalation, then built behind the adapter (the host.sh pattern: one contract, swappable
backend). Two suite-unique cuts become computable only once the external source can be
joined to `journeys.json` by journey name: (a) do incidents concentrate on DARK vs
OBSERVED journeys; (b) the paged-vs-dashboard-only alert-seam share on CORE vitals.
**Acceptance:**
- [det] the adapter contract has a mock backend; a fixture incident set + fixture alert-
  config joined to a fixture journeys.json yields incident-count, MTTR, AND paged-share
  split by OBSERVED-vs-DARK (hand-computed).
- [det] with no backend configured, ALL of incident/MTTR/paged-share render
  `[OUTCOME-SOURCE-ABSENT: incident-system]` / `[OUTCOME-SOURCE-ABSENT: alert-config]`
  and the v1 pitch renders without them (absence never blocks the report).
- [drain] once a real backend is named + built, the numbers match the source's own for
  the window.

## D. Report + schedule + lock

### OM-07 — Report renderer: delta + significance + HONESTY-CLASS labeling [ADR 0004; agent-first]
`scripts/outcome_report.sh` reads the store and renders a machine-parseable artifact +
markdown digest (agent-first, ADR 0006). Rules: a delta is shown UN-caveated only when
BOTH baseline and post windows >= the minimum (default 8 weeks, escalated); shorter →
'directional, not yet significant'. No frozen baseline → [OUTCOME-NO-BASELINE], absolute
only. **New in hardening:** every metric line prints its `honesty_class` badge —
Deterministic / Agent-graded / Human-annotated — so a reader (and a VP) can never mistake
the agent-graded emission share for a hermetic number (H1). Every DORA/defect/incident
delta carries a named-confounder line (multi-causal honesty); the emission share is
labeled 'suite-produced, agent-graded', NOT 'causally proven'. NEVER emits a gating exit
code (always 0).
**Acceptance:**
- [det] a store with baseline + after run renders the delta table with all present
  metrics; a missing metric is omitted, not zero-filled.
- [det] EVERY rendered metric line carries its honesty_class badge; a Class-A row renders
  'Agent-graded' and NEVER 'Deterministic' (asserts the H1 anti-laundering guard end to
  end).
- [det] a `window_short` baseline renders every delta as directional.
- [det] no frozen baseline renders [OUTCOME-NO-BASELINE] + absolute values (no fabricated
  delta).
- [det] `outcome_report.sh` exits 0 on every fixture including error/degrade ones (report-
  only, ADR 0004).

### OM-08 — Scheduled digest mode (ride the MARSHAL's existing cron entry) [ADR 0010/0011]
Corrected from r1 (H3): there is NO wired audit ambient-cron to reuse. The digest is an
ADDED per-fire step on the Marshal's EXISTING operator-wired single-fire cron entry
(the marshal domain of plugins/zero-trust, the same entry that runs the merge pass), OR a manual/CI-invoked mode.
A fire runs `outcome-capture` (OM-03) + (if the LAST audit produced a journeys.json)
`outcome-emit` (OM-04, NO fresh audit trigger — H6) + `outcome_report.sh` (OM-07). Exits
0 always. DIGEST POSTING is the Marshal's (it already holds write scope) via `host.sh
pr-comment` OR an artifact write; the audit's outcome-emit posts NOTHING (H5). Never
creates a status check.
**Acceptance:**
- [det] the cron step invokes the three sub-steps in order and exits 0 even when a step
  degrades (host unreachable → that step SKIPS, digest still renders).
- [det] outcome-emit in the cron path does NOT invoke a fresh audit: asserts it only
  READS an existing journeys.json and no walker/audit process is spawned (H6).
- [det] the digest posts through the MARSHAL's host.sh write path (mock); the audit-side
  outcome-emit is asserted to make zero host writes (H5); no status-check surface is
  created.
- [drain] a scheduled fire on the live repo produces a digest with real numbers.

### OM-09 — V11 vendoring lint + self_test growth (lock every [det]; guard the [audit-run] tags) [ADR 0001 pattern]
Add rule **V11** to `scripts/lint_consistency.sh` (V1-V10 exist; V11 is next free): the
outcome-store schema (`schema/outcome/v1.schema.json`) and the renderer contract are the
single canonical copy; any vendored copy inside Marshal or audit (standalone install) is
byte-identical — the V1/V3 pattern (the two producers must not drift on the store
contract). Grow `suite_self_test.sh`: a GREEN V11 run, a RED-drift plant (mutate a
vendored copy, assert V11 catches it), a false-positive guard (benign reformat does not
red), and skip-honesty via the existing `component_skips` detector (an outcome step that
cannot reach the host is PASS-WITH-SKIPS, not a false green). **New in hardening:** a
self-test assertion that the emission-share acceptance is registered as [audit-run] (or
its fixture-arithmetic slice as [det]) and NOWHERE as a whole-metric [det] — a
machine-checkable guard against re-laundering H1 in a future edit.
**Acceptance:**
- [det] V11 GREEN against the real tree; V11 RED on a byte-drifted vendored store-schema
  copy; V11 does not red on a whitespace-only reformat (has-teeth + not-vacuous, mirrors
  V1 self-test).
- [det] `suite_self_test.sh` records the new producer assertions and, when the host mock
  is absent, records them PASS(skips) not PASS (skip-honesty via component_skips).
- [det] a lint/grep assertion that the OM-04 real-repo emission-share acceptance is
  tagged [audit-run] and no [det] acceptance in the register claims a real-repo (non-
  fixture) agent-graded number (the H1 guard, mechanized).
- [det] every [det] acceptance in OM-01..OM-08 is covered by a named assertion in a
  producer self-test (the CH-10-style close).

> **Correction note (2026-07-17, ADR 0031):** the outcome runtime family moved from
> repo-root `scripts/` into `plugins/zero-trust/scripts/` (post-consolidation residue:
> the plugin is the one installable unit). Acceptance entries above that cite
> `scripts/outcome_store.sh` (OM-01), `scripts/outcome_baseline.sh` (OM-02) and
> `scripts/outcome_report.sh` (OM-07) now resolve at
> `plugins/zero-trust/scripts/outcome_*.sh`; the acceptance semantics, exit contracts
> and honesty-class rules are unchanged. Entries are append-only, so the original
> lines stay as written (ADR 0031).
