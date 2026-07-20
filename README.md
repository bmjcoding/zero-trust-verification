# Zero-Trust Verification

**A software-quality suite for the AI-assisted development lifecycle — where nothing counts until it's verified.**

One Claude Code plugin — **`zero-trust`** — whose six domains cover the ADLC left to right — *generate a spec → implement it → audit it → merge it* — plus a read-only org-memory index and a production-telemetry triage source, all integrated through a shared, machine-readable **Verification Manifest** (six plugins consolidated into one by ADR 0025). Every claim the system makes about your code is backed by deterministic evidence: a test that runs, a mutant that dies, a git-log entry, a build status. Agent judgment is used everywhere; agent judgment blocks a merge nowhere without that evidence.

> **Status:** `v2.0.0-rc.1` — **feature-complete, field-hardened, consolidated.** All six future-scope capabilities designed in v1.0.0 are shipped (mutation testing, remediation loop, production-telemetry triage, outcome measurement, org-wide memory, system-design coverage), the first production e2e drain's field retros are absorbed (autopilot 3.1.0), and the six plugins are now ONE plugin (ADR 0025 Wave 1 — see the migration note under Install). Self-hosting on GitHub, provably green in one command with zero skips.

---

## Why this exists

100% test coverage is a lie if 30–40% of those tests assert nothing. A spec that never forces the idempotency question ships a loan-wiring flow with no idempotency key. Docs describe code that was deleted three PRs ago. And the agent that "verified" the work was often the same agent that wrote it — *who checks the checker?*

This suite answers that with a single discipline: **verify against the spec's declared ground truth, not the implementer's self-report** — and prove it with evidence a skeptic can reproduce. It raises the floor rather than the ceiling.

## The six domains (one plugin)

| Domain | Role | One-liner |
|---|---|---|
| **[spec-gen](./plugins/zero-trust/skills/spec)** | Shift-left | Interrogates raw intent into a Spec + a complete **Verification Manifest**, refusing to finalize while any completeness rule fails. Two adversarial attackers stress the design before you see it; the only path to a confirmed CORE money/auth requirement is a human answer. |
| **[autopilot](./plugins/zero-trust/skills/autopilot)** | Implement | Drains a manifest-bearing Spec into PRs autonomously — plan (disjoint ownership + test gates) → TDD RED/GREEN → parallel multi-validator review → one draft PR per Story. Anti-flakiness contract + N=5 determinism gate + a **D6.5 anti-vacuous mutation gate**. Host-agnostic (GitHub + Bitbucket DC). |
| **[codebase-health](./plugins/zero-trust/skills/cleanup-audit)** | Audit + PR Gate | Seven specialist agents audit dead code, redundancy, flaky/vacuous tests, observability, transactional integrity, security, and business-critical journeys — to *measured* coverage. Deterministic tools find evidence; agents judge; **nothing counts until `/verify` reruns the closing test 5×**. Hosts the mutation PR-gate sibling, the `/remediate` loop, the outcome-emit step, and system-design coverage. |
| **[marshal](./plugins/zero-trust/docs/marshal)** | Merge | A serial, deterministic composed-state merge backstop. Verifies the build on the **post-rebase** head — the check that catches the Composition Breaks two clean merges hide. Zero agent judgment in the merge path. Carries the report-only outcome-capture + digest modes. |
| **[org-memory](./plugins/zero-trust/docs/org-memory)** | Recall | A read-only, **refuse-by-default** index over the memory every repo already commits — glossaries, ADRs, manifests, decision logs. Derived-view-only (never a second store of truth), respects repo visibility (ACL at query time), and exposes a query CLI + MCP surface so an agent never has to be told twice what the org already decided. |
| **[triage](./plugins/zero-trust/skills/triage)** | Prod → Spec | A read-only, **bounded-window** source that turns an emitted production incident into a resumable *incident-Spec* feeding spec-gen's resume path — never a patch, never an auto-merge. Vendor-neutral telemetry (default OTEL/OTLP-JSON; CloudWatch/Dynatrace behind one adapter). Correlates a runtime event to the manifest journey/behavior it belongs to. |

All six install together as the one `zero-trust` plugin (ADR 0025). Together they are the whole lifecycle, from a raw idea to a merged, verified change — and back again when production tells you something.

