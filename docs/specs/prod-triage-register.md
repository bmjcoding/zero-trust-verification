# Production-Telemetry Triage Plugin — Change Register (prod→spec source, HARDENED r2)

> Status: HARDENED r2 (adversarial critique applied) · new plugin `triage` (fifth PLUGIN,
> NOT a fifth Tier — CONTEXT.md fixes "Tier" at three; ADR 0011 already established a fourth
> non-tier plugin, Marshal). GAPS_SPEC register style, mirrors autopilot-v3-register.md and
> codebase-health-register.md.
>
> Acceptance vocabulary (tightened for honesty):
>   `[det]`        = hermetic self_test.sh / lint assertion — grep / fixture / exit-code-provable,
>                    zero live telemetry, zero dependence on any UNBUILT artifact.
>   `[det-cond]`   = deterministic BUT gated on a dependency that is not yet built in this repo
>                    (specifically the journeys.json v2 backref, codebase-health CH-02). Runs
>                    hermetically ONLY against a triage-owned fixture the plugin ships itself;
>                    the claim is explicitly NOT 'the suite already proves this end to end'.
>   `[drain]`      = measured only in a real triage run against a live backend + manual
>                    incident-eval (the suite's honest-residual convention — never automated coverage).
>
> Sources verified against the working tree (not asserted): CONTEXT.md (Tier=three; Vital,
> Journey, Spec, Verification Manifest, Config Profile — normative); ADR 0002 (escalation);
> ADR 0006 (OTEL vendor-neutral, profiles, agent-first); ADR 0011 (fourth plugin = wiring, the
> non-tier-plugin precedent this one follows); ADR 0013 (host-agnostic adapter, host.sh detect
> matrix at scripts/host.sh:60-74); ADR 0014/0015 (validator toolchain, uv substrate);
> ADR 0001 (vendoring lint, scripts/lint_consistency.sh V1-V6). Manifest spec §4 (env-keyed
> maps, `environments` primitive), §5 (behaviors), §10 (completeness grammar `rule-<n>: <path>`),
> §11 (validator exit 0/3/4/5 + degrade rows), §12 (the join — READ CAREFULLY BELOW), §13
> (induced consumers). Reused artifacts confirmed present: scripts/validate_manifest.sh,
> plugins/spec-gen/scripts/{profile_resolve.py,resume_projection.py}, plugins/autopilot/scripts/{host.sh,
> secret_get.sh}, tests/fixtures/join/{manifest.yaml,journeys.json}.
> Baseline: greenfield plugin dir plugins/triage/; NO greenfield infra.

## 0. Position and posture (read first) — CORRECTED FRAMING

**This is a fifth PLUGIN, not a fifth Tier, and not a closed ring.** CONTEXT.md's `Tier` glossary
entry is normative: exactly three tiers (Spec Generation, Autopilot, Audit) cover the ADLC
*left-to-right*. ADR 0011 already added a fourth plugin (Marshal) that is deliberately NOT a tier
('wiring, not a checker'). `triage` follows that precedent: it is an independently installable
plugin that acts as a new SOURCE feeding the existing left edge (spec-gen), not a fourth stage of
the left-to-right pipeline and not a new quality opinion. The r1 draft's 'fifth tier' /
'closes the ADLC ring prod→spec' framing is REJECTED as a vocabulary contradiction; the honest
claim is narrower and still valuable: prod telemetry becomes a first-class *input* to spec-gen,
the same way a human-authored incident report already can be.

**What the manifest actually gives us (critique correction — do not overclaim).** §12's event_name
join discovered-side is literally 'emitted event name in the step's `emission_grade` evidence' — an
AUDIT observation, a static discovered field, NOT a runtime stream. §12 was authored for
intent↔audit, not intent↔runtime. The r1 claim that the manifest 'links runtime emission to
design-time intent BY CONSTRUCTION' OVERCLAIMS: what exists by construction is that the manifest's
`event_name` is the SAME string the implementer emits at runtime (§6: renaming event_name is
withdrawal+addition, drift visible via §12). So a runtime window CAN join on `event_name` with no
new key — but this is a NEW third source we are introducing, not a join the spec already performs.
Honest thesis: *we reuse the §12 key vocabulary for a new (runtime) source table*; we do NOT
inherit a proven runtime join. This distinction drives the [det]→[det-cond] demotions below.

**Hard invariants (release blockers):**
- **Read-only on prod and on the repo target.** Queries telemetry; writes exactly one artifact
  class (`triage/` + a drafted incident-Spec on a branch/draft-PR). NEVER mutates a running
  system, NEVER auto-merges, NEVER authors a fix.
- **The deliverable is a Spec, not a patch.** Output plugs into spec-gen's *resume* path (§10:
  an incomplete manifest is consumable by nothing except a resumed spec-tier session). The loop
  re-enters at the LEFT edge — interrogation then a gated drain — never a hotfix bypass.
