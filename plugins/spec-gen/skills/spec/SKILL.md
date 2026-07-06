---
name: spec
description: >
  Interrogate raw intent into a product-approvable Spec plus a complete
  Verification Manifest by walking the manifest schema as a question tree —
  refusing to finalize while any completeness rule fails. Use when the user says
  "/spec", "write a spec for", "turn this intent/ADR/Jira into a spec + manifest",
  "resume a spec session", or "amend a merged spec". An interrogator, not a
  generator: silence is impossible on the straight-through path.
license: MIT
argument-hint: "[--profile <name>] <intent...> | @draft.md | --resume @<spec>.manifest.yaml | --amend @<spec>.manifest.yaml <intent...>"
metadata:
  version: "0.1.0"
---

# Spec Generation (`/spec`)

The spec tier is an **interrogator, not a generator**. It converts raw intent into
a product-approvable Spec plus a complete Verification Manifest by walking the
manifest schema as a question tree and **refusing to finalize** while any
completeness rule fails. Generation happens — prose drafting, behavior proposal,
vitals mapping — but always as the *output* of interrogation, never a substitute.
The differentiator vs generation frameworks: **silence is impossible on the
straight-through path**. A wire-transfer flow cannot reach `completeness: complete`
without an idempotency answer (manifest rule 2). The floor being raised is the
*question floor*, not the prose ceiling.

Governing decisions: **ADR 0002** (escalation criterion — vendored here as in
every tier), **ADR 0005** (GWT behaviors, no Gherkin runtime), **ADR 0006**
(Config Profiles), **ADR 0008** (a complete manifest's output gates autonomous
drains), **ADR 0009** (Spec lifecycle; Pickup is the Claim event). Vocabulary:
`CONTEXT.md` is normative for every capitalized term.

## Posture (read first)

This is the **second-lowest-trust plugin** after the audit — the adoption on-ramp
for teams that want better specs before they want drains. Every write is
**markdown / YAML + a git branch/PR only**: the draft Spec, the manifest, S2
glossary edits, S4 draft ADRs. It **never writes product code, runbooks, or
trackers** (Hard Contract 3). The deterministic substrate under `scripts/` is
covered by `scripts/self_test.sh`; run it after any change there.

Tradeoffs are resolved **agent-vs-agent first** (the S4 adversarial round) and
only the MUST-escalate residue reaches a human — human confirmation of a
recommended default is rubber-stamping, not scrutiny (ADR 0002).

### Escalation boundary (ADR 0002 — the one rule, vendored verbatim)

The boundary below is the same MUST-escalate rule autopilot and the audit carry, **byte-identical** (kept in sync by the repo `lint_consistency.sh`). For this tier the S4 adversarial round is where resolvable decisions settle and S5 presents only the residue; the spec-gen decision log is the manifest `interrogation.log`, not a tracker (HC3 — this tier never writes trackers or product code).

<!-- vendored:escalation-criterion:begin (ADR 0002 — byte-identical across all tiers; do NOT edit one copy) -->
Resolve a decision yourself ONLY when it is BOTH (1) reversible at low cost — undoing it is a normal PR, not a migration or announcement — AND (2) verifiable downstream by the suite's own gates (a test, the D6 audit, or the audit tier). Record each such decision as a one-line decision-log entry (tracker + PR body); promote to an ADR only when it is hard to reverse, surprising without context, AND a real trade-off.

You MUST escalate — never decide unilaterally — any decision requiring:
1. values / risk appetite (e.g. silent-dedupe vs reject-and-alert on a duplicate);
2. external facts you cannot observe (alert seams, compliance, org standards, upstream commitments);
3. irreversible / outward-facing commitments (public API shapes, wire formats).
<!-- vendored:escalation-criterion:end -->

## Invocation and modes

