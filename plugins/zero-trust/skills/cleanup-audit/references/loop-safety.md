# Loop Safety Invariants

An automated loop with flawed logic must be able to cost you **wrong reports**,
never **damaged code**. This file is the CANONICAL statement of that shared
blast-radius guarantee for every loop the plugin ships — the audit loop,
`/remediate`, `/health-loop`, and autopilot's GENERATE/DRAIN/RESUME loop cite it
rather than restate it (drain-specific invariants:
`skills/autopilot/references/loop-safety.md`). The numbered invariants bind
every command, agent, script, and hook in the audit loop; check anything new
against this list first — a violation is a release blocker.

## The invariants

1. **Detection never mutates.** `/audit`, `/health-audit`, `/incomplete-logic`,
   `/architecture`, `/verify`, and all seven agents write only under `audit/`.
   Probes (test runs, timing harnesses, executed examples) are read-only with
   respect to the repo AND the user's machine outside it (no global config, no
   home-directory writes beyond a self-cleaned temp dir), and bounded: single
   tests or single files, fixed repeat counts (N≤10), never the whole suite,
   never while-until-fail. Never execute a test whose body, fixtures, or
   collection-time setup performs real network mutation or destructive I/O —
   that unsafety IS the finding; trace it. **Read before you probe**: everything
   a probe will execute (test body, fixtures, conftest, the example script) is
   read first, so this gate is applied before the run, never discovered after
   it. Agents delete any throwaway files they create and never touch files they
   didn't. Mutation-testing tools mutate the working tree, so nothing here ever
   runs one — pre-existing reports are ingested like coverage. (One documented
   exception: the Rust tool pack runs `cargo build`/`clippy`, which write
   `target/` and execute `build.rs` — skip the Rust pack where that matters.)
2. **The only mutating paths are explicit and human-gated.** `/dead-code`
   removal, `/diagnose-bug`'s fix phase, and spec execution happen only on
   explicit user request, from a green baseline, in small revertable batches,
   with tests between batches and a log (`DELETION_LOG.md` / `FIX_LOG.md`).
   One batch = one revert.
3. **Hooks warn; they never block or fix.** `check_new_debt.sh --hook` reports
   newly introduced debt and exits 0 — unconditionally: hook mode ignores
   `--strict`/`--no-strict`/`WARN_ONLY` entirely. Blocking exit codes exist only
   on the CI/script surface, which a human wires — the plugin never installs a
   gate for you. (This is an invariant, not a default; Decision 1 below does
   not touch it.)
4. **Broken state degrades to less action, not more.** Missing/corrupt/
   unknown-schema `state.json` → treat as first run and say so. Never act on
   partially-parsed state, never repair it by guessing, never delete it.
5. **Severity inflation is a defect.** Unconfirmed findings cap at MED
   (`severity-rubric.md`). A loop that cries HIGH erodes trust and gets
   ignored — which is how real HIGHs ship.
6. **Silent truncation is a defect.** Anything skipped — files unread, tools
   missing, journeys not executed, findings dropped in dedup — is reported
   (`Not covered`, `[skip]` lines, downgrade notes). "Said nothing, looked
   clean" is worse than any false positive.
7. **Verification requires evidence.** `/verify` marks FIXED only with
   `verified_by` pointing at a regression test or explained removal. "Looks
   fixed" is PARTIAL. The loop never rounds up.
8. **Every automated write is idempotent and diffable.** Artifacts live in
   `audit/`; running the same command twice produces the same state, and
   `state.json` history is append-only.
9. **A flaky gate is no gate.** A gate that passes only sometimes proves
   nothing and trains people to ignore red. Both of this loop's gates must
   themselves be deterministic: (a) fixtures land red-first *deterministically*
   — every new deterministic planted assertion must fail on two consecutive
   `scripts/self_test.sh` runs before any detector work begins; agent-scored
   plants have no automated red and are governed by the blind-eval recurrence
   rule instead (re-run the manual blind-corpus eval before any release that
   changed agent prompts, the taxonomy, or a reference a dispatched agent
   consumes). (b) Closure evidence must be deterministic — `/verify`'s
   closing-test gate (5 fresh-process reruns, one order-randomized, `FLAKY_RE`
   screen; defined in `audit-state-and-verify.md`) grades any red, unrunnable,
   or unmitigated-flaky closing test PARTIAL. A nondeterministic pass never
   rounds up to FIXED.

## Why warn-only is the right default

A blocking loop with a false positive halts a team; a warning loop with a false
positive costs one glance. Enforcement belongs where a human chose to put it
(CI, branch protection) — not inside a tool that can be wrong.

**The strict-default/warn-only split (Decision 1, 1.4.0).** On the CI/script
surface — `check_new_debt.sh` run as a CLI/CI step — strict exit codes are the
DEFAULT, with `--no-strict` and `WARN_ONLY=1` as the documented escape hatches;
only the high-precision fixture-locked classes gate, and stdout-logging
candidates never gate anywhere. That surface exists only where a human wired
the step, so the principle above holds. The hook surface (`--hook`) stays
warn-only exit 0 UNCONDITIONALLY per invariant 3. The one strictness contract
lives in the `check_new_debt.sh` header.

## The convergence rule

Errors are capped by construction: a false positive is downgraded by
adversarial verification or `/verify` (worst case a human marks WONTFIX once);
a false negative becomes a permanent regression fixture via the miss-to-fixture
rule (`audit-state-and-verify.md`); flaky closure evidence grades PARTIAL
(invariant 9); detector/prevention/verification drift is impossible — all three
source the same `debt_patterns.sh`. Nothing in the loop feeds model judgment
back into model judgment without deterministic evidence or a human between
them.
