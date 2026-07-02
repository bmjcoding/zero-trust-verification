# Autopilot v2.3.0 — Gap Register & Closure Spec

Audit of the `autopilot` skill (v2.3.0, 26 files, ~4,550 lines) performed 2026-07-02.
Methodology mirrors the codebase-health-suite v1.3.0 audit: **ground truth over
judgment** (every suspected mechanical bug was reproduced by executing the script
against a controlled fixture before being registered), **executed tests for
everything deterministic** (each fix ships with a `self_test.sh` assertion that
fails against the v2.3.0 baseline), and **author-blind adversarial verification**
(independent agents re-review the fixes without seeing this register's authorship
context).

Every finding has an ID, severity, evidence, acceptance criteria, and status.
Statuses: `OPEN` → `FIXED (test: <assertion-id>)` → adversarially `CONFIRMED`,
or `DOCUMENTED` (accepted residual, recorded honestly).

Severity: **P0** = the skill cannot work as documented (fatal); **P1** = a documented
safety/correctness property is silently false; **P2** = contradiction or dead
contract that will misroute an orchestrator; **P3** = hygiene/portability.

---

## A. Fatal mechanical bugs (all empirically reproduced against v2.3.0)

### A1 — `bitbucket.sh`: `HTTP_STATUS` set in a command-substitution subshell — every REST subcommand fails unconditionally [P0]
**Evidence (executed).** Against a mock server returning HTTP 200 `{"state":"OPEN"}`:
`bitbucket.sh pr-state --num 42` → `LAST_STATE=pr-state-http-0`, exit 1.
`bb_curl` sets the `HTTP_STATUS` global, but every caller invokes it as
`resp=$(bb_curl …)` — a subshell — so the parent always sees the initial `HTTP_STATUS=0`
and every status check fails, **including on success**. Corollary: `die_state` inside
`bb_curl` (e.g. credential-unavailable) exits only the subshell; the caller continues
with an empty response (observed: both `LAST_STATE=credential-unavailable` *and*
`LAST_STATE=pr-state-http-0` emitted in one run). The script has never completed any
subcommand successfully. Everything downstream that "worked" in prior drains cannot
have gone through this script.
**Acceptance.** All subcommands succeed against a mock Bitbucket DC server (2xx),
fail with the correct `LAST_STATE` on non-2xx, and abort the whole script when the
credential resolver fails. Self-test runs the full subcommand matrix.
**Status.** FIXED (tests: T01–T07). `bb_curl` now writes the body to a caller-named
file and returns the status on stdout; no state crosses a subshell boundary.

### A2 — `repo_shape_probe_patterns.sh`: `${entry%%|*}` truncates every regex at its first internal `|` [P0]
**Evidence (executed).** 5 of 6 realistic Bitbucket DC rejection strings fail to match
(`you are not permitted to force-push…`, `commit message must contain a valid JIRA issue key`, …).
The parser splits regex/signal on the **first** pipe, but most regexes contain `|`
alternations — the truncated pattern has unbalanced parens and `grep -E` errors
silently (`2>/dev/null`). Only alternation-free patterns ever matched.
**Acceptance.** Table-driven test: every registry pattern matches its documented
example message and maps to the right signal; a nonsense message matches nothing.
**Status.** FIXED (test: T08). Regex is now `${entry%|*}` (everything before the
**last** pipe); registry format documented accordingly; example message added per row.

### A3 — Force-push probe performs a fast-forward, not a history rewrite — can never detect denial [P0]
**Evidence (executed).** Against a bare repo with `receive.denyNonFastForwards=true`
(denial proven by a sanity force-push that was rejected), the probe reported
`FORCE_PUSH_ALLOWED=true`. The probe pushes trunk-tip `T`, then builds `T+B` and
force-pushes — but `T → T+B` **is a fast-forward**, so it succeeds on every server.
Consequence: `branching.no_force_push` is never auto-set, so the entire AP-23
batched-delta machinery is unreachable through the advertised auto-detection path.
**Acceptance.** Probe returns `false` against a deny-non-fast-forward fixture and
`true` against a permissive fixture.
**Status.** FIXED (tests: T09, T10). Probe now pushes `T+A`, rewrites the branch to
the divergent sibling `T+B`, and force-pushes — a genuine non-fast-forward update.

