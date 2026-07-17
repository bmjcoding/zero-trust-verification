# Simplification & readability review — 2026-07-17

Full-repo e2e read (four parallel deep-readers: autopilot, cleanup-audit/agents/commands,
plugin substrate, docs/root tooling; key claims re-verified against the live tree).
Goal: further simplification and human-readability without weakening any deterministic
gate. Doctrine: ADR 0025 — keep the gates, gut the prose.

**Status at review time:** main @ 6790083, v2.1.0-rc.1 (plugin.json), ~41.7K tracked
lines (excl. worktrees/uv.lock) vs the ADR 0025 target of 25–28K. ~12.4K (~30%) is
self-test harness. Nothing found requires weakening any gate.

**TL;DR:** Waves 1–3d of ADR 0025 ran and worked; **Waves 4 and 5 never executed** and
are where the remaining weight sits. One real bug found (seven stale pre-consolidation
default paths). One likely wiring gap (CH-01/CH-03 have no live caller). The
documentation layer still narrates the retired six-plugin/marketplace world.

---

## 1. BUG — fix first: seven stale `plugins/autopilot/` default paths (verified)

Wave 1 moved autopilot to `plugins/zero-trust/skills/autopilot/`, but seven scripts
still default to the pre-consolidation `plugins/autopilot/scripts/…` path (directory
does not exist). Masked because every self-test injects `MARSHAL_HOST`/`TRIAGE_HOST`/
`--host` — no assertion covers default resolution.

| Site | Effect when default used |
|---|---|
| `plugins/zero-trust/scripts/marshal.sh:68` | bare `marshal.sh` (the documented cron entry in `references/marshal-loop.md`) exits 66 "host adapter not found". Comment at `marshal.sh:31-32` states the CORRECT path — code and comment disagree in the same file. |
| `plugins/zero-trust/scripts/loop_guard.py:45` | `is-open` can't query PR state → every ledgered key reports `open (state=unqueryable)` → **all re-fired incidents silently suppressed forever** (fail-safe direction, wrong reason). |
| `plugins/zero-trust/scripts/resume_handoff.sh:30` | dies "host adapter not found". |
| `plugins/zero-trust/scripts/outcome_capture.sh:40` | silently degrades to `--no-host` (change-failure/MTTR dropped). |
| `plugins/zero-trust/scripts/outcome_digest.sh:30` | same silent degrade. |
| `plugins/zero-trust/scripts/backends/cloudwatch.sh:23` | wrong `secret_get.sh` path in REFUSE messages. |
| `plugins/zero-trust/scripts/backends/dynatrace.sh:20` | same. |

Correct default: `…/skills/autopilot/scripts/{host.sh,secret_get.sh}` (exists; lint V13
already checks that path at root `lint_consistency.sh:569`).

