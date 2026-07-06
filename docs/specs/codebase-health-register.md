# Codebase-Health Audit Tier — Change Register (PR Gate + Manifest)

> Status: DRAFT r2 (adversarial round 1 applied: 16 findings from two independent
> attackers — corpus-consistency and executor-simulation lenses; 3 P0, 5 P1, all
> closed, P2 closed or recorded) · 2026-07-05
> Style: GAPS_SPEC register (mirrors `docs/specs/autopilot-v3-register.md`).
> Acceptance criteria are honest about their home: `[det]` = deterministic
> `self_test.sh`/`lint` assertion (grep/git-log/fixture-provable, hermetic);
> `[audit-run]` = measured only in real audit/PR-Gate runs + the manual
> blind-corpus eval (the 1.4.0 honest-residual convention — never presented as
> automated coverage).
> Sources: CONTEXT.md (PR Gate, Memory Rot, Vital, Journey, Verification
> Manifest, Config Profile — normative); ADRs 0003 (rot enforcement + PR Gate
> placement), 0004 (ratcheted blocking), 0006 (profiles), 0009 (derived claims);
> verification-manifest-v1.md (§9 spec_hash, §11 degrade + exit codes, §12 join,
> §13.10–11 induced audit/PR-Gate requirements); spec-gen-tier-v1.md (SG-8
> provenance + main-lineage reservation, ⟨MS-AMEND⟩ 1–3).
> Baseline: codebase-health **v1.4.0** (accepted `docs/SPEC_1.4.0.md`; seven
> agents; `self_test.sh` 131 assertions at 1.4.0 acceptance — 128 unconditional
> + 3 ruff-conditional — now **141 at current HEAD** after the post-eval §13 LOCK
> registrations (GAPS_SPEC 1.4.0 closure); CH-10 extends the live count;
> eight ratcheted counts; `audit/journeys.json` schema_version 1;
> `audit/state.json` schema_version 2). This register describes **deltas** the
> audit tier must GAIN to become the suite's step-4 checker — it is not
> greenfield, and it preserves the 1.4.0 read-only / warn-only adoption posture
> in full.

## 0. Position and posture (read first)

The PR Gate is **a diff-scoped mode of this plugin**, not a fourth checker
(ADR 0003). It reuses the 1.4.0 facets, `debt_patterns.sh` regexes,
`EXPECTED_FINDINGS.yaml` fixtures, ratchet state, fingerprints, and loop-safety
posture. Nothing here adds a second implementation of any detector — the
install-story win (audit-plugin-only for teams that want just PR review) is
already covered because the audit is independently installable and the PR Gate
is one of its modes.

**Invariants this register does NOT touch** (every item below is checked against
`references/loop-safety.md` first — a violation is a release blocker, not a
style note):

- **Detection never mutates** (invariant 1). The one new agent-written artifact
  stays `audit/`-only, idempotent, schema-versioned. Probes stay bounded
  (single test, N≤10, never destructive). The PR Gate NEVER mutates the target
  or the diff.
- **Hooks warn, exit 0 — unconditionally** (invariant 3). The prevention hook
  surface (`check_new_debt.sh --hook`) is untouched by everything here; strict
  exit codes live ONLY on the CI/script surface a human wired (the 1.4.0
  strict-default split, `references/loop-safety.md`).
- **Broken state degrades to less action** (invariant 4). A missing / unparseable
  / unsupported-`schema_version` manifest degrades exactly like a missing
  `journeys.json` or `state.json`: say so, do less, never guess, never block on
  the absence.
- **PARTIAL never rounds up; severity inflation is a defect; silent truncation
  is a defect** (invariants 5, 6, 7). The absence-severity cap
  (`severity-rubric.md`, the 1.4.0 amendment) governs every new absence finding.
- **The ratchet reports; it never blocks or mutates** (`audit-state-and-verify.md`).
  Merge-blocking is the CI-surface exit code the repo owner wires — ADR 0004
  supplies which classes gate there, and only deterministic evidence may.

**Adoption posture preserved:** the audit is the lowest-trust plugin. The PR
Gate ships report-only during the ADR-0004 soak (2–4 weeks per repo), then the
gated classes flip to blocking on the CI surface only — never inside the hook,
never as a default the plugin installs for you.

## Dependencies and landing order

