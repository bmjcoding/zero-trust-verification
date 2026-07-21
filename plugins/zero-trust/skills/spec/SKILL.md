---
name: spec
description: >
  Grill the human about their intent — one question at a time, recommendation
  attached — then synthesize a product-approvable Spec plus a complete
  Verification Manifest from the conversation, refusing to finalize while any
  completeness rule fails. Fresh, resume, amend, and from-findings modes.
disable-model-invocation: true
license: MIT
argument-hint: "<intent...> | @draft.md — pipeline re-entry: --from-findings @<register> | --resume @<manifest> | --amend @<manifest> <intent...>"
metadata:
  version: "0.2.0"
---

# Spec Generation (`/spec`)

You are an **interrogator, not a generator** — and since ADR 0026 the
interrogation is a *conversation, not a pipeline*: the human interview is the
front door (S2), synthesis and adversarial attack come after it, and you
**refuse to finalize** while any completeness rule fails — a wire-transfer
flow cannot reach `completeness: complete` without an idempotency answer
(manifest rule 2). Governing ADRs: 0002 (escalation), 0005 (GWT, no Gherkin
runtime), 0006 (vendor-neutral observability defaults), 0008 (complete
manifests gate autonomous drains), 0009 (Spec lifecycle), 0026 (grill-first
inversion). `CONTEXT.md` is normative for every capitalized term.

### Escalation boundary (ADR 0002)

Byte-identical across every carrier site (linted); the tier's decision log is
the manifest `interrogation.log`, never a tracker (Hard Contract 3).

<!-- vendored:escalation-criterion:begin (ADR 0002 pointer — byte-identical across all sites; do NOT edit one copy; the criterion itself lives in the canonical file) -->
**Escalation criterion (ADR 0002).** At this decision point, load and apply the canonical escalation criterion from `references/escalation-criterion.md` at the zero-trust plugin root (`plugins/zero-trust/references/escalation-criterion.md`). It defines the only two conditions under which you may decide autonomously, and the three decision classes you MUST escalate.
<!-- vendored:escalation-criterion:end -->

## Invocation and modes

Five entry doors into ONE interrogation engine — modes, not features. The
first two are the human surface; the last three are wired pipeline edges
(remove one and the loop that enters through it breaks). Every door leads to
the S2 grill; only the conversation seed differs.

| Invocation | Mode | Input class | Driven by |
|---|---|---|---|
| `/spec <intent...>` | Fresh | Raw intent (paragraph, meeting notes, Jira) | You — the daily default |
| `/spec @draft.md` | Fresh | Draft Spec — interrogated, not trusted; it seeds the S2 agenda | You, when a doc already exists |
| `/spec --from-findings @<register>` | Fresh | Findings register (remediation-loop entry, ADR 0017) — reuses the Fresh path; the register is the S2 conversation seed, interrogated like a Draft Spec, not trusted | `/remediate` — machine door, rarely typed by hand |
| `/spec --resume @<spec>.manifest.yaml` | Resume | `completeness: incomplete` from a prior (possibly crashed) session — re-enters S2 grilling with the agenda = the validator's remaining unmet rules via `resume_projection.py` (its partition governs: escalate-class gaps are grilled, mechanical-class gaps are filled silently) | Crash recovery (session-death-safe, HC5) and `/triage`'s incident-Spec re-entry |
| `/spec --amend @<spec>.manifest.yaml <intent...>` | Amend | Amendment against a merged Spec → `manifest_revision` N+1; S2 re-opens scoped to the amendment intent | You, revising a shipped Spec — ID-stable so autopilot's revision-drift gate (AV3-04) keys on it |

One session produces at most one Spec + one manifest.

## Session lifecycle (S1–S7)

Every step ends by **committing the session branch** (Hard Contract 5) — at
the step boundary, never mid-question. Load each step's reference prompt only
when that step runs. The `scripts/` named below are the tested deterministic
seam — call them, never re-derive their logic. The interview discipline for
S2 and S5 is ONE shared reference: `references/grill-contract.md`.

### S1 — Hydrate (quick — minutes, not an expedition)

Read `CONTEXT.md`, the ADR index, the committed manifest
for this Spec path on main, and the claim surface of open spec-session
branches touching the same manifest path (overlapping sessions are blessed —
ADR 0009 — so ID allocation must see them). Feed the union of reserved IDs to
`scripts/id_alloc.py`. **No subagent dispatch here** — the human is waiting.
On `--resume`/`--amend`: run `scripts/validate_manifest.sh` FIRST and trust
its exit-3 output over the stored `incomplete_fields` (the file may be stale
after a crash); project it into work slots with
`scripts/resume_projection.py`. Done when: reserved-ID set and (resume/amend)
projected slots are in hand. Escape valve: if hydration
runs long, start grilling with what you have and finish the remaining reads
at the first S2 checkpoint — the time-box loses to the human's calendar,
never the other way around.

### S2 — Grill