## Five capabilities woven through, not bolted on

Some of the suite's most valuable behavior ships as *modes and skills of the plugins above*, not as new checkers — a deliberate choice (ADR 0003: no extra tier just to add a feature):

- **Mutation testing as a first-class gate** — a surviving mutant on a *changed line* is a vacuous test. It blocks at write-time (autopilot **D6.5**, in a throwaway worktree so the live checkout is never mutated) and reports comment-only on CORE paths at the PR Gate (ingest-only). One adapter map, byte-identical across producer and consumer. ([ADR 0016](./docs/adr/0016-mutation-testing-first-class-gate.md))
- **Remediation loop** — a codebase-health skill (`/remediate`) that routes *confirmed, deterministically-scored* audit findings into a findings-register → spec-gen → an autonomous drain → a PR awaiting human review, behind a three-guard ratchet (idempotency, depth ceiling, no tail-chasing). Advisory-first; never auto-merges. ([ADR 0017](./docs/adr/0017-remediation-loop-wiring.md), [ADR 0018](./docs/adr/0018-remediation-ratchet-guards.md))
- **Health-loop** — the attended campaign counterpart (`/health-loop`): one prompt drains a whole audit wave by wave — slice `SPEC.md`, drain through autopilot, merge (operator-approved per wave, or delegated for SAFE waves under a double-keyed hatch with a deterministic P1–P4 evidence bar), then `/verify --strict` gates every boundary. Merge-before-verify is a correctness rule, not ceremony; REGRESSED or a ratchet increase halts the campaign; nothing is ever re-fixed by the loop. ([ADR 0024](./docs/adr/0024-health-loop-attended-wave-drain.md))
- **Suite outcome measurement** — report-only, permanently. DORA metrics (a Marshal mode) and the *journey-instrumentation share* (an audit emit step) land in a shared store with a mandatory honesty-class badge on every number, so an agent-graded metric can never be laundered as deterministic. ([ADR 0023](./docs/adr/0023-outcome-measurement-report-only.md))
- **System-design coverage** — *declare-then-verify*: the manifest declares where a control lives (`locus: app | gateway | mesh | sidecar | …`); the audit verifies only in-repo (`locus: app`) claims and reports the rest **out-of-scope-by-declaration** — never a false "missing rate limit." ([ADR 0021](./docs/adr/0021-manifest-control-locus.md), [ADR 0022](./docs/adr/0022-out-of-scope-by-declaration.md))

## The idea that ties them together: the Verification Manifest

The manifest is the machine-readable companion a Spec ships with — acceptance behaviors with stable IDs (Given/When/Then), the journey map with criticality, required vitals (what must be *observed*, not just logged), idempotency requirements, and (additive, optional) the declared control `locus` for out-of-repo defenses. It is the **single join key** across the suite:

```
  spec-gen ──produces──▶  Verification Manifest  ◀──consumes── autopilot (maps Subtasks → Behavior IDs)
                               │  (schema_version-pinned,
                               │   degrades when absent)
                               ▼
                     codebase-health / PR Gate
              (verifies the implementation against the
               manifest — not the implementer's claims)
                               │
                               ▼
                            marshal
             (merges only a verified, composed-green state)
                               ▲
                               │
        triage ──incident-Spec──┘   (a production incident re-enters at the left edge)
```

Because the manifest links *design-time intent* to *runtime behavior* (event names, vital classes, behavior IDs), an audit can prove "was what was claimed actually implemented," a production incident can be traced straight back to the journey that broke, and outcome measurement can report how much of your CORE money/auth surface is actually observed rather than dark.

## Install