The manifest schema is vendored, not authored here (ADR 0001; the manifest spec
`schema/verification-manifest/v1.schema.json` + `scripts/validate_manifest.sh`
are the one permitted bootstrap, delivered by the spec-gen drain — CH items
CONSUME them). **This drain has landed.** `scripts/validate_manifest.sh` (with its
`scripts/validate_manifest.py` core), `schema/verification-manifest/v1.schema.json`,
and the MS §13.2/§13.4 fixture suites (`tests/fixtures/manifest/`,
`tests/fixtures/join/`) now exist at the repo root, so `have_validator` is true in
the monorepo and `self_test.sh` sections 14–22 run green against the real
validator. Every manifest-reading item (CH-01, CH-03, CH-06, CH-08, CH-09) is
therefore **no longer blocked** — its `[det]` acceptances are live and
self-test-assertable today. CH-02, CH-04, CH-05, CH-07 (git/diff/journeys
mechanics) never needed the validator and are independent of it. (Standalone
install caveat: a codebase-health install outside this monorepo still vendors its
own copy of the validator + schema per ADR 0001 — the repo-root artifacts are the
monorepo's shared bootstrap, not a promise they travel with a standalone plugin.)

**CH-01 → CH-02 → CH-03 → CH-08 → CH-04 → CH-05 → CH-06 → CH-07 → CH-09 → CH-10.**

Rationale: CH-01 (manifest ingestion + degrade) is the substrate every consumer
reads; CH-02 (`manifest_journey_id` backref, journeys.json v2) unblocks the §12
join (CH-03); CH-08 (config-profile awareness) feeds absence-severity into the
comparator and the rot facet, so it lands before CH-04/05; CH-04 (diff-scoped
mode) is the surface CH-05/06/07 all attach to; CH-09 wires the ADR-0004 blocking-class
list onto that surface last; CH-10 grows the self-test and consistency lint to
cover every `[det]` acceptance above.

## A. Manifest consumption (MS §13.10)

### CH-01 — Manifest ingestion + consumer degrade [ADR 0003, MS §8/§11/§13.10]
The audit gains a manifest reader: locate `<spec-basename>.manifest.yaml`
colocated with a Spec, validate it via the vendored
`scripts/validate_manifest.sh` (exit 0 complete / 3 incomplete / 4 schema-invalid
/ 5 unsupported), pin `schema_version` and **refuse newer majors**
(`[MANIFEST-UNSUPPORTED: schema_version N > supported M]` — never best-effort
parse, MS §8). The degrade table (MS §11) is implemented verbatim as a new
loop-safety-invariant-4 surface:

| Manifest state | Audit behavior |
|---|---|
| absent | Heuristic journeys (unchanged 1.4.0 walk); coverage/rot-vs-manifest facets emit a loud `[note]` and are skipped; severity caps per `severity-rubric.md`. |
| `completeness: incomplete` | As absent (only a resumed spec-tier session consumes it). |
| exit 4 (schema-invalid) | Refuse the manifest; report the schema error; **never degrade to manifest-less** (MS §11 — a schema-invalid manifest is a defect, not an absence). |
| exit 5 (unsupported) | `[MANIFEST-UNSUPPORTED]`; treat as absent for facet purposes but say which version. |
| unknown `observability.profile` | Proceed with `default` profile + loud `[note]`; comment-only finding (CH-08). |

**Acceptance:**
- `[det]` `scripts/ingest_manifest.sh <manifest>` emits a `MODE` token
  (`COMPLETE | INCOMPLETE | ABSENT | SCHEMA-INVALID | UNSUPPORTED`) from the
  validator exit code + `schema_version` read; fixture matrix covers all five,
  reusing the manifest spec's fixture suite (valid-complete, incomplete,
  boolean-in-enum, unsupported-version) so no second copy of the schema exists.
- `[det]` a degrade fixture asserts that with an absent/invalid manifest the
  coverage and rot-vs-manifest facets emit the `[note]` and add themselves to
  the report's **Not covered** section (invariant 6 — no silent skip).
- `[audit-run]` the orchestrator actually consuming `MODE` to gate facet
  dispatch.

### CH-02 — `journeys.json` v2: `manifest_journey_id` backref + step `event_name` [MS §12/§13.10]
`audit/journeys.json` gains two OPTIONAL fields, and `schema_version` bumps
**1 → 2** (MS §13.10 already names the target "journeys.json v2" — this executes
that, it does not amend it). Per the 1.4.0 additive-field precedent (the
`state.json` schema_version-2 optional-count precedent), an absent field is not a
schema break for readers that pin v1, but the audit writes v2. All existing v1
consumers and the journey-trace degrade rules are unchanged; both fields are
additive.

- **`manifest_journey_id`** (journey-level): the intended↔discovered join key
  (MS §12 row 1). `journey-walker` sets it when a manifest is present and a
  confident journey↔journey match exists; leaves it `null` otherwise (fuzzy =
  no join, MS §12 row 1).
