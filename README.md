# Zero-Trust Verification

**A software-quality suite for the AI-assisted development lifecycle — where nothing counts until it's verified.**

Six independently-installable Claude Code plugins that cover the ADLC left to right — *generate a spec → implement it → audit it → merge it* — plus a read-only org-memory index and a production-telemetry triage source, all integrated through a shared, machine-readable **Verification Manifest**. Every claim the system makes about your code is backed by deterministic evidence: a test that runs, a mutant that dies, a git-log entry, a build status. Agent judgment is used everywhere; agent judgment blocks a merge nowhere without that evidence.

> **Status:** `v1.1.0` — **feature-complete.** All six future-scope capabilities designed in v1.0.0 are now shipped (mutation testing, remediation loop, production-telemetry triage, outcome measurement, org-wide memory, system-design coverage). Self-hosting on GitHub, provably green in one command with zero skips.

---

## Why this exists

100% test coverage is a lie if 30–40% of those tests assert nothing. A spec that never forces the idempotency question ships a loan-wiring flow with no idempotency key. Docs describe code that was deleted three PRs ago. And the agent that "verified" the work was often the same agent that wrote it — *who checks the checker?*

This suite answers that with a single discipline: **verify against the spec's declared ground truth, not the implementer's self-report** — and prove it with evidence a skeptic can reproduce. It raises the floor rather than the ceiling.

## The six plugins

| Plugin | Role | One-liner |
|---|---|---|
| **[spec-gen](./plugins/spec-gen)** | Shift-left | Interrogates raw intent into a Spec + a complete **Verification Manifest**, refusing to finalize while any completeness rule fails. Two adversarial attackers stress the design before you see it; the only path to a confirmed CORE money/auth requirement is a human answer. |
| **[autopilot](./plugins/autopilot)** | Implement | Drains a manifest-bearing Spec into PRs autonomously — plan (disjoint ownership + test gates) → TDD RED/GREEN → parallel multi-validator review → one draft PR per Story. Anti-flakiness contract + N=5 determinism gate + a **D6.5 anti-vacuous mutation gate**. Host-agnostic (GitHub + Bitbucket DC). |
| **[codebase-health](./plugins/codebase-health)** | Audit + PR Gate | Seven specialist agents audit dead code, redundancy, flaky/vacuous tests, observability, transactional integrity, security, and business-critical journeys — to *measured* coverage. Deterministic tools find evidence; agents judge; **nothing counts until `/verify` reruns the closing test 5×**. Hosts the mutation PR-gate sibling, the `/remediate` loop, the outcome-emit step, and system-design coverage. |
| **[marshal](./plugins/marshal)** | Merge | A serial, deterministic composed-state merge backstop. Verifies the build on the **post-rebase** head — the check that catches the Composition Breaks two clean merges hide. Zero agent judgment in the merge path. Carries the report-only outcome-capture + digest modes. |
| **[org-memory](./plugins/org-memory)** | Recall | A read-only, **refuse-by-default** index over the memory every repo already commits — glossaries, ADRs, manifests, decision logs. Derived-view-only (never a second store of truth), respects repo visibility (ACL at query time), and exposes a query CLI + MCP surface so an agent never has to be told twice what the org already decided. |
| **[triage](./plugins/triage)** | Prod → Spec | A read-only, **bounded-window** source that turns an emitted production incident into a resumable *incident-Spec* feeding spec-gen's resume path — never a patch, never an auto-merge. Vendor-neutral telemetry (default OTEL/OTLP-JSON; CloudWatch/Dynatrace behind one adapter). Correlates a runtime event to the manifest journey/behavior it belongs to. |

Each installs and runs standalone. Together they are the whole lifecycle, from a raw idea to a merged, verified change — and back again when production tells you something.

## Four capabilities woven through, not bolted on

Some of the suite's most valuable behavior ships as *modes and skills of the plugins above*, not as new checkers — a deliberate choice (ADR 0003: no extra tier just to add a feature):

- **Mutation testing as a first-class gate** — a surviving mutant on a *changed line* is a vacuous test. It blocks at write-time (autopilot **D6.5**, in a throwaway worktree so the live checkout is never mutated) and reports comment-only on CORE paths at the PR Gate (ingest-only). One adapter map, byte-identical across producer and consumer. ([ADR 0016](./docs/adr/0016-mutation-testing-first-class-gate.md))
- **Remediation loop** — a codebase-health skill (`/remediate`) that routes *confirmed, deterministically-scored* audit findings into a findings-register → spec-gen → an autonomous drain → a PR awaiting human review, behind a three-guard ratchet (idempotency, depth ceiling, no tail-chasing). Advisory-first; never auto-merges. ([ADR 0017](./docs/adr/0017-remediation-loop-wiring.md), [ADR 0018](./docs/adr/0018-remediation-ratchet-guards.md))
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

