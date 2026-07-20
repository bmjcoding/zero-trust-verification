# Changelog

All notable changes to the autopilot skill. Format follows Keep a Changelog; versioning is SemVer. CHANGELOG.md is the single source of truth for version history — the SKILL.md frontmatter does not carry a `version:` field.

**Release gate (v2.4.0, GAPS M3/M6).** Every behavioral claim in a release entry MUST cite the `scripts/self_test.sh` assertion id (Txx) or `scripts/lint_consistency.sh` rule id (Lxx) that proves it, or be tagged `[doc-only]`. Both scripts must pass before tagging. Any drain failure attributable to the skill must land a failing self-test assertion before (or with) its fix — a gap found once may not recur silently. (This gate exists because v2.1.0–v2.3.0 shipped multiple claimed-but-unimplemented behaviors, recorded in the since-deleted GAPS register.)

**ID note.** `AV3-x.n` ids cited below resolve to `scripts/self_test.sh` assertions (the standalone autopilot-v3 register doc was retired); `GAPS-xx` / M-x references in older entries are historical — `docs/GAPS_SPEC.md` was deleted in the ADR 0025 Wave 2 sediment deletion.

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
foundation. Per the M3 gate every
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

Entries ≤2.4.0 are archived verbatim in `plugins/zero-trust/docs/autopilot/CHANGELOG-v2.md` (ADR 0031).