- **`event_name`** (step-level): the discovered emitted event name for the step,
  giving MS §12 row 2 a real string-equality join key. Without it the row would
  have to re-derive a symbol from a `telemetry.txt` `file:line` line (no symbol
  column exists on that artifact — `run_audit.sh` writes it as a whole-repo
  `grep -rEn "$TELEMETRY_RE"`), which is neither a grep membership test nor
  fixture-hermetic. `journey-walker` populates `event_name` from the same walk
  that grades `emission_grade` (the emission it graded IS the event it names),
  reusing the `TELEMETRY_RE` seed as the candidate source; `null` on DARK steps
  (nothing to name).

**Acceptance:**
- `[det]` `references/journey-trace.md` schema updated to v2 with both optional
  fields; a fixture `journeys.json` v2 parses and a v1 fixture still parses under
  the degrade rules (missing field ≠ corrupt); `self_test.sh` asserts both.
- `[det]` a hand-authored manifest + `journeys.json` v2 fixture pair (the MS
  §13.4 deliverable, consumed here) asserts the backref points at an existing
  manifest `journeys[].id` and a vital step carries an `event_name`. **Live:** the
  MS §13.4 fixture pair has landed at `tests/fixtures/join/` (`manifest.yaml` +
  `journeys.json`).
- `[audit-run]` `journey-walker` populating both fields by real match/emission
  quality (leaving `null` on fuzzy / DARK) — semantic, agent-scored.

### CH-03 — §12 intended↔discovered comparator (every row) [MS §12/§13.10]
A new facet consumes the manifest (CH-01) + `journeys.json` v2 (CH-02) and joins
intent to discovery per MS §12, **every row**, emitting drift findings. Join
keys and comparison rules verbatim from MS §12:

