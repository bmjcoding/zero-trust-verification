# Changelog

All notable changes to the Zero-Trust Verification suite are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/); the suite tag
is the release marker, and individual plugins carry their own `plugin.json` version.

## [Unreleased]

### Added — /health-loop attended wave drain (ADR 0024)

One prompt runs audit → per-wave autopilot drain → merge → `/verify --strict` →
gate → next wave, until the original audit is drained. Landed in three PRs:

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

No changes to autopilot, marshal, spec-gen, or `/verify`. Autopilot HC §4
(never merges) untouched — the hatch delegates *approval* only, behind
deterministic preconditions, and the Marshal's composed-state build executes
every merge.

## [1.2.0] — 2026-07-10

Field-hardening release: the first e2e production drain of the suite (audit-w345,
Waves 3–5, on a Bitbucket DC + Jenkins host) fed two retros back through the
improve-validate cycle; all 13 recommendations plus the 11 confirmed findings of the
pre-merge adversarial review are absorbed. Additive contract surface only — existing
runbooks, manifests, and drains are unaffected.

### Changed

- **autopilot 3.0.1 → 3.1.0** — absorbs the audit-w345 e2e field retros (Waves 3–5,
  2026-07-07/08): seam-inventory planning (`invalidated_seams` + monkeypatch
  inventory, L18-pinned), shared-helper blast-radius validation, Bitbucket DC
  split-SSH-endpoint host fix (`AUTOPILOT_BITBUCKET_HOST` override + `repo-coords`
  debug), `CI_STATUS_REPORTING` probe with honest `ci.skip_wait` degradation,
  `gates.format` format-before-commit, AP-1 new-file-relocation compressed-cycle
  exception, `regen_rituals` (producer-wired: implementer commit rule 8 +
  validator input 7), foreign-dirty-tree stashing, Resume stale-ACTIVE reclaim
  (gated on a dead-session signal, never lock expiry alone), and documented
  `--yolo` merge-authorization semantics (Hard Contract 4 unchanged). All 11
  confirmed findings of the pre-merge adversarial review (3 MAJOR / 8 MINOR)
  folded in, including PR-head build-status sampling and the dotless `-ssh`
  host strip. Plugin self-test 319 → 383 assertions, zero-skip,
  mutation-verified red-tests; suite lint V1–V12 green. See
  `plugins/autopilot/CHANGELOG.md` §3.1.0.

## [1.1.0] — 2026-07-07

Feature-complete: all six future-scope capabilities designed in v1.0.0 are shipped.
Every one is **report-only / advisory first** and every change is additive — existing
manifests, plugins, and drains are unaffected (`schema_version` stays 1). Each landed
via an isolated spec-first build and a multi-pass adversarial review; the whole suite
proves green in one command with zero skips (`SUITE_STRICT=1`).

### Added — capabilities

