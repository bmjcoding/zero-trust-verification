# Changelog

All notable changes to the autopilot skill. Format follows Keep a Changelog; versioning is SemVer. CHANGELOG.md is the single source of truth for version history — the SKILL.md frontmatter does not carry a `version:` field.

**Release gate (v2.4.0, GAPS M3/M6).** Every behavioral claim in a release entry MUST cite the `scripts/self_test.sh` assertion id (Txx) or `scripts/lint_consistency.sh` rule id (Lxx) that proves it, or be tagged `[doc-only]`. Both scripts must pass before tagging. Any drain failure attributable to the skill must land a failing self-test assertion before (or with) its fix — a gap found once may not recur silently. (This gate exists because v2.1.0–v2.3.0 shipped multiple claimed-but-unimplemented behaviors; see docs/GAPS_SPEC.md §B.)

## [3.1.0] - 2026-07-10

**audit-w345 e2e retro absorption.** Every fix/pattern from the two field retros
of the audit-w345 drain (Waves 3–5, 2026-07-07/08) reviewed against the repo and
landed: two P0 validator/planner gaps that let a broken main ship, the Bitbucket
DC split-SSH-endpoint host bug that forced a manual workaround on 20+ REST calls,
and the honesty gaps around CI build-status polling, session death mid-CI-poll,
and dirty-tree fires. A 4-dimension adversarial merge review of the branch
(0 BLOCKER / 3 MAJOR / 8 MINOR, each independently verified) was then folded in
pre-merge; the entries below describe the post-review state.

### Added

- **`invalidated_seams:` planner field + Monkeypatch inventory (retro-1 F3 / retro-2 finding 4).**
  The planner schema gains `invalidated_seams[]` — the test modules whose
  mocks/monkeypatches bind to the owned files' import seams — populated by a
  mandatory inventory grep (planner Rule 13) before any refactor / symbol-move
  Subtask is emitted; `[]` is legal only after an empty inventory. The field is
  in the AP-3 reviewer projection (new NO-GO condition 9: absent field = the
  inventory never ran) and feeds the D6.1 scoped test set. Pinned by **L18**
  (extended to `invalidated_seams`; the projection-side pin is anchored to the
  canonical allow-list ENTRY shape so prose mentions can't satisfy it, and the
  planted-drift red-test scrubs only the entry line — the L18b overclaim caught
  in review).
- **Shared-helper blast radius (retro-1 F2, P0).** Quality validator check 2b +
  D6.1: a change to a shared mock/test helper expands `gates.test_scoped`
  `{paths}` to every test file importing the touched module — repo-wide, even
  for single-edit Subtasks — and D5 now states validators are NEVER skipped for
  small diffs. The trigger is being imported by tests, not residence in the
  test tree: src-shipped test fakes (the `<pkg>/testing.py` pattern) qualify
  too (review finding — the residence-restricted trigger reopened the F2
  broken-trunk window for src-resident fakes). [doc-only]
- **`CI_STATUS_REPORTING` probe key (retro-1 F7).** G1.5 samples the host
  build-status API over recent trunk commits AND the 5 most recent PR head shas
  (`refs/pull-requests/*/from` | `refs/pull/*/head`) — never just the tip, and
  never trunk-only: PR-only-reporting CI on squash/rebase-merge repos (the
  suite's primary Bitbucket DC shape) posts statuses to PR heads that trunk
  sampling can never see, and a trunk-only sample would misread that WORKING
  endpoint as silent (review MAJOR). Emits `true|false|unknown`;
  `CI_PRESENT=true` + `CI_STATUS_REPORTING=false` (CI runs but never posts to
  the endpoint) auto-seeds `ci.skip_wait: true` — the CI gate degrades honestly
  at GENERATE-time instead of polling a void to `ci-stuck-pending` mid-drain.
  Backend-error ≠ silent-endpoint (unavailable never reads as `false`),
  `unknown` never auto-flips (loop-safety invariant 2). Proven by
  **W345-F7a–F7g** via the new `AUTOPILOT_PROBE_BITBUCKET` injection seam:
  **F7c** reds on deleting the backend-error→unavailable guard (the vacuous-F7c
  review MAJOR — now CI-config-present + always-erroring backend), **F7e** the
  no-CI case, **F7f** reds on a tip-only (`-5`→`-1`) sampling regression,
  **F7g** reds on dropping the PR-head sample; all four mutations verified.
- **`gates.format` + format-before-every-commit (retro-2 rec 2).** Optional
  runbook gate (Python default `ruff format {files}`); implementer commit rule 7
  runs it on exactly the staged files before EACH commit, absorbing the
  formatting-only validator fix cycle (~60K tokens per affected Subtask in the
  field). [doc-only]
- **AP-1 compressed-cycle exception (retro-1 F4).** New-file relocation of
  already-tested behavior may compress to one RED + one GREEN pair (declared
  `Compressed cycle: new-file-relocation` in the implementer report; D6.2
  documents the accepted shape). Coverage is never compressed — every behavior
  still needs a test. [doc-only]
- **`regen_rituals:` runbook field + integration-validator check 7 (retro-1 F8).**
  Generated artifacts (wire-format fingerprints, generated clients) declare a
  regen ritual + additive-vs-breaking classification; a diff touching a declared
  path without `regen:` evidence blocks — an auto-regen can no longer fold
  silently into a PR. Wired end-to-end after review (the contract shipped with
  enforcement but no producer): validator input 7 hands validators the runbook
  path + frontmatter check 7 keys on; implementer input 6 + commit rule 8
  produce the `regen: additive|breaking` line at commit time (`breaking`
  requires operator sign-off pre-commit — amending landed commits is forbidden,
  so a missing line costs a full fix cycle). [doc-only]
- **Foreign dirty-tree handling (retro-1 F6).** D1.2 stashes foreign dirty
  tracked paths under a per-fire label (drain-state paths escalate to
  `dirty-drain-state` instead), D8 pops it before exit; a pop conflict preserves
  the stash + drift-notes it. Loop-safety invariant 4 records the stash as state
  preservation, never an edit. [doc-only]
- **Stale-ACTIVE reclaim (retro-2 finding 6 / rec 5, applied at RESUME).** A
  session dying between D7.5 and D8 strands the tracker `ACTIVE`; the dead
  session cannot flip its own status at D8, so Resume step 2 now reclaims an
  ACTIVE tracker whose session lock is null/expired **AND** shows a
  dead-session signal — `last_heartbeat_at` > 90 min stale (the D1.3 crash
  standard) or `awaiting_ci: true` with no in-flight Subtask work — flipping to
  `PAUSED` with `status_reason: "session_ended_between_ci_polls"` (or
  `session_ended_mid_fire`) and proceeding through the normal PAUSED path.
  Lock expiry alone never reclaims (review MAJOR: the lock refreshes only at
  fire start, so a normal live fire outlives it — expiry-only reclaim let
  `--resume` hijack a live fire into a concurrent drain); with a fresh
  heartbeat Resume refuses and says when to retry. D8 documents the
  terminal-fire contract; the SKILL.md modes-table RESUME row carries the
  reclaim contract (it previously read PAUSED-only). [doc-only]
- **Merge-authorization semantics (retro-1 F1 + Bitbucket merge pattern).**
  SKILL.md documents `--yolo`'s authorization scope explicitly: autonomous drain
  + PR opening, never merge authority; an operator-confirmed merge under
  operator-as-reviewer is the operator's action (via `host.sh pr-merge`, logged
  to `## Force Audit`), and policy/safety classifiers should judge scope against
  these documented semantics, not the flag literal. Hard Contract 4 unchanged.
  [doc-only]
- **Byte-stability refactor authoring guidance (retro-2 rec 4).**
  Runbook-template authoring section + planner kind-selection note: pre-declare
  conditional `owned_files` expansion clauses, or plan as `kind: code` — the
  w4-6.1/w3-5.1 zero-commit-BLOCK class. [doc-only]

### Fixed

- **Bitbucket DC split-SSH-endpoint host derivation (retro-2 rec 1).** A BB_HOST
  derived from an SSH origin (`bb-ssh.example.com`) now strips the `-ssh`
  suffix from the first hostname label to reach the REST host — including
  dotless single-label intranet hosts (`bitbucket-ssh` → `bitbucket`; review
  finding: the dot-anchored pattern never fired on them, contradicting the
  header's first-label claim); https-derived hosts are never rewritten, and
  `AUTOPILOT_BITBUCKET_HOST` overrides all derivation. New internal
  `repo-coords` debug subcommand makes the derivation testable offline. Proven
  by **W345-BB1–BB6** (BB6 asserts the extracted value — a substring check
  would vacuously match the unstripped host). The self-test preamble unsets an
  inherited `AUTOPILOT_BITBUCKET_HOST` so the documented persistent operator
  override cannot false-red BB1–BB4 on a correct tree.

## [3.0.1] - 2026-07-05

**autopilot v3 — P2 hardening.** Two fail-open edges surfaced by the v3
adversarial review (PR #19), each fixed test-first. Per the M3 gate both fixes
land a failing self-test assertion before the fix; the suite grew 312 → **319**
assertions (L1–L23 unchanged), all green on bash 3.2.57.

### Fixed

- **P2-a — determinism gate param-index blind spot (D6.4 / AV3-12).**
  `scripts/determinism_gate.sh` fingerprinted failure output by blanket-stripping
  ALL digits (`tr -d '0-9'`) before hashing, which collapsed a parametrized pytest
  test that fails a different case index each round (`test_login[0]` vs
  `test_login[1]` → both `test_login[]`) to one signature and reported
  `DETERMINISTIC` — false-greening that common real flaky pattern. The fingerprint
  now volatile-normalizes into an order-independent failure skeleton that keeps a
  **`::` node-id token verbatim** (so its parametrize index survives) and
  digit-strips every other token plus `0x` addresses; lines are sorted so a mere
  reorder of the SAME failure set (expected under the order-randomized round) is
  not mistaken for flake. Keying on the node-id token — not on brackets, which also
  hold volatile durations like `[123 ns]` — preserves the index without
  false-reddening a deterministic run whose output carries a bracketed number. New
  **AV3-12.8** plants a param-index-flipping flaky test and asserts it is caught
  (`[BLOCKED: flaky-test]`, exit 1); it reds against the old digit-stripping logic
  (the existing AV3-12.5 uses letter-only names and sidestepped the case). New
  **AV3-12.9** is the false-RED regression guard: a stable node id beside a volatile
  bracketed duration stays `DETERMINISTIC`. (Scoped to pytest/unittest `::` node
  ids; non-bracket subtest-index notations like Go's `/case_N` remain out of scope.)
  AV3-12.1–.7 unchanged.
- **P2-b — D2 claim-eligibility fail-closed edge (ADR 0009 / AV3-09).** When
  `host.sh pr-state` returns `UNKNOWN` — a read that SUCCEEDED but whose PR state was
  null / unmappable to the vocabulary (a genuinely unreadable read instead dies
  `exit 1`, leaving an empty state) — `claim_overlap.sh eligibility` exits 64, but
  `references/drain-lifecycle.md` D2 documented only exit 0 (eligible) and exit 2
  (blocked) — leaving the exit-64 path unspecified, so the claim poll was not wired
  to fail closed (loop-safety invariant 3). D2 now routes exit 64 to `STATUS:
  HUMAN_NEEDED — claim-eligibility-usage-error` (external fault, no counter
  increment), matching D7.5's `ci-check-usage-error` and D1.0's
  `lock-check-usage-error`. New **AV3-09.8** pins that BOTH `UNKNOWN` and an empty
  state fail closed as exit 64 (never 0/eligible). `[doc-only]` dispatch row added to
  drain-lifecycle.md D2 + loop-safety invariant 3 enforcement list.

## [3.0.0] - 2026-07-05

**autopilot v3** — Verification-Manifest consumption, PR-per-Story granularity,
cross-drain coordination, and quality shift-left, on the host-agnostic adapter
foundation. Register: `docs/specs/autopilot-v3-register.md`. Per the M3 gate every
behavioral claim cites its `self_test.sh` assertion id (`AV3-xx.n`, plus the
inherited `Txx`/`HD`/`HG`/`H50`) or `lint_consistency.sh` rule (`Lxx`); the suite
grew 170 → 312 assertions and L1–L15 → **L1–L23**, all green.

### Added

- **Manifest consumption (§A).** `scripts/detect_input_mode.sh` — mode inference
  (ADR 0008): complete manifest → `STRAIGHT_THROUGH`, bare/incomplete →
  `GENERATE_PAUSE`, manifest-less `--yolo` → `GENERATE_YOLO`, schema-invalid/
  unsupported → refuse-never-degrade (AV3-01.1–.7). `scripts/validate_plan_mapping.sh`
  — 48h Story sizing (AV3-07.1–.6) + Subtask↔Behavior-ID mapping (AV3-02.1–.5).
  `scripts/validate_manifest.sh --union` — multi-doc ID-collision + profile/
  environments mismatch (AV3-03.1–.6). `scripts/manifest_revision_gate.sh` — D1.0.6
  drift detection + Resume refusal → `--generate --merge` revision-regen
  (AV3-04.1–.7). `scripts/audit_behavior_binding.sh` — D6.3 Behavior→test binding
  verified from git log (AV3-05.1–.4).
- **Granularity + coordination (§B/§C).** `scripts/audit_commit_shape.sh` — D6.2
  Story-range TDD audit (`prev_pushed_sha..HEAD`, no false `tdd-scope-leak`;
  AV3-06.1–.6). `scripts/runbook_pr.sh` — Runbook PR predicted-file-surface block
  (AV3-08.1–.3). `scripts/claim_overlap.sh` — vendored claim consultation
  (BINDING/TERMINAL/ADVISORY/EXCLUDED + D2 eligibility; AV3-09.1–.7).
  `scripts/claim_loss_attribution.sh` — D7.0 serialize-and-replan routing
  (AV3-10.1–.6).
- **Quality shift-left (§D).** `scripts/determinism_gate.sh` — D6.4 N=5 flaky gate,
  runner-agnostic, digit-stripped fingerprints, loud skip-note (AV3-12.1–.7). The
  implementer anti-flakiness contract + design-validator routing (L21) and the
  vendored ADR 0002 escalation rule (L22).
- **`scripts/host.sh` — the single PR/build surface.** Detects the backend from
  `origin` (`BITBUCKET_DC` via the `/scm/` path shape, `GITHUB` via `github.com`,
  `$AUTOPILOT_HOST_BACKEND` override) and dispatches the full subcommand set
  (`pr-open [--draft]`, `pr-ready`, `pr-state`, `pr-comment`, `pr-merge`,
  `pr-approve`, `pr-decline`, `pr-merge-strategies`, `build-status`) to the
  backend by `exec` (byte-identical stdout/exit pass-through). `host.sh backend`
  prints the detected backend. Detection fixtures for both origin URL shapes plus
  ssh, override, invalid-override, unrecognised-origin, and unknown-subcommand.
  (H50, HD08, HG01)
- **`scripts/github.sh` — GitHub backend via the `gh` CLI**, implementing the
  contract. `gh` owns credential resolution (token never in argv/context);
  `isDraft`→`DRAFT` and `CLOSED`→`DECLINED` map GitHub's vocabulary onto the
  shared one; `build-status` aggregates BOTH the commit-status API (its
  authoritative combined `.state`) and the check-runs API into
  `SUCCESSFUL|FAILED|INPROGRESS|UNKNOWN` — fail-safe on unseen pagination pages
  (never a false GREEN) and dropping neutral/`stale` conclusions. The T01-class
  contract matrix runs against it through a `gh` argv shim (no network/python).
  (`H-GH` matrix, HG20–HG30)
- **Draft-PR surface (AV3-06 dependency).** `pr-open --draft`, `pr-ready`
  (draft→ready flip), and `pr-state` `DRAFT` emission across both backends. The
  Bitbucket DC backend adds `AUTOPILOT_BITBUCKET_DRAFT_MODE`: `native` (the
  `draft` boolean) or `title-prefix` (a `[DRAFT] ` title convention for servers
  predating native draft PRs; native `draft:true` is still honoured in either
  mode). (HD01–HD07, HG20–HG23)
- **`ci_check.sh` is now host-agnostic** — the D7.5 CI poll reads PR state and
  build status through `host.sh`, so it turns GREEN against either backend. (HG30)

### Changed

- **PR-per-Story (AV3-06 / ADR 0007).** Hard Contracts 1 & 4 rewritten: one Story
  = one branch (`autopilot/<slug>/<story-id>`) = one draft PR; Subtasks are the
  Story's commit series, not separate PRs. Draft mechanics (`pr-open --draft`,
  `pr-ready`, `pr-state` `DRAFT` + DC title-prefix fallback) landed with AV3-15
  (HD01–HD11, HG20–HG25). D6.2 audit range → `prev_pushed_sha..HEAD`; D1.4/D4
  branch tables, D7.0/D7.3/D7.3a, D2 story-affinity, and the end-of-drain
  dangling-draft disposition re-keyed to Story branches/PRs. New lint **L17** reds
  retired PR-per-Subtask framing.
- **Runbook PR replaces the rolling tracker PR (AV3-08).** G7 opens one long-lived
  Runbook PR at Pickup (`autopilot/<slug>/runbook`, runbook + tracker) with a
  grep-able predicted-file-surface block; it is the single bookkeeping home under
  both `no_force_push` settings and MERGE-ORDER's final entry (operator/Marshal
  merges; autopilot never merges its own PRs). New lint **L19** (file-surface
  markers + retired-framing pin).
- **Mode table + flag registry (AV3-01/04/16a).** Mode detection now infers the
  GENERATE shape from the manifest (`STRAIGHT_THROUGH` on complete); `--yolo`
  narrowed to the manifest-less override; `--merge` documents the revision-regen
  mode. AP-3 projection allow-list gains `behavior_ids` + `predicted_hours` (lint
  **L18**). Behavior-coverage PR-body format (lint **L20**), as-built docs
  deliverable (lint **L23**). Reference index adds the ten new AV3 scripts and the
  L1–L23 lint list.
- **Mock server on `uv run` (ADR 0015).** `self_test.sh` launches its mock
  Bitbucket DC server via `uv run --no-project python`, killing the
  python3-not-on-PATH fragility.
- **Hard Contract 11 rewritten** (AV3-16b): "Bitbucket Data Center is the
  source-of-truth host / `gh` is NOT a dependency" → "**the host adapter is the
  single PR/build surface**". `bitbucket.sh` is now the Bitbucket DC backend
  behind `host.sh` (hardened internals intact); lifecycle references (D7.3,
  D7.3a, D1 tracker-PR check), the reference index, README, and validator/
  loop-safety prompts route through `host.sh`. New lint **L16** reds the retired
  single-host framing and any direct backend invocation ANYWHERE in the doc set
  (SKILL + README + all references). (L16; self-test plants a `source-of-truth
  host` line and asserts L16 reds it)
- **`pr-merge-strategies` now emits self-consumable operator tokens.** The
  Bitbucket DC backend previously printed raw DC strategy ids (`rebase-no-ff`,
  `squash-ff-only`, …) that its OWN `pr-merge --strategy` rejects; it now maps
  them to the operator vocabulary (`no-ff`/`ff-only`/`squash`/`rebase`) that
  `pr-merge` accepts, matching the GitHub backend's contract. `pr-merge`'s
  internal discovery still matches raw DC ids via a private helper. (HD11)
- **`self_test.sh` mock server is non-fatal.** When the HTTP mock can't start
  (no python3 / locked-down sandbox) the DC-backend HTTP tests SKIP with a note
  rather than aborting; the deterministic, GitHub-backend, and lint assertions
  always run. Baseline 96 → 170 assertions (101 + 3 skips when the DC server is
  unavailable). (skip banner + `H-GH`/`H50` sections)

### Fixed

- **DC REST stack was broken on bash 3.2 + BSD sed** (the macOS default
  toolchain, and ADR 0013's "community distribution" target). `"${empty[@]}"`
  under `set -u` is an unbound-variable error on bash 3.2 (`CA_ARG`, `CURL_AUTH`,
  and GET-time `extra[]` are all legitimately empty), so `curl` never ran and
  sidecar detection always reported `http=000`; and `\b` word boundaries in the
  sidecar mode-line `sed` are a GNU extension BSD sed ignores. Guarded empty-array
  expansions with `${arr[@]+"${arr[@]}"}` and dropped the `\b`. No behavior change
  on GNU/bash-4; self_test now runs green on macOS bash 3.2. (T01–T07, T28, T36)

## [2.4.0] - 2026-07-02

Audit release. A ground-truth audit (docs/GAPS_SPEC.md — every mechanical finding reproduced by executing the script against a fixture before registration) found that the deterministic substrate had never been executed: the Bitbucket adapter could not succeed at anything (T01), the force-push probe could not detect a denial (T09), the concurrency guard could not detect a concurrent drain (T13), and the documented CI-poll invocation terminated the drain (T17). It also found five claimed-but-unimplemented changelog entries and ~20 cross-file contract contradictions. This release fixes all of it and adds the machinery that keeps it fixed: an executed self-test, a cross-file consistency lint, loop-safety invariants, and this release gate.

### Adversarial verification rounds (within this release)

Two author-blind agents reviewed the release before tagging (docs/GAPS_SPEC.md
§"Verification rounds"). Round 1 mutation-tested the harness (five baseline bugs
re-introduced on copies; the corresponding assertions went red every time) and
caught three overclaims, fixed in round 2. Round 3 fixed the fresh-eyes agent's
findings, the most significant being:

- **macOS `secret_set.sh` was unusable and leaked**: the ownership probe parsed
  `security -g` stderr and treated "item could not be found" as an existing
  foreign entry — every first-ever store aborted exit 5 (forcing `--force`,
  which also bypassed the collision guard); the store itself passed the token
  in `security`'s argv; and an unset `$USER` (containers/CI, `set -u`) made the
  store silently no-op while reporting success. Fixed: exit-code existence
  check, attribute dump without `-g` (no password fetched), token via
  `security -i` stdin, `RUN_USER` fallback. (T30)
- **Auth-failure bodies reached the orchestrator context**: every non-2xx path
  logged a 200-char body excerpt, violating the sidecar contract's 401/403/407
  rule; and the contract's 429/502/407 handling did not exist. Fixed:
  `body_excerpt` redaction, bounded Retry-After retry, 502 backoff retry,
  407 → `LAST_STATE=sidecar-session-invalid`; retries are owned by `bb_curl`,
  not `curl --retry` (which also fires on 429/5xx and bypasses the table).
  (T35, T36)
- **`--dry-run` was not dry**: trunk detection ran `ls-remote` and the cleanup
  trap ran remote branch deletes. Fixed: local-refs-only trunk detection,
  disarmed trap, and the promised operation plan printed (stderr). (T32)
- **The force-push probe was blinded by JIRA hooks** on exactly the strict
  repos AP-23 targets (its own probe commits were rejected before the rewrite
  test): new `--jira-key` flag unblinds it; without a key the JIRA verdict is
  concluded from that first rejection instead of a second push. (T29, T37)
- **Crash-recovery spam**: D1.0.4 appended a `crash_recovery` entry whenever
  the batched queue was non-empty at fire start — which is every healthy
  batched-mode fire; now requires actual crash evidence (expired-lock reclaim
  or the 90-minute heartbeat detector). `[doc-only]`
- **Undecidable tracker-PR table**: dispatched on `MERGEABLE|CONFLICTED`,
  which `pr-state` cannot observe, and had no row for `NONE`; rewritten to the
  observable state set. `[doc-only]`
- Also: quoted-YAML lock values parse (T34); empty churn window is a clean
  empty result, not exit 1 (T31); `--show-patterns` prints intact rows (T33);
  healthz body must BE "ok", not contain it (T38); env-token tier reachable on
  keychain-less platforms and documented under its real name
  (`AUTOPILOT_<SERVICE>_TOKEN`); D1.4 rows are ordered first-match with
  external PR state checked before CI polling; a Done resets both counters;
  PAUSED recovery is `--resume`-only; `detect_concurrent_drain.sh` exit 64
  routed at G1/D1; credentialed-URL redaction in probe stderr; cadence
  deferral precedence stated; `in_progress.pushed_at` documented;
  `ci.build_states` marked reserved; G1 slug derivation defined; the security
  validator's grep uses `-iE` (PCRE `(?i)` errors under `grep -E`). `[doc-only]`
  where no assertion id is cited.

### Added

- **`scripts/self_test.sh`** — hermetic self-test (mock Bitbucket DC server, local bare repos with deny-configs and pre-receive hooks, curl argv shim, macOS keychain shims): 96 assertions covering every script. (GAPS M1)
- **`scripts/lint_consistency.sh`** — deterministic cross-file contract lint, rules L1–L15: one artifact-path scheme, one tracker schema, one step graph, one validator catalog, budget-sourced caps, batching-doc alignment, one TDD commit format, removed fields stay removed, one size vocabulary, cron prompts carry the drain invocation, version refs pinned to this file's top entry, complete flag registry, no consumer-repo leakage, runbook-sourced gates. (GAPS M2)
- **`references/loop-safety.md`** — the loop's ten never-do invariants, each mapped to its enforcing mechanism, plus honest residuals. (GAPS M4)
- **`gates:` runbook block** — language-agnostic gate command templates (`test_scoped`, `test_single`, `test_contract`, `typecheck`, `lint`, `precommit` with `{paths}`/`{files}`/`{test}` placeholders; Python defaults preserved). D6.1, the D5 validators, the implementer prompt, and conflict resolution now reference gates instead of hardcoded `pytest`/`mypy`/`ruff`; `test_runner` becomes a warned legacy alias. Lint is scoped to changed files — never repo-wide. (GAPS D3; L15) `[doc-only]` for the prompt files; the contract is linted.
- **`ci_check.sh --once`** — single-observation mode for the cross-fire D7.5 dispatch: `VERDICT=GREEN|RED|PENDING|PR_DECLINED` (exit 0/1/5/4); `LAST_STATE` on stderr now carries the actual last observed build state. The blocking poll mode remains for operator use. (GAPS A6/A7; T17–T20)
- **`bitbucket.sh pr-state --branch <src>`** — PR state lookup by source branch (returns `NONE` when absent), used by the tracker-PR availability check which knows the branch but not the PR number. (T02)
- **`hot_file_audit.sh --churn`** — implements G4's 30-day churn contract (top-20 from origin-trunk history); the old overlap analysis moved to `--subtasks <slug>` for D7.0. (GAPS A8; T21–T23)
- **`secret_get.sh --list-candidates`** + the candidates claimed in v2.1.0 but never implemented: `<service>-token:<host>` and `$<SERVICE>_HOST`-derived hosts. (GAPS B3; T25)
- **`repo_shape_probe.sh --show-patterns`** — prints the rejection-pattern registry (the behavior v2.3.0's changelog attributed to `--explain`; `--explain` is, and remains, the stderr reasoning trace). (GAPS B6) `[doc-only]`
- **D1.2 runtime-budget check** (`budget.max_runtime_minutes` → `HUMAN_NEEDED — runtime-budget-expired`) and **D4 cycle cap** (`budget.max_cycles_per_subtask` → `[BLOCKED: cycle-budget-exhausted]`) — these budget fields previously existed in the runbook schema but were enforced nowhere. `[doc-only]` (L6 pins the cap sourcing)
- **G4 dangling-dependency check on every generate path** — planners run in parallel and cannot verify cross-Story `depends_on[]` ids; previously only `--merge` validated them. `[doc-only]`
- **SKILL.md flag registry** — `--reprobe`, `--no-probe`, `--no-auto-seed` registered (previously referenced only in references); `argument-hint` frontmatter added; ghost flag `--force-rolling-tracker` removed. (L13)

### Fixed

- **`bitbucket.sh` could never succeed** (release-blocking): `bb_curl` was always invoked in a command substitution, so the `HTTP_STATUS` it set never reached the caller — every subcommand failed its status check even on HTTP 200, and resolver failures inside the substitution didn't abort the script. `bb_curl` now writes the body to a caller-named file and sets `HTTP_STATUS` in the calling shell. (GAPS A1; T01–T07)
- **Rejection-pattern registry could not match most patterns**: the regex/signal split took everything before the FIRST `|`, truncating every alternation-bearing regex into an unbalanced pattern grep silently errored on (5 of 6 realistic Bitbucket DC rejection strings failed). Signal is now everything after the LAST `|`. Also fixed a dynamic-scoping bug where `match_rejection`'s local `signal` shadowed the probe's outvar of the same name. (GAPS A2; T08)
- **Force-push probe could never return `false`**: it force-pushed a fast-forward (trunk-tip + new commit over trunk-tip), which every server accepts; `branching.no_force_push` was therefore never auto-set and the AP-23 batched-delta machinery was unreachable by detection. The probe now pushes tip+A, rewrites to the divergent sibling tip+B, and force-pushes — a genuine non-fast-forward. Verified against a `receive.denyNonFastForwards` fixture. (GAPS A3; T09/T10)
- **Probe stdout pollution**: git chatter inside the detector command substitutions corrupted the emitted `KEY=VALUE` values; all git output now goes to the probe logfile, and stdout purity is asserted. (GAPS A4; T11)
- **`detect_concurrent_drain.sh` could never detect a concurrent drain**: it read a legacy field set (`session_id`/`lock_acquired_at`) that no tracker written by G7 contains, G1's documented call passed a bare slug (silent exit 0), its 5-minute heartbeat window would have declared healthy `*/30`-cadence drains stale (lock-steal), and unreadable state failed open. Now: canonical `session_lock`/`session_lock_expires_at` fields, tracker-path argument (slug-shaped args rejected with exit 64), staleness = lock expiry only, and exit 4 fail-closed on corrupt state. (GAPS A5, C2; T12–T16, T27)
- **The documented CI-poll invocation killed the drain**: D7.5 (and D1.4) called `ci_check.sh <pr_number>`; the script requires `--sha`/`--pr`, so the call exited 64, which the dispatch table routes to `HUMAN_NEEDED` + cron deletion. Lifecycle and script now agree on `ci_check.sh --sha <sha> --pr <N> --once`, and D7.4 records `in_progress.pushed_sha` to feed it. (GAPS A6; T17)
- **Sidecar silently bypassed for contract-conformant sidecars**: the contract's platform id is `bitbucketdc`; `bitbucket.sh` matched only legacy `bitbucket` and fell back to local keychain mode — defeating the token-never-in-workspace guarantee. Both ids are now accepted and the matched id is used as the URL segment; the sidecar mode-line is parsed without `eval`. (GAPS A9; T05)
- **Response UTF-8 sanitisation actually implemented** — claimed in v2.1.0, but only request payloads were sanitised; a non-UTF-8 byte in a PR response still broke jq and misreported "no PR number in response". (GAPS B1; T04)
- **`pr-merge` strategy discovery actually implemented** — claimed in v2.1.0; the code did a static name mapping and never consulted `pr-merge-strategies`. Now discovers enabled strategies and falls back down an ordered candidate list; also fixed a jq `//`-operator bug that treated `enabled: false` as enabled. (GAPS B2; T06)
- **`secret_set.sh` cross-candidate collision guard actually implemented** — claimed in v2.2.0; only the exact target name was probed, so the documented silent-two-copy state was still reachable. Default mode now probes every `secret_get.sh --list-candidates` name and aborts (exit 5) on any foreign entry. Erratum: `--as-host` writes `autopilot-<service>-<host>` (as the script always did), not the `bitbucket-token:cluster03` form the v2.2.0 entry described — that form is now a read-side candidate instead. (GAPS B3; T25 covers the read side)
- **Unknown-rejection corpus-growth message actually implemented** — claimed in v2.3.0 ("probe: unknown rejection pattern; please add ..."); it now fires, always-on, whenever a push rejection matches no registry row. (GAPS B4; T26)
- **CI-manifest detection**: recursive tree listing so `.github/workflows/*.yml` is detectable (non-recursive `ls-tree` listed `.github`, never the nested path). (GAPS A10; T24)
- **Token never in curl argv**: the Bearer header is passed via a 0600 temp file (`-H @file`) instead of an argv `-H` string readable in `/proc/*/cmdline`, matching what sidecar-contract.md already claimed. curl `--retry` is now GET-only (retrying POSTs risks duplicate PR/merge submissions). (T03)
- **`sidecar_detect.sh` checks the healthz body** ("ok") as its own header always claimed, not just the status code. (T28)
- **Doc-corpus contradictions reconciled** (full list: docs/GAPS_SPEC.md §C) `[doc-only]`, each now pinned by a lint rule: one artifact-path scheme (`.autopilot/runbooks/`, L1); one tracker schema (L2); legacy D0..D7.5 step graph purged from README/template/script headers (L3); the duplicate step id D7.5 renamed to D7.3a for the stacked-merge strategy (L4); one validator catalog — integration/design/quality (+security/sre) — replacing the phantom correctness/performance/style set (L5); escalation caps sourced from `budget.max_*_blocks` instead of hardcoded 3s (L6); tracker-delta-batching.md rewritten to the D7.1a fold semantics it contradicted on five points (L7); one TDD commit format (L8); `branch_pattern` removed from the planner schema and projection (L9, it contradicted AP-7); G3.6 eligibility uses the planner's actual `S|M|L` vocabulary (L10); cron prompts carry `/autopilot --drain` (L11); stale version references corrected (L12); AP-17/AP-18 rationale aligned with the shipped mechanisms; D3.0 staleness routing is terminal-block in all files; the plan-reviewer allow-list is defined once in plan-reviewer-projection.md.
- **Honesty**: SKILL.md's description no longer promises overnight drains ("while you sleep") that AP-19 explicitly says cannot happen; the constraint (autonomous within a live session, no headless mode) is stated up front and in README "When NOT to use". Non-standard `lifecycle:` frontmatter field removed. `[doc-only]`
- **De-branding**: internal corporate hostname removed from sidecar-contract.md; origin-repo file names (`internal_sdk/`, `internal.yml`, `mcp/server.py`, `verbs/`), vendor-specific state stores, and `~/.claude/skills/*` dependencies generalized out of the role prompts (L14). The sidecar probe-budget section rewritten to describe the real transport mix instead of an unimplementable REST budget table (GAPS B5). `[doc-only]`

### Known limitations (documented, not fixed)

- Under `branching.no_force_push: true`, the AP-4 session lock is checkout-local until the next D7.1a fold lands; cross-clone concurrency relies on the branch-namespace check. (drain-lifecycle D1.0 note)
- The orchestrator contract binds an LLM through prose; the self-test proves the deterministic substrate only. (loop-safety.md residuals)
- `--jira` mode depends on an environment-specific MCP server; it now fails fast with a clear message when absent, but cannot be self-tested here.

## [2.3.0] - 2026-06-29

Closes all three v2.2.0 "Known follow-ups" in one release: the batched tracker-delta queue (AP-23 dispatcher contract), the probe rejection-message regex registry, and the sidecar-contract probe-budget documentation. The v2.2.0 frontmatter `branching.no_force_push: true` flag now has the dispatcher machinery behind it — under v2.2.0 the contract was documented but the dispatcher would still fall through to the same force-push code path; under v2.3.0 the flag is honoured.

Versioning rationale (chose v2.3.0 minor over v2.2.1 patch):

- The batched-delta queue is a NEW dispatcher concept with new tracker state (`## Pending Tracker Deltas (batched)` section), new D-step extensions (D1.0.4 migration + recovery, D2 / D7.1a / D7.4 queue interactions), new commit-shape rules (`Tracker deltas folded in:` body block), and new PR-body section (`## Tracker deltas folded in`). Calling that a patch would obscure a dispatcher behavior change. The v2.2.0 contract was incomplete — v2.3.0 is the implementation, not a fix.
- Items B (regex registry) and C (sidecar docs) are small in isolation but are bundled into the same minor bump to keep the audit trail clean per the operator's "less noise" bias.

### Added

- **AP-23 batched tracker-delta queue** (`SKILL.md` §"Tracker delta batching (AP-23)", `references/tracker-delta-batching.md`, `references/runbook-template.md` tracker body sections). When `branching.no_force_push: true`, tracker bookkeeping commits cannot land on a rolling tracker branch (no force-push, divergence is fatal). The queue holds tracker deltas inside the tracker file at `## Pending Tracker Deltas (batched)`; the next successful Subtask's PR (D7.1a) flushes the queue into one atomic commit alongside the impl edit. Queue entries carry `subtask_id`, `delta_kind` (one of `subtask_done | in_progress_claim | drift_notes | status_change | session_lock | crash_recovery | other`), `diff_summary`, and verbatim `body:`. Durable across BLOCKED fires until the next-Subtask-PR-merge.
- **D1.0.4 — Pending-deltas migration + crash recovery** (`references/drain-lifecycle.md`). New first step in DRAIN dispatch when `branching.no_force_push: true`. Injects the queue section header on first fire against a v2.1.0 / v2.2.0 tracker; on crash-recovery (non-empty queue at fire start), appends a `delta_kind: crash_recovery` audit entry without removing prior entries. Idempotent.
- **D7.1a tracker-delta fold step** (`references/drain-lifecycle.md`). Extends D7.1's "stage owned_files[]" step under `branching.no_force_push: true`: reads the queue, builds a `Tracker deltas folded in:` block in the commit body listing each pending entry's `delta_kind` + `diff_summary`, flushes the queue to `_(empty)_`, stages the tracker file alongside `owned_files[]`. Single atomic commit lands the impl edit + cumulative tracker mutations + queue flush. D7.3 surfaces the same folded entries as a `## Tracker deltas folded in` H2 in the PR description.
- **`scripts/repo_shape_probe_patterns.sh`** (NEW). Regex registry for rejection-message parsing. Each row is `<pattern>|<signal_name>` (e.g., `FORCE_PUSH_REJECTED`, `JIRA_HOOK_REJECTED`) with a comment citing the DC version where each pattern was observed. The probe sources this file at startup; matching is delegated to a `match_rejection` helper that emits the raw rejection to stderr with `probe: unknown rejection pattern; please add to repo_shape_probe_patterns.sh: <raw message>` whenever no entry matches. This is the corpus-growth seam — every operator-visible `unknown` rejection is a candidate new pattern.
- **`repo_shape_probe.sh --explain` flag.** Prints the current registry contents on stdout and exits 0. No network, no git state. Useful for operators reviewing which rejection patterns are recognized before running a real probe.
- **Sidecar-contract `## Probe budget under sidecar mode` section** (`references/sidecar-contract.md`). Enumerates which probe operations require sidecar mediation (none today; all four AP-23 probes use local git transport + file inspection) and which hypothetical future probes would (REST-based `audit-log` or `pre-receive-hook-list`). Documents the hybrid-sidecar failure mode where local git transport is blocked: the probe falls through to `unknown` for network-bound checks and the runbook's `## Repo constraints (detected)` block surfaces the `unknown` state; the `unknown` values explicitly do NOT auto-flip frontmatter flags, so the operator decides each.

### Changed

- **`scripts/repo_shape_probe.sh` delegates rejection matching to the registry.** The inline `grep -qiE 'force|deny|reject|protected|pre-receive'` (force-push) and `grep -qiE 'jira|JIRA ID|missing.*key|pre-receive'` (JIRA) calls are replaced by `match_rejection <logfile> <outvar>`, which loops the registry and writes the matching signal name (or empty string) to the caller-supplied output variable. Unknown rejections surface raw text on stderr automatically.
- **D2 and D7.4 honour `branching.no_force_push: true`.** Under the flag, neither step commits the tracker delta directly — both append entries to `## Pending Tracker Deltas (batched)` instead. The committed-tracker behavior under `branching.no_force_push: false` (default) is unchanged.

### Known follow-ups (not in this release)

- _(none — all v2.2.0 follow-ups closed in this release.)_

### Fixed (on-demand patch, 2026-06-29)

- **Delegation rule reframed from permission-shape to positive default + first-action gate** (`SKILL.md` new "Loading preamble (read first, every invocation)" section; Hard contracts §10 rewrite). Failure mode observed: orchestrator read Rule 10 ("Orchestrator NEVER directly Reads source files...") and still defaulted to direct edits because (a) the rule was the 10th of 15 bullets, (b) wording was prohibition-shaped without a positive default, (c) no first-action precondition enforced naming the subagent before any tool call, and (d) `--yolo` plus a "one branch, one PR" branching override were misread as licensing skip of the dispatch contract. Fix adds: (1) Loading preamble at the top of the skill body framing delegation as the positive default and stating the first-action gate ("before any tool call, name the subagent you are about to dispatch"); (2) explicit override-scoping section establishing that `--yolo` and branching-model overrides are orthogonal to the delegation contract; (3) context-poisoning note that having SPEC.md / ADR text in context is more reason to delegate, not less; (4) Rule 10 itself rewritten with the explicit "survives every override" clause and cross-reference to the preamble; (5) D1 in-fire preamble cross-references the first-action gate so it survives auto-compaction that drops the top of the file.

### Fixed (full-cycle structural cleanup, 2026-06-29)

- **SKILL.md body split to satisfy 500-line cap (S07) and removed unsupported `version:` frontmatter field (S09)** — resolves the two P2 items deferred in the prior on-demand patch. Body went from 766 → 189 lines by extracting reference / lookup material into three new files; orchestrator-must-read content (loading preamble, override scoping, context-poisoning trap, all 15 hard contracts including the rewritten Rule 10, modes table) is unchanged and remains in SKILL.md.
  - **`references/generate-lifecycle.md`** (NEW). Holds the full G1..G8 step text: pre-flight, G1.5 repo-shape probe (AP-23), G2 extraction, G3 planning, G3.5 plan-review (AP-3), G3.6 consolidation (AP-21), G4 topo-sort + hot-file detection, G5 already-shipped, G6 Jira, G7 write, G8 review/arm. SKILL.md keeps a one-paragraph overview + a step index table pointing into the reference.
  - **`references/drain-lifecycle.md`** (NEW). Holds the full D1..D8 lifecycle including the D1 WIP-recovery dispatch table, D3 audited-SHA verification (AP-5), D4 TDD per-cycle commits (AP-1), D5 validator contradictory-finding escalation (AP-18), D6 commit-shape audit (AP-1), D7 pre-push rebase + commit + PR + D7.1a tracker-delta fold (AP-23), D7.5 CI-poll dispatch table (including `ci.skip_wait` short-circuit), D8 adaptive cron re-arm. Also holds the Resume mode contract, failure-escalation rules (AP-2), STATUS state machine, tracker-PR availability dispatch table, and end-of-drain output contract. The file opens with an explicit reminder that the SKILL.md loading-preamble delegation contract (Rule 10 + override scoping + context-poisoning trap + first-action gate) applies to every step inside.
  - **`references/tracker-delta-batching.md`** (NEW). Holds the AP-23 batched-tracker-delta queue contract: queue location, valid `delta_kind:` values, flush points, durability across BLOCKED fires, recovery semantics, schema migration. Also holds the `branching.no_force_push: true` short-circuit that disables the rolling tracker PR pattern. Lifecycle integration points (D1.0.4 / D1.0 / D2 / D7.1a / D7.4) stay in `drain-lifecycle.md`; this file is the data-and-rationale document. Opens with the same delegation-contract reminder.
- **Dropped `version:` frontmatter field** (`SKILL.md` frontmatter). The canonical Anthropic skill schema (per `definition-review/scripts/lint-definition.py` SUPPORTED_SKILL_FIELDS set) does not define `version`; CHANGELOG.md is now the single source of truth for version history. Linter S09 warning resolved. A note in the SKILL.md intro states "CHANGELOG.md is the single source of truth for version history" so the field's absence is documented rather than implicit.
- **Reference index expanded** (`SKILL.md`). The reference table now lists the three new files alongside the existing references; the index also adds `scripts/repo_shape_probe.sh` and `scripts/repo_shape_probe_patterns.sh` which were already on disk but not surfaced in the index.
- **Behavioral preservation verified.** All five rules from the prior on-demand patch are intact post-split: (1) loading preamble at top of SKILL.md, (2) override scoping section (`--yolo` / branching orthogonality clause), (3) context-poisoning trap section, (4) Rule 10 rewrite with "survives every override" clause and cross-reference to the preamble, (5) first-action gate restated at the start of `references/drain-lifecycle.md` §D1 so it survives auto-compaction. Linter PASS (0 errors, 0 warnings).

## [2.2.0] - 2026-06-29

Adds the AP-23 repo-shape probe at GENERATE time, closing the gap that forced the `audit-pre-gates` drain to ship an operator-authored "Repo constraints (READ FIRST)" block by hand. Also rolls in the three surgical fixes from the [2.1.1] follow-up pass (see Changed / Added below) so there is one current release tag rather than two minor-version bumps in the same hour.

### Added

- **AP-23: G1.5 repo-shape probe** (`scripts/repo_shape_probe.sh`, `SKILL.md`, `references/runbook-template.md`). New GENERATE step run after dirty-tree / not-on-trunk / concurrent-drain refusals. Probes the remote for: trunk branch, CI manifest presence (`bitbucket-pipelines.yml` / `.github/workflows/*.y(a)ml` / `Jenkinsfile` / `.gitlab-ci.yml`), force-push acceptance (via temp-branch `+` refspec push), and JIRA-key pre-receive hook enforcement (via temp-branch push with a hook-violating commit subject). Emits `KEY=VALUE` lines on stdout, warnings on stderr, exit 0 even when individual probes return `unknown`. Cleanup is via `trap` on EXIT/INT/TERM — orphan probe branches from killed runs can be cleaned up manually using the temp-branch naming convention documented in the script header (`autopilot/probe-force-push-<PID>`, `autopilot/probe-jira-hook-<PID>`).
  - Probe facts seed runbook frontmatter automatically: `CI_PRESENT=false` → `ci.skip_wait: true`; `FORCE_PUSH_ALLOWED=false` → `branching.no_force_push: true`; `JIRA_HOOK_ENFORCED=true` → `enforce_jira_key: true`. `unknown` values do NOT auto-flip — they surface as warnings in the G8 review summary and the operator decides.
  - Probe facts ALSO populate a `### Repo constraints (detected)` block at the top of the seeded runbook body so the operator can read them without re-running the probe. This is the auto-populated complement to the operator-authored `### Repo constraints (READ FIRST)` block that the audit-pre-gates drain produced manually.
  - JIRA-hook probe design choice: temp-branch push (same approach as the force-push probe) rather than a heuristic on `git config` / remote URL. Pre-receive hooks are server-side state; the only ground truth is "what does the server reject". A local heuristic would miss the actual signal.
  - `--dry-run` flag prints every probe operation and the temp branch names that WOULD be created, with no network calls. Useful for operators reviewing what the probe will touch.
- **`ci.skip_wait` frontmatter flag** (`SKILL.md` D7.5.0, `references/runbook-template.md`). When true, D7.5 skips the entire CI poll branch and treats every operator-approved PR as GREEN. The dispatcher does NOT call `ci_check.sh` under this flag; calling it would consume polling fires that never resolve. Default `false`; auto-set by G1.5 when `CI_PRESENT=false`.
- **`branching.no_force_push` frontmatter flag** (`SKILL.md` tracker-PR availability, `references/runbook-template.md`). When true, the rolling tracker PR pattern is disabled — tracker bookkeeping rides on each in-flight Subtask PR's branch instead, as a final `chore(tracker): <id> — …` commit. Default `false`; auto-set by G1.5 when `FORCE_PUSH_ALLOWED=false`.
- **`branching.single_branch_single_pr` frontmatter flag** (`references/runbook-template.md`). Operator-toggle only (NOT auto-set by the probe). When true, the entire drain collapses into ONE feature branch and ONE PR; Subtasks merge into the same branch as incremental commits. Use when the work is tightly coupled and the operator-mandated review unit is the drain, not the Subtask (the audit-pre-gates pattern). Default `false`; G1.5 emits a `## Drift Notes` reminder when the operator has manually flipped this flag so subsequent dispatchers know to honour the single-PR model.

### Changed (was [2.1.1] surgical follow-up; folded into 2.2.0)

- **`scripts/bitbucket.sh pr-merge`: 409 retry-with-fresh-GET.** New `bb_curl_status` helper captures HTTP status codes separately from response bodies. On `409 Conflict` from the merge POST (PR version changed between our GET and POST — typical causes: comment added, approval recorded, external rebase landed), the script re-GETs the PR, refreshes `version`, and retries the POST exactly once. A second 409 is surfaced as `pr-merge: 409 Conflict after refresh-and-retry; PR is contested`. No further retry — looping would mask the underlying problem. Other status codes are unaffected (non-2xx still hard-fail with the response body excerpt).
- **`scripts/ci_check.sh`: emit `LAST_STATE=<value>` on stderr before exit 2/3.** The D7.5 dispatch table row for exit 2 cites "the script's last seen build state"; the script captured `LAST_STATE` at line 70 but never emitted it. Now `LAST_STATE=<value>` (or `LAST_STATE=UNKNOWN` if never set) is written to stderr immediately before `exit 2` (STUCK timeout) and `exit 3` (UNDETERMINED grace-window expiry). Stdout stays machine-parseable (`VERDICT=…`); LAST_STATE is on stderr only.
- **`scripts/secret_set.sh`: write/read divergence guard rails.** Adds `--as-host` (writes to the host-derived joined name, e.g. `bitbucket-token:cluster03`, instead of the default `autopilot-<service>` namespace — for operators who want one shared entry across their tooling) and `--force` (bypasses the operator-credential abort and writes the autopilot-namespaced copy anyway). In default mode, the script now probes every OTHER resolver-chain candidate from `secret_get.sh` (override env var, host-named, bare `<service>-token`, bare `<service>`) and aborts with `operator-owned credential detected at <name>` when any of them has a non-empty entry — preventing the silent two-copy state where an operator had `bitbucket-token:cluster03` and then ran `secret_set.sh bitbucket` and ended up with both. Both flags can be combined; rejected alternative (a single flag without the abort) would have left the silent-duplicate failure mode in place.

### Known follow-ups (not in this release)

- **Dispatcher implementation of batched tracker-delta queue under `branching.no_force_push: true`.** Delivered in [2.3.0] (AP-23 dispatcher contract).
- **Probe rejection-message regex registry.** Delivered in [2.3.0] (`scripts/repo_shape_probe_patterns.sh`).
- **Probe budget under sidecar mode.** Delivered in [2.3.0] (`references/sidecar-contract.md` §"Probe budget under sidecar mode").

## [2.1.0] - 2026-06-29

Surgical fixes from the `audit-pre-gates` drain on `HLASTRO/astro-agents` (5 fires, 3 PRs landed). Each item below traces to a documented `## Drift Notes` finding in the consumer-repo tracker. No breaking changes; all v2.0.x runbooks continue to work.

### Added

- **AP-20: D1.0.5 drift-notes hydration** (`references/drain-lifecycle.md`). New first step in every DRAIN fire: read every `## Drift Notes` entry in the tracker before any git or Bitbucket action and treat the documented findings as hard preconditions, not commentary. Stops fires re-deriving the same workarounds from scratch.
- **AP-21: G3.6 Subtask consolidation pass** (`references/generate-lifecycle.md`, `references/runbook-template.md`). After plan-review, eligible groups of small same-kind config / docs Subtasks within a Story can be merged into one before draining. Off by default; operators opt in with `pack_subtasks: true` in runbook frontmatter or `--consolidate=auto` on the GENERATE invocation.
- **AP-22: JIRA-key per-commit enforcement** (`references/drain-lifecycle.md`, `references/runbook-template.md`). New `enforce_jira_key:` frontmatter flag. When true (or under `--jira` mode), every TDD-cycle commit, every PR-tip commit, and every tracker-bookkeeping commit prefixes the JIRA key in brackets. Required for pre-receive hooks that reject pushes containing any commit without a key.
- **`bitbucket.sh pr-approve` and `pr-decline` subcommands.** State-changing endpoints with the XSRF-safe `X-Atlassian-Token: no-check` header applied centrally in `bb_curl`. Previously the skill had no way to drive approval / decline through the script.
- **`bitbucket.sh pr-merge-strategies` subcommand.** Queries the PR merge endpoint to discover which strategy IDs the repo has enabled (`merge-commit`, `no-ff`, `squash`, etc.) so `pr-merge` can fall back from `merge-commit` to `no-ff` on repos where only one is enabled.
- **D7.5 dispatch table rows for `ci_check.sh` exits 2 (STUCK timeout) and 4 (PR_DECLINED) and 64 (usage error).** Previously only exits 0, 1, and 3 were enumerated; exit 2 was silently masked as "no-op fire that bumps the counter".

### Changed

- **`scripts/bitbucket.sh` response sanitisation.** Every response body now passes through `python3 ... decode('utf-8', errors='replace')` before reaching `jq`. Em-dashes and other non-UTF-8 bytes in PR titles / descriptions no longer make `pr-open` silently misreport "no PR number in response" when the PR was actually created. Stable across DC versions; stdlib-only.
- **`scripts/bitbucket.sh` XSRF header.** Every state-changing POST now includes `X-Atlassian-Token: no-check`. Bitbucket DC's XSRF guard rejects approve / merge POSTs from non-browser clients without it on some cluster configurations.
- **`scripts/bitbucket.sh` `pr-merge` strategy discovery.** Translates the caller's intent (`merge-commit` | `squash`) into an ordered candidate list and probes which strategies the repo has enabled via `pr-merge-strategies` before posting. Falls back to the first candidate on parse miss (older DC). Avoids the "Enabled strategies … are: no-ff" 400 hit on repos that only enable `no-ff`.
- **`scripts/secret_get.sh` keychain service-name resolver.** Now probes a priority list of candidate service names — `$AUTOPILOT_<SERVICE>_KEYCHAIN_NAME` override, `autopilot-<service>` canonical, host-derived joined-name (`<service>-token:cluster03` sniffed from `$BITBUCKET_HOST` or the origin remote URL), `<service>-token`, bare `<service>` — instead of the single canonical name. Stops the convention `bitbucket-token:cluster03` keychain entry from being invisible to the script.

### Known follow-ups (not in this release)

- **Repo-shape probe at GENERATE time.** Delivered in [2.2.0] (AP-23).

## [2.0.0] - 2026-06-27

This is a breaking release. Read the migration section before upgrading.

### Added

- **Sidecar contract v0** (`references/sidecar-contract.md`). Autopilot detects an identity-proxy sidecar and routes Bitbucket DC traffic through it with NO Authorization header when available. Sidecar mode is required in workspace-container deployments; local-laptop deployments fall back to the resolver chain.
- **Credential resolver chain** (sidecar → OS keychain → env). Scripts: `scripts/secret_get.sh`, `scripts/secret_set.sh`, `scripts/sidecar_detect.sh`. Tokens never enter argv, trace logs, or Claude Code tool arguments.
- **Bitbucket DC adapter** (`scripts/bitbucket.sh`) replacing all gh CLI calls. Subcommands: `pr-open`, `pr-state`, `pr-comment`, `pr-merge`, `build-status`.
- **Per-cycle TDD commits** (AP-1). D4 implementer emits a `test:` commit (RED) and a `feat:` commit (GREEN) per TDD cycle. D6 verifies the cycle by walking git log, replacing the old heuristic LLM check.
- **Split block counters** (AP-2). `consecutive_impl_blocks` and `consecutive_ci_blocks` track impl vs CI failure modes independently. External faults (foreign commits, trunk rename, tracker-pr-blocked) bypass counters and escape directly to HUMAN_NEEDED.
- **Plan reviewer projection** (AP-3). Plan reviewer at D3.2 sees only `id`, `kind`, `owned_files`, `depends_on`, `test_gates`, `validators`, `public_api` signature, `behaviors_to_test`, `estimated_size`. Internal contract prose and `test_name_hint` are stripped.
- **Tracker lockfile keyed on CLAUDE_SESSION_ID** (AP-4) with 30-min expiry and heartbeat refresh.
- **audited_sha pre-check** (AP-5). Planner emits the SHA the audit was run against. D3.0 verifies every `owned_files` path exists at that SHA and HEAD has not drifted into any owned path. Stale plans return `[BLOCKED: plan-stale-*]` (impl).
- **Heartbeat enforcement at every step boundary** (AP-6). `last_heartbeat_at` is written at D1.2, D3, D4, D5, D6, D7.x.
- **Branch shape check at D1.1** (AP-7). Current branch must match `autopilot/<slug>/(setup|tracker|<subtask-id>)`.
- **Rationale paragraph in D7.1 commit body** (AP-8).
- **test_name_hint in planner schema** (AP-9).
- **Stacked PR merge-commit strategy** (AP-10). `bitbucket.sh pr-merge` defaults to `merge-commit` to preserve TDD cycle history. Squash is opt-in per PR.
- **Force-audit trail** (AP-11). `--force` operator overrides are logged to `force_audit:` in tracker frontmatter.
- **PAUSED dedup** (AP-17). Same block re-hit does not emit a duplicate tracker commit.
- **Contradictory validator handling** (AP-18). Findings with opposing directives on the same path emit `[BLOCKED: validator-contradiction]` (impl) and route to HUMAN_NEEDED.
- **Scoped pytest during rebase** (AP-15). Conflict resolution runs only the subtask's test_gates plus tests under touched paths, never the full suite.
- **800-token cap on implementer report** (AP-16).

### Changed

- **D6 (TDD verification)** is now a deterministic git log walk over per-cycle commits (AP-1) instead of an LLM heuristic.
- **CI platform** is exclusively `bitbucket-dc` in v2.0.0. GitHub support has been removed.

### Removed

- **`install_external_scheduler.sh` and `uninstall_external_scheduler.sh`** (AP-19). Cadence is now strictly in-session.
- **`--external-scheduler` flag and all related dispatcher branches**.
- **gh CLI dependency** (AP-13). All Bitbucket interaction routes through `scripts/bitbucket.sh` (git + Bitbucket REST).

### Migration from v1

Required operator actions before first v2 dispatch:

1. **Remove v1 cron entries.** v1 may have installed crontab/launchd entries via `install_external_scheduler.sh`. v2 does not ship `uninstall_external_scheduler.sh`. Remove entries manually.
2. **Store Bitbucket DC token** via `scripts/secret_set.sh bitbucket` (token read from STDIN, never argv), or rely on sidecar mode.
3. **Update each runbook's frontmatter**: add `audited_sha:`, replace `consecutive_failures_cap:` with `max_impl_blocks:` and `max_ci_blocks:`, remove `external_scheduler:`, `cron_*`, `gh_cli_path:`, `secrets_inline:`.
4. **Uninstall gh CLI** if it was installed solely for autopilot v1.