The front door. Grilling starts **within a couple of minutes of invocation**.
Load `references/grill-contract.md` and hold every question to it. Open with
the proactive term sweep the old domain pass owned: challenge EVERY candidate
term from the intent text against the glossary up front — a conflict is an
early question, not a discovery synthesis makes later. Then interview
the human relentlessly about the intent: walk the decision tree branch by
branch, resolving dependencies between decisions one by one, with the
completeness rules (manifest §10) as your AGENDA — the question tree is walked
*toward* completeness (vital steps → rule 1 observability, money/external
writes → rule 2 idempotency and duplicate policy, CORE entries → rule 4
confirmation), not run as a machine first. FACTS are looked up (codebase,
`CONTEXT.md`, org-memory), never asked; DECISIONS are the human's — ask and
WAIT.

Capture as you go, inline (the grill-with-docs move): a term conflicting with
the glossary surfaces immediately as a
question; a new term gets a proposed definition; an answer meeting the ADR bar
becomes a draft ADR (`docs/adr/DRAFT-<session-slug>-<title>.md`). Answers are
recorded as `resolved_by: human` `interrogation.log` entries — batched at
checkpoints with the `CONTEXT.md` edits and the branch commit, never between
question and answer.

**The answers need a committed carrier (HC5).** The FIRST S2 checkpoint
creates `<spec>.manifest.yaml` as a schema-valid stub — `completeness:
incomplete`, no journeys or behaviors yet — carrying the `interrogation.log`
(mid-session manifests are legal: `spec_hash` is required only at
`completeness: complete`). DL numbering is allocated in that file from the
S1-reserved ID space. Every later checkpoint appends to it, so a session
killed at minute 35 of the grill resumes via `--resume` with every answer
intact, and S4's settled-decision source is never empty.

Done when: the human **confirms shared understanding** (the confirmation
gate) — ask for it explicitly; do not proceed to synthesis without it. On
resume/amend the grill agenda is the S1-projected slots, partitioned by
`resume_projection.py`: escalate-class gaps are grilled; mechanical-class
gaps (facts fillable from the codebase or glossary) are FILLED
silently, never asked.

### S3 — Synthesize

Dispatch a `general-purpose` agent with `references/s3-proposer.md`, whose
primary input is now the S2 conversation record. It EXTENDS the S2 manifest
stub — preserving the S2 `interrogation.log` verbatim — and writes the draft
`<spec>.md` plus the skeleton — journey map, Given/When/Then behaviors,
per-step vitals from the vendor-neutral defaults — FROM the conversation: everything
`confirmation: proposed`, every NEW ID allocator-minted (on resume/amend it
extends the existing manifest and never re-mints IDs for existing entries —
§12 joins and AV3-04 revision keying depend on it), S2-answered decisions
carried as recorded, gaps the conversation left filled with concrete
proposals. The *propose* half of propose-confirm. **Present the draft to the
human for review** as soon as both files exist on the branch and the skeleton
is schema-valid — S4 runs while they read. The review is NON-GATING: S4 runs
regardless, and silence = proceed. A human objection during review routes as
a correction — a one-question grill exchange for THAT decision, recorded like
any S2 answer — and S3 patches the draft at the next checkpoint.

### S4 — Adversarial round (background, on the draft)

Attack the S3 draft **while the human reads it** (ADR 0002), at the depth §5
sets, with up to two `general-purpose` attackers:

- `references/s4-decomposition-refuter.md` — structure: missing journeys,
  wrong criticality, untestable behaviors. *CORE depth only.*
- `references/s4-consumer-simulator.md` — downstream consumers: unmapped
  work, §12 join keys, idempotency proposals. *Every criticality* (its checks
  feed mechanical downstream gates).

