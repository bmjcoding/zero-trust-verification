# Changelog — spec-gen

All notable changes to the Spec Generation tier plugin. This file is the single
source of truth for version history; `SKILL.md` carries no `version:` outside its
frontmatter. Per the M3 process gate (spec-gen §7.5), **every behavioral claim
below cites a self-test assertion** (`run_cases.py` group / `lint_consistency.sh`
rule) or is marked `[doc-only]`.

## [0.1.0] — 2026-07-05

Initial cut of the Spec Generation tier (spec of record:
`docs/specs/spec-gen-tier-v1.md`, deliverables SG-1..SG-8).

### Added

- **Plugin skeleton** (SG-1): `spec` skill encoding the S1–S7 session lifecycle;
  `/spec` command; `plugin.json`; marketplace entry in the repo-root
  `.claude-plugin/marketplace.json`. Lifecycle steps S1–S7 and all four §4 hard
  contracts are pinned by `lint_consistency.sh` L1/L2 `[det]`.
- **Role prompts** (SG-2): S3 proposer, S4 decomposition-refuter, S4
  consumer-simulator, S5 presenter as vendored references. The two S4 output
  schemas REQUIRE `dissent` + `escalation_check` (the ADR 0002 trilist as a
  checklist) — asserted by `run_cases.py` group F and `lint_consistency.sh` L6
  `[det]`.
- **Vendored validator** (SG-3): `scripts/validate_manifest.{sh,py}` +
  `schema/verification-manifest/v1.schema.json`, **byte-identical** to the repo
  root — asserted by `run_cases.py` group 0 and `lint_consistency.sh` L3/L4
  `[det]`. Validator reuse over the repo fixtures + a rule-8 mutation + the
  mid-session manifest: `run_cases.py` group A `[det]`.
- **Deterministic helpers** (SG-4): `id_alloc.py` (§6 grammar; next-ID, 999→new
  slug, main-lineage + open-branch reuse refusal — `run_cases.py` group B);
  `resume_projection.py` (validator exit-3 → escalate-class rules 1,2,4 vs
  mechanical rules 0,3,5,6,7,8 — group C); `profile_resolve.py` (flag → repo
  config → default+escalate — group D); `emission_check.py` (S7 emission-shape —
  group E). All `[det]`.
- **Session-death safety** (SG-5): per-boundary commit contract documented in
  `SKILL.md`; the killed-mid-S4 fixture resumes losslessly from branch state,
  reconstructing the full escalate residue independent of the stale
  `incomplete_fields` — `run_cases.py` group G `[det]`.
- **Self-test + consistency lint** (SG-6): `scripts/self_test.sh` (uv-bootstrapped,
  ADR 0015) runs the 81-assertion case suite, the 8-rule lint, and a
  planted-violation check that proves the byte-identity lint goes red on a
  tampered vendored copy `[det]`.

### Notes

- **SG-7** (ADR 0001 `amended-by: 0011`; ADR 0002 `rule-<n>: <path>` erratum +
  two-class echo): the ADR headers already carry these; this plugin adds the
  lint L-rule that pins the grammar (`lint_consistency.sh` L5 `[det]`).
- **SG-8** (induced PR Gate provenance check + main-lineage-only ID reservation):
  recorded for the codebase-health register (CH-07) — **not implemented here**
  `[doc-only]`.