- **Vendor-neutral by contract (ADR 0006 + ADR 0013).** Backends behind one `telemetry.sh`
  surface; `default` = OTEL/OTLP-JSON (hermetic + community). CloudWatch/Dynatrace are backend
  *selections*, never a caller-path branch. Bailey's env is config, not architecture.
- **Degrade to less action (suite rule 4).** No manifest / unknown profile / empty window /
  backend returns nothing → say so, do less, escalate the gap; never fabricate a join and never
  guess an incident-Spec from an un-joined signal.
- **BOUNDED-WINDOW-ONLY — the cost invariant (the mutation-testing analog).** `window` MUST be
  bounded by an explicit `--since/--until` AND scoped by `--service`/`--event`; it MUST NEVER
  issue a full-retention or whole-fleet scan. This is the direct analog of the suite's
  never-run-mutation-across-the-whole-repo rule (codebase-health whole-repo facets are
  NOT-re-run-per-diff and diff-scoped; audit grew `--diff` in ADR 0003 for exactly this reason).
  An unbounded/absent window is a refuse-condition, not a default-to-everything. Enforced by a
  [det] guard (TR-01).
- **NO SELF-INGESTION / LOOP GUARD (new, TR-loop-guard).** The tier MUST NOT correlate on events
  it or a prior incident-Spec's still-open PR emitted, and MUST NOT emit a second incident-Spec
  for an incident whose incident-Spec PR is still open. Prevents infinite regress.

**Non-goals (explicit, unchanged from r1 + one addition):**
- NOT an alerting/paging system (consumes an incident that already fired; does not decide to page).
- NOT a dashboard/APM replacement (ADR 0006 dashboards are the human compat layer; this is the
  agent-first primary consumer, orthogonal).
- NOT a metrics/SLO/error-budget computer.
- NOT a root-cause fixer (names the drifted behavior/journey, drafts the Spec; fix is the drain).
- NOT a new join key (reuses §12's `event_name` verbatim).
- NEW: NOT a replacement for or duplicate of the audit's intent↔discovered join (CH-03). The
  audit joins intent↔*audit-discovered* (static, from a code walk); this joins intent↔*runtime-
  observed* (a live window). Same key vocabulary, different source table, different data direction.

## Dependencies and landing order

**TR-01 → TR-02 → TR-loop-guard → TR-03 → TR-04 → TR-05 → TR-06 → TR-07 → TR-08.**

TR-01 (adapter surface + bounded-window guard) is the substrate. TR-02 (incident-window schema)
is what TR-03 joins. TR-loop-guard lands before TR-03 so the correlation can never see self-
emitted events. TR-03 (the correlation) reuses §12's key + the vendored validator, but SEE its
[det-cond] gating on CH-02. TR-04 (profile resume) reuses spec-gen's resolver. TR-05 (incident-
Spec emitter) is the deliverable. TR-06 (agent prompt) orchestrates. TR-07 (spec-gen resume
handoff). TR-08 grows self_test + extends lint (V7 telemetry contract, V5 tier-set 4→5).

---

## A. Ingestion (vendor-neutral, ADR 0006 + ADR 0013)