### A4 — Probe stdout pollution corrupts the KEY=VALUE contract [P1]
**Evidence (executed).** Same run emitted
`FORCE_PUSH_ALLOWED=branch 'autopilot/probe-force-push-4966' set up to track 'origin/main'.` —
git wrote informational text into the command substitution that captures the value.
**Acceptance.** Probe stdout consists of exactly four `KEY=VALUE` lines matching
`^[A-Z_]+=(true|false|unknown|[A-Za-z0-9._/-]+)$` under all outcomes.
**Status.** FIXED (test: T11). All git output inside detectors is redirected to the
probe logfile.

### A5 — `detect_concurrent_drain.sh` cannot detect a concurrent drain (two independent faults) [P0]
**Evidence (executed).**
(a) G1 documents `detect_concurrent_drain.sh <slug>`; the script requires a tracker
*path*. Called with a slug, `[[ ! -f ]]` → exit 0 = "no concurrent drain": the refuse
can never fire.
(b) Called with a valid path against a tracker seeded per G7's schema
(`session_lock` / `session_lock_expires_at`), the script reads the *legacy* field names
(`session_id` / `lock_acquired_at`) → empty → exit 0, even with a live foreign lock.
(c) Design fault: the script's 5-minute heartbeat window declares a lock "stale"
between perfectly healthy fires armed at `*/30` cadence — a second session could
steal the lock of a healthy drain.
(d) Fail-open: any unreadable/foreign tracker yields exit 0 (proceed), violating
refuse-by-default.
**Acceptance.** Script consumes the canonical G7 field names, takes a tracker path
(and callers pass one); live foreign lock → exit 2; expired lock → exit 3;
readable-but-lockless → exit 0; staleness = `session_lock_expires_at <= now`
(matches the D1.0 dispatch table, no heartbeat-window race).
**Status.** FIXED (tests: T12–T16).

### A6 — `ci_check.sh` interface mismatch: the documented D7.5 call kills the drain [P0]
**Evidence (executed).** drain-lifecycle D7.5 (and D1.4) call `ci_check.sh <pr_number>`;
the script demands `--sha <sha> --pr <N>` → exit 64. The D7.5 dispatch table routes
exit 64 to `STATUS: HUMAN_NEEDED — ci-check-usage-error` + `CronDelete`. **The first
CI poll of every drain terminates the drain.**
**Acceptance.** Lifecycle text and script agree on one invocation; self-test executes
that exact invocation shape.
**Status.** FIXED (tests: T17–T20). Canonical call is
`ci_check.sh --sha <sha> --pr <N> --once`; lifecycle updated.

### A7 — `ci_check.sh` blocks for up to 30 minutes inside a fire; "pending" rows unreachable [P1]
**Evidence.** The script loops `sleep $POLL` until GREEN/RED/timeout (default 1800 s).
The D7.5 design is cross-fire: one observation per fire, re-arm cron at `*/10`.
The dispatch table's `pending + ci_check_count < 6` rows can never occur — the script
never exits on pending; it blocks and then reports STUCK. Also: the emitted
`LAST_STATE=stuck-timeout` is a constant, not "the script's last seen build state"
as v2.2.0's changelog claims; the internal `LAST_STATE` variable that captures the
real build state is dead.
**Acceptance.** `--once` mode returns immediately with
`VERDICT=GREEN|RED|PENDING|PR_DECLINED` (exit 0/1/5/4 — an UNKNOWN single
observation is PENDING; the dispatcher's `ci_check_count` cap converts
persistent pending into `ci-stuck-pending`, and STUCK/UNDETERMINED remain
blocking-mode verdicts); D7.5 consumes `--once`; `LAST_STATE` on stderr
carries the actual last observed build state.
**Status.** FIXED (tests: T17–T20). Blocking mode retained for operator use;
dispatcher uses `--once`.