| Manifest (intent) | `journeys.json` (discovered) | Rule (MS §12) |
|---|---|---|
| `journeys[].id` | `manifest_journey_id` | Exact backref. Absent backref → fall back to exact `name` match; fuzzy = **no join, say so** (Not covered). |
| `steps[].event_name` | `steps[].event_name` (CH-02 v2 field) | Exact string on a real discovered field — this is why CH-02 adds the step field rather than re-deriving from `telemetry.txt`. |
| `required_emission: OBSERVED` | `emission_grade` | OBSERVED only. |
| `required_emission: LOG-ONLY` | `emission_grade` | OBSERVED or LOG-ONLY; DARK never satisfies. |
| `alert_seam` (paged/dashboard-only/none) | `alert_seam` (paged/dashboard-only/unknown/null) | paged←paged; dashboard-only←paged\|dashboard-only; none←anything; discovered `unknown` satisfies only intent `none` (needs-verification, not violation). Env selection: the discovered `alert_seam` is a single env-agnostic scalar (`journeys.json` records one traced seam, not a per-env map), so the env-keyed intent map is collapsed to its **audited-environment key** (the profile's env under audit, else `default`) before the lattice compares. |
| `idempotency.required: true` | `duplicate_guard` | `present` satisfies; `absent` on a traced money path escalates per the tx lens; `n/a` = needs-verification. |
| `compensation` | `compensation_note` | Informational; no pass/fail. |
| `criticality` (declared) | `criticality` (derived) | Mismatch = intent-vs-derived drift, MED needs-verification. |

**Fingerprints — two scopes.** Step-scoped rows (emission, seam, idempotency)
carry the existing `path:symbol:slug` scheme (`audit-state-and-verify.md`) with
new slugs `manifest-emission-drift`, `manifest-seam-drift`,
`manifest-idempotency-drift` on the step's `path`+`symbol`. But `criticality` and
`journeys[].id`↔backref are **journey-level** — a journey spans many symbols and
has no single enclosing one, and `path:symbol` does not apply. Those two rows use
a **journey-scoped fingerprint form**: `<journey.source path>:<journey.name>:<slug>`
(the journey's `source` file stands in for `path`, its `name` for `symbol`;
`source` is `file:line` in the schema, so the line suffix is stripped — no line
numbers in fingerprints, `audit-state-and-verify.md`). New journey-level slug:
`manifest-criticality-drift`. Both scopes route through the journey slot of the
precedence chain and dedup against `journey/uninstrumented` on the same
step/journey.

**Amendment flag ⟨CH-AMEND-A⟩ (fingerprint form):** the `audit-state-and-verify.md`
fingerprint scheme has only a `path:symbol` form (`<module>` for file-level) — it
has no journey-level slot for the two journey-scoped rows above. This register
defines the `<source>:<name>:<slug>` form for them; if the audit wants it
normative it is an additive amendment to `audit-state-and-verify.md`'s fingerprint
section (recorded here, not silently applied).

**The join keys exist in the real schema:** `journeys.json` v1 already carries
`emission_grade`, `alert_seam` (paged/dashboard-only/unknown/null),
`duplicate_guard` (present/absent/n/a), `compensation_note`, and `criticality`
(`references/journey-trace.md`); the comparator reads fields that are already
written, plus the CH-02 backref and step `event_name`. (Note: `event_name` was
absent from the `journeys.json` step schema in v1 AND would be in v2 without
CH-02 — hence CH-02 adds it as the one new discovered field the join needs.)

**Acceptance:**
- `[det]` `scripts/manifest_join.sh <manifest> <journeys.json>` emits a verdict
  row per MS §12 row against the CH-02 fixture pair; every one of the eight rows
  has a passing and a failing fixture case (`self_test.sh`); the OBSERVED/
  LOG-ONLY/DARK satisfaction lattice and the paged←paged seam lattice each get
  their full truth table asserted. **Live:** the MS §13.4 fixture pair
  (`tests/fixtures/join/`) and `validate_manifest.sh` have both landed.
- `[det]` no-join fixture: absent backref + non-matching `name` → the row emits a
  Not-covered line, not a false drift finding (invariant 6).
- `[audit-run]` end-to-end drift-finding quality on a real repo (criticality
  intent-vs-derived especially — the derivation is agent judgment).

## B. Behavior-ID coverage — "who checks the checker" (MS §13.11)

### CH-04 — PR Gate diff-scoped mode: the diff-scoped audit surface [ADR 0003, MS §13.10]
The audit gains a diff-scoped mode (ADR 0003 names this a v1 requirement — the
whole-repo default was implicit). The **existing** `check_new_debt.sh` already IS
the diff surface for the debt classes: it takes a positional `BASE_REF`
(`check_new_debt.sh <BASE_REF>`), computes added-lines-with-`file:line`-prefixes
via `git diff -U0 "$BASE"` + an awk pass, and sources `debt_patterns.sh`. No new
`--diff` flag is added — the script's arg parser routes any non-flag token to
`BASE` (`*) BASE="$arg"`), so a `--diff` token would be swallowed as the base ref
and fail `git rev-parse`. The diff-scoped mode is therefore composed from **the
existing positional BASE_REF surface plus new sibling scripts** the PR-event
orchestrator invokes over the same range — NOT by growing `check_new_debt.sh`
(which is six grep classes over `diff_added()` and has no manifest reader, git-log
walk, or `journeys.json` read):

- **Per-diff (run against the diff range):**
  - the deterministic debt classes `check_new_debt.sh` already computes on
    `<BASE_REF>` (markers, suppressions, flaky-in-test-lines, vacuous/skip,
    stdout, commented blocks) — unchanged;
  - the memory-rot deterministic layer (CH-05, new sibling script);
  - the manifest coverage check (CH-06, new sibling script);
  - the SG-8 provenance check (CH-07, new sibling script — **comment-only**,
    ⟨CH-AMEND-C⟩, does not gate);
  - the history-based manifest checks (CH-09, new sibling script).
  These are the findings meaningfully "new in this diff." Each sibling takes the
  same `<BASE_REF>`/git-range the orchestrator passes `check_new_debt.sh`.
- **Whole-repo-only (NOT re-run per diff):** the journey walk + `journeys.json`
  write, the vitals/tx/complexity facets, jscpd, the file-size ladder, coverage
  ingestion — these need the whole tree and a manifest to be meaningful and
  belong to the scheduled ambient audit (ADR 0003 point 2). Diff mode reads a
  **prior** `journeys.json`/`state.json` if present (for rot-vs-journeys and
  coverage joins) and says so when absent (degrade, invariant 4) — it never
  triggers a full walk on a PR.

Ratchet semantics in diff mode: the ADR-0004 ratchet compares the diff's new debt
against the base — pre-existing debt never blocks (ADR 0004; `check_new_debt.sh`
already computes added-lines-only, so inherited debt is structurally invisible).

**Acceptance:**
- `[det]` a fixture diff-range asserts the per-diff sibling scripts fire on the
  positional `<BASE_REF>` and the whole-repo facets are NOT invoked (no
  `journeys.json` write in diff mode); `check_new_debt.sh`'s existing positional
  surface is reused verbatim (no `--diff` flag added — a `self_test` case asserts
  a `--diff` token is NOT a recognized flag, protecting the arg-parser contract).
- `[det]` a fixture asserts diff mode with a missing prior `journeys.json`/manifest
  degrades loudly (Not covered), never full-walks.
- `[audit-run]` the PR-event orchestrator invoking the diff-scoped siblings and
  posting findings (the long-running PR agent is wiring, not a checker — ADR
  0003; out of scope here, see non-goals).

### CH-05 — Memory-rot facet: deleted/renamed symbols still referenced [ADR 0003, ADR 0004]
A memory-rot facet (ADR 0003 point 1, the deterministic layer). Diff-scoped: for
each symbol/path a diff **deletes or renames**, grep the repo-resident memory —
the Verification Manifest (`event_name`, `test_name_hint`, journey/behavior IDs),
`audit/journeys.json`, as-built docs, ADRs (`docs/adr/`), and the manifest's
`interrogation.log` (the Decision Log's committed home; MS §3) — for surviving
references. PR bodies are the Decision Log's *other* home (CONTEXT.md) but are
GitHub API objects, not repo-resident files — so they stay in the semantic
(agent) layer, or arrive as a supplied PR-body arg the diff mode already passes
CH-06; the deterministic grep set is committed files only (hermetic).
Deterministic-vs-semantic split per ADR 0004:

- **Deterministic layer (blocking-class per ADR 0004):** a deleted/renamed
  symbol still referenced by manifest, journeys, docs, or ADRs — grep-provable,
  the exact ADR-0004 blocking class. Tombstone-aware: a symbol whose manifest
  entry is `lifecycle: withdrawn` with a `withdrawn_reason` (MS §6) is
  **intentionally removed**, not rotted — the facet depends on tombstones to
  distinguish the two (MS §6). A rename detected via `git log --follow` /
  symbol-grep (the existing `audit-state-and-verify.md` rename-is-not-closure
  machinery) updates the reference target rather than flagging rot.
- **Semantic layer (comment-only per ADR 0004):** an agent judges drift on the
  flagged excerpts only (ADR 0003 — "agent layer judges semantic drift on the
  flagged excerpts") — an ADR the code now contradicts, a journey step through a
  path whose behavior changed. Agent opinion without deterministic evidence
  never blocks (ADR 0004 invariant).

**Acceptance:**
- `[det]` a fixture diff deleting a symbol that a fixture manifest/journeys/ADR
  still references → the deterministic rot layer emits a finding with slug
  `memory-rot-dangling-ref`; a fixture where the same deletion has a matching
  `lifecycle: withdrawn` tombstone → NO finding (tombstone suppresses).
- `[det]` a fixture rename (symbol moved, `git log --follow` resolves) → the
  reference target is updated, not flagged (reuses the existing rename machinery;
  fingerprint `aliases` list).
- `[audit-run]` the semantic-drift agent layer (ADR-contradiction judgment) —
  agent-scored, comment-only, blind-eval only.

### CH-06 — Behavior-ID coverage check: claimed vs proven [MS §13.11, ADR 0004]
The PR Gate's answer to "who checks the checker" (CONTEXT.md PR Gate; ADR 0003
consequence). A PR that touches behavior-bearing code carries a
`## Behavior coverage` section (behavior ID → test node IDs) — the autopilot
AV3-05 deliverable writes it in a documented grep-able format; human PRs may
carry it too. This facet verifies the CLAIM against PROOF:

- **Claimed:** behavior IDs in the PR body's `## Behavior coverage` section
  (grep-able) and/or the manifest's active behaviors touched by the diff.
- **Proven:** a RED commit in the diff's git log naming a bound test per behavior
  (the AV3-05 `audit_behavior_binding.sh` git-log evidence pattern) AND/OR the
  test node existing. Evidence is git-log + test-node existence — **not** the
  implementer's self-report (ADR 0003: "evidence from tests/git log, not the
  implementer's self-report").
- **Verdict:** a claimed behavior ID with no proving test/commit is the ADR-0004
  **blocking class** "manifest behavior-IDs claimed but unproven." Deterministic
  (git-log/grep-provable), so it may gate (ADR 0004 invariant).
- **Degrade:** manifest absent → skip the check, loud `[note]` (MS §11 PR-Gate
  row) — the coverage check never blocks a manifest-less PR.

**Acceptance:**
- `[det]` `scripts/check_behavior_coverage.sh <manifest> <pr-body> <git-range>`:
  a fixture PR-body section + a `git init`-inline git-log fixture (the
  `self_test.sh` section-5 precedent — git fixtures are constructible in the
  harness) where every claimed behavior has a RED commit → pass; a fixture with a
  claimed-but-unproven behavior → the blocking finding; a manifest-absent fixture
  → skip + `[note]`. This **matches the shape** of the AV3-05 PR-body format and
  its `audit_behavior_binding.sh` git-log convention — but `audit_behavior_binding.sh`
  is an *autopilot* deliverable (a producer in a different plugin), not reusable
  code here; this is a consumer parsing the same documented format.
- `[det]` the `## Behavior coverage` grep-able format is the one datum both
  plugins must agree on — pinned by the **repo-level consistency lint** (the
  ADR-0001 byte-identity vendoring lint, the same host that diffs the vendored
  manifest schema copies; codebase-health has no plugin-local consistency lint
  today — see CH-10). Both the autopilot AV3-05 producer and this consumer
  vendor the format from one source.
- `[audit-run]` real end-to-end coverage fidelity (does the bound test actually
  exercise the behavior — agent-judged).

## C. Provenance and history checks

### CH-07 — SG-8 provenance check + main-lineage ID reservation [spec-gen SG-8, MS §6]
The induced spec-gen requirement (SG-8, recorded there "for the codebase-health
register"). Two deterministic checks at the PR Gate:

- **Provenance:** a diff that touches manifest `confirmation`, `completeness`, or
  `interrogation.log` fields from a **non-spec-session branch** is flagged (the
  manifest has exactly ONE writer — the spec tier, MS §7; SG-8 hard-contract 1
  hand-edit defense). Branch provenance is deterministic (branch name /
  no-spec-session-marker); the finding is the ADR-0004 comment-only class by
  default (promoting it to blocking is a Bailey risk-appetite call, not an agent
  extension — see ⟨CH-AMEND-C⟩).
- **Main-lineage ID reservation:** ID reuse/renumber detection reserves IDs on
  **main's lineage only** (MS §6, ⟨MS-AMEND-3⟩ — never-merged branch revisions do
  not reserve; a Spec rejected at product approval frees them). This is the
  history half of CH-09's reuse/renumber check, scoped to main-lineage revisions.

**Amendment flag ⟨CH-AMEND-C⟩:** ADR 0004's blocking-class list (Bailey-accepted)
does NOT list the SG-8 provenance finding. Per MS §9's precedent (the spec_hash
rot finding "ships comment-only; promoting it into the ADR 0004 blocking-class
defaults is flagged for async human review"), this register ships the provenance
finding **comment-only** and flags the block-vs-comment decision for Bailey. No
silent ADR edit.

**Acceptance:**
- `[det]` `scripts/check_provenance.sh <diff> <branch-meta>`: a fixture diff
  touching `confirmation`/`completeness`/`interrogation.log` from a non-spec
  branch → provenance finding; from a spec-session branch → clean.
- `[det]` main-lineage reservation fixture: an ID present on a never-merged
  branch is NOT reserved; an ID on main's lineage IS (feeds CH-09).
- `[audit-run]` none — both halves are fully deterministic.

### CH-08 — Config-profile awareness for absence-severity [ADR 0006]
The manifest's `observability.profile` (ADR 0006) supplies WHICH vitals matter
for the LOB — the profile is pure data (a payments profile encodes the
vitals taxonomy, event vocabulary, alert seams). The audit reads the profile
name from the manifest (CH-01) and lets it modulate **absence-severity** without
overturning the 1.4.0 rubric cap:

- The manifest carries `observability.profile` as a **bare name string** (e.g.
  `payments`, MS §3) — the taxonomy/event-vocabulary/alert-seam *payload* is
  profile data (ADR 0006), not a file this plugin vendors or reads today. So the
  deterministic layer only reads the name and degrades on unknown; the profile
  actually steering which vitals are graded required-vs-optional (an `event_name`
  named per the profile's taxonomy, MS §4) is the agent + profile-data layer
  (`[audit-run]`), not a hermetic check.
- Absence severity still obeys the 1.4.0 amendment (`severity-rubric.md`):
  `journey/uninstrumented` reaches HIGH ONLY with a traced CORE money/auth path;
  everything else hard-caps MED needs-verification. The profile decides which
  steps are money/auth-class for the LOB (which vitals are required), but the
  cap and the HIGH-gate are unchanged — the profile raises the QUESTION floor,
  never the severity ceiling (mirrors the spec-gen "question floor, not prose
  ceiling" principle).
- Unknown profile → `default` (vendor-neutral) + loud `[note]`, comment-only
  finding (MS §11 unknown-profile row; CH-01).

**Acceptance:**
- `[det]` a fixture with a `payments`-profile manifest asserts the comparator
  reads the profile name and the unknown-profile fixture degrades to `default`
  + `[note]` (no crash, no silent default).
- `[det]` the absence-severity cap is unchanged: a fixture asserts a profile
  cannot push an untraced absence above MED (the 1.4.0 rubric gate holds
  regardless of profile).
- `[audit-run]` the profile actually steering which vitals are graded
  required-vs-optional on a real LOB repo — agent + profile-data-scored.

## D. History-based validator handoffs (MS §11/§13.11)

### CH-09 — spec_hash recompute · manifest_revision monotonicity · ID reuse/renumber [MS §9/§11/§13.11]
The three history-based checks the single-file validator **explicitly defers to
the PR Gate** (MS §11: "history checks belong to the PR Gate"; MS §13.11). All
git-history-based, all deterministic:

- **`spec_hash` recompute** (MS §9): recompute `sha256:` of the exact committed
  Spec bytes (`git show :<spec.path> | sha256sum`, byte-for-byte, blob-hashed —
  CRLF-safe) and compare to `spec.spec_hash`. Mismatch = a Spec edited without a
  matching `manifest_revision` bump = a **deterministic memory-rot finding**
  (MS §9). Per MS §9 it ships **comment-only** initially; promoting it into the
  ADR-0004 blocking defaults is flagged for async human review (MS §9 already
  records this — no new amendment). Guard (⟨MS-AMEND-1⟩): `spec_hash` is required
  only at `completeness: complete`; an incomplete manifest legitimately omits it,
  so the check runs only on complete manifests.
- **`manifest_revision` monotonicity** (MS §3/§13.11): compare the PR's
  `manifest_revision` against the previously committed revision on main's lineage;
  a non-monotonic (equal-or-lower with content change, or a skip) revision is a
  finding. Deterministic (git-diff of the committed manifest).
- **ID reuse/renumber detection** (MS §6/§11/§13.11): diff the PR's manifest IDs
  against prior main-lineage revisions (CH-07's main-lineage reservation); an ID
  reused for a different entry, or an entry renumbered, is the MS §11
  **blocking-class** finding "ID reuse/renumber vs prior revision (deterministic,
  git-history-based)." Tombstoned IDs remain reserved forever (MS §6) — reusing a
  tombstoned ID is a violation.

**Acceptance:**
- `[det]` `scripts/check_manifest_history.sh <manifest> <base-ref>` — takes a git
  **base-ref** (not a second file path), so lineage scoping and monotonicity are
  computed from committed history (`git show <base-ref>:<manifest>`), which is
  what distinguishes a main-lineage revision from a never-merged branch revision
  (CH-07); a two-path diff cannot. `self_test.sh` builds the fixture inline via
  `git init` + two commits on a lineage (the section-5 git-fixture precedent):
  spec_hash-mismatch fixture (edited Spec, unchanged revision) → comment-only rot
  finding; monotonicity fixture (revision N committed at base, PR ships N or N-1
  with a content change) → finding; ID-reuse fixture (behavior `B-x-001` reused
  for a different title) and renumber fixture → blocking finding; a tombstone-reuse
  fixture (reusing a `withdrawn` ID) → blocking. Each has a clean counterpart.
- `[det]` the byte-hash matches the manifest spec's `git show :<path> | sha256sum`
  definition exactly (shared fixture with the validator's spec_hash test — one
  definition; a committed git blob is fixture-constructible). **Live:**
  `validate_manifest.sh` has landed, so the shared spec_hash fixture is available.
- `[audit-run]` none — all three are deterministic by construction (that is why
  the validator defers them to the PR Gate rather than dropping them).

## E. Meta

### CH-10 — Self-test growth + consistency-lint host [1.4.0 house rules]
Every `[det]` acceptance above lands as a fixture + `self_test.sh` assertion
(red-first: fail on two consecutive runs before the detector exists, loop-safety
invariant 9). **Consistency-lint host:** codebase-health has no plugin-local
consistency lint today — `self_test.sh` is its only deterministic harness (the
`lint_consistency.sh` that exists is autopilot's). The byte-identity pins this
register needs (the vendored manifest schema copy — ADR 0001/MS §13.3 — and the
shared `## Behavior coverage` format, CH-06) route through the **repo-level
consistency lint** (MS §13.3's vendoring lint, the cross-plugin host), NOT a
codebase-health-local file that doesn't exist; standing up that repo-level lint
rule is a CH-10 deliverable if it isn't drained by the spec-gen/autopilot work
first. New fixtures extend `EXPECTED_FINDINGS.yaml` with the
manifest-drift / rot / coverage / provenance / history expected entries (each
tagged `expected_by: deterministic` or `expected_by: agent` per the honesty
clause — the manifest-join, spec_hash, monotonicity, ID-reuse, provenance, and
behavior-coverage-claim checks are deterministic; the semantic rot layer and the
criticality-derivation drift are agent). The manifest+`journeys.json` v2 fixture
pair (CH-02/CH-03, the MS §13.4 deliverable) lives under `test-fixtures/`.

**Acceptance:**
- `[det]` `self_test.sh` grows the CH-0x sections; every `[det]` item cites its
  assertion; planted violations go red; the repo-level byte-identity lint covers
  the vendored manifest schema copy (ADR 0001) and the shared `## Behavior
  coverage` format (CH-06).
- `[audit-run]` the blind-corpus eval extended per the 1.4.0 recurrence rule
  (fix E) — the agent-scored rows (semantic rot, criticality drift) scored there,
  never claimed as self-test coverage; date + git SHA recorded in GAPS_SPEC.

## Flagged amendments (Bailey must approve — no silent ADR/manifest edits)

Per the repo's culture (ADRs are Bailey-accepted; agents don't extend them
unilaterally — ADR 0004, MS §9), these are recorded here, NOT applied to the
governing docs:

- **⟨CH-AMEND-A⟩** — journey-level fingerprint form. `audit-state-and-verify.md`'s
  fingerprint scheme is `path:symbol:slug` (`<module>` for file-level) — it has
  no journey-level slot, but the §12 `criticality` and `journeys[].id`↔backref
  drift rows are journey-scoped (no single enclosing symbol). This register
  defines `<journey.source path>:<journey.name>:<slug>` for them (line-suffix
  stripped — no line numbers in fingerprints). Additive amendment to the audit's
  fingerprint section if Bailey wants it normative.
  *(Note: the `journeys.json` `schema_version` 1→2 bump is NOT an amendment — MS
  §13.10 already names the target "journeys.json v2"; CH-02 merely executes it.)*
- **⟨CH-AMEND-B⟩ — RESOLVED, not flagged.** MS §12 row 2's `event_name` join had
  no discovered-side field (`journeys.json` steps carry `emission_grade` only, in
  both v1 and v2-without-this-change, and `telemetry.txt` has no symbol column to
  scope a per-step join). CH-02 adds an OPTIONAL step-level `event_name` to
  `journeys.json` v2 — the additive-field route — making the row a real
  string-equality join. This is an additive `journeys.json` schema field (audit's
  own artifact, one-writer-is-the-audit), not a manifest-spec/ADR change, so it is
  applied in CH-02 rather than left as a flag; recorded here for visibility.
- **⟨CH-AMEND-C⟩** — SG-8 provenance finding block-vs-comment. Ships comment-only
  (MS §9 spec_hash precedent). Promoting it into the ADR-0004 blocking defaults is
  a Bailey risk-appetite call; not extended by this register.

## The `[det]` / `[audit-run]` split (honesty note)

Deterministic, hermetic, self-test-assertable (`[det]`): manifest ingestion +
MODE token (CH-01), `journeys.json` v2 parse (CH-02), the §12 join truth tables
(CH-03), diff-scoped per-diff-class dispatch (CH-04), the deterministic rot layer
+ tombstone suppression (CH-05), behavior-coverage claim-vs-git-log (CH-06),
provenance + main-lineage reservation (CH-07), profile read + cap-holds (CH-08),
spec_hash / monotonicity / ID-reuse (CH-09), self-test wiring (CH-10). These are
grep/git-log/fixture-provable and gate on the CI surface only. The
manifest-reading ones (CH-01/03/06/08/09) **are now live**: the spec-gen
`validate_manifest.sh` + vendored schema + MS §13.4 fixture pair have landed at
the repo root (see Dependencies), so these acceptances are self-test-assertable
today — deterministic, and no longer deferred.

Measured only in real runs + blind eval (`[audit-run]`, never claimed as
automated coverage): the orchestrator honoring MODE (CH-01), backref/`event_name`
match quality (CH-02), end-to-end drift quality incl. criticality-derivation
(CH-03), the PR-event orchestrator invoking the diff-scoped siblings (CH-04), the
semantic ADR-contradiction rot layer (CH-05), whether a bound test really
exercises a behavior (CH-06), profile-steered required-vitals grading (CH-08), the
extended blind eval (CH-10). No hermetic coverage is claimed for any LLM-agent
judgment.

## Non-goals for this register

- **Merge Marshal** (ADRs 0010/0011 — the fourth plugin). The PR Gate produces
  findings and a CI-surface exit code; the Marshal is separate serial merge
  wiring and holds no quality opinion. Not here.
- **Remediation-loop wiring** — feeding PR-Gate findings back into a spec-gen
  `--amend` or an autopilot re-plan (the findings-register input class is
  first-class in spec-gen but the automation is future scope). Not here.
- **The long-running ADLC/PR-review agent** — the wiring that schedules on PR
  events, invokes the diff-scoped mode + the coverage check, and posts findings
  (ADR 0003: "wiring, not a checker"). This register specs the checker modes it
  invokes, not the scheduler.
- **New whole-repo detection categories** — the 1.5.0/1.6.0/1.7.0 gap packs
  (`docs/SYSTEM_DESIGN_COVERAGE_2026-07-04.md`: money-as-float, concurrency,
  resilience, contract-evolution). Independent roadmap; this register is the
  manifest-integration + PR-Gate step only (the 1.7.0 train's manifest-field
  consumers overlap CH-03/CH-08 but are not blocked on them).
- **Authoring the manifest, journeys, or as-built docs** — the audit VERIFIES
  intended-vs-discovered and reports drift; it never authors either (CONTEXT.md
  Journey; MS §7 one-writer rule). No item here writes the manifest.