### TR-01 — Telemetry adapter surface + bounded-window guard [ADR 0006, ADR 0013]
`plugins/triage/scripts/telemetry.sh <subcommand>`, modeled on plugins/autopilot/scripts/host.sh
(verified detect matrix at :60-74). Callers never name a vendor.
Subcommands: `window --since <ts> --until <ts> [--service S] [--event E]` → normalized incident-
window NDJSON (TR-02) on stdout; `probe` → reachability/auth (exit 0/non-zero+reason); `backend`
→ detected backend id (host-local).
Backend detection (first match wins), mirroring host.sh but WITHOUT an origin heuristic:
  1. `$TRIAGE_TELEMETRY_BACKEND` authoritative (`OTEL_FILE | CLOUDWATCH | DYNATRACE`).
  2. committed `triage.config.yaml` `telemetry.backend:` key.
  3. else REFUSE, pointing at `$TRIAGE_TELEMETRY_BACKEND`. Deliberate difference from host.sh:
     host.sh sniffs Bitbucket-vs-GitHub from the origin URL; there is NO origin-equivalent for a
     telemetry vendor, so absence is an ADR 0002 external-fact escalation, never a guessed default.
Backends: `otel_file.sh` (default; OTLP/OTEL-JSON logs file — hermetic + community), `cloudwatch.sh`
(Logs Insights), `dynatrace.sh` (Grail/DQL). Secrets via the existing plugins/autopilot/scripts/secret_get.sh
chain — tokens never enter agent context.
**Bounded-window guard (the cost invariant, made mechanical):** `window` REFUSES if `--since`/
`--until` are absent, if the span exceeds a configured max (`triage.config.yaml`
`window.max_span`, default 24h), or if neither `--service` nor `--event` is given on a backend
whose retention is unbounded. No implicit 'scan everything'.
**Acceptance:**
- `[det]` `telemetry.sh backend` returns the env-override; unset+no-config REFUSES with the
  escalation message (fixtures: override / config / neither) — mirrors host.sh's detect matrix.
- `[det]` `otel_file.sh window` over a committed OTLP-JSON fixture emits TR-02 NDJSON; a
  `--since/--until` fixture proves the window bounds output; empty window → empty output + exit 0.
- `[det]` the bounded-window guard: `window` with no `--since/--until` REFUSES (exit non-zero +
  reason); a span over `window.max_span` REFUSES; a scoped bounded window passes. THIS is the
  never-whole-repo teeth.
- `[det]` CloudWatch and Dynatrace backends produce SCHEMA-VALID TR-02 records (validated by the
  TR-02 jsonschema, not eyeballed) from canned API-response fixtures — no live call. 'works on
  CloudWatch'/'works on Dynatrace' = the same jsonschema assertion (ADR 0013 discipline).
- `[drain]` a real `window` against a live backend returning real vitals — measured, never hermetic.

### TR-02 — Normalized incident-window schema [MS §4/§12]
`triage/incident-window.schema.json` (vendored JSON Schema, ADR 0001). Vendor-neutral shape every
backend's `window` emits, carrying EXACTLY the §12 discovered-side field names so TR-03 joins one
schema regardless of source:
  `event_name` (string; the §12 join key), `vital_class`
  (money|state-transition|external-side-effect|auth|null), `service`, `env` (∈ the manifest's
  `environments` primitive — §4), `timestamp`, `trace_id`/`span_id` (OTEL, ADR 0006), `severity`,
  `count`, `attributes` (backend passthrough, ignored by the join), and `emitter` (NEW — the
  producing service/agent identity, consumed by TR-loop-guard to exclude self-emitted events).
A record missing `event_name` is DARK-in-prod (unjoinable), bucketed separately, never dropped.
NO `manifest_journey_id` in a window record — telemetry has no design-time IDs; TR-03 DERIVES the
journey by matching event_name (asserting one from telemetry would be fabrication).
**Acceptance:**
- `[det]` the schema validates the OTLP-JSON fixture's normalized output; a record missing
  `event_name` validates but is flagged DARK-in-prod by TR-03, not rejected.
- `[det]` a boolean/non-string in the `vital_class` enum position is schema-invalid — the same
  Norway-guard the manifest validator enforces (MS §2), via `uv run` jsonschema (ADR 0014/0015).