### A8 — `hot_file_audit.sh` does not implement its G4 contract; the hot-file DAG feature is inert [P1]
**Evidence (executed).** G4: "Run `hot_file_audit.sh` — surfaces the 20 most-churned
files in the last 30 days" (no args). The script (a) requires a `<slug>` arg — the
documented call exits 64/1; (b) computes cross-subtask-*branch* overlap, which at
GENERATE time is always empty because no subtask branches exist yet. The G4 hot-file
serialization feature can never trigger.
**Acceptance.** `--churn [--days N] [--top N]` mode implements the G4 contract
(git-log churn); `--subtasks <slug>` retains the drain-time overlap mode; G4 invokes
`--churn`; both modes covered by tests.
**Status.** FIXED (tests: T21–T23).

### A9 — Sidecar platform-name mismatch: contract-conformant sidecar is silently bypassed [P1]
**Evidence (executed).** sidecar-contract.md guarantees platform id `bitbucketdc`
(env example `bitbucketdc,jira,github`; URL shape `/bitbucketdc/…`). `bitbucket.sh`
matches only `,bitbucket,` and builds `/bitbucket…`. With
`IDENTITY_PROXY_PLATFORMS=bitbucketdc` the script fell through to local keychain
mode — defeating the "token never enters the workspace process tree" guarantee
whenever a real sidecar is present.
**Acceptance.** Both `bitbucketdc` (canonical) and `bitbucket` (legacy) are accepted;
the URL segment uses the matched platform id; self-test exercises the sidecar path
with `PLATFORMS=bitbucketdc`.
**Status.** FIXED (tests: T05–T07).

### A10 — CI-manifest detection can never see `.github/workflows` [P2]
**Evidence.** `detect_ci` greps non-recursive `git ls-tree` output for the literal
`^\.github/workflows$`; non-recursive ls-tree lists `.github`, never the nested path.
**Acceptance.** Recursive listing; fixture with a workflow file detected.
**Status.** FIXED (test: T24).

## B. Claimed-but-not-implemented changelog entries (release-integrity class)

These are the most corrosive gap type for a loop skill: the CHANGELOG asserts a
safety behavior that does not exist, so operators trust guarantees that no code
provides. Root cause registered as M3 (no release gate ties claims to assertions).

### B1 — v2.1.0 "response UTF-8 sanitisation" is absent [P1]
CHANGELOG: "Every response body now passes through python3 … decode('utf-8',
errors='replace') before reaching jq." `bb_curl` emits the raw body (`cat "$tmp_body"`);
only *request* payloads are sanitised. The original "no PR number in response" failure
mode is still live.
**Status.** FIXED (test: T04 — mock returns an invalid-UTF-8 byte in the body;
`pr-open` still extracts the id).

### B2 — v2.1.0 "pr-merge strategy discovery" is absent [P1]
CHANGELOG: pr-merge "probes which strategies the repo has enabled via
pr-merge-strategies before posting. Falls back to the first candidate on parse miss."
The code performs a static name mapping and never calls the discovery subcommand.
**Status.** FIXED (test: T06 — mock repo enables only `squash`; `pr-merge --strategy
merge-commit` discovers and posts the fallback instead of 400ing).