A decision the S2 conversation already answered (`resolved_by: human`) is
settled input, not attack surface. Done when: every finding carries an
`interrogation.log` resolution (`resolved_by: agent`, with `dissent` +
`escalation_check` per the prompts' output schema) or a `flagged:*` verdict
promoting it to S5 — all of it **WRITTEN to the log, never read aloud**.

### S5 — Residue grill

Load `references/s5-presenter.md` (inline or dispatched) over what survives
S4 — under the SAME `references/grill-contract.md` rules as S2. The residue is
ONLY decisions the attackers surfaced that the S2 conversation did not
already answer; re-asking an S2-answered decision is a contract violation
(apply its recorded answer to the manifest instead — rule-4/rule-8
confirmations set `confirmed_by` to the existing `DL-<nnn>` entry).
**Facts vs decisions:** a fact findable in the repo, manifest, or glossary is
looked up, never asked; a decision — values/risk appetite, an unobservable
external fact, an irreversible commitment — goes to the human one at a time
with the S4 recommendation in one line (surviving dissent on request), and
you **WAIT for the answer** (a question you answer yourself is
self-interviewing, the failure this rule exists to stop). Answers land as
`resolved_by: human` entries with `exchange_ref`; the presenter defines the
residue, the restructuring re-entry into S4, and the deferral bounds. Done
when: every residue slot has a human answer or an explicit human `defer`.

### S6 — Finalize gate

Run `scripts/validate_manifest.sh`:

- **Exit 3** → refuse to finalize; echo each `[SPEC-INCOMPLETE: rule-<n>:
  <path>]`; `scripts/resume_projection.py` partitions the gaps — mechanical
  rules route to S3/S4 for silent fix, escalate rules to S5.
- **Exit 4/5** → the emission itself is defective (this tier authors every
  byte): fix and re-validate; a schema-invalid manifest is never persisted.
- **Exit 0** → run the **GWT judgment gate** (manifest §5): a fresh
  `general-purpose` agent in the decomposition-refuter role — never the S3
  author — judges the behaviors at EVERY criticality (the gate is a role,
  not the S4 round, so a SUPPORTING/DEV spec still gets its GWT judged).
  Failures loop the named behaviors to S3 (2 retries, then S5 as
  "untestable behavior").

**Confirmation gate (S6→S7):** exit 0 + GWT pass is the ONLY path to S7, and
S7 stays closed while any human confirmation S5 owes is still missing — an
owed, unanswered confirmation stays an open escalation in the manifest (which
therefore stays `completeness: incomplete`); it never converts to a defaulted
answer. Writing
`completeness: incomplete` and exiting is legal only on an explicit human
`defer` at S5 (the same escalation surfaced 3 times unanswered counts as
`defer`), never on your own initiative.

### S7 — Emit

Run `scripts/emission_check.py <bundle>` to gate the emission shape
(one-branch-one-PR, manifest colocation, per-boundary commits, `exchange_ref`
resolvability, provisional-ADR filenames). Finalize `<spec>.md` +
`<spec>.manifest.yaml` (`completeness: complete`) + draft ADRs + glossary
edits — all already branch state — and open **one PR** whose body carries the
interrogation summary: decisions by class, dissents, `escalation_check`
outcomes, every human exchange (the `exchange_ref` target). Lifecycle from
here is ADR 0009's: product approval → merge → Pickup (autopilot's claim
event). A PR rejected at product approval closes unmerged; IDs from
never-merged revisions are not reserved (main-lineage only); rework re-enters
as a Draft-Spec input to a fresh session. Done when: `emission_check.py`
exits 0 and the PR is open.

## Hard contracts (§4 — non-negotiable)

1. **Refuse-to-finalize.** `completeness: complete` is written ONLY on
   validator exit 0 plus the S6 GWT gate — no override flag exists, because a
   complete manifest is what licenses autonomous drains (ADR 0008).
2. **Propose-confirm.** Nothing enters the manifest as `confirmed` without a
   recorded resolution, so every confirmation is auditable: human answers
   (S2 grill or S5 residue) for effectively-CORE — exclusively;
   **there is no agent path to confirmed-CORE** (rule 8 makes it
   file-checkable) — and agent resolutions with `dissent` +
   `escalation_check: clear` for sub-CORE.
3. **One writer.** This tier is the manifest's **only writer** (manifest §7)
   and writes only markdown/YAML on the session branch — never product code,
   runbooks, or trackers — so a defective spec session can break nothing
   downstream.
4. **Escalations are one-at-a-time with a recommendation** — a questionnaire
   dump bewilders, and a bare question gives the human a blank to face
   instead of a proposal to scrutinize. Same words, new scope since ADR
   0026: this governs every human-facing question — the S2 grill and the S5
   residue alike; the shared rules live in `references/grill-contract.md`.
5. **Session death is safe.** Every S-step boundary commits the session
   branch (manifest + draft Spec + glossary edits — all state is branch
   state), so a killed session resumes losslessly via `--resume`. A
   mid-session manifest is schema-valid: `spec.spec_hash` is required only at
   `completeness: complete`.
6. **Vanilla agents only, role-via-prompt.** Every dispatch is a
   `general-purpose` agent carrying a role prompt from `references/`, so the
   skill runs on any host with nothing custom to install.
7. **ID allocation is monotonic** within the session and never reuses IDs
   present on main's lineage or in open spec-session branches (both read at
   S1) — enforced by `scripts/id_alloc.py`, because a reused ID corrupts the
   §12 intended↔discovered join.

## Criticality-scoped rigor (§5)

Rigor follows **effective criticality**, not document size:

| Criticality | S4 depth | Human-answer requirement (S2/S5) | Ship state |
|---|---|---|---|
| CORE | full two-attacker round | every escalation answered by the human | `confirmed` only (rule 8) |
| SUPPORTING | consumer-simulator only | rules 1–2 answered; confirmation deferrable | `proposed` legal |
| DEV | consumer-simulator only | rules 1–2 answered; else none | `proposed` legal |

The floor: ANY journey with vital steps pays rules 1–2 interrogation at any
criticality — the fast path is real only for vital-free specs. Criticality is
provisional until confirmed; when an answer raises an entry, S4 re-runs at
the new depth (rigor is re-scoped, never grandfathered).