- **Mutation testing as a first-class gate** (autopilot D6.5 + codebase-health PR-Gate
  sibling). A surviving mutant on a *changed line* is a vacuous test: blocked at
  write-time in a throwaway worktree (the live checkout is never mutated), reported
  comment-only on CORE paths at the PR Gate (ingest-only). One adapter map, byte-identical
  across producer and consumer, pinned by lint **V7**. No repo-wide mutation score.
  (ADR 0016; #28)
- **Org-Wide Memory** — a new fifth plugin `org-memory`: a read-only, refuse-by-default
  index over the memory repos already commit (ADRs, glossaries, manifests, decision logs).
  Derived-view-only with a source pointer on every answer, ACL at query time, a
  hard-bounded read surface (memory globs only, never the code tree), a SQLite+FTS index,
  and a thin MCP query surface over the deterministic CLI. Vendoring pinned by lint **V8**.
  (ADR 0019; #27)
- **Remediation loop** — a codebase-health `/remediate` skill that routes confirmed,
  deterministically-scored audit findings into a findings-register → spec-gen → an
  autonomous drain → a PR awaiting human review, behind a three-guard ratchet (idempotency,
  depth ceiling ≤ 1, no tail-chasing). Reads state only; the one mutation it makes is an
  additive `remediation` record. Never auto-merges, never runs a detector or mutation tool.
  Table pins by lint **V10**. (ADR 0017, ADR 0018; #29)
- **Production-Telemetry Triage** — a new sixth plugin `triage`: a read-only, bounded-window
  source that turns an emitted incident into a resumable *incident-Spec* feeding spec-gen's
  resume path (never a patch, never an auto-merge). Vendor-neutral telemetry (default
  OTEL/OTLP-JSON; CloudWatch/Dynatrace behind one adapter), a self-ingestion/open-incident
  loop-guard, and correlation to the manifest journey/behavior via the §12 `event_name` key.
  Contract pinned by lint **V9**; escalation block vendored (V5). (ADR 0020; #30)
- **Suite outcome measurement** — report-only, permanently. DORA metrics as a Marshal mode
  and the journey-instrumentation share as an audit emit step, in a shared `outcome/` store
  whose every row carries a mandatory honesty-class badge (`deterministic | agent-graded |
  human-annotated`) so an agent-graded number can never be rendered as `[det]`. Baseline
  captured at adoption, frozen, refuse-second. Store contract pinned by lint **V11**.
  (ADR 0023; #31)
- **System-design coverage** — *declare-then-verify* for controls that live outside the repo.
  The manifest gains an additive-optional control-`locus` family; the audit verifies only
  `locus: app` claims (extending the existing CH-03 comparator — no second join engine) and
  reports every other locus as **out-of-scope-by-declaration**: never a false "missing X"
  finding, never blocking. Honest deterministic in-repo seeds (money-as-float, tz-in-prod,
  timeout-absence, …) emit candidates, never verdicts. Guards pinned by lint **V12**.
  (ADR 0021, ADR 0022; #32)

### Changed

- Root `marketplace.json` now registers **six** plugins; the description tracks the
  ADR 0011 → 0019 → 0020 amendment history (four → five → six).
- `scripts/lint_consistency.sh` grew from six to **twelve** cross-plugin vendoring rules
  (V7–V12), each with a planted-drift red-test in `suite_self_test.sh` proving it has teeth.
- `scripts/suite_self_test.sh` now proves eight components (six plugin self-tests + the
  root outcome and system-design self-tests) plus the validator and all lints, zero-skip
  under `SUITE_STRICT=1`.
- The Verification Manifest schema gained additive-optional `locus` declaration fields
  (system-design coverage); all vendored copies re-synced byte-identical (lint V1).
- Per-plugin `plugin.json` versions are managed independently by each plugin (each
  enforces its own CHANGELOG release gate — every behavioral claim cites a self-test
  assertion id). The suite tag is this release's marker; the plugins that gained
  capabilities this cycle (autopilot D6.5; codebase-health mutation sibling, `/remediate`,
  outcome-emit, system-design coverage; marshal outcome modes; spec-gen findings-register
  door) roll their own version + CHANGELOG entry on their next per-plugin release pass.

### Docs

- Added this CHANGELOG; refreshed the README for the six-plugin suite and the four
  woven-in capabilities; ADRs now number **0001–0023**.

## [1.0.0] — 2026-07-06

Initial feature-complete release: four plugins covering the ADLC left to right
(spec-gen, autopilot, codebase-health, marshal), integrated through a shared, machine-readable
**Verification Manifest** (JSON Schema + validator, exit-code contract 0/3/4/5). One root
marketplace entry point; `scripts/suite_self_test.sh` proves the whole suite in one command
(validator + every plugin self-test + cross-plugin vendoring lints V1–V6 with planted-drift
red-tests). Substrate is shell + Python-on-uv (ADR 0015); host-agnostic through one adapter
(GitHub + Bitbucket Data Center; ADR 0013). 22 ADRs with adversarial dissent preserved.

[1.2.0]: https://github.com/bmjcoding/zero-trust-verification/releases/tag/v1.2.0
[1.1.0]: https://github.com/bmjcoding/zero-trust-verification/releases/tag/v1.1.0
[1.0.0]: https://github.com/bmjcoding/zero-trust-verification/releases/tag/v1.0.0