Fix PR should include: 7 one-line edits + **one new assertion that the default path
resolves to an existing file** (the class the self-tests don't cover).

Smaller cousin in the same PR: `skills/autopilot/scripts/hot_file_audit.sh:77` excludes
the retired `tracker` branch name but not the current `runbook` branch.

---

## 2. Waves 4 & 5 never ran (the big sanctioned lever)

Git history: Waves 1, 2, 3a–3d merged as PRs #42–#48 (2026-07-12); campaign then
pivoted to ADR 0026 (grill-first) and the product-platform-spec spec. No wave-4/wave-5
commits; no `tests/lib/`. `docs/specs/refactor-2026-07-consolidation.md` was never
updated — it reads as if all five waves are pending. **Add a status block** (Waves 1–3
executed, with the ADR 0027 divergence: marketplace retired rather than re-registered;
Waves 4–5 not executed).

### Wave 4 — shared test harness (~300–400 lines of pure boilerplate)
- `pass/fail/assert_eq/assert_contains(/assert_rc)` re-declared in SEVEN files:
  `self_test_marshal.sh:33-39`, `self_test_org_memory.sh:36-42`, `self_test_triage.sh:56-63`,
  root `outcome_self_test.sh`, `sd_self_test.sh`, `tests/codebase-health/self_test.sh`,
  autopilot `self_test.sh`. → one `scripts/test_harness.sh`.
  Caution: preserve exact `ok [id]`/`FAIL [id]` output shapes and the suite
  skip-detector wording (see deliberate phrasing `self_test_org_memory.sh:328-329,542-546`).
- uv-bootstrap "find nearest pyproject and exec" in 5+ copies: `_owm_run.sh:14-37`,
  `_triage_run.sh:17-42`, `validate_manifest.sh:8-22`, `mock_host.sh:20-37`,
  cleanup-audit `py_run.sh`; plus three behaviorally-identical `--no-project` Python
  runners (`remediation_lib.sh:rl_pyrun`, `mutation_adapter.sh:_mut_py`,
  `outcome_emit.sh:py`). → one sourced `_py_run.sh` (~90 lines). The two `--project`
  variants differ for a documented reason — leave them.
- autopilot `self_test.sh` internal compression (~125 lines): nine structurally
  identical planted-lint blocks (lines 2217–2326, L16–L23) → `plant_and_expect_red`
  helper (keep L18b's fixture self-check at 2261; keep every plant); ~6 repeats of
  git-init boilerplate → `mk_repo` helper.
- Assertion counts are an explicit floor (ADR 0025 Consequences).

### Wave 5 — bitbucket.sh (901) / github.sh (486) dedup (~120–180 lines, optional)
Genuinely shared: `die_state`/`die` (bitbucket.sh:118-125 ≡ github.sh:87-93),
~10 per-subcommand arg-parse loops ×8 lines each side (e.g. bitbucket.sh:494-501 ≡
github.sh:172-180), `resolve_trunk` shells (bitbucket.sh:790-804 ≈ github.sh:372-383),
usage/dispatch, origin-URL host regexes (third copy in secret_get.sh:122-129 /
secret_set.sh:101-105). REST-vs-`gh` cores are NOT shareable. `contract_matrix`
(self_test.sh:322-366) already proves cross-backend parity behaviorally — this buys
maintenance, not correctness. Skippable per the original spec.

---

## 3. Structural simplifications

1. **Move the outcome family into the plugin.** Ten runtime files
   (`scripts/outcome_{store,report,dora,emission,external,assemble,annotate,baseline}.*`)
   live at repo ROOT while their three production callers live inside the plugin and
   escape via `SUITE_ROOT="$HERE/../../.."` (`outcome_capture.sh:29-32`,
   `outcome_digest.sh:28-29`, `outcome_emit.sh:29-31`). Contradicts README:126
   ("everything installable lives here") and README:138 mislabels them "dev tooling".
   Works today only because the skills-dir symlink sits inside the full clone.
   Same-PR updates: `outcome_self_test.sh:26-32` paths + lint V11 references.
   The .py/.sh pairing itself is justified (sh = CLI/uv bootstrap, py = logic); no dead
   members. Optional fold-in: shared `_outcome_lib.sh` for the `py()`/`iso_utc()`
   duplicates (5–6 files) and a shared `_flag()` module (6 .py files) — ~60–80 lines.
2. **Collapse to one uv project (~358 lines).** Root vs plugin `pyproject.toml`+`uv.lock`:
   identical dependency graphs, differ only in name/version (uv.lock lines 331-332).
   Re-point root harnesses' `--project` (`self_test.sh:16`, `sd_self_test.sh:47`,
   `tests/codebase-health/self_test.sh:44`, `outcome_store.sh:21`) or the plugin's
   (`validate_manifest.sh:8-15`, `self_test_spec_gen.sh:27`). Own PR; SUITE_STRICT is
   the gate.
3. **Version identity — make one number win.** `plugin.json` 2.1.0-rc.1 vs plugin
   `pyproject.toml` 2.0.0rc1 vs README:7 "v2.0.0-rc.1" vs `mcp_server.py:40` 0.1.0 vs
   root pyproject 0.1.0. No v2.x git tag exists (RCs only).
4. **Archive autopilot CHANGELOG tail (~230 lines).** Entries ≤2.4.0 (lines 281–511) →
   `plugins/zero-trust/docs/autopilot/CHANGELOG-v2.md` (precedent: CHANGELOG-v1.md,
   per-domain changelogs). L12 lint parses only the TOP entry. Keep the release-gate
   header (line 5) — but fix it: it cites `docs/GAPS_SPEC.md`, deleted in Wave 2.
5. **Command→reference dedup in cleanup-audit (~60–80 lines).** Commands restate the
   references they declare canonical:
   - `commands/health-loop.md:21-37` "Posture" restates `references/health-loop.md:9-13,71-93,100-101,15-27`
     right after saying "read the reference FIRST… this command adds only invocation
     modes". The merge hatch is currently described in 3 places (command, reference,
     `loop.config.yaml:24-35`).
   - `commands/remediate.md:19-28,37-62` vs `references/remediation-loop.md:12-19,21-43` —
     keep the script-sequenced version once (~20 lines net).
   - `commands/verify.md:41-49,61-67` re-specifies the N=5 gate + ratchet parameters that
     `audit-state-and-verify.md:165-188,190-226` owns — highest-drift-risk copy in the
     command set; keep procedure order + citation, drop re-specified parameters.
6. **The one unpinned drift pair:** `sd_seeds.sh:36-38,70` carries byte-duplicates of
   `TEST_PATH_RE`/`VITAL_RE`/`TX_RETRY_RE` from `run_audit.sh:186-187` (which claims
   "single consumer") with NO lint pin. Source/export from one place (run_audit already
   invokes sd_seeds; pass via env).
7. **Mirrored severity mapping:** `business-vitals.md:95-113` duplicates
   `severity-rubric.md:29-44` HIGH/MED cap logic as a self-acknowledged
   "change-them-together" pair → 3-line citation (~12 lines).
8. **Housekeeping (zero risk):** delete untracked on-disk residue
   `plugins/{codebase-health,org-memory,spec-gen,triage}/` (only gitignored
   `.venv`/`__pycache__`, 4.2M — actively suggests six plugins still exist),
   `plugins/zero-trust/.venv`, `scripts/__pycache__/validate_manifest.cpython-314.pyc`.
9. Stale RED-FIRST comment in `tests/codebase-health/self_test.sh:177-181` (the 1.4.0
   wave landed long ago) — 5 dead lines.

---

## 4. Human-readability improvements (value order)

1. **A codename key — the single biggest fix.** ID families used with no findable
   definition: `AP-x` (adversarial-review findings), `AV3-x.n` (v3 register assertions —
   register file gone, see §6), `CH-x`, `RL-x`, `MT-x`, `SD-x`, `OM-x`, `HC-n` (hard
   contracts), `MS §n` (= `docs/specs/verification-manifest-v1.md`, never expanded),
   `DL-###`, Defects A–H, `W345-*`, self-test families `T/HD/HG/H50`. → ~20-line
   "ID conventions" table (prefix → meaning → home doc) in README or a shared
   reference; plus a 10-line legend in autopilot self_test.sh's header, plus a 10-line
   script-family index in cleanup-audit SKILL.md (its Scripts section lists 4 of ~30).
2. **Name collisions — cheap renames, zero semantics:**
   - `lint_consistency.sh` ×3: root (V2,V6,V9–V13 repo rules, 579), plugin scripts
     (spec-gen L1–L8, 123), autopilot (L1–L23, 382). NOT duplicates — but two share the
     `L<n>` namespace ("LINT-FAIL [L2]" is ambiguous in suite output). Rename plugin one
     → `lint_spec_gen.sh` (callers: `self_test_spec_gen.sh:31,43`) or prefix ids.
   - `validate_manifest.sh` ×2: autopilot's is `--union`-only (105 lines); plugin's is
     the canonical schema/completeness validator. lifecycle.md:9 must carry a warning
     sentence just to disambiguate → rename autopilot's `validate_manifest_union.sh`
     (update lifecycle.md:9,84; SKILL.md:140; self_test 1208–1320) or fold `--union`
     into the canonical validator. Also: plugin `validate_manifest.sh:18-19,30` still
     says "vendored per ADR 0001" — false post-0025.
   - `run_cases.py` ×2: root = validator driver (209); plugin = spec-gen substrate suite
     (347, and it imports the validator + reads ROOT fixtures anyway — not standalone).
     Rename plugin one `run_spec_gen_cases.py` or merge trees.
   - `mock_host.sh` ×2 with DIFFERENT contracts: `scripts/mock_host.sh` (marshal,
     `MARSHAL_MOCK_*`) vs `fixtures/host/mock_host.sh` (triage, `MOCK_PR_*`). Rename one.
   - Three `self_test_*.sh` headers self-identify as `self_test.sh` / as "plugin"s.
3. **Retire the six-plugin narrative from live docs:**
   - `CONTEXT.md:3` still "the three-tier suite"; Tier entry (79-81) says "three
     independently runnable stages"; glossary missing triage, org-memory, health-loop,
     honesty class, locus.
   - `docs/marshal/README.md:4-6` "fourth plugin, installable entirely on its own";
     `:10-15` **falsely** claims `pr-list-ready` wiring is a tracked follow-up (MG01–MG03
     prove it shipped; contradicts host-contract.md); points at renamed self_test.
     `docs/triage/README.md:3` "sixth plugin"; `docs/org-memory/CHANGELOG.md:8` "fifth".
     Candidate: fold five READMEs into one `docs/README.md` with per-domain sections;
     freeze changelogs as history (~300–450 live lines).
   - Register one-line supersession notes: `prod-triage-register.md:2-9` ("SIXTH
     registered plugin… V6 assert six"), `org-wide-memory-register.md:10-11`,
     `outcome-measurement-register.md:29-30` ("V11 is the next free rule"),
     `spec-gen-tier-v1.md:214-216` (contradicts its own :245). CAUTION:
     outcome-measurement-register is live grep-input to lint V11 H1
     (root lint 399–422) — avoid `[det]`/`agent-graded` collocations; run suite.
4. **Indexes:**
   - `docs/adr/README.md` (~30 lines): number → title → status → superseded-by. Natural
     home for supersession annotations. Unannotated narrowed/superseded ADRs: 0001,
     0011, 0016, 0017, 0019, 0020, 0023, 0024; 0025's marketplace clause retired by
     0027; **0018's title is a copy-paste duplicate of 0017's** (real defect). Styles
     split: 0001–0024 YAML frontmatter vs 0025+ bold-markdown.
   - `docs/specs/README.md` (~10 lines) labeling genre + liveness: living contract
     (verification-manifest-v1 — though its §8/§13.3 still describe per-plugin
     vendoring, behavior-coverage-format, outcome-store-contract) / frozen build record
     (codebase-health-spec-1.4.0 — live V10 grep-input, banner must not touch §12;
     refactor-2026-07-consolidation — needs status block) / registers (append-only) /
     product-spec-in-flight (product-platform-spec.md + 1305-line manifest + 2 DRAFT
     ADRs — a product spec awaiting a build, candidate for `docs/specs/gateway/`
     subtree so suite contracts stand out).
5. **Stale "vendored" prose sweep (~40 sites, comment-only).** Each should say
   "canonical single copy (ADR 0025)" or nothing: `owm.py:9-15,68,234`,
   `extract_memory.sh:5`, `correlate.py:33`, `resume_projection.py:115`,
   `emit_incident_spec.py:39`, `profile_resume.sh` + `resume_handoff.sh` RESOLVER
   comments, `id_alloc.py:40-42`, `self_test_triage.sh:17`, `manifest_lib.sh:7-9`,
   `remediation_depth.sh:40`, mutation-adapters.md:11,18 decorative markers (V7
   retired; the escalation-criterion markers ARE still load-bearing — L22 diffs them).
   Two actively-false ones:
   - `skills/autopilot/scripts/claim_overlap.sh:4-9` — "do NOT edit one copy without
     the others" for a file with exactly ONE copy (Marshal-plugin era).
   - `skills/cleanup-audit/scripts/mutation_adapter.sh:11-13` — self-contradictory
     ("vendored BYTE-IDENTICAL into autopilot … ADR 0025: single copy"; nothing is
     vendored, mutation_gate.sh path-resolves it at :53).
   Plus stale assertion labels: autopilot self_test MT-01.a/b/c (1693–1700) say
   "vendored adapter" while testing the canonical one (keep assertions, fix wording).
   Plus `classify_fix.sh:46-47` comment wrong about `log-only-refund` routing (it's
   agent-provenance per slug_provenance.tsv:18-24 → INELIGIBLE, never routes).
6. **Dead pointers:** `docs/GAPS_SPEC.md` cited from autopilot CHANGELOG:5 (the live
   release-gate header!), :283,:287,:332,:366 — file deleted in Wave 2.
   `docs/specs/autopilot-v3-register.md` absent but AV3-xx cited ~80× (ids still
   resolve to self_test assertions, so evidence chain holds; reword or restore).
   `sidecar-contract.md:3` lists ci_check.sh as REST-calling (it now calls host.sh only).
   `runbook-template.md:244` hardcodes `host: bitbucket-dc` in the CANONICAL tracker
   schema despite ADR 0013 host-agnosticism.
7. **Local polish:** `plugin.json:5` description is one ~1,600-char sentence (first
   thing the plugin UI shows) → two sentences + README pointer. `lifecycle.md` (532)
   needs an 8-line TOC. `SKILL.md:140` 20-script run-on paragraph → table or delete.
   SKILL.md:30 merge-authorization paragraph triple-states one rule.
   `commands/health-loop.md:14-19` one 6-line noun-phrase sentence → split/delete with
   §3.5. ALL-CAPS density in cleanup-audit references (outcome-emit.md: 9 shouts in 11
   lines) → halve without touching semantics. `check_new_debt.sh:62` thinking-out-loud
   comment. `commands/audit.md:70-71` `--focus` table covers 3 of the advertised
   values. Intra-file restatements in autopilot: delegation contract ×3 in SKILL.md
   (22-26,28,65), stale-ACTIVE reclaim ×3, D6.4/D6.5 honesty rule in 5 places
   (mutation_gate.sh's 47-line header → usage + pointer, ~20 lines),
   repo_shape_probe.sh 74-line header restating auto-seed rationale (~15 lines),
   bash-3.2 array-guard essay ×3. Agents/*.md boilerplate (~30-40 repeated lines
   across 7 files) — LOW priority: they're dispatched standalone, factoring costs each
   agent a file-read; trim to one-line forms only. s4-consumer-simulator.md:3-15 ≈
   s4-decomposition-refuter.md:3-17 ADR-0026 preamble → grill-contract.md (~10 lines).
8. `owm.py` cosmetics: hand-rolled CLI parse (780-806) diverges from siblings' argparse
   and silently drops unknown flags; four near-identical `_record()` constructions.
   No dead subcommands — all six wired.

---

## 5. OPEN QUESTION — CH-01 / CH-03 have no live caller

`ingest_manifest.sh` (CH-01, manifest→MODE token) and `manifest_join.sh/.py` (CH-03,
the §12 intended-vs-discovered join + SD rows) are referenced by NO command and not by
`pr_gate.sh` — only self-tests call them. `pr_gate.sh:140-142` prints
`[not-covered] manifest-coverage (§12 join)` when a manifest is ABSENT but never runs
the join when one is present. Either the ambient-audit orchestration lives only in
docs/specs (machinery without a driver), or a one-line dispatch is missing in
pr_gate.sh / commands/audit.md. **This is a trust/accuracy question, not a
simplification one** — as-is, the manifest-coverage join the README advertises may
never fire in practice. Decide: wire it or declare it.

---

## 6. Trust-critical inventory — do NOT weaken while simplifying

- **Autopilot D6 chain:** audit_commit_shape.sh (range arithmetic `prev_pushed_sha..HEAD`),
  audit_behavior_binding.sh (`grep -w` :86), determinism_gate.sh `_dg_normalize`
  fingerprint (:76-99, node-id-verbatim, red-tested AV3-12.8/12.9), mutation_gate.sh
  worktree isolation + trap (:104-120) + budget-degrade semantics (inconclusive → exit 0).
- **Fail-closed exit contracts:** detect_concurrent_drain 0/1/2/3/4/64; claim_overlap
  eligibility 0/2/64 (UNKNOWN/empty→64); ci_check 0-5/64; detect_input_mode refuse
  paths (`--yolo` cannot bypass); manifest_revision_gate 3/2; wave_gate 0/2/3/4 w/
  fail-closed unknown-fingerprint; spec_wave refuse exits 3/5/1/7.
- **/verify determinism:** 5 fresh processes, one order-randomized, N=5 FIXED no
  override; PARTIAL never rounds up; FIXED requires `verified_by`; removed-symbol
  closure requires FIX_LOG/DELETION_LOG naming the finding.
- **Ratchet & guards:** same-target baseline only; absent-count-never-0;
  check_new_debt hook-surface unconditional exit 0 vs CLI strict (the one strictness
  contract); remediation Guard 1 fail-safe-to-FILED, Guard 2 unknown→ESCALATE, Guard 3
  never-merges; RL-02 agent-scored-never-drains via slug_provenance.tsv (V10-pinned —
  the "dead" TX branch in classify_fix.sh:44-45 is a DELIBERATE superset, keep);
  wave_preauth P1–P4 + double-keyed hatch + journal fail-closed.
- **Marshal zero-judgment path:** APPROVED-only strict FIFO (:132-137), D7.0 refusals
  (:187-230), composed-state SUCCESSFUL-only merge + one-in-flight (:242-276),
  merge-failure never reported merged, hotfix pin never bypasses build gate.
- **Validator semantics:** exit 0/3/4/5; YAML-1.2 Norway guard; rules 0–8 incl. rule-8
  no-agent-path-to-confirmed-CORE; resume_projection unknown-rule→escalate (:70-77);
  id_alloc monotonic no-reuse.
- **OWM/MCP refuse-by-default:** `_parse_allow` neither-flag→refuse-all (owm.py:621-629);
  refusals never return records; closed MEMORY_GLOBS; byte-ceilings before open;
  mcp_server always passes allow-list, refusal as tool-result not transport error.
- **Triage bounds:** telemetry.sh both-bounds+max_span (:178-196); loop_guard
  timestamp-free key + unqueryable→open; correlate refuse on exit-4/5 manifest;
  emit_incident_spec incomplete-by-construction + validator exit-3 round-trip;
  DRAFT-PR-only, Spec-not-a-patch.
- **Secret discipline:** secret_get/set full flow, `bb_curl -H @file`, 401/403/407
  redaction, probe URL redaction; bb_curl retry ownership (NOT `curl --retry`; GET-only;
  407 abort) and the `has()`-not-`//` jq patterns (each guards a documented bug).
- **host.sh `exec` pass-through + contract_matrix** (self_test :322-366) — never fork
  per backend.
- **Lint pins & live grep-inputs** (edits near these need same-PR lint updates + suite
  run): V2 ← behavior-coverage-format.md literal line-shape; V10 ←
  codebase-health-spec-1.4.0.md §12 + slug_provenance.tsv + classify_fix superset;
  V11 ← outcome-store-contract.md vendored block + outcome-measurement-register tag
  lines (H1 anti-laundering); V13 ← health-loop pins incl. the skills/autopilot host
  path; escalation-criterion pointer blocks byte-pinned at 3+ sites; L18 entry-shape
  pins; L22 marker diff; L24 dispatch-claim map. Never renumber lint ids; retired ids
  stay retired. **Assertion counts are floors** (ADR 0025).
- **Ground-truth harness:** tests/codebase-health self_test + EXPECTED_FINDINGS.yaml +
  planted corpus + make_blind_corpus case-sensitive stripping; tests/fixtures/ shared
  by three consumers; suite_self_test red-test/false-positive matrix (:103-420) +
  component_skips skip-honesty + SUITE_STRICT semantics.
- **ADR bodies are history** — annotate, never rewrite. Register acceptance entries are
  append-only; corrections as new dated notes.

---

## 7. Suggested sequencing

1. **Bug PR** — §1: seven path fixes + default-resolution assertion + hot_file_audit
   branch name. Small, pure correctness.
2. **Decide §5** — wire CH-01/CH-03 into pr_gate//audit or declare them out.
3. **Docs-truth PR** — §4.3–4.6 + §2's refactor-spec status block: ADR annotations +
   `docs/adr/README.md` index + `docs/specs/README.md` genre index, register/README/
   CONTEXT.md corrections, dead-pointer fixes, stale-vendored sweep. Zero code
   semantics, biggest readability payoff. (Mind the V10/V11 grep-input cautions.)
4. **Structural PR(s)** — §3: outcome family into plugin, single uv project + version
   reconciliation, naming-collision renames, CHANGELOG archive.
5. **Wave 4** (shared harness, §2) — then **Wave 5** if appetite remains.

Realistic total: ~2.5–4K lines removed + a documentation layer that tells the truth
about the post-0025 architecture, with every gate byte-identical. Each PR through the
established gate: SUITE_STRICT zero-skip green, no assertion-count loss.