| Invocation | Mode | Input class |
|---|---|---|
| `/spec [--profile <name>] <intent...>` | Fresh | Raw intent (paragraph, meeting notes, Jira) |
| `/spec @draft.md` | Fresh | Draft Spec — interrogated, not trusted; gaps found the same way |
| `/spec --resume @<spec>.manifest.yaml` | Resume | `completeness: incomplete` from a prior (possibly crashed) session |
| `/spec --amend @<spec>.manifest.yaml <intent...>` | Amend | Amendment against a merged Spec → `manifest_revision` N+1 |

**Profile resolution order (fresh sessions):** `--profile` flag → committed repo
config (`spec-gen.config.yaml` at repo root, `profile:` key) → `default`. When it
falls through to `default`, S5 MUST surface "no Config Profile is configured — is
`default` correct for this repo?" as its **first** escalation (an org-standard is
an external fact; agents don't assume it — ADR 0002). Resume/amend take the profile
from the manifest. This order is implemented deterministically by
`scripts/profile_resolve.py` — call it, don't reason it out by hand.

One session produces **at most one Spec + one manifest** (multi-doc unions are
autopilot's concern, not this tier's).

## Session lifecycle (S1–S7)

Each step below ends at a **boundary that commits the session branch** (Hard
Contract 5) — the manifest, draft Spec, and glossary edits are all branch state,
never context-only, so a killed session resumes losslessly via `--resume`.

| Step | Name | Produces |
|---|---|---|
| S1 | Hydrate | Reserved-ID set, resolved profile, prior-manifest + open-branch claim reads |
| S2 | Domain pass | Glossary (CONTEXT.md) edits committed to the branch |
| S3 | Skeleton proposal | Draft `<spec>.md` + proposed journey map + GWT behaviors + vitals |
| S4 | Adversarial round | Attacker findings, `resolved_by: agent` log entries, draft ADRs |
| S5 | Escalation | `resolved_by: human` answers for the MUST-escalate residue |
| S6 | Finalize gate | Validator exit-0 + GWT judgment gate, or refuse |
| S7 | Emit | One branch, one PR: Spec + manifest + draft ADRs + glossary edits |

### S1 — Hydrate

Read `CONTEXT.md`, the ADR index (titles + one-liners), the resolved Config
Profile, the committed manifest for this Spec path if one exists **on main**
(ID-reservation input, Hard Contract 7), and the **claim surface of open
spec-session branches** touching the same manifest path (ADR 0009 — overlapping
sessions are blessed, so ID allocation must see them). Feed the union of reserved
IDs to `scripts/id_alloc.py`. On `--resume`/`--amend`: run
`scripts/validate_manifest.sh` **FIRST** and trust its exit-3 output over the
stored `incomplete_fields` (the file may be stale after a crash); project it into
work slots with `scripts/resume_projection.py`.

### S2 — Domain pass

Extract candidate terms from the intent; challenge each against the glossary
(conflict → surface immediately; new term → propose a definition). Output persists
as **CONTEXT.md edits committed to the session branch** — file state, not manifest
fields and not context memory.

### S3 — Skeleton proposal

Dispatch a `general-purpose` agent with `references/s3-proposer.md`. It writes the
draft Spec skeleton to disk (`<spec>.md` — it must exist before any manifest
references it) and drafts the journey map (names, criticality + reasons, steps with
`vital_class`), the Acceptance Behavior list (**Given/When/Then**, IDs per the
manifest §6 grammar via the allocator), and proposes vitals per step from the
profile's taxonomy. Everything is **proposed**, not confirmed. Nothing here asks
the human anything — it is the *propose* half of propose-confirm.

### S4 — Adversarial round

Up to **two independent `general-purpose` attackers** (depth per §5, criticality-
scoped) attack the skeleton **before any human sees it** (ADR 0002):

- **Decomposition-refuter** (`references/s4-decomposition-refuter.md`) — missing
  journeys, wrong criticality, untestable behaviors, GWT naming no observable
  trigger. *CORE depth only.*
- **Consumer-simulator** (`references/s4-consumer-simulator.md`) — would the
  planner find unmapped work? do the §12 join keys exist? does every
  money/external-write step have an idempotency answer *proposed*? *Every
  criticality* (it survives reduction because its checks feed mechanical
  downstream gates).

