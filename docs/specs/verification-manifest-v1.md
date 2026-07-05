# Verification Manifest — Schema v1 Specification

> Status: DRAFT r2 (adversarial round 1 applied: 40 findings from two independent
> attackers — corpus-consistency and consumer-simulation lenses — all P0/P1 closed,
> P2/P3 closed or explicitly recorded) · 2026-07-03
> Governing decisions: ADR 0001 (manifest contract, vendoring), ADR 0002 (escalation),
> ADR 0003 (PR Gate consumes coverage), ADR 0005 (GWT behaviors), ADR 0006 (profiles,
> environment as primitive), ADR 0007 (Story granularity), ADR 0008 (straight-through drains).
> Vocabulary: CONTEXT.md is normative for every capitalized term.

## 1. Purpose and position

The Verification Manifest is the machine-readable companion a Spec ships with. It is the
single join key across the suite: the spec tier **produces** it; autopilot and the audit
**consume** it. Consumption is **target-state**: today's autopilot and audit implement none
of it — §13 enumerates every induced consumer requirement, per the ADR 0003 precedent of
naming them explicitly.

The manifest is the *intended* counterpart of the audit's *discovered* trace
(`audit/journeys.json`). They are joined through the explicit field mapping in §12 — the
vocabularies overlap (`vital_class`, the criticality ladder, alert-seam terms) but are not
identical, and nothing in this spec pretends otherwise.

The manifest is **not** a spec, a plan, a tracker, or an as-built record. Prose lives in
the Spec; task decomposition lives in the runbook; test-ID bindings live downstream (§7).

## 2. File identity and parsing

- **Format:** YAML, parsed with a YAML 1.2 core-schema parser. A boolean or any non-string
  in an enum position is schema-invalid (exit 4) — this is the whole Norway-problem
  defense; no raw-text scanning is required or permitted.
- **Validation layering (normative):** the vendored JSON Schema
  (`schema/verification-manifest/v1.schema.json`) enforces ONLY structure: types, enums,
  ID regexes (§6), required/optional per §3's table, and `incomplete_fields` non-empty
  iff `completeness: incomplete`. The §10 completeness rules MUST NOT be schema-enforced —
  an incomplete manifest is always schema-valid, so a resumed spec-tier session can load it.
- **Location & name:** colocated with its Spec as `<spec-basename>.manifest.yaml`.
- **One Spec → one manifest.** For multi-doc invocations (`--generate @a.md @b.md`):
  IDs (§6) MUST be unique across the union; a union-time collision is
  `[GENERATE-FAILED: manifest-id-collision]`. `observability.profile` and `environments`
  MUST be identical across unioned manifests; mismatch is
  `[GENERATE-FAILED: manifest-union-mismatch]`. (Induced autopilot requirement — §13.)

## 3. Top-level structure

```yaml
schema_version: 1            # integer; see §8
manifest_revision: 1         # integer; REQUIRED; first finalized revision is 1;
                             # monotonicity is verified by the PR Gate against the
                             # previously committed revision (not by the validator)
spec:
  path: ./loan-pricing-adr.md   # relative to the manifest file
  title: "Loan pricing engine"
  spec_hash: "sha256:<64 lowercase hex>"   # §9 defines the exact input bytes; REQUIRED iff
                                           # completeness: complete — MAY be absent while
                                           # incomplete (mid-session, the Spec prose may not
                                           # be committed yet)
completeness: complete       # complete | incomplete   (top-level; per-entry state is
                             # `lifecycle:` — deliberately different field names)
incomplete_fields: []        # non-empty iff incomplete; entry grammar §10
observability:
  profile: payments           # Config Profile name (ADR 0006); "default" = vendor-neutral
environments: [dev, test, prod]  # the primitive; env-keyed maps use exactly the reserved
                                 # key `default` plus zero or more keys from this list
interrogation:               # the spec-time record (see note below on Decision Log)
  adrs: []                   # paths of ADRs created during interrogation
  log:
    - id: DL-001             # per-manifest scope
      summary: "Duplicate wire → reject-and-alert, not silent dedupe"
      resolved_by: human     # agent | human (ADR 0002)
      dissent: ""            # REQUIRED (non-empty) when resolved_by: agent; optional otherwise
      exchange_ref: ""       # optional path/anchor to the recorded human exchange
journeys: []                 # §4
behaviors: []                # §5
```

