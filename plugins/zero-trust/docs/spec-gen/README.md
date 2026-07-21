# spec-gen

The **Spec Generation tier** of the Zero-Trust Verification suite — an
*interrogator, not a generator*. It converts raw intent (a paragraph, meeting
notes, a Jira description, a draft ADR/PRD) into a product-approvable **Spec** plus
a complete **Verification Manifest**, by walking the manifest schema as a question
tree and **refusing to finalize** while any completeness rule fails.

The differentiator vs generation frameworks: **silence is impossible on the
straight-through path**. A wire-transfer flow cannot reach `completeness: complete`
without an idempotency answer (manifest rule 2). The floor being raised is the
*question floor*, not the prose ceiling.

## Install / invoke

Ships inside the one `zero-trust` plugin (ADR 0025), installed via the
skills-dir clone (ADR 0027 — see the root `README.md`). Surface: one skill
(`/spec`).

```
/spec <intent...>                             # fresh session from raw intent
/spec @draft.md                               # interrogate a draft Spec
/spec --resume @<spec>.manifest.yaml          # resume a prior/crashed session
/spec --amend  @<spec>.manifest.yaml <intent> # amend a merged Spec (revision N+1)
```

## Session lifecycle (S1–S7)

`hydrate → grill → synthesize → adversarial round (background) → residue grill →
finalize gate → emit` (grill-first since ADR 0026). The human interview is the front
door: grilling starts within minutes of invocation — **one decision per question,
one-line recommendation, facts looked up never asked**. The Spec + manifest are
synthesized FROM the conversation; the S4 adversarial round (two vanilla
`general-purpose` attackers — a decomposition-refuter and a consumer-simulator)
attacks the draft **in the background while the human reads it**, resolutions
written to the log, never read aloud; S5 grills only the residue the conversation
did not already answer. Every step boundary **commits the session branch**, so a
killed session resumes losslessly. Full step text:
[`skills/spec/SKILL.md`](skills/spec/SKILL.md).

The one rule with no agent path: **effectively-CORE `confirmation: confirmed` comes
only from a recorded human answer** — at the S2 grill or the S5 residue (manifest
§10 rule 8).

## Deterministic substrate

The LLM interrogation cannot be self-tested; the deterministic seam can and is.

| Script | Role |
|---|---|
| `scripts/validate_manifest.sh` | Manifest validator, **vendored byte-identical** from the repo root (ADR 0001). Exit 0/3/4/5. |
| `scripts/id_alloc.py` | Manifest §6 ID allocation: next-ID, 999→new-slug, main-lineage + open-branch reuse refusal. |
| `scripts/resume_projection.py` | Validator exit-3 → escalate-class (rules 1,2,4) S5 slots vs mechanical (0,3,5,6,7,8) S3/S4 fix queue. |
| `scripts/emission_check.py` | S7 emission-shape gate (one-branch-one-PR, manifest colocation, per-boundary commits, `exchange_ref` resolvability, provisional-ADR filenames). |

Run the hermetic self-test (bootstraps deps via `uv run`, ADR 0015; then the 8-rule
consistency lint and a planted-violation check):

```
bash scripts/self_test.sh
```

## Governing decisions

ADR 0001 (manifest contract, vendoring), ADR 0002 (escalation criterion),
ADR 0005 (GWT behaviors, no Gherkin runtime), ADR 0006 (vendor-neutral
observability defaults), ADR 0008 (a complete manifest gates autonomous drains),
ADR 0009 (Spec lifecycle), ADR 0015 (shell + Python-on-uv substrate),
ADR 0033 (Config Profiles removed). Vocabulary: `CONTEXT.md` is normative.

Spec of record: [`docs/specs/spec-gen-tier-v1.md`](../../docs/specs/spec-gen-tier-v1.md).
