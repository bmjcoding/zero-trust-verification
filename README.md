# Zero-Trust Verification

**A software-quality suite for the AI-assisted development lifecycle — where nothing counts until it's verified.**

Four independently-installable Claude Code plugins that cover the ADLC left to right — *generate a spec → implement it → audit it → merge it* — integrated through a shared, machine-readable **Verification Manifest**. Every claim the system makes about your code is backed by deterministic evidence: a test that runs, a mutant that dies, a git-log entry, a build status. Agent judgment is used everywhere; agent judgment blocks a merge nowhere without that evidence.

> **Status:** `v1.0.0` — feature-complete, self-hosting on GitHub, provably green in one command. Six more capabilities are designed and in build (see [Roadmap](#roadmap)).

---

## Why this exists

100% test coverage is a lie if 30–40% of those tests assert nothing. A spec that never forces the idempotency question ships a loan-wiring flow with no idempotency key. Docs describe code that was deleted three PRs ago. And the agent that "verified" the work was often the same agent that wrote it — *who checks the checker?*

This suite answers that with a single discipline: **verify against the spec's declared ground truth, not the implementer's self-report** — and prove it with evidence a skeptic can reproduce. It raises the floor rather than the ceiling.

## The four plugins

| Plugin | Role | One-liner |
|---|---|---|
| **[spec-gen](./plugins/spec-gen)** | Shift-left | Interrogates raw intent into a Spec + a complete **Verification Manifest**, refusing to finalize while any completeness rule fails. Two adversarial attackers stress the design before you see it; the only path to a confirmed CORE money/auth requirement is a human answer. |
| **[autopilot](./plugins/autopilot)** | Implement | Drains a manifest-bearing Spec into PRs autonomously — plan (disjoint ownership + test gates) → TDD RED/GREEN → parallel multi-validator review → one draft PR per Story. Anti-flakiness contract + N=5 determinism gate. Host-agnostic (GitHub + Bitbucket DC). |
| **[codebase-health](./plugins/codebase-health)** | Audit + PR Gate | Seven specialist agents audit dead code, redundancy, flaky/vacuous tests, observability, transactional integrity, security, and business-critical journeys — to *measured* coverage. Deterministic tools find evidence; agents judge; **nothing counts until `/verify` reruns the closing test 5×**. |
| **[marshal](./plugins/marshal)** | Merge | A serial, deterministic composed-state merge backstop. Verifies the build on the **post-rebase** head — the check that catches the Composition Breaks two clean merges hide. Zero agent judgment in the merge path. |

Each installs and runs standalone. Together they are the whole lifecycle.

## The idea that ties them together: the Verification Manifest

The manifest is the machine-readable companion a Spec ships with — acceptance behaviors with stable IDs (Given/When/Then), the journey map with criticality, required vitals (what must be *observed*, not just logged), and idempotency requirements. It is the **single join key** across the suite:

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
```

Because the manifest links *design-time intent* to *runtime behavior* (event names, vital classes, behavior IDs), an audit can prove "was what was claimed actually implemented," and — soon — a production incident can be traced straight back to the journey that broke.

## Install

Requires [Claude Code](https://claude.com/claude-code). Add the marketplace, then install whichever plugins you want:

```
/plugin marketplace add bmjcoding/zero-trust-verification
/plugin install codebase-health@zero-trust-verification   # lowest-trust, read-only — the easiest place to start
/plugin install spec-gen@zero-trust-verification
/plugin install autopilot@zero-trust-verification
/plugin install marshal@zero-trust-verification
```

Adopt tier by tier: the audit is read-only and warn-only, so a team can run it without granting an autonomous drain anything. Add spec-gen when you want better specs, autopilot when you want the drain, marshal when you want deterministic merge safety.

## Prove it in one command

The whole suite — every plugin's self-test, the manifest validator, and the cross-plugin vendoring lints — runs from the repo root:

```bash
scripts/suite_self_test.sh          # all four plugins + validator + lints + red-tests
SUITE_STRICT=1 scripts/suite_self_test.sh   # require a zero-skip proof (needs all optional dev tools)
```

The Python substrate uses [uv](https://docs.astral.sh/uv/) (self-bootstrapping from `uv.lock`); shell tooling targets Bash 3.2 for portability. See [ADR 0015](./docs/adr/0015-substrate-shell-python-uv-not-rust.md).

## How it was built (and why that matters)

This suite was built *by itself*, spec-first. Every plugin was implemented against a merged, adversarially-reviewed spec, and every PR passed a two-pass review: a spec-fidelity check, then an independent skeptic trying to *block* the merge. That process is not decoration — it caught a Marshal defect a green self-test hid (a queue command that only worked against the test mock), and it **mutation-tests its own fixes**: reintroduce the original bug, confirm the new assertion goes red. A test that passes when the code is broken constrains nothing.

The design record lives in the open:

- **[CONTEXT.md](./CONTEXT.md)** — the glossary (the ubiquitous language every plugin shares).
- **[docs/adr/](./docs/adr/)** — 22 architecture decision records, with the dissent from each adversarial round preserved in *Considered Options*.
- **[docs/specs/](./docs/specs/)** — the Verification Manifest schema and every plugin's build register.

## Repository layout

```
├── plugins/spec-gen/          # Spec Generation tier
├── plugins/autopilot/         # Autopilot implementation drain
├── plugins/codebase-health/   # Audit + PR Gate plugin
├── plugins/marshal/           # Merge Marshal
├── schema/                    # Verification Manifest v1 JSON Schema (canonical)
├── scripts/                   # manifest validator + suite_self_test.sh + root lints
├── tests/                     # manifest fixtures + codebase-health dev/test harness (tests/codebase-health/)
├── docs/adr/                  # architecture decision records
├── docs/specs/                # manifest spec + per-plugin build registers
├── CONTEXT.md                 # the shared glossary
└── .claude-plugin/            # root marketplace.json (product entry point)
```

## Roadmap

Designed and in build (each spec-first, adversarially reviewed):

1. **Mutation testing as a first-class gate** — a surviving mutant on a changed line = a vacuous test; block at write-time (autopilot D6.5) and on CORE money/auth paths (PR Gate). ([ADR 0016](./docs/adr/0016-mutation-testing-first-class-gate.md))
2. **Remediation loop** — audit findings → a manifest-bearing Spec → an autonomous drain → a PR awaiting review. ([ADR 0017](./docs/adr/0017-remediation-loop-wiring.md))
3. **Production-telemetry triage** — an incident → the journey/behavior that broke → an incident-Spec into the remediation loop (the fifth plugin). ([ADR 0020](./docs/adr/0020-triage-fifth-plugin.md))
4. **Suite outcome measurement** — report-only evidence the suite improves production quality, led by journey-instrumentation share.
5. **Org-wide memory** — a read-only index over the memory every repo already commits (glossaries, ADRs, manifests), respecting repo visibility. ([ADR 0019](./docs/adr/0019-org-wide-memory-index.md))
6. **System-design coverage** — expand the audit to more system-design principles (rate limiting, circuit breakers, isolation) via *declare-then-verify*: the manifest declares where a control lives; the audit verifies only in-repo (`locus: app`) claims and reports the rest out-of-scope-by-declaration — never a false "missing X." ([ADR 0021](./docs/adr/0021-manifest-control-locus.md), [ADR 0022](./docs/adr/0022-out-of-scope-by-declaration.md))

New capabilities ship **report-only first** and are promoted to blocking/autonomous per-repo after a soak.

## License

MIT.