- `[det]` `env` outside the reserved set is schema-invalid (aligns to §4's `environments` primitive).

### TR-loop-guard — Self-ingestion / infinite-regress guard [ADR 0002 refuse-by-default]
Before correlation, TR-03 filters the window: (a) drop records whose `emitter` matches the triage
agent's own identity or any service the tier itself instruments; (b) consult open incident-Spec
PRs (via the vendored host.sh `pr-list`/`pr-state`) and SUPPRESS emitting a new incident-Spec for
an `event_name`+journey whose prior incident-Spec PR is still open (dedupe by incident key). This
is the loop-safety guarantee: the tier cannot triage its own emissions, and cannot fan out a
second Spec for an unresolved incident.
**Acceptance:**
- `[det]` a window fixture containing a self-`emitter` record is excluded from correlation input.
- `[det]` with a fixture 'open incident-Spec PR' state, a duplicate incident key is SUPPRESSED
  (no second Spec) and logged as `[note] already-open-incident-spec`, not re-emitted.
- `[det]` the dedupe key is (`event_name`, derived journey, drift-class) — grep-provable it does
  NOT include a timestamp (so retries of the same incident collapse).

## B. Correlation (the join — HONESTY-CORRECTED)

### TR-03 — Incident↔manifest correlation: §12 key, runtime source [MS §12, ADR 0006]
Consume (a) the incident window (TR-02, post-loop-guard) and (b) the Verification Manifest,
validated via the VENDORED scripts/validate_manifest.sh (exit 0/3/4/5 per §11; refuse newer
majors, degrade on absent — reuse verbatim, do not reimplement). Join runtime emission to intent:

| Incident window (runtime) | Manifest (intent) | Join / verdict rule |
|---|---|---|
| `event_name` | `journeys[].steps[].event_name` | Exact string. THE §12 key, now runtime↔intent. Hit → the emission belongs to this journey+step. |
| (derived) matched journey | `journeys[].id` | The journey the incident correlates to, DERIVED by the event_name match above. NOTE: this is NOT read from a backref — telemetry has none. |
| `vital_class` on the record | `steps[].vital_class` | Must agree; disagreement = class-drift finding (rot signal into the Spec). |
| `severity`/`count` spike | `steps[].required_emission` + `alert_seam` (env-collapsed to the audited env key per §12) | Contextualizes severity using the criticality ladder; does not invent severity. |
| `event_name` with NO manifest match | — | **Unmapped-in-prod**: a vital firing that no manifest step declares. Surfaced, never dropped. |
| manifest CORE step with NO emission in window | — | Informational ONLY — absence-in-a-bounded-window is not absence-in-prod; NEVER a violation, degrade per rule 4. |

Output `triage/correlation.json` — per record its derived `journey_id` + step + affected behavior
IDs (behaviors whose `journey:` equals the matched journey, §5), or an explicit `no-join` bucket
with reason (unmapped-in-prod / DARK-in-prod / manifest-absent).
**CRITICAL HONESTY CORRECTION vs r1:** r1 claimed the derived journey is 'the same value the audit
backrefs (§12 row 1)' and cited the committed `tests/fixtures/join/journeys.json` as proof the key
'literally already exists'. FALSE as stated: that fixture is `schema_version: 2` with a `_note`
tying it to codebase-health **CH-02, which is NOT yet built** (`source_run.kind: "audit"` — it is
the AUDIT's static discovered-side artifact, not a runtime window). §12 row 1 is marked
'*(v2 backref)* … Until it ships: exact name match'. So the `manifest_journey_id` backref this
tier's 'same value the audit backrefs' phrasing leans on DOES NOT EXIST in the built suite. The
tier therefore DERIVES the journey purely from the event_name→step match and does NOT depend on
CH-02. Where a proof would require the audit's v2 backref, the acceptance is demoted to [det-cond].
**Acceptance (re-tagged for honesty):**
- `[det]` from a TRIAGE-OWNED window fixture (event_name: pay.captured) + the committed
  tests/fixtures/join/manifest.yaml, `pay.captured` derives journey J-pay-001, step 0, behavior
  B-pay-001 — proven WITHOUT the journeys.json v2 backref (event_name→step is a v1 manifest field).
- `[det]` an `event_name` absent from the manifest → `unmapped-in-prod` bucket with reason, not
  dropped; a manifest-absent run degrades to 'no join possible, all records DARK-context' + loud
  `[note]` (reusing §11 degrade rows).
- `[det]` a `vital_class` disagreement emits a `class-drift` signal.
- `[det]` correlation.json is idempotent + schema-versioned (detection never mutates).
- `[det-cond]` cross-checking the derived journey against an audit `journeys.json` v2 backref for
  agreement is possible ONLY once codebase-health CH-02 ships; until then this cross-check is
  SKIPPED with a `[note] backref-unavailable (CH-02 unbuilt)`, NOT silently assumed. Asserted
  against a triage-owned v2 fixture, explicitly labeled 'not end-to-end suite proof'.
- `[drain]` join precision/recall on a real incident with real event_names — agent-scored residual.

### TR-04 — Config-profile resume [ADR 0006]
Resume the profile the way spec-gen does — reuse the VENDORED
plugins/spec-gen/scripts/profile_resolve.py (`--mode resume --manifest`); the incident's manifest
carries `observability.profile`, so no re-escalation. Per codebase-health CH-08: the profile
*payload* (taxonomy/vocabulary/seams) is NOT vendored today; the deterministic layer reads the
bare name and degrades on unknown → `default` + loud `[note]`. Profile decides WHICH vitals matter
(steers severity, a floor not a ceiling), never HOW severe past the ladder cap.
**Acceptance:**
- `[det]` a `payments`-profile manifest resolves via the vendored profile_resolve.py; unknown
  profile degrades to `default` + `[note]` (reuse spec-gen resolver fixtures — zero new resolver code).
- `[det]` the profile cannot raise incident severity above the ladder cap (mirrors CH-08's
  floor-not-ceiling assertion).
- `[drain]` profile taxonomy → concrete emitted field names on a real LOB stream — agent + profile-data scored.

## C. Emission (into spec-gen's resume path)

### TR-05 — Incident-Spec emitter [CONTEXT.md Spec, MS §5/§10]
From a CONFIDENT correlation (TR-03) emit an incident-Spec: a drafted `<incident-id>.md` (prose)
PLUS a partial `<incident-id>.manifest.yaml` that is `completeness: incomplete` BY CONSTRUCTION —
pre-filling what the join proves (affected `journeys[].id`, behavior IDs, drifted
`event_name`/`vital_class`) and leaving risk/values fields for spec-gen's interrogation
(`incomplete_fields` per §10 grammar `rule-<n>: <path>`). Induced-PRODUCER analog of §13's induced
consumers. Behavior IDs are NEVER reallocated (§6: IDs never reused/renumbered) — the incident
references EXISTING IDs the join found; a genuinely undeclared behavior is an `unmapped-in-prod`
prose note for spec-gen to allocate, not minted here.
**Acceptance:**
- `[det]` from the TR-03 fixture, the emitter writes `<incident-id>.manifest.yaml` that is
  schema-valid AND `completeness: incomplete` (validator exit 3, via vendored validate_manifest.sh);
  references existing B-pay-001/J-pay-001, mints no new ID. `incomplete_fields` entries match the
  `rule-<n>: <path>` grammar (e.g. `rule-2: journeys[J-pay-001].steps[0].idempotency`).
- `[det]` the drafted `.md` names the joined journey + behavior IDs + drift class (grep-provable);
  an `unmapped-in-prod` incident produces a prose note, not a minted ID.
- `[det]` the emitter REFUSES to emit from a `no-join` correlation (manifest-absent / all-DARK) —
  degrade rule 4: no confident join → no Spec, surface the gap.
- `[det]` (loop-safety) the emitter checks TR-loop-guard's open-incident dedupe and refuses a
  duplicate for an already-open incident-Spec.
- `[drain]` incident-Spec prose quality (interrogation-ready?) — agent-scored.

### TR-06 — The triage agent (SKILL/prompt) [ADR 0006 agent-first]
`plugins/triage/skills/triage/SKILL.md` + `commands/triage.md` running probe→window→loop-guard→
correlate→profile→emit; applies judgment where the deterministic layer stops (incident vs noise;
real class-drift vs benign rename). Vendors the ADR 0002 escalation-criterion block VERBATIM
(V5 lint extends to this plugin), so external facts (source, auth) escalate rather than being
assumed. Agent-first per ADR 0006: this SKILL is the primary vitals consumer; no dashboard in path.
**Acceptance:**
- `[det]` the escalation-criterion block is byte-identical to the canonical (extends V5's tier set
  from 4 to 5 — TR-08).
- `[det]` the SKILL names the read-only + Spec-not-patch + bounded-window + no-self-ingestion
  invariants (grep-provable).
- `[drain]` end-to-end agent judgment on a real incident — the honest residual, incident-eval.

## D. Loop closure + self-test

### TR-07 — Spec-gen resume handoff [CONTEXT.md Tier, MS §10]
Wire the incident-Spec into spec-gen's EXISTING resume path (plugins/spec-gen/scripts/
resume_projection.py, profile_resolve.py --mode resume). The incident-Spec is a spec-gen INPUT,
not a new spec-gen mode: `/spec @<incident-id>.md` with its incomplete manifest is exactly the
resumable-incomplete case (§10: incomplete manifest consumable only by a resumed spec-tier
session). The plugin hands off; it does not reimplement interrogation. Honest loop statement:
prod telemetry → incident-Spec → spec-gen resume → autopilot → audit → marshal (NOT a magic ring;
a new source feeding the left edge).
**Acceptance:**
- `[det]` the emitted `<incident-id>.manifest.yaml` is accepted as resumable input by spec-gen's
  VENDORED resume projector (exit 3 incomplete, resumable) — cross-plugin fixture, no new spec-gen code.
- `[det]` the handoff opens a DRAFT PR via the VENDORED host adapter (host.sh pr-open --draft) —
  the Spec lands as a Claim (CONTEXT.md), reusing ADR 0013's surface, no new host code.

### TR-08 — self_test + vendoring lint [ADR 0001/0015]
Grow `plugins/triage/scripts/self_test.sh` (uv-bootstrapped, ADR 0015 — `uv run --no-project`,
no manual venv, matching plugins/autopilot/scripts/self_test.sh:257-265) to cover every `[det]` and
`[det-cond]` above (the [det-cond] ones run against triage-owned fixtures with an explicit
'not-suite-end-to-end' banner). Extend scripts/lint_consistency.sh:
  V5 (existing) — extend the escalation-block tier set from FOUR to FIVE (one-line change; the
     rule mechanism is unchanged). The block must be present + byte-identical in the triage SKILL.
  V7 (new) — the telemetry-adapter observable contract doc
     (`plugins/triage/reference/telemetry-contract.md`) is the single source; any vendored
     backend-contract copy is byte-identical (the host-contract precedent).
  V1 (existing) — extend the byte-identity walk to `incident-window.schema.json` if any standalone
     copy ships.
Register the fifth plugin in the root .claude-plugin/marketplace.json (V6 already lints the single-
marketplace invariant — add the `triage` entry + its own `.claude-plugin/plugin.json`). NOTE:
update the marketplace `description` string, which currently says 'four-plugin' — that copy MUST
change to five, or V6 documents a lie (flagged as a required edit, not left implicit).
**Acceptance:**
- `[det]` self_test.sh runs green hermetically (OTLP-JSON fixture backend only — the `default`
  backend IS the test backend), matching autopilot, codebase-health, spec-gen, and marshal self-test discipline.
- `[det]` a planted drift in the vendored telemetry-contract / escalation-block / window-schema is
  caught by V7/V5/V1 (`$ROOT` fixture-tree teeth, the existing lint self-test pattern).
- `[det]` the marketplace lint (V6) passes with FIVE plugins, each carrying its own plugin.json,
  and the marketplace description no longer claims 'four-plugin'.

## E. What the critique changed (delta from r1, for the reviewer)
- Reframed 'fifth tier / closes the ADLC ring' → 'fifth PLUGIN, a new SOURCE feeding the left edge'
  (CONTEXT.md Tier=three; ADR 0011 non-tier-plugin precedent). Removed all ring language.
- Demoted TR-03's headline join proof from [det] to a split: [det] on the event_name→step match
  (a v1 manifest field, genuinely hermetic) + [det-cond] on any journeys.json v2 backref cross-
  check (CH-02 UNBUILT). Rejected r1's 'the committed fixture already proves it' as false —
  that fixture is the audit's static v2 discovered artifact, not a runtime window.
- Corrected the 'runtime↔intent join by construction' overclaim: §12's event_name discovered-side
  is `emission_grade` audit evidence, not a runtime stream. We reuse the KEY for a new source; we
  do not inherit a proven runtime join.
- Added the bounded-window cost invariant with mechanical [det] teeth (the mutation-testing analog:
  never a full-retention / whole-fleet scan; absent/oversized window = refuse).
- Added TR-loop-guard (self-ingestion exclusion + open-incident dedupe) — the missing infinite-
  regress prevention; refuse-by-default.
- Added the marketplace 'four-plugin' description as a REQUIRED edit so V6 doesn't lint a lie.