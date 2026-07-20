# Changelog

All notable changes to the Zero-Trust Verification suite are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/); the suite tag
is the release marker. Since v2.0.0-rc.1 the suite ships as ONE plugin
(`zero-trust`, ADR 0025) whose version lives in its `plugin.json`; per-domain
v1.x changelogs are preserved under `plugins/zero-trust/docs/<domain>/` (and
`plugins/zero-trust/skills/autopilot/CHANGELOG.md`).

## [2.1.0-rc.1] - 2026-07-12 (release candidate; tag at release merge)

### Changed — distribution: marketplace retired, skills-dir install (ADR 0027)

Managed Claude Code deployments now enforce marketplace allowlists that
third-party marketplaces cannot join — and a local-path marketplace add is
policed by the same allowlist. Distribution is now a local git clone consumed
through Claude Code's skills directory:
`ln -s <clone>/plugins/zero-trust ~/.claude/skills/zero-trust` (auto-loads as
`zero-trust@skills-dir` with every skill, agent, hook, and the org-memory MCP
server; update = `git pull` in the clone).

- **Removed** the root `.claude-plugin/marketplace.json` — the plugin's own
  `plugin.json` is the product entry point (no marketplace residue anywhere).
- **Lint V6 inverted**: was "ONE root marketplace registers exactly the one
  plugin"; now "NO marketplace.json anywhere (residue guard) + exactly one
  installable plugin under `plugins/` + plugin.json named `zero-trust`". The
  V13 full-tree presence key moves from the marketplace to the plugin.json.
  Self-test teeth re-cut to match (missing plugin.json, root + nested
  marketplace residue, rogue 2nd installable plugin, name drift; compact-JSON
  and non-installable-dir false-positive guards).
- Install/update/migration docs rewritten for the clone+symlink path;
  `--plugin-dir` documented as the session-only try-it door.

### Changed — /spec grill-first inversion (ADR 0026)

Minor bump: breaking only in *interaction shape* — no artifact, gate, schema,
script, or door changes. Field evidence: an operator field session
(~50 min of agent runtime before the first human question; 33 pre-adjudicated
findings; dissent-as-dialogue questions) rejected the pipeline-first flow.

- **S2 is now the GRILL** (was: agent domain pass): the human interview starts
  within a couple of minutes of invocation; the completeness rules are the
  question AGENDA; domain-term + draft-ADR capture happens inline; ends when
  the human confirms shared understanding. `[doc-only]` (prompt-level; the
  deterministic seam is unchanged — spec-gen run_cases 89/89 green).
- **S3 SYNTHESIZES from the conversation** (was: skeleton from raw intent);
  the draft is presented to the human for review.
- **S4 runs in the BACKGROUND on the draft** while the human reads it — same
  two attackers, same output schemas (run_cases §F pins verbatim);
  resolutions written to `interrogation.log`, never read aloud; S2-answered
  decisions are settled input, never re-litigated.
- **S5 is the residue grill**: only decisions the S2 conversation did not
  answer; re-asking an answered decision is a contract violation.
- **New shared reference** `skills/spec/references/grill-contract.md` — the
  question-style contract (one decision per question; ≤3 sentences of setup;
  recommendation in one line; dissent on request; facts looked up, never
  asked; no background work while a question is pending; bookkeeping batched
  at checkpoints). HC4 — same words — now governs S2 and S5 alike.
- The Config-Profile fall-through question moved from S5-first to early-S2
  (S5 asks it only if S2 never did).
- **Frozen (verified unchanged):** all seven §4 hard contracts; the §10
  completeness checker + every `scripts/` tool; the ADR 0002
  escalation-criterion block (byte-identical); §5 criticality-scoped rigor;
  the `--from-findings`/`--resume`/`--amend` doors (resume = re-enter S2 with
  the agenda = remaining unmet rules via `resume_projection.py`); HC5
  per-boundary commits. `docs/specs/spec-gen-tier-v1.md` amended with marked
  ⟨ADR-0026⟩ sections.

## [2.0.0-rc.1] - 2026-07-12 (release candidate; tag at release merge)

### Changed — six plugins consolidated into ONE `zero-trust` plugin (ADR 0025, Wave 1)

**Breaking:** plugin names and install paths change; every command name is
unchanged (`/spec`, `/autopilot`, `/audit`, `/verify`, `/remediate`,
`/health-loop`, `/architecture`, `/diagnose-bug`, `/dead-code`,
`/health-audit`, `/incomplete-logic`, `/marshal-pass`, `/marshal-staleness`,
`/triage`). Migration: uninstall the six old plugins, refresh the catalog,
install `zero-trust` (README §Install).

- Structural only — no gate/validator semantic change, no prose rewrites; the
  merge gates held: `SUITE_STRICT=1 scripts/suite_self_test.sh` green with
  ZERO skips before and after.
- **One canonical copy of every vendored artifact, inside the plugin:**
  manifest schema 4→1 (`schema/verification-manifest/`), validator toolchain
  4→1 (`scripts/validate_manifest.{sh,py}`; autopilot's distinct `--union`
  checker keeps its own path), `claim_overlap.sh` 2→1
  (`skills/autopilot/scripts/`), mutation adapter map + resolver 2→1
  (`skills/cleanup-audit/`), spec-gen resume helpers 2→1 (`scripts/`),
  outcome schema 3→1 (`schema/outcome/`). Root `schema/` and root
  `scripts/validate_manifest.*` deleted; root dev tooling re-pointed.
- **Escalation criterion (ADR 0002) extracted** to
  `references/escalation-criterion.md` (5 byte-identical vendored blocks → 1
  canonical file); the five prompt sites keep their markers and carry an
  identical short pointer (autopilot lint L22 and triage TR-06 still pin
  pointer byte-identity).
- **Lint:** byte-identity vendoring rules V1/V3/V4/V5/V7/V8 deleted with the
  copies they policed; V2/V6/V9–V13 kept with IDs unchanged (V6 now pins the
  single-plugin marketplace; V9's vendored-script pin became a re-vendor
  guard). 16 planted-drift red-tests for the deleted rules removed from
  `suite_self_test.sh` (+3 V1-teeth checks from the codebase-health harness);
  every surviving rule keeps its teeth tests.
- Marketplace registers exactly one plugin: `zero-trust@2.0.0-rc.1`.

### Added — /health-loop attended wave drain (ADR 0024)

One prompt runs audit → per-wave autopilot drain → merge → `/verify --strict` →
gate → next wave, until the original audit is drained. Shipped across three
PRs — substrate (#36), the loop (#37), enforcement (this entry):

- **Deterministic substrate** (#36) — `spec_wave.sh` (SPEC.md wave parser:
  waves/slice/fingerprints/forward-deps, fail-closed exit contract),
  `wave_gate.sh` + `.py` (pure-reader advance gate over `audit/state.json`:
  0 ADVANCE / 2 INCOMPLETE / 3 REGRESSION-or-RATCHET with a GLOBAL regressed
  scan / 4 UNREADABLE; ratchet mirrors `/verify`, `stdout_logging_count` stays
  report-only), `wave_preauth_check.sh` (P1–P4 evidence bar for delegated
  wave-PR approval, exact-match allow-list). Self-test HL-01..HL-03, 57
  assertions incl. planted red paths for every pre-merge adversarial-review
  finding (0 BLOCKER / 3 MAJOR / 4 MINOR / 2 NIT — all fixed with red-tests).
- **The loop** — `commands/health-loop.md` + `references/health-loop.md` +
  `loop.config.yaml` (wave policy, severity ceiling, `merge: pause |
  preauthorized` double-keyed hatch, depth-0 partial policy, budgets);
  merge-before-verify as a correctness rule; stateless position + append-only
  `audit/loop_log.md` journal; `/remediate` coexistence (drip vs drain,
  Guard-1 stamping with `health-loop:` ref prefix). ADR 0024.
- **Enforcement** — root lint **V13** (presence coupling all-or-nothing,
  config vocabulary, gate-status-subset-of-lifecycle, wave_gate read-only pin,
  full-tree autopilot/marshal presence) with four planted-drift red-tests + a
  false-positive guard in `suite_self_test.sh`; hermetic
  `tests/codebase-health/loop_e2e.sh` (HL-04) proving the dispatch composition
  — green path (position walk, delegated-approval journaling, Guard-1 stamps,
  empty-wave skip, drained no-op) and red paths (HUMAN_NEEDED stops before the
  next wave slices, REGRESSED halts with no stamps, forward dep refuses
  pre-generate, corrupt state fails closed).

No changes to autopilot, marshal, spec-gen, or `/verify`. Autopilot HC §4
(never merges) untouched — the hatch delegates *approval* only, behind
deterministic preconditions, and the Marshal's composed-state build executes
every merge.


---

v1.x suite history (1.0.0 – 1.2.0, the six-plugin era) moved to
`plugins/zero-trust/docs/CHANGELOG-v1.md` (verbatim, tags and release links
included). Per-domain v1.x changelogs remain under
`plugins/zero-trust/docs/<domain>/`.