### B3 — v2.2.0 `secret_set.sh` cross-candidate collision guard is absent [P1]
CHANGELOG: default mode "probes every OTHER resolver-chain candidate … and aborts
with `operator-owned credential detected at <name>` when any of them has a non-empty
entry." The code probes only the exact target name. The documented silent-two-copy
failure mode is still present. Also: the changelog describes the `--as-host` name as
`bitbucket-token:cluster03`, but the implementation writes `autopilot-bitbucket-<host>`.
**Status.** FIXED (code + doc): cross-candidate probe implemented (keychain-less CI
covered by T25's `--list-candidates` contract); changelog erratum recorded in 2.4.0
notes. `secret_get.sh` gains the documented `<service>-token:<host>` /
`$<SERVICE>_HOST` candidates it claimed in v2.1.0 (test: T25).

### B4 — v2.3.0 "unknown rejection → corpus-growth stderr message" is absent [P2]
CHANGELOG: `match_rejection` "emits the raw rejection to stderr with `probe: unknown
rejection pattern; please add to repo_shape_probe_patterns.sh: <raw message>` whenever
no entry matches." Not implemented anywhere; the no-match path is silent (or
`--explain`-gated with different text).
**Status.** FIXED (test: T26) — emitted by the probe on any unmatched rejection,
always-on.

### B6 — v2.3.0 `--explain` claim describes a different flag [P3]
CHANGELOG v2.3.0 (and generate-lifecycle §--explain): "`--explain` prints the current
registry contents on stdout and exits 0." The implemented `--explain` was a stderr
reasoning trace during a real probe — a different, and more useful, behavior.
**Status.** FIXED: `--explain` keeps (and docs now describe) the trace; the registry
printer ships as `--show-patterns`.

### B5 — v2.3.0 sidecar "probe budget" table describes REST machinery the probe doesn't have [P2]
The budget table (4/4/12/24 max requests, 429 `Retry-After` handling) is attached to
a probe that uses git transport (no HTTP statuses) and performs a fixed, bounded set
of operations. Nothing implements or could implement the table as written.
**Status.** FIXED (doc): section rewritten to describe the real bound (fixed operation
count by construction; REST exposure limited to one `build-status` GET routed through
`bitbucket.sh`, which owns 429 handling) and the real operator controls
(`--dry-run`, `--no-probe`).

## C. Contract contradictions across the doc corpus

An orchestrator (an LLM) loads these files as ground truth; each contradiction is a
coin-flip at runtime. C-class fixes canonicalize one contract and are enforced going
forward by `lint_consistency.sh` (M2).

### C1 — Two artifact-path schemes [P0-doc]
G7/D1.2/Resume/cadence: `docs/design/AUTOPILOT-PROMPT-<slug>.md` +
`docs/design/AUTOPILOT-TRACKER-<slug>.md`. README/runbook-template:
`.autopilot/runbooks/<slug>.md` + `<slug>.tracker.md`. A GENERATE following one file
and a DRAIN following the other never find each other's artifacts.
**Canonical.** `.autopilot/runbooks/<slug>.md` (runbook) and
`.autopilot/runbooks/<slug>.tracker.md` (tracker). Lint L1 forbids the legacy paths.
**Status.** FIXED (lint: L1).

### C2 — Two tracker frontmatter schemas [P0-doc]
G7 seeds `session_lock` / `session_lock_expires_at` / `STATUS` / split counters /
`in_progress`; runbook-template documents `session_id` / `lock_acquired_at` /
`current_step` / `paused:`; `detect_concurrent_drain.sh` read the latter (see A5).
**Canonical.** The G7 schema, now written out in full in runbook-template.md §Tracker
file and consumed by the script. Lint L2 greps for the legacy field names.
**Status.** FIXED (lint: L2; tests: T12–T16).

### C3 — Legacy D0..D7.5 step graph still documented in three places [P1-doc]
runbook-template §"How autopilot reads the runbook" (D0 init / D1.x audit / D2 plan /
D3 dispatch), README ("Step graph D0..D7.5"), and the headers of
`hot_file_audit.sh` / `detect_concurrent_drain.sh` describe the pre-v2.3 graph;
the operative graph is G1..G8 / D1..D8.
**Status.** FIXED (lint: L3).

### C4 — Duplicate step id `D7.5` [P1-doc]
drain-lifecycle has both "### D7.5 — Stacked PR merge strategy (AP-10)" and
"## Step D7.5 — CI poll (cross-fire)". SKILL.md's table means the latter.
**Canonical.** Stacked-PR merge strategy renamed **D7.3a** (it is part of PR
creation); D7.5 = CI poll only.
**Status.** FIXED (lint: L4).

### C5 — Three validator catalogs [P0-doc]
runbook-template frontmatter + README examples: `correctness, security, performance,
style`. validator-prompts.md / planner rules / D5: `integration, design, quality`
(+ optional `security`, `sre`). An operator following the template configures
validators that do not exist; the planner-emitted names are never legal per the
template.
**Canonical.** `integration, design, quality` always; `security`, `sre` optional.
**Status.** FIXED (lint: L5).

### C6 — Budget caps documented as configurable, hardcoded in the lifecycle; three cap values in circulation [P1-doc]
Runbook `budget.max_impl_blocks` (default 3) / `max_ci_blocks` (default 2) are never
consulted: drain-lifecycle hardcodes `>= 3` for both; role-prompts-rationale says
impl 3 / ci 2; cadence's "hits 2 = one short of the threshold" assumes 3. Also
`max_subtasks`, `max_cycles_per_subtask`, `max_runtime_minutes` are enforced nowhere.
**Canonical.** Caps come from runbook frontmatter (defaults impl 3, ci 2). D2/AP-2
compare against the configured caps; cadence deferral fires at `cap − 1`. Enforcement
points added: G3 (max_subtasks at plan validation), D4 (max_cycles_per_subtask in the
implementer contract + D6 audit), D1.2 (max_runtime_minutes wall-clock check).
**Status.** FIXED (lint: L6).

### C7 — `tracker-delta-batching.md` contradicts drain-lifecycle on five load-bearing points [P0-doc]
(1) Flush point: "immediately after a Subtask PR is confirmed merged and before D7.2
tracker-PR cadence check" vs D7.1a's pre-push fold (before the PR exists).
(2) Flush target: "pushed to the tracker branch as a normal fast-forward" *under
no_force_push* — under that flag there is no tracker branch; that's the whole point.
(3) Queue location: "immediately above `## Audit trail`" vs D1.0.4's "between
`## Drift Notes` and the first Subtask".
(4) Flush commit shape: `tracker: fold Subtask <id> + <N> batched deltas` vs the
impl commit carrying a `Tracker deltas folded in:` body block.
(5) References to a nonexistent step `D1.0.6` (twice) and an unregistered flag
`--force-rolling-tracker`.
**Canonical.** drain-lifecycle.md D7.1a/D1.0.4 semantics; batching doc rewritten;
`--force-rolling-tracker` dropped (operator flips `branching.no_force_push` manually,
logged via AP-11).
**Status.** FIXED (lint: L7).

### C8 — AP-17 dedup: two mechanisms [P2-doc]
spec_hash + `paused_count` (rationale + template `paused:` field) vs "same
`status_reason` → skip the commit" (drain-lifecycle D8).
**Canonical.** The drain-lifecycle mechanism; `paused:` frontmatter field removed.
**Status.** FIXED (lint: L2 covers the removed field).

### C9 — AP-18 detection: two mechanisms [P2-doc]
Opposing-`directive` matching over a field that doesn't exist in the findings schema
(rationale) vs lexical `suggested_fix` comparison at the same `location`
(validator-prompts + drain-lifecycle).
**Canonical.** The lexical mechanism. Rationale updated.
**Status.** FIXED.

### C10 — TDD commit format: two shapes [P2-doc]
`test: <subtask-id> <test-name> [RED]` (rationale) vs
`test: <id>.<n> RED — <behavior>` (implementer prompt, D4, D6 audit).
**Canonical.** The latter (D6's parser anchors on it). Rationale updated.
**Status.** FIXED (lint: L8).

### C11 — D3.0 staleness routing: auto-replan vs terminal block [P2-doc]
Rationale: "returns to D2 for replan … planner picks per the staleness pattern."
drain-lifecycle: "No retry; … needs human re-plan."
**Canonical.** Terminal `[BLOCKED: plan-stale-*]` (impl), no auto-replan.
**Status.** FIXED.

### C12 — Plan-reviewer projection allow-list: three variants; NEVER-GO makes the drift dangerous [P1-doc]
plan-reviewer-projection.md includes `parent_story` + `branch_pattern`; G3.5's list
and the rationale omit them (rationale also cites a nonexistent step "D2.1").
Because a reviewer must NEVER-GO on any field outside its allow-list, an orchestrator
stripping per one file and a reviewer checking per another produces spurious
`[GENERATE-FAILED: plan-review-ungated]`.
**Canonical.** plan-reviewer-projection.md is the single source; other files
reference it without enumerating. `branch_pattern` removed entirely (see C13).
**Status.** FIXED (lint: L9).

### C13 — `branch_pattern: <type>/<slug>-{date}` contradicts AP-7 and is consumed by nothing [P2-doc]
AP-7/D4 mandate `autopilot/<slug>/<subtask-id>`. The planner-schema field would fail
the D1.1 branch-shape check if honored.
**Canonical.** Field deleted from planner schema and projection.
**Status.** FIXED (lint: L9).

### C14 — `estimated_size` vocabulary mismatch disables AP-21 [P2-doc]
Planner schema: `S | M | L`. G3.6 eligibility: "`estimated_size` is `xs` or `s`" —
values that cannot occur, so consolidation is never eligible.
**Canonical.** Eligibility = `S`.
**Status.** FIXED (lint: L10).

### C15 — Dangling cross-Story `depends_on` only checked in `--merge` mode [P1-doc]
Planners run in parallel and may reference other Stories' Subtask IDs they cannot
know; base-path G4 checks cycles and overlap but not unknown IDs (only GENERATE-merge
re-runs the dangling check).
**Canonical.** G4 always validates every `depends_on[]` id and fails with
`[GENERATE-FAILED: dangling-dependency]`.
**Status.** FIXED.

### C16 — Cron re-arm prompt would not restart the loop [P1-doc]
`CronCreate(prompt='@…/runbook.md')` (D8, cadence, Resume) loads file content with no
instruction — nothing tells the next fire to run the DRAIN lifecycle.
**Canonical.** `prompt='/autopilot --drain @<runbook-path>'`.
**Status.** FIXED (lint: L11).

### C17 — Stale version references and impossible dates [P3]
README "v2.0.0 ships Bitbucket DC only" / cadence-dispatch "no external-scheduler
path in v2.0.0" (both mean "since v2.0.0"); README dates v2.3.0 at 2026-07-02 while
CHANGELOG dates it 2026-06-29.
**Status.** FIXED (lint: L12 pins version strings to CHANGELOG top entry).

### C18 — "While you sleep" vs "no headless mode" [P1-doc, honesty]
SKILL.md description sells "drain it into PRs while you sleep / overnight autonomous
PR drain"; role-prompts-rationale (AP-19) states flatly: "Autopilot only makes
progress while a Claude Code session is active — there is no headless mode."
**Canonical.** Honest phrasing: the loop is autonomous *within a live session*
(self-re-arming cron, no re-prompting); it does not survive session death, and the
description now says so.
**Status.** FIXED.

### C19 — Unregistered flags [P2-doc]
`--reprobe` (README, runbook-template, sidecar-contract), `--no-auto-seed`
(runbook-template, probe), `--no-probe` (sidecar-contract), `--force-rolling-tracker`
(batching doc) appear only in references; SKILL.md's modes/flags table is silent on
all four, and the skill has no `argument-hint`. Same failure class as the audit
plugin's unwired `--focus`/`--no-html`.
**Canonical.** SKILL.md gains a flags table registering every flag with its scope;
`--force-rolling-tracker` dropped; `argument-hint` frontmatter added;
non-standard `lifecycle:` frontmatter field removed (S09-class; the canonical skill
schema doesn't define it — status line moved into body text).
**Status.** FIXED (lint: L13 — every `--flag` token in references must appear in
SKILL.md's registry).

### C20 — Session-lock protection is checkout-local under batched-delta mode [P2-doc]
Under `branching.no_force_push: true`, D1.0's lock write lands only in the local
tracker file (queued, unpushed) — a second session on another clone cannot see it.
AP-4 silently degrades from repo-wide to same-checkout.
**Status.** DOCUMENTED — honest limitation note added to drain-lifecycle D1.0 and
tracker-delta-batching.md; cross-clone guard remains the branch-namespace probe.

### C21 — `delta_kind` catalog: wrong emit-points, conflated meanings [P3]
Catalog rows cite `D1.0.6` (nonexistent) and define `in_progress_claim` as a session
-lock write (it's D2's Subtask claim; `session_lock` is the lock kind).
**Status.** FIXED (rewritten alongside C7).

### C22 — Runbook immutability contradicted [P3]
G7: "runbook (immutable after this point)" vs runbook-template inviting operator
edits of the detected block and G8's "reminder to edit before draining".
**Canonical.** Runbook is operator-editable until the drain is armed; immutable
during an active drain except the G1.5-owned detected block.
**Status.** FIXED.

### C23 — `mcp__dev-tools__activate_jira` dependency violates the portability contract [P2]
Hard Contract 2 promises "no dependency on user-defined agents"; G6 hard-depends on a
user-specific MCP server for `--jira`.
**Status.** FIXED (doc): G6 declares the dependency explicitly optional-and-external —
refuses `--jira` with a clear message when the tool surface is absent (probed via
ToolSearch) instead of halting mid-generate; core modes carry no MCP dependency.

## D. Consumer-repo contamination (meta-skill hygiene)

### D1 — Internal hostname leak [P1]
`sidecar-contract.md` cites `bitbucket-dc.example.internal` — a real internal corporate
domain, in a skill intended for general distribution.
**Status.** FIXED (lint: L14 — no `internal-host`, no other real-internal hostnames;
placeholder `bitbucket-dc.internal.example.com`).

### D2 — Origin-repo specifics baked into role prompts [P2]
Planner test-gate rules name `verbs/`, `mcp/server.py`; SRE validator names
`*/workspace/apply.py`, "TFE / SSM"; config kind names `internal.yml`; conflict-resolution
example paths `internal_sdk/…`; validators reference `~/.claude/skills/owasp-reference/` and
`~/.claude/skills/observability-patterns/`. On any other repo these rules are noise
the planner will pattern-match anyway.
**Status.** FIXED — repo-specific triggers generalized ("wire-shape/contract modules
as configured by the runbook's `contract_paths:` globs", "external state stores",
generic example paths); optional local-skill references framed as "if present".

### D3 — Python-only tooling hardcoded across the drain [P1]
D6.1 gates (`pytest -m unit`, `mypy`, `ruff`, `pre-commit`), the quality/integration
validators (`python -c import`, `pyproject.toml`), the implementer prompt, and
conflict-resolution all hardcode the Python toolchain, while the runbook's
`test_runner.cmd` field is consumed by **nothing** (dead config). A TS/Go/Rust repo
fails every gate. Additionally `ruff check .` repo-wide "must be zero" makes any
brownfield repo permanently RED and contradicts the skill's own scoping philosophy
(AP-15).
**Canonical.** New runbook `gates:` block (scoped test / typecheck / lint /
precommit command templates with `{paths}`/`{files}`/`{test}` placeholders; Python
defaults preserved verbatim). D6.1, validators, implementer, and conflict-resolution
reference gates by name. Lint scope is changed-files, not repo-wide. `test_runner`
accepted as legacy alias with a warning.
**Status.** FIXED (lint: L15 — no bare hardcoded gate invocations in lifecycle docs
outside the defaults table).

## M. Meta-gaps (the loop about the loop)

### M1 — Nothing ever executed the scripts; the skill has no self-test [P0]
The deepest finding: A1–A10 could all be true simultaneously because no assertion ever
ran any script. A skill whose promise is *machine-verifiable evidence* (TDD via git
log, probes via server ground truth) shipped with zero machine verification of
itself. Direct analog of the audit plugin's "nothing ever executes the code".
**Acceptance.** `scripts/self_test.sh`: hermetic (mktemp sandbox, local bare repos,
mock HTTP server, curl argv shim), loopback-only, covers every A/B-class fix, exits
non-zero on any failure, runs in well under 60 s.
**Status.** FIXED — 69 assertions, all green; every A/B fix landed with its
assertion. The harness caught two additional bugs in this session's own fixes
before they shipped (a dynamic-scoping shadow in `match_rejection`'s outvar, and a
jq `//`-operator bug treating `enabled: false` as enabled) — both now pinned
(T08 regression case, T06).

### M2 — No consistency enforcement across the doc corpus [P0]
C1–C19 accumulated because 17 markdown files restate each other's contracts with no
mechanical check. For a skill whose orchestrator *is* an LLM reading these files,
cross-file contradiction is the highest-probability failure injector.
**Acceptance.** `scripts/lint_consistency.sh`: deterministic greps enforcing the
canonical contracts (L1–L15 as referenced above), wired into `self_test.sh`.
**Status.** FIXED — 15 lint rules, all green.

### M3 — No release gate: CHANGELOG claims are unverified [P1]
B1–B5 shipped because nothing ties an "Added/Changed" bullet to evidence.
**Acceptance.** Release checklist in CHANGELOG.md header: every behavioral claim in a
release entry must cite a self-test assertion id or be tagged `[doc-only]`;
the v2.4.0 entry demonstrates the format.
**Status.** FIXED (process gate; enforced by review, seeded by example).

### M4 — No loop-safety invariants document [P1]
The skill has strong scattered instincts (refuse-by-default, external faults bypass
counters, `unknown` never auto-flips) but no single statement of what the loop may
never do, and at least one guard was fail-open (A5d). Analog of the audit plugin's
`loop-safety.md`.
**Acceptance.** `references/loop-safety.md`: invariants (probes never mutate operator
branches; detection/verify paths never mutate product code; guards fail closed;
corrupt/unreadable state degrades to refuse, never to proceed; every override is
audited; terminal states always release the lock and delete the cron), each mapped to
its enforcement point.
**Status.** FIXED.

### M5 — No fixture-grade end-to-end exercise of a drain [P2]
Even with A/B fixed, GENERATE→DRAIN as a whole has only prose. Full LLM-loop e2e is
out of scope for a self-test, but the deterministic seam (scripts calling scripts:
probe → seed flags → detect-drain → ci-check against fixtures) is testable and now is
(T27 chain test). Agent-level behavior remains measured only in real drains.
**Status.** PARTIALLY CLOSED (T27) + DOCUMENTED residual.

### M6 — No feedback channel from drain failures into the skill's own regression corpus [P2]
`## Drift Notes` capture consumer-repo workarounds but nothing feeds skill bugs back
into `self_test.sh` — the "every real-world miss becomes a fixture" ratchet the audit
plugin adopted.
**Acceptance.** Standing rule added to CHANGELOG header + loop-safety.md: a drain
failure attributable to the skill MUST land a failing self-test assertion before (or
with) its fix.
**Status.** FIXED (process gate).

## Additional script-level findings folded into the A/B fixes

- `bitbucket.sh` `curl --retry 1` applied to POSTs risks duplicate PR/merge
  submissions on timeout → retries now GET-only. (test: T07)
- Bearer token passed in curl argv (`-H "Authorization: …"`) is visible in
  `/proc/*/cmdline`, contradicting sidecar-contract's "never visible in ps" —
  now passed via a 0600 header file (`-H @file`). (test: T03)
- `sidecar_detect.sh` docs claim the healthz *body* must contain "ok"; code checked
  status only → body check added, docs and code agree. (test: T28)
- `secret_get.sh` sidecar tier keyed on `AUTOPILOT_SIDECAR_MODE` which nothing sets →
  documented as the explicit caller contract (bitbucket.sh sets it in sidecar mode);
  Linux locked-keychain short-circuit claim corrected to match `secret-tool` reality.
- `secret_set.sh --help` exited 64 → exits 0. `repo_shape_probe.sh --help` sed range
  drift-proofed.
- Registry CI signals (`CI_PIPELINE_*`) were defined but never dispatched → marked
  reserved with an explicit note (kept for side-band parsing, not currently wired).
- G5's `git log --oneline --all` seed for already-shipped detection picks up probe
  and foreign-drain branches → scoped to `origin/<trunk>`.

## Honest residuals (recorded, not hidden)

1. **The orchestrator contract is still prose.** The first-action gate, delegation
   default, and step ordering bind an LLM, not a program. The self-test proves the
   deterministic substrate; it cannot prove the orchestrator will follow SKILL.md.
   Mitigation: contracts are now internally consistent (M2), which removes the
   known-worst failure injector; drain-time compliance remains measured only by real
   drains and Drift Notes (M6 ratchet).
2. **Bitbucket DC REST behavior is mocked, not real.** The mock asserts our side of
   the contract (paths, methods, headers, payload shape, status handling). DC-version
   quirks (merge strategy ids, draft-PR support by version) remain field-verified.
3. **`--jira` mode remains environment-specific** (C23): it now fails fast and clean
   without the MCP server, but cannot be self-tested here.
4. **Keychain code paths** (`security`, `secret-tool`) are not executable in this
   container; covered by argument/contract tests only (T25 tier), not live-keychain
   tests.
5. **Windows remains sidecar-only**, per contract v0, unchanged.