Tradeoffs are resolved agent-vs-agent ONLY within ADR 0002's agent-decidable
class. Each resolution is an `interrogation.log` entry with `resolved_by: agent`
and **non-empty `dissent`** (manifest rule 6). The S4 output schema REQUIRES an
`escalation_check: clear | flagged:<values|external-fact|irreversible>` field per
resolution — the ADR 0002 trilist applied as a **checklist, not vibes**; any
`flagged:` resolution is involuntarily promoted to S5. Clear + ADR-worthy
resolutions are drafted as `status: agent-decided` ADRs under provisional
filenames `docs/adr/DRAFT-<session-slug>-<title>.md` (the number is assigned at
merge/rebase — renumber-at-rebase is legal and required).

### S5 — Escalation

Dispatch/inline `references/s5-presenter.md` over what survives S4: the
MUST-escalate residue (values/risk appetite, unobservable external facts,
irreversible commitments) plus everything `flagged:` by the checklist. Present each
**one at a time, with the adversarial round's recommendation and dissent attached**
(grilling discipline, Hard Contract 4). Answers land as `resolved_by: human`
entries (`exchange_ref` → the transcript section in the PR description).
**Effectively-CORE `confirmation: confirmed` comes ONLY from S5 human answers** —
there is **no agent path to confirmed-CORE** (manifest §10 class (b), rules 4 & 8);
the S4 agent path confirms sub-CORE entries only. A human may defer *confirmation*
on SUPPORTING/DEV entries; rules 1–2 escalations (vitals intent, idempotency) fire
for ANY journey with non-null `vital_class` steps regardless of criticality.
**Restructuring transition:** an S5 answer that raises effective criticality or
adds/removes a journey re-enters S4 at the new depth for the affected entries only
(bound: 2 re-entries per entry; the third becomes its own S5 escalation).

### S6 — Finalize gate

Run `scripts/validate_manifest.sh`:

- **Exit 3** → refuse to finalize; echo each `[SPEC-INCOMPLETE: rule-<n>: <path>]`;
  route mechanical-class rules to S3/S4 for silent fix, escalate-class rules to S5
  (the split is `scripts/resume_projection.py`'s partition).
- **Exit 4/5** → the session's own emission is defective (the tier authors every
  byte): internal defect — fix and re-validate; never persist a schema-invalid
  manifest.
- **Exit 0** → additionally run the **GWT judgment gate** (manifest §5): judged by
  a fresh `general-purpose` agent in the **decomposition-refuter role**, never the
  S3 author. This role is dispatched for the gate at EVERY criticality — including
  SUPPORTING/DEV, where the S4 refuter *round* does not run (§5) — because the gate
  is a role, not the S4 round; a vital-free SUPPORTING spec still gets its GWT
  judged. Failures loop the named behaviors to S3 (bounded at 2 retries, then
  surface at S5 as "untestable behavior"). **Exit 0 + GWT pass is the ONLY path to
  S7.**
- **Deferred exit:** writing `completeness: incomplete` and exiting is legal ONLY on
  an explicit human `defer` at S5, never on the orchestrator's own initiative. (An
  escalation surfaced 3 times without an answer is treated as `defer`.)

### S7 — Emit

Before opening the PR, run `scripts/emission_check.py <bundle>` to gate the
emission shape (one-branch-one-PR, manifest colocation, per-boundary commits,
`exchange_ref` resolvability, provisional-ADR filenames). Finalize `<spec>.md` +
`<spec>.manifest.yaml` (`completeness: complete`) + S4 draft ADRs + S2 glossary
edits — all already on the session branch (Hard Contract 5) — and open **one PR**.
The PR body carries the interrogation summary: decisions by class, dissents,
`escalation_check` outcomes, and every human exchange (the `exchange_ref` target).
Spec lifecycle from here is ADR 0009's: product-approved → merged to main → Pickup
(autopilot's claim event, not this tier's job). **Rejection at product approval:**
the PR closes unmerged; IDs from never-merged revisions are NOT reserved
(main-lineage only); rework re-enters as a Draft-Spec input to a fresh session.