Requires [Claude Code](https://claude.com/claude-code). Distribution is a local
git clone consumed through Claude Code's **skills directory** (ADR 0027) — no
plugin marketplace involved, so it works unchanged under managed-settings
marketplace allowlists:

```bash
git clone https://github.com/bmjcoding/zero-trust-verification.git
ln -s "$(pwd)/zero-trust-verification/plugins/zero-trust" ~/.claude/skills/zero-trust
```

Restart Claude Code. The plugin auto-loads as `zero-trust@skills-dir` — every
skill and command, the seven audit agents, the org-memory MCP server, and the
hooks; confirm with `claude plugin list`.

**Updating:** `git pull` in the clone — the symlink picks it up next session.
To pin a release, check out its tag instead of tracking `main`.

**Trying it without installing:** `claude --plugin-dir /path/to/clone/plugins/zero-trust`
loads it for one session only (note managed settings can disable sideload
flags; the skills-dir install is the supported path).

**Migrating from a marketplace install (≤ v2.0.x):** the marketplace entry
point is retired (ADR 0027). Uninstall and remove it, then install as above —
every command name is unchanged:

```
/plugin uninstall zero-trust
/plugin marketplace remove zero-trust-verification
```

(v1.x six-plugin installs uninstall `spec-gen`, `autopilot`, `codebase-health`,
`marshal`, `org-memory`, and `triage` instead — ADR 0025 consolidated them into
the one `zero-trust` plugin.)

Adopt tier by tier: the audit and org-memory are read-only, so a team can run them without granting an autonomous drain anything. Add spec-gen when you want better specs, autopilot when you want the drain, marshal when you want deterministic merge safety, triage when you want production incidents to become specs.

## Prove it in one command

The whole suite — every domain's self-test, the manifest validator, and the cross-domain contract lints — runs from the repo root:

```bash
scripts/suite_self_test.sh          # all six domains + validator + lints + red-tests
SUITE_STRICT=1 scripts/suite_self_test.sh   # require a zero-skip proof (needs all optional dev tools)
```

Green means: every domain's self-test passes, the manifest validator round-trips, the surviving cross-domain contract lints (V2, V6, V9–V13 — the byte-identity vendoring rules V1/V3/V4/V5/V7/V8 retired with the vendored copies, ADR 0025) hold, and every one of those lints has *teeth* — a planted-violation red-test proves it catches the drift it guards against. The Python substrate uses [uv](https://docs.astral.sh/uv/) (self-bootstrapping from `uv.lock`); shell tooling targets Bash 3.2 for portability. See [ADR 0015](./docs/adr/0015-substrate-shell-python-uv-not-rust.md).

## ID conventions

Prefixes you will meet in self-test output, lints, registers, and changelogs — prefix → meaning → home:

| Prefix | Meaning | Home |
|---|---|---|
| `V<n>` | root cross-domain lint rule (V2, V6, V9–V13 live; V1/V3–V5/V7/V8 retired with the vendored copies, ADR 0025 — ids never renumber) | `scripts/lint_consistency.sh` |
| `L<n>` | autopilot lint rule (L1–L23; L24 pending in PR #47) | `plugins/zero-trust/skills/autopilot/scripts/lint_consistency.sh` — the spec-gen substrate lint (`plugins/zero-trust/scripts/lint_consistency.sh`) also uses L1–L8 ids (rename pending, ADR 0031) |
| `T` / `HD` / `HG` / `H50` / `W345-*` | autopilot self-test assertion families (see the legend in its header) | `plugins/zero-trust/skills/autopilot/scripts/self_test.sh` |
| `AV3-x.n` | autopilot v3 register assertion ids — they resolve to self-test assertions (the standalone v3 register doc was retired) | `plugins/zero-trust/skills/autopilot/scripts/self_test.sh` |
| `AP-x` | autopilot adversarial-review finding ids, cited as behavior anchors (origin register retired; historical) | `plugins/zero-trust/skills/autopilot/references/lifecycle.md` |
| `CH-x` | codebase-health manifest-consumer wiring (PR-Gate siblings, CH-01..CH-10) | `tests/codebase-health/self_test.sh` + `plugins/zero-trust/docs/codebase-health/CHANGELOG.md` |
| `MT-x` | mutation-testing gate items (ADR 0016) | autopilot self-test `MT` family + `plugins/zero-trust/skills/cleanup-audit/scripts/mutation_adapter.sh` |
| `RL-x` | remediation-loop items | `plugins/zero-trust/skills/cleanup-audit/references/remediation-loop.md` |
| `SD-x` | system-design coverage items | `docs/specs/system-design-coverage-register.md` |
| `OM-x` / `OWM-x` | outcome measurement / org-wide memory items | `docs/specs/outcome-measurement-register.md` / `docs/specs/org-wide-memory-register.md` |
| `MG` / `TR-x` | marshal real-backend e2e section / triage items | `plugins/zero-trust/scripts/self_test_marshal.sh` / `self_test_triage.sh` + `docs/specs/prod-triage-register.md` |
| `HC-n` | hard contracts — two numbered families: spec tier HC1–HC7 and autopilot's Hard Contracts 1–15 ("autopilot HC4" = never merges) | `plugins/zero-trust/skills/spec/SKILL.md` / `skills/autopilot/SKILL.md`, each §"Hard contracts" |
| `MS §n` | the Verification Manifest spec, by section | `docs/specs/verification-manifest-v1.md` |
| `DL-###` | decision-log line ids (per-manifest scope, MS §6) | CONTEXT.md "Decision Log" + each manifest's `interrogation.log` |
| Defects A–H | remediation-build adversarial-hardening defect letters (historical; not every letter survives in live docs — H: `references/remediation-loop.md`; C: ADR 0018; others in cleanup-audit script comments) | `plugins/zero-trust/skills/cleanup-audit/scripts/{finding_eligible,build_register,remediation_depth}.sh` |

## How it was built (and why that matters)

This suite was built *by itself*, spec-first. Every capability was implemented against a merged, adversarially-reviewed spec, and every PR passed a multi-pass review: a spec-fidelity check, then independent skeptics trying to *block* the merge. That process is not decoration — it caught a Marshal defect a green self-test hid (a queue command that only worked against the test mock), an unpinned vendored-copy that could silently drift, and an honesty-class laundering hole where an agent-graded metric could render as deterministic. It **mutation-tests its own fixes**: reintroduce the original bug, confirm the new assertion goes red. A test that passes when the code is broken constrains nothing.

The design record lives in the open:

- **[CONTEXT.md](./CONTEXT.md)** — the glossary (the ubiquitous language every domain shares).
- **[docs/adr/](./docs/adr/)** — 32 architecture decision records (indexed with supersession notes in [docs/adr/README.md](./docs/adr/README.md)), with the dissent from each adversarial round preserved in *Considered Options*.
- **[docs/specs/](./docs/specs/)** — the Verification Manifest schema and every capability's build register.
- **[CHANGELOG.md](./CHANGELOG.md)** — what shipped in each release.

## Repository layout

```
├── plugins/zero-trust/        # THE plugin (ADR 0025) — everything installable lives here
│   ├── commands/              #   /spec /audit /verify /remediate /health-loop /marshal-pass /triage …
│   ├── agents/                #   the seven audit specialist agents
│   ├── skills/spec/           #   Spec Generation tier (S1–S7 interrogation)
│   ├── skills/autopilot/      #   Autopilot drain (SKILL + references + scripts, incl. D6.5 mutation gate)
│   ├── skills/cleanup-audit/  #   Audit + PR Gate (+ /remediate, outcome-emit, system-design coverage)
│   ├── skills/triage/         #   Production-telemetry triage → incident-Spec source
│   ├── scripts/               #   canonical manifest validator + marshal / org-memory / triage substrate
│   ├── schema/                #   Verification Manifest v1 + outcome / org-memory / triage schemas (canonical)
│   ├── references/            #   shared references (escalation criterion, host + telemetry contracts, …)
│   ├── mcp/ + .mcp.json       #   org-memory read-only MCP query server
│   └── docs/<domain>/         #   per-domain READMEs + changelogs
├── scripts/                   # dev tooling: suite_self_test.sh + root lint + outcome/SD harnesses
├── tests/                     # manifest fixtures + codebase-health dev/test harness (tests/codebase-health/)
├── docs/adr/                  # architecture decision records
├── docs/specs/                # manifest spec + per-capability build registers
├── CONTEXT.md                 # the shared glossary
└── CHANGELOG.md               # release notes
```

The product entry point is the plugin's own `plugins/zero-trust/.claude-plugin/plugin.json`
(ADR 0027 — the root marketplace is retired).

## What's next

The suite is feature-complete. Beyond it: an org-wide-memory *index/crawler* rollout across many repos (the plugin ships the read surface; the aggregation layer is an infra decision), and evidence-gathering for org adoption — with outcome measurement's journey-instrumentation share as the headline metric. New capabilities always ship **report-only first** and are promoted to blocking/autonomous per-repo only after a soak.

## License

MIT.