**Required/optional table (top-level):** `schema_version`, `manifest_revision`, `spec`
(with `path`, `title`; `spec_hash` required iff complete), `completeness`, `observability.profile`,
`environments` (≥1 entry), `journeys`, `behaviors` are REQUIRED (empty lists legal —
but see §10 rule 0). `incomplete_fields` REQUIRED iff incomplete. `interrogation`
optional; when present, per-entry fields as annotated above.

**Decision Log note:** the Decision Log's canonical homes are the tracker + PR body
during drains (CONTEXT.md) and the manifest's `interrogation.log` during spec sessions —
the CONTEXT.md definition is extended accordingly in this change.

## 4. Journeys

```yaml
journeys:
  - id: J-pricing-001        # §6 grammar
    name: "Rate lock end-to-end"
    lifecycle: active        # active | withdrawn; withdrawn REQUIRES withdrawn_reason
    criticality: CORE        # CORE | SUPPORTING | DEV — same three values as the audit
                             # ladder, but DECLARED here (with criticality_reason), not
                             # derived; the audit derives its own, and intent-vs-derived
                             # drift is an audit finding
    criticality_reason: "Money movement; customer-facing rate commitment"
    confirmation: confirmed  # confirmed | proposed (criticality-scoped rigor; §10 rule 4)
    confirmed_by: DL-001     # REQUIRED for effectively-CORE entries with confirmation:
                             # confirmed — references an interrogation.log entry with
                             # resolved_by: human (§10 rule 8); optional otherwise
    steps:
      - name: "Lock request accepted"
        vital_class: state-transition   # REQUIRED on every step; one of
                                        # money | state-transition | external-side-effect
                                        # | auth | null (explicit null; absent key = invalid)
        # When vital_class is null: required_emission, alert_seam, and event_name MUST be
        # absent (schema-enforced); idempotency MAY appear.
        required_emission: OBSERVED     # OBSERVED | LOG-ONLY. DARK is never a valid intent.
        event_name: rate_lock.accepted  # REQUIRED when vital_class is non-null; the
                                        # intended-vs-discovered join key (§12); named per
                                        # the profile's taxonomy
        alert_seam:                     # env-keyed map: `default` REQUIRED, other keys ⊆ environments
          default: dashboard-only       # paged | dashboard-only | none  (§12 maps these
          prod: paged                   #   to the audit's discovered values)
        idempotency:                    # REQUIRED when vital_class is money or
                                        # external-side-effect; optional otherwise
          required: true
          mechanism: idempotency-key    # idempotency-key | duplicate-guard | upsert |
                                        # transactional-outbox | not-needed
          justification: "Client retries on timeout; duplicate lock = double commitment"
        compensation:                   # REQUIRED when idempotency is required; structured:
          ref: J-pricing-003            #   {ref: <journey id>} XOR {none_reason: "<why>"}
```

## 5. Behaviors

```yaml
behaviors:
  - id: B-pricing-001        # §6 grammar
    title: "Rejects expired rate lock"
    lifecycle: active        # active | withdrawn (+ withdrawn_reason)
    journey: J-pricing-001   # optional (pure-library specs may omit); MUST reference an
                             # existing journey; referencing a withdrawn journey is legal
                             # but then criticality MUST be explicit
    criticality: CORE        # REQUIRED when journey is absent or withdrawn; otherwise
                             # optional, defaulting to the journey's. §10 rules apply to
                             # EFFECTIVE criticality (after inheritance).
    confirmation: confirmed  # §10 rule 4 applies to effective criticality
    confirmed_by: DL-001     # as on journeys: REQUIRED when effectively-CORE + confirmed (§10 rule 8)
    given: "A rate lock created 46 days ago with a 45-day term"
    when: "The borrower requests to exercise the lock"
    then: "The request is rejected with RateLockExpired and vital rate_lock.expired is emitted"
    test_name_hint: "test_rejects_expired_rate_lock"   # hint only; binding lives downstream (§7)
```