Requires [Claude Code](https://claude.com/claude-code). Add the marketplace, then install whichever plugins you want:

```
/plugin marketplace add bmjcoding/zero-trust-verification
/plugin install codebase-health@zero-trust-verification   # lowest-trust, read-only — the easiest place to start
/plugin install org-memory@zero-trust-verification         # read-only, refuse-by-default — also zero-risk to adopt
/plugin install spec-gen@zero-trust-verification
/plugin install autopilot@zero-trust-verification
/plugin install marshal@zero-trust-verification
/plugin install triage@zero-trust-verification
```

Adopt tier by tier: the audit and org-memory are read-only, so a team can run them without granting an autonomous drain anything. Add spec-gen when you want better specs, autopilot when you want the drain, marshal when you want deterministic merge safety, triage when you want production incidents to become specs.

## Prove it in one command

The whole suite — every plugin's self-test, the manifest validator, and the cross-plugin vendoring lints — runs from the repo root:

```bash
scripts/suite_self_test.sh          # all six plugins + validator + lints + red-tests
SUITE_STRICT=1 scripts/suite_self_test.sh   # require a zero-skip proof (needs all optional dev tools)
```

Green means: every plugin's self-test passes, the manifest validator round-trips, all twelve cross-plugin vendoring lints (V1–V12) hold, and every one of those lints has *teeth* — a planted-drift red-test proves it catches the drift it guards against. The Python substrate uses [uv](https://docs.astral.sh/uv/) (self-bootstrapping from `uv.lock`); shell tooling targets Bash 3.2 for portability. See [ADR 0015](./docs/adr/0015-substrate-shell-python-uv-not-rust.md).

## How it was built (and why that matters)

This suite was built *by itself*, spec-first. Every capability was implemented against a merged, adversarially-reviewed spec, and every PR passed a multi-pass review: a spec-fidelity check, then independent skeptics trying to *block* the merge. That process is not decoration — it caught a Marshal defect a green self-test hid (a queue command that only worked against the test mock), an unpinned vendored-copy that could silently drift, and an honesty-class laundering hole where an agent-graded metric could render as deterministic. It **mutation-tests its own fixes**: reintroduce the original bug, confirm the new assertion goes red. A test that passes when the code is broken constrains nothing.

The design record lives in the open:

- **[CONTEXT.md](./CONTEXT.md)** — the glossary (the ubiquitous language every plugin shares).
- **[docs/adr/](./docs/adr/)** — 23 architecture decision records, with the dissent from each adversarial round preserved in *Considered Options*.
- **[docs/specs/](./docs/specs/)** — the Verification Manifest schema and every plugin's build register.
- **[CHANGELOG.md](./CHANGELOG.md)** — what shipped in each release.

## Repository layout

```
├── plugins/spec-gen/          # Spec Generation tier
├── plugins/autopilot/         # Autopilot implementation drain (+ D6.5 mutation gate)
├── plugins/codebase-health/   # Audit + PR Gate (+ /remediate, outcome-emit, system-design coverage)
├── plugins/marshal/           # Merge Marshal (+ outcome-capture / digest)
├── plugins/org-memory/        # Read-only org-wide memory index + MCP query surface
├── plugins/triage/            # Production-telemetry triage → incident-Spec source
├── schema/                    # Verification Manifest v1 + outcome store JSON Schemas (canonical)
├── scripts/                   # manifest validator + suite_self_test.sh + root lints + outcome/SD scripts
├── tests/                     # manifest fixtures + codebase-health dev/test harness (tests/codebase-health/)
├── docs/adr/                  # architecture decision records
├── docs/specs/                # manifest spec + per-capability build registers
├── CONTEXT.md                 # the shared glossary
├── CHANGELOG.md               # release notes
└── .claude-plugin/            # root marketplace.json (product entry point)
```

## What's next

The suite is feature-complete. Beyond it: an org-wide-memory *index/crawler* rollout across many repos (the plugin ships the read surface; the aggregation layer is an infra decision), and evidence-gathering for org adoption — with outcome measurement's journey-instrumentation share as the headline metric. New capabilities always ship **report-only first** and are promoted to blocking/autonomous per-repo only after a soak.

## License

MIT.
