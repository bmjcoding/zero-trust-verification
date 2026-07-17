# Refactor spec — suite consolidation & prose diet (2026-07)

Governing decision: ADR 0025. This spec is the wave plan. Each wave is one PR,
built in an isolated session, adversarially reviewed, merged only on
SUITE_STRICT zero-skip green. Waves are ordered so that every later wave is
cheaper because of the one before it.

**Thesis:** keep the deterministic gates, gut the prose process layer, collapse
the plugin boundary that generates the vendoring.

Line-count targets below are goals that direct effort, not merge gates.
The merge gates are: suite self-test green zero-skip, no validator/gate
semantic change (waves 1–2 byte-identical behavior), no assertion-count loss.

**Status (2026-07-17).** Waves 1, 2, and 3a–3d executed as PRs #42–#46 and #48
(2026-07-12; #47 is the separate, still-open L24 lint PR). One divergence from the Wave 1 text: the marketplace was not
re-registered as one entry — it was retired entirely (ADR 0027, skills-dir
distribution). Wave 4 executed 2026-07-17 (this campaign's harness PR): one
sourced assertion library (`scripts/test_harness.sh`, both output dialects
behind `th_init`) adopted by all seven self-tests with per-harness assertion
counts provably unchanged (floors held: 94/76/113/75/72/470/405); one sourced
uv bootstrap (`plugins/zero-trust/scripts/_py_run.sh`) adopted by
`_owm_run.sh`, `_triage_run.sh`, `mock_host.sh`, `validate_manifest.sh`, and
the three `--no-project` runners in cleanup-audit (the plugin-pinned
`py_run.sh` stays separate by design); autopilot's nine planted-lint blocks
collapsed into `plant_and_expect_red` and its git-fixture boilerplate into
`mk_repo`. Divergence from the Wave 4 text above: no `tests/lib/` fixture tree
— the shared surface that actually repeated was assertions + uv bootstrap, and
`suite_self_test.sh` was already thin orchestration. Wave 5 remains open, with
appetite, per the 2026-07-17 review adjudication (ADRs 0028–0032 extend the
campaign).

---

## Wave 1 — Consolidation (structural, no prose edits)

Merge the six plugins into `plugins/zero-trust/` with single `skills/`,
`agents/`, `commands/`, `scripts/`, `schema/`, `references/` trees.

- Delete vendored copies: manifest schema (4→1), validator toolchain (4→1),
  claim-overlap (2→1), mutation adapter map (2→1), escalation-criterion block
  (5→1 — becomes `references/escalation-criterion.md`, prompts point at it).
- Rewrite `.claude-plugin/marketplace.json` to one entry; one `plugin.json`.
- `lint_consistency.sh`: delete V1/V3/V4/V5/V7/V8 (vendoring police) and their
  planted-drift fixtures; keep structural rules. Expected ~903 → ~350 lines.
- `suite_self_test.sh` re-pointed; every existing assertion still runs.
- README migration note (uninstall six, install one), version → v2.0.0-rc.

Exit: identical behavior, ~3–4K fewer lines, vendoring class extinct.

## Wave 2 — Sediment deletion (mechanical doc merges, no meaning changes)

- Delete `docs/GAPS_SPEC.md` (566 lines, superseded — verify no inbound refs).
- Merge `drain-lifecycle.md` (690) + `generate-lifecycle.md` (320) →
  one `lifecycle.md`; the shared machinery (state commits, session lock,
  heartbeat, resume) is stated once.
- One canonical loop-safety doc (currently split across loop-safety /
  remediation-loop / health-loop narratives — the guarantees are stated once,
  the loops cite them).
- Tracker schema and audit `state.json` schema each get one canonical
  definition; other docs link instead of restating.
- CHANGELOG history >1 major version old moves to `docs/history/`.

Exit: references tree roughly halved (5.2K → ~2.5K in autopilot's tree) with
zero semantic edits — every deletion is a duplicate or a superseded doc.

## Wave 3 — Prose diet (semantic, the careful one)

Rewrite skills and surviving references under the writing-great-skills
discipline (ADR 0025 §3):

- **No-op hunt, sentence by sentence.** Anything the model does by default
  goes. (Benchmark: the entire red-green TDD workflow reduces to "red before
  green, one slice at a time" plus anti-patterns — the loop lives in priors.)
- **Leading words over restatement:** seam, tracer bullet, frontier, red/green,
  drain, wave, ratchet. One strong word replaces each restated triad.
- **Progressive disclosure:** SKILL.md holds steps + completion criteria;
  reference moves behind pointers loaded only when a branch needs it.
- **Invocation taxonomy** applied to every skill (user-invoked orchestrators
  vs model-invoked discipline; orchestrators get
  `disable-model-invocation: true`).
- **Explain the why on every hard rule** — stated reasons measurably improve
  compliance (e.g. "asking multiple questions at once is bewildering").
- Import three proven upstream fixes:
  1. **Facts vs decisions** in S5 escalation and all grilling-style prompts:
     facts the agent looks up itself; decisions go to the human and the agent
     waits. (Fixes the documented Fable self-grilling failure mode — our
     production model.)
  2. **Explicit confirmation gates** wherever a phase must not roll into the
     next without human sign-off (S6→S7, GENERATE→DRAIN review pause).
  3. **Fowler-smell one-liners** in the review agents' standards axis —
     name the smell, one sentence each; the definitions live in priors.

Targets: spec SKILL.md 262 → ~140; autopilot references ~2.5K → ~1.5K;
planner/implementer/validator prompts each cut ≥30% with no gate weakened.

Gate for this wave only: per-skill definition-review after rewrite, plus one
field run (a real /spec session and a real drain on a fixture repo) before
Wave 4 starts.

## Wave 4 — Test harness unification

- Shared fixture library (mock host, git fixture repos with gpgsign pinned,
  YAML round-trip, manifest samples) under `tests/lib/`.
- Per-domain test files keep their assertions; boilerplate collapses into the
  library. Assertion count is a floor (autopilot's 377 included).
- One runner: `suite_self_test.sh` becomes thin orchestration.

## Wave 5 (stretch) — Host adapter dedup

Extract the shared pr-*/build-status op patterns from `bitbucket.sh` (901) and
`github.sh` (486) into a common layer; backends keep only transport specifics.
Medium risk, parity enforced by the existing identical fixtures. Skippable if
Waves 1–4 consume the appetite; the adapters are correct today, just repetitive.

---

## Out of scope (by declaration, ADR 0022 style)

- Tracker-as-state / wayfinder pattern (Bitbucket DC constraint — ADR 0025).
- Any semantic change to: 8-rule completeness checker, refuse-to-finalize,
  D6.5 mutation gate, N=5 determinism, marshal FIFO, outcome honesty classes.
- Manifest schema changes.
- New features of any kind.

## Expected end state

~46K → ~25–28K lines with identical gate semantics, one plugin, one copy of
every artifact, half the lint, and skills that lean on model priors instead of
restating them.