## Hard contracts (§4 — non-negotiable)

1. **Refuse-to-finalize.** `completeness: complete` is written ONLY on validator
   exit 0 plus the S6 GWT gate. No override flag exists.
2. **Propose-confirm.** Nothing enters the manifest as `confirmed` without a
   recorded resolution: S5 human answers for effectively-CORE (exclusively),
   ADR-0002-legal agent resolutions with `dissent` + `escalation_check: clear` for
   sub-CORE. **There is no agent path to confirmed-CORE** (rule 8 makes this
   file-checkable; effectively-CORE confirmation comes only from an S5 human answer).
3. **One writer.** This tier is the manifest's **only writer** (manifest §7) and
   never writes product code, runbooks, or trackers.
4. **Escalations are one-at-a-time with a recommendation** — never a questionnaire
   dump, never a question without the recommended answer and surviving dissent.
5. **Session death is safe.** Every S-step boundary **commits** the session branch
   (manifest + draft Spec + glossary edits — all state is branch state). A killed
   session resumes losslessly via `--resume`. A mid-session manifest is
   schema-valid: `spec.spec_hash` is required only at `completeness: complete`.
6. **Vanilla agents only, role-via-prompt.** S4 attackers are `general-purpose`
   agents with the role prompts under `references/`; no custom subagent types.
7. **ID allocation** is monotonic within the session and never reuses IDs present
   on main's lineage OR in open spec-session branches touching the same manifest
   path (both read at S1) — enforced by `scripts/id_alloc.py`.

## Criticality-scoped rigor (the fast path — §5)

Rigor follows **effective criticality**, not document size:

| Criticality | S4 depth | S5 requirement | Ship state |
|---|---|---|---|
| CORE | full two-attacker round | every escalation answered by the human | `confirmed` only (rule 8) |
| SUPPORTING | consumer-simulator only | rules 1–2 answered; confirmation deferrable | `proposed` legal |
| DEV | consumer-simulator only | rules 1–2 answered; else none | `proposed` legal |

The rigor **floor**: ANY journey with vital steps pays rules 1–2 interrogation at
any criticality; the minutes-fast path is real only for vital-free specs. S3
criticality is provisional — the S5 restructuring transition re-runs S4 at higher
depth when a human upgrades an entry (rigor is re-scoped, never grandfathered).

## Deterministic substrate

The LLM interrogation cannot be self-tested; the deterministic seam can and is
(`scripts/self_test.sh`). Call these instead of reasoning the logic out by hand:

| Script | Role |
|---|---|
| `scripts/validate_manifest.sh` | Manifest validator (vendored **byte-identical** from repo root; exit 0/3/4/5). S6 finalize gate. |
| `scripts/id_alloc.py` | §6 ID allocation: next-ID, 999→new-slug, main-lineage + open-branch reuse refusal. S1/S3. |
| `scripts/resume_projection.py` | Validator exit-3 → escalate-class (rules 1,2,4) S5 slots vs mechanical (0,3,5,6,7,8) S3/S4 queue. S1/S6. |
| `scripts/profile_resolve.py` | Profile resolution order (flag → repo config → default+escalate). S1. |
| `scripts/emission_check.py` | S7 emission-shape gate (one-branch-one-PR, colocation, per-boundary commits, refs, ADR filenames). |
| `scripts/self_test.sh` | Hermetic self-test (`uv run`, ADR 0015) + `lint_consistency.sh`. |

## Reference index

| File | Purpose |
|---|---|
| `references/s3-proposer.md` | S3 skeleton proposer role prompt (propose-only). |
| `references/s4-decomposition-refuter.md` | S4 attacker (CORE depth): structure/testability. Output schema REQUIRES `dissent` + `escalation_check`. |
| `references/s4-consumer-simulator.md` | S4 attacker (all depths): downstream-consumer breakage. Output schema REQUIRES `dissent` + `escalation_check`. |
| `references/s5-presenter.md` | S5 escalation presenter (one-at-a-time, recommendation + dissent). |
