# Spec Generation Tier — v1 Specification

> Status: DRAFT r2 (adversarial round 1 applied: 24 findings from two independent
> attackers — corpus-consistency and executor-simulation lenses; all P0/P1 closed,
> P2 closed or recorded) · 2026-07-04
> Governing decisions: ADR 0002 (escalation criterion — vendored here as in every tier),
> ADR 0005 (GWT behaviors), ADR 0006 (profiles), ADR 0008 (its output gates autonomous
> drains), ADR 0009 (Spec lifecycle: Pickup is the Claim event).
> Contract consumed: docs/specs/verification-manifest-v1.md (schema_version 1) — this
> revision also carries three additive amendments to that spec (marked ⟨MS-AMEND⟩ below).
> Vocabulary: CONTEXT.md is normative. Working plugin name: `spec-gen` (final name is
> Bailey's call at packaging time; nothing below depends on it).

## 1. Purpose

The spec tier is an **interrogator, not a generator**: it converts raw intent into a
product-approvable Spec plus a complete Verification Manifest by walking the manifest
schema as a question tree and **refusing to finalize** while any completeness rule fails.
Generation happens — prose drafting, behavior proposal, vitals mapping — but always as
the *output* of interrogation, never a substitute. The differentiator vs generation
frameworks (BMAD-class): silence is impossible on the straight-through path. A
wire-transfer flow cannot reach `completeness: complete` without an idempotency answer
(manifest rule 2), and ADR 0008 denies an incomplete manifest the straight-through drain —
it degrades to the manifest-less GENERATE+pause path, where a human review gate stands.

The floor being raised is the *question floor*, not the prose ceiling.

## 2. Inputs and invocation

| Input class | Example | Notes |
|---|---|---|
| Raw intent | a paragraph, meeting notes, a Jira description | The normal case. |
| Draft Spec | an existing ADR/PRD/design doc | Interrogated, not trusted; gaps found the same way. |
| Findings register | a GAPS_SPEC-style audit register | The remediation loop's entry point (future scope; input class first-class from day one). |
| Incomplete manifest | `completeness: incomplete` from a prior session | Resume: re-validate, continue interrogation (§3 S1). |
| Complete manifest | an amendment request against a merged Spec | Amendment session: produces `manifest_revision` N+1 (the manifest spec §6 requires this session type to exist; the manifest has no other writer). |

Invocation: `/spec [--profile <name>] <intent...>` · `/spec @draft.md` ·
`/spec --resume @<spec>.manifest.yaml` · `/spec --amend @<spec>.manifest.yaml <intent...>`.

**Profile resolution order (fresh sessions):** `--profile` flag → committed repo config
(`spec-gen.config.yaml` at repo root, `profile:` key) → `default`, in which case S5 MUST
surface "no Config Profile is configured — is `default` correct for this repo?" as its
first escalation (an org-standard is an external fact; agents don't assume it, ADR 0002).
Resume/amend sessions take the profile from the manifest.

One session produces at most one Spec + one manifest (multi-doc unions are autopilot's
concern, not this tier's).

## 3. Session lifecycle (S1–S7)

**S1 — Hydrate.** Read CONTEXT.md, the ADR index (titles + one-liners), the resolved
Config Profile, the committed manifest for this Spec path if one exists on main
(ID-reservation input, HC7), and the claim surface of open spec-session branches touching
the same manifest path (ADR 0009 — overlapping sessions are blessed, so ID allocation must
see them). On `--resume`/`--amend`: run `validate_manifest.sh` FIRST and trust its exit-3
output over the stored `incomplete_fields` (the file may be stale after a crash).

**S2 — Domain pass.** Extract candidate terms from the intent; challenge each against the
glossary (conflict → surface immediately; new term → propose a definition). Output
persists as CONTEXT.md edits committed to the session branch — file state, not manifest
fields and not context memory.

**S3 — Skeleton proposal.** Write the draft Spec skeleton to disk (`<spec>.md` on the
session branch — it must exist before any manifest can reference it) and draft the journey
map (names, criticality + reasons, steps with `vital_class`) and the Acceptance Behavior
list (GWT, IDs per the manifest spec §6 grammar) — *proposed*, not confirmed. Propose
vitals per step from the profile's taxonomy. Nothing here asks the human anything; it is
the propose half of propose-confirm.

**S4 — Adversarial round.** Up to two independent agents (depth per §5) attack the
skeleton before any human sees it (ADR 0002): the **decomposition-refuter** (missing
journeys, wrong criticality, untestable behaviors, GWT naming no observable trigger) and
the **consumer-simulator** (would the planner find unmapped work? do the §12 join keys
exist? does every money/external-write step have an idempotency answer *proposed*?).
Tradeoffs are resolved agent-vs-agent ONLY within ADR 0002's agent-decidable class; each
resolution is an `interrogation.log` entry with `resolved_by: agent` and non-empty
`dissent`. The S4 output schema REQUIRES per resolution an
`escalation_check: clear | flagged:<values|external-fact|irreversible>` field — the
ADR 0002 trilist applied as a checklist, not vibes; any `flagged:` resolution is
involuntarily promoted to S5. Resolutions meeting the three ADR criteria are drafted as
`status: agent-decided` ADRs under **provisional session-slug filenames**
(`docs/adr/DRAFT-<session-slug>-<title>.md`); the final number is assigned at merge/rebase
time — ADR numbers are not manifest IDs, renumber-at-rebase is legal and required.

**S5 — Escalation.** What survives S4 is the MUST-escalate residue: values/risk appetite,
unobservable external facts, irreversible commitments — plus everything `flagged:` by the
checklist. Present each **one at a time, with the adversarial round's recommendation and
dissent attached** (grilling discipline). Answers land as `resolved_by: human` entries
(`exchange_ref` pointing at the session transcript section in the PR description).
**Effectively-CORE `confirmation: confirmed` comes ONLY from S5 human answers** — there
is no agent path to confirmed-CORE (manifest §10 class (b) and rule 8); the S4 agent path
confirms sub-CORE entries only. Deferral scope: a human may defer *confirmation* on
SUPPORTING/DEV entries (`proposed` is legal per manifest rule 4), but rules 1–2
escalations (vitals intent, idempotency answers) fire for ANY journey with non-null
`vital_class` steps regardless of criticality — the truly-fast path (§5) exists only for
specs with no vital steps at all.
**Restructuring transition:** an S5 answer that raises effective criticality, or adds or
removes a journey, re-enters S4 at the new depth for the affected entries only. Bound: 2
re-entries per entry; the third becomes itself an S5 escalation ("this decision is
oscillating — human owns it now").

**S6 — Finalize gate.** Run `scripts/validate_manifest.sh`.
- Exit 3 → refuse to finalize; echo each `[SPEC-INCOMPLETE: rule-<n>: <path>]`; route
  mechanical-class rules to S3/S4 for silent fix, escalate-class rules to S5.
- Exit 4/5 → the session's own emission is defective (the tier authors every byte):
  internal defect, fix and re-validate; never persist a schema-invalid manifest.
- Exit 0 → additionally run the **GWT judgment gate** (manifest spec §5): judged by the
  decomposition-refuter role, never the S3 author; failures loop the named behaviors to
  S3, bounded at 2 retries, then surface at S5 as "untestable behavior" questions.
  Exit 0 + GWT pass is the ONLY path to S7.
- **Deferred exit:** writing `completeness: incomplete` and exiting is legal ONLY on an
  explicit human `defer` instruction at S5, never on the orchestrator's own initiative —
  the default on unanswered escalations is to keep asking. (Session budget: a session that
  has surfaced the same escalation 3 times without an answer treats that as `defer`.)

**S7 — Emit.** Finalize `<spec>.md` + `<spec>.manifest.yaml` (`completeness: complete`) +
S4 draft ADRs + S2 glossary edits — all already living on the session branch (HC5) — and
open one PR. The PR body carries the interrogation summary: decisions by class, dissents,
`escalation_check` outcomes, and every human exchange (the `exchange_ref` target).
Spec lifecycle from here is ADR 0009's: product-approved → merged to main → Pickup
(autopilot's claim event, not this tier's job). **Rejection at product approval:** the PR
closes unmerged; IDs from never-merged revisions are NOT reserved (manifest §6 reservation
is main-lineage only ⟨MS-AMEND-3⟩); rework re-enters as a Draft-Spec input to a fresh
session.

## 4. Hard contracts

1. **Refuse-to-finalize.** `completeness: complete` is written ONLY on validator exit 0
   plus the S6 GWT gate. No override flag exists. Hand-edit defense is layered: the
   validator recomputes completeness at consume time; rule 8 ⟨MS-AMEND-2⟩ makes CORE
   confirmation file-checkably reference a human-resolved `DL-*` entry; and the PR Gate
   provenance check (§8 induced) flags manifest diffs from non-spec-session branches.
2. **Propose-confirm.** Nothing enters the manifest as `confirmed` without a recorded
   resolution: S5 human answers for effectively-CORE (exclusively), ADR-0002-legal agent
   resolutions with dissent + `escalation_check: clear` for sub-CORE.
3. **One writer.** This tier is the manifest's only writer (manifest spec §7) and never
   writes product code, runbooks, or trackers.
4. **Escalations are one-at-a-time with a recommendation** — never a questionnaire dump,
   never a question without the recommended answer and surviving dissent.
5. **Session death is safe.** Every S-step boundary **commits** the session branch
   (manifest + draft Spec + glossary edits — all state is branch state, none is
   context-only). A killed session resumes losslessly via `--resume`. ⟨MS-AMEND-1⟩ makes
   the mid-session manifest schema-valid: `spec.spec_hash` is required only at
   `completeness: complete`.
6. **Vanilla agents only, role-via-prompt** (autopilot Hard Contracts 2–3 inherited):
   S4 attackers are `general-purpose` with role prompts from this plugin's references.
7. **ID allocation** is monotonic within the session and never reuses IDs present on
   main's lineage OR in open spec-session branches touching the same manifest path
   (both read at S1). The PR Gate enforces main-lineage reuse; the branch-claim read
   closes the overlapping-sessions window that ADR 0009 deliberately allows.

## 5. Criticality-scoped rigor (the fast path)

Rigor follows effective criticality, not document size:

| Criticality | S4 depth | S5 requirement | Ship state |
|---|---|---|---|
| CORE | full two-attacker round | every escalation answered by the human | `confirmed` only (rule 8) |
| SUPPORTING | consumer-simulator only | rules 1–2 escalations answered; confirmation deferrable | `proposed` legal |
| DEV | consumer-simulator only | rules 1–2 escalations answered; else none | `proposed` legal |

The consumer-simulator is the attacker that survives reduction because its checks feed
mechanical downstream gates (planner mapping, §12 joins). Note the rigor floor: ANY
journey with vital steps pays rules 1–2 interrogation at any criticality; the
minutes-fast path is real only for vital-free specs. S3 criticality is provisional —
the §3 S5 restructuring transition re-runs S4 at the higher depth when a human upgrades
an entry (rigor is re-scoped, never grandfathered).

## 6. Packaging

Plugin `spec-gen` in this marketplace (ADR 0001, as amended by ADR 0011 — four plugins).
Surface: one skill (`/spec`) + vendored references (S3 proposer, S4 attacker ×2, S5
presenter role prompts; the manifest JSON Schema copy) + `scripts/validate_manifest.sh`
(vendored; byte-identity lint extended from the schema to the script copy — a new lint
rule following the ADR 0001 pattern). Read-mostly permission posture: writes are
markdown/YAML + git branch/PR only — the second-lowest-trust plugin after the audit, and
the adoption on-ramp for teams that want better specs before they want drains.

## 7. Deterministic substrate and self-test

The LLM interrogation cannot be self-tested; the deterministic seam can and is:

1. `validate_manifest.sh` — already specced (manifest spec §13.2) with its fixture suite,
   extended with rule-8 fixtures (CORE-confirmed-without-DL-ref → incomplete).
2. **Resume projection**: fixture incomplete manifest → assert the deterministic mapping
   validator-exit-3 output → escalate-class question *slots* (rules 1, 2, 4 entries only;
   mechanical-class entries are filtered to the S3/S4 queue). Recommendation/dissent
   content comes from the mandatory S4 re-run over resumed entries and is excluded from
   this assertion.
3. **ID allocation**: table-driven tests for the manifest spec §6 grammar allocator
   (next-ID, 999 overflow → new slug, main-lineage + open-branch reuse refusal).
4. **Emission shape**: fixture session output → assert one-branch-one-PR layout, manifest
   colocation, per-boundary commits present (HC5), `exchange_ref` resolvability,
   provisional-ADR filename shape.
5. Process gate (M3 pattern): every behavioral claim in this tier's CHANGELOG cites a
   self-test assertion or is `[doc-only]`.

## 8. Deliverables register (drains from this spec)

| ID | Deliverable | Acceptance |
|---|---|---|
| SG-1 | Plugin skeleton (`plugins/spec-gen/`): SKILL.md (S1–S7 lifecycle), marketplace entry | Skill loads; lifecycle table matches §3; lint passes |
| SG-2 | Role prompts (S3 proposer, S4 attacker ×2, S5 presenter) as references | Each states its output schema; S4 schema REQUIRES `dissent` + `escalation_check`; fixture prompt-projection asserts the checklist field exists |
| SG-3 | `validate_manifest.sh` + JSON Schema incl. ⟨MS-AMEND⟩ 1–3 (shared with manifest spec §13.1–2) | Manifest fixture suite + rule-8 fixtures green |
| SG-4 | Deterministic helpers: ID allocator, resume projection, profile resolution order | §7.2–3 assertions green |
| SG-5 | Session-death safety: per-boundary commits + `--resume` re-validation | Kill-mid-S4 fixture resumes losslessly from branch state |
| SG-6 | Self-test + consistency lint wiring (S-step ids, contract refs, schema+script byte-identity) | `self_test.sh` green; planted violations red |
| SG-7 | ADR 0001 `amended-by: 0011` annotation + ADR 0002 erratum (grammar + two-class echo) | Headers updated; lint L-rule pins the grammar |
| SG-8 | Induced PR Gate requirement (recorded for the codebase-health register): provenance check on diffs touching `confirmation`/`completeness`/`interrogation.log`; main-lineage-only ID reservation | Register entry exists; not implemented here |

**⟨MS-AMEND⟩ — additive amendments applied to verification-manifest-v1.md in this change:**
1. `spec.spec_hash` (and `spec_hash` recompute) required iff `completeness: complete`;
   MAY be absent while incomplete (mid-session manifests are schema-valid).
2. New optional field `confirmed_by: DL-<nnn>` on journeys and behaviors + completeness
   rule 8 *(mechanical)*: every effectively-CORE active entry with
   `confirmation: confirmed` carries `confirmed_by` referencing an `interrogation.log`
   entry with `resolved_by: human`.
3. §6 ID reservation scope clarified to **main's lineage**: never-merged branch revisions
   do not reserve IDs (rejected Specs free them).

Explicit non-goals for v1: multi-Spec batch sessions; Jira creation (autopilot's `--jira`
owns that at Pickup); remediation-loop automation (input class reserved, wiring is future
scope); org-memory aggregation (formats already comply).