GWT fields are prose but MUST use CONTEXT.md canonical terms, and each MUST name an
observable trigger and outcome. **Enforcement is honestly split:** the deterministic
validator checks only non-emptiness (§10 rule 3); observable-trigger quality is a
spec-tier judgment gate applied BEFORE finalization (a conforming spec tier never
finalizes "handles errors gracefully") and is re-judged downstream by plan review and
the PR Gate's agent layer. It is NOT part of `incomplete_fields`.

## 6. ID grammar, stability, and amendment

- **Grammar (schema-enforced):**
  - Journey: `^J-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{3}$`
  - Behavior: `^B-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{3}$`
  - Interrogation log: `^DL-[0-9]{3}$` (no slug; per-manifest scope)
  - The numeric suffix is the FINAL hyphen-delimited token, always exactly 3 digits
    (`001`–`999`); the slug is everything between the type prefix and the suffix.
    At 999, allocate a new slug — suffixes never grow a fourth digit.
- IDs are **never reused and never renumbered**. Reservation scope is **main's lineage**:
  revisions on never-merged branches do not reserve IDs (a Spec rejected at product
  approval frees them). Reuse/renumber detection requires history and is therefore owned
  by the **PR Gate** (diffing main-lineage revisions), not the single-file validator (§11).
- Amendment = a new `manifest_revision` landing by PR, produced by a spec-tier session.
- Removal is a **tombstone**: `lifecycle: withdrawn` + non-empty `withdrawn_reason`
  (§10 rule 7). Tombstoned IDs remain reserved forever. The memory-rot facet depends on
  tombstones to distinguish "intentionally removed" from "rotted".
- **Mid-drain amendment (normative):** autopilot checks `manifest_revision` at every fire's
  hydrate step. On drift: the in-flight Subtask completes its current commit pair, then the
  drain halts with `STATUS: PAUSED — manifest-revision-drift` (not `--force`-bypassable;
  external-fault class, no counter increment). Open draft Story PRs stay draft. Resume
  requires re-GENERATE against the new revision; §6's stability rules guarantee that
  Subtasks whose Behavior IDs survived are re-plannable without rework. (Induced autopilot
  requirement — §13.)
- Renaming a vital step's `event_name` is semantically withdrawal+addition; record it in
  `interrogation.log`. Drift is visible mechanically via the §12 join.

## 7. Ownership: the one-writer rule

The manifest has exactly ONE writer: the spec tier (via PR). Downstream tiers read only:

| Datum | Lives in | Written by |
|---|---|---|
| Behavior intent (GWT, IDs) | manifest | spec tier |
| Subtask → Behavior-ID mapping | runbook/tracker | autopilot planner (G3) |
| Behavior-ID → concrete test IDs | tracker (D7.4) + Story PR body (D7.3) | autopilot dispatcher; **verified** at D6 from git log/test run |
| Coverage verdict per PR | PR Gate report | audit tier |
| Discovered journey trace | `audit/journeys.json` | audit journey-walker |

(Per CONTEXT.md, the as-built journey doc itself is authored by the implementer alongside
the code; `journeys.json` is the audit's *trace*, not the as-built doc.)

## 8. Versioning and vendoring

- `schema_version` is a single integer. v1 is **additive-only**: consumers MUST ignore
  unknown fields; any breaking change is v2.
- Consumers pin supported versions and **refuse newer majors** with
  `[MANIFEST-UNSUPPORTED: schema_version N > supported M]` — never best-effort parse.
- The JSON Schema is vendored byte-identical into each plugin (ADR 0001); the repo-level
  consistency lint diffs the copies and fails on drift.

## 9. Rot link: `spec_hash`

`spec.spec_hash` is `sha256:` + the lowercase-hex SHA-256 of the **exact committed bytes**
of the Spec file (`git show :<spec.path> | sha256sum` — byte-for-byte, no normalization;
CRLF working-tree checkouts don't affect it because the blob is hashed, not the checkout).
A Spec edited without a matching `manifest_revision` bump is a deterministic memory-rot
finding. It ships **comment-only**; promoting it into the ADR 0004 blocking-class defaults
is flagged for async human review (ADR 0004's list is Bailey-accepted; agents don't extend
it unilaterally).

## 10. Completeness rules

`completeness: complete` is legal only when ALL rules hold. Rules 0–7 are machine-checkable
by the single-file validator. They fall in two classes, per ADR 0002: **(a) mechanical
validity** — an agent MUST fix these itself before finalizing (never surfaced to a human);
**(b) unanswered MUST-escalate fields** — the questions only a human may answer. Only
class (b) items are the ADR 0002 "escalation residue"; both classes block completeness.

Rules 1–4 quantify over `lifecycle: active` entries ONLY; criticality means EFFECTIVE
criticality (§5).

0. *(mechanical)* At least one active behavior exists. (An empty manifest must never
   trigger an ADR 0008 straight-through drain.)
1. *(escalate — observability intent)* Every active journey's step with non-null
   `vital_class` has `required_emission`, `event_name`, and `alert_seam.default`.
2. *(escalate — risk appetite)* Every step with `vital_class: money` or
   `external-side-effect` has `idempotency` with `required` answered and, when
   `mechanism: not-needed`, a non-empty `justification`; `compensation` present
   (`ref` XOR `none_reason`).
3. *(mechanical)* Every active behavior has non-empty `given`/`when`/`then`.
4. *(escalate — confirmation)* Every effectively-CORE active journey and behavior has
   `confirmation: confirmed`.
5. *(mechanical)* No dangling `journey:` or `compensation.ref` refs; no duplicate IDs
   within the file; every env key used is `default` or ∈ `environments`.
6. *(mechanical)* Every `resolved_by: agent` entry has non-empty `dissent`.
   (Whether a `resolved_by: human` entry corresponds to a real surfaced exchange is a
   spec-tier session obligation — optionally evidenced via `exchange_ref` — NOT a
   validator rule; it is not checkable from the file.)
7. *(mechanical)* Every withdrawn entry has non-empty `withdrawn_reason`.
8. *(mechanical)* Every effectively-CORE active entry with `confirmation: confirmed` has
   `confirmed_by` referencing an existing `interrogation.log` entry with
   `resolved_by: human`. (Makes the no-agent-path-to-confirmed-CORE contract
   file-checkable; the spec-gen tier is the enforcement point, this rule is the backstop.)

**`incomplete_fields` entry grammar:** `"rule-<n>: <path>"` where `<path>` is a
JSONPath-like locator using IDs, e.g.
`"rule-1: journeys[J-pricing-001].steps[0].alert_seam.default"`. The spec tier echoes
each entry as `[SPEC-INCOMPLETE: rule-<n>: <path>]`.

An incomplete manifest is schema-valid (§2 layering) and consumable by nothing except a
resumed spec-tier session; autopilot treats it as manifest-less input (ADR 0008
GENERATE+pause path).

## 11. Consumer degrade rules (normative)

| Situation | Consumer behavior |
|---|---|
| Manifest absent | Autopilot: GENERATE+pause (ADR 0008). Audit: heuristic journeys, severity caps per its spec. PR Gate: skip coverage check, loud `[note]`. |
| `completeness: incomplete` | As absent, except a spec-tier session may resume it. |
| Unsupported `schema_version` | Refuse `[MANIFEST-UNSUPPORTED]`. |
| Schema-invalid (exit 4) | Refuse; report the schema error; never degrade to manifest-less. |
| `spec_hash` mismatch | Deterministic rot finding (§9, comment-only initially); consumers proceed on the manifest, flag the Spec. |
| Unknown `observability.profile` | Proceed with `default` profile + loud `[note]`; the finding is comment-only. |
| Unknown fields (same major) | Ignore silently. |
| ID reuse/renumber vs prior revision | PR Gate blocking-class finding (deterministic, git-history-based). |

**Validator exit codes** (`scripts/validate_manifest.sh <file>`): 0 complete ·
3 incomplete (prints `incomplete_fields`) · 4 schema-invalid · 5 unsupported version.
Single-file, hermetic; history checks belong to the PR Gate.

## 12. Intended ↔ discovered mapping (the join)

| Manifest (intent) | `journeys.json` (discovered) | Join / comparison rule |
|---|---|---|
| `journeys[].id` | *(v2 backref)* `manifest_journey_id` | Exact; backref is an induced audit requirement (§13). Until it ships: exact `name` match, fuzzy = no join, say so. |
| `steps[].event_name` | emitted event name in the step's `emission_grade` evidence | Exact string; this is why `event_name` is required on vital steps. |
| `required_emission: OBSERVED` | `emission_grade` | Satisfied by OBSERVED only. |
| `required_emission: LOG-ONLY` | `emission_grade` | Satisfied by OBSERVED or LOG-ONLY. DARK never satisfies. |
| `alert_seam` (intent: paged / dashboard-only / none) | `alert_seam` (discovered: paged / dashboard-only / unknown / null) | paged ← paged only; dashboard-only ← paged or dashboard-only; none ← anything. Discovered `unknown` satisfies nothing except intent `none` (needs-verification, not violation). Env-keyed intent compares against the audited environment. |
| `idempotency.required: true` | `duplicate_guard` | Satisfied by `present`; `absent` on a traced money path escalates per the audit's tx lens; `n/a` = needs-verification. |
| `compensation` | `compensation_note` | Informational join; no pass/fail. |
| `criticality` (declared) | `criticality` (derived) | Mismatch = audit finding (intent-vs-derived drift), MED needs-verification. |

## 13. Deliverables and induced consumer requirements

**This repo (drains from this spec):**
1. `schema/verification-manifest/v1.schema.json` — structure only, per §2 layering.
2. `scripts/validate_manifest.sh` — schema check + §10 rules; exit codes per §11; hermetic
   self-test with fixtures: valid-complete, incomplete (each rule), boolean-in-enum,
   dangling ref, intra-file duplicate ID, withdrawn-without-reason, empty-behaviors-complete.
3. Vendoring lint rule (byte-identical schema copies) in the repo consistency lint.
4. Fixture pair: a manifest + a hand-authored `journeys.json` for a toy repo exercising
   every §12 row, with the expected comparison verdicts asserted.

**Induced — autopilot (goes in the autopilot-v3 register, not implemented today):**
5. Mode inference (ADR 0008): valid+complete manifest → straight-through; else pause path.
6. G2/G3: planner maps every Subtask to active Behavior IDs; `[GENERATE-FAILED:
   unmapped-subtask]` when it can't.
7. G4: union ID-collision + profile/environments-mismatch refusals (§2).
8. D1: `manifest_revision` drift check (§6, external-fault class).
9. D7.3/D7.4: Behavior-ID → test-ID binding section in Story PR body + tracker; D6
   verifies bindings from git log/test run.

**Induced — audit / PR Gate (goes in the codebase-health register post-migration):**
10. Manifest ingestion + §12 comparator; `manifest_journey_id` backref in journeys.json v2.
11. PR Gate: coverage check (behavior IDs claimed vs proven), ID reuse/renumber detection,
    `spec_hash` recompute, `manifest_revision` monotonicity.
