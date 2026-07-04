# codebase-health — the audit tier

The third tier of the Zero-Trust Verification Suite (see [../CONTEXT.md](../CONTEXT.md)):
a closed-loop codebase audit that runs independently of the spec-generation and
autopilot tiers and integrates with them through the Verification Manifest
(journey-walker verifies intended journeys, vitals, and idempotency requirements
against the code).

Current release: **1.4.0** — the test-health & observability release. Accepted spec:
[docs/SPEC_1.4.0.md](docs/SPEC_1.4.0.md); closure evidence:
[docs/GAPS_SPEC.md](docs/GAPS_SPEC.md); user-facing docs:
[plugins/codebase-health/README.md](plugins/codebase-health/README.md).

## Layout

| Path | What it is |
|---|---|
| `plugins/codebase-health/` | The plugin: 7 agents, commands (`/audit`, `/verify`, …), the cleanup-audit skill, references, detection scripts |
| `test-fixtures/planted/` | The planted defect corpus — the answer key's subject. Every fixture is annotated with `PLANT`/`MUST-NOT-FLAG` lines |
| `test-fixtures/EXPECTED_FINDINGS.yaml` | The answer key: expected findings, must-not-flag precision traps, expected-noise register. Lives outside the scanned tree by design |
| `test-fixtures/blind/` | Generated stripped copy for author-blind evals — never edit by hand; regenerate with `scripts/make_blind_corpus.sh` |
| `scripts/self_test.sh` | The deterministic ground-truth harness (131 assertions + 3 ruff-conditional). Run it before and after touching anything |
| `docs/` | Accepted specs and the append-only gap-closure registers |

## Development setup

The self-test has one **required** external dependency and two optional ones:

| Tool | Status | Install | What breaks without it |
|---|---|---|---|
| `jscpd` | **Required** for `self_test.sh` | `npm install -g jscpd` | Section 0 fails loudly; the ND1 clone-pair fixture cannot be scored (Decision 8 in `docs/SPEC_1.4.0.md`: deterministic scoring is a hard requirement for the suite's own eval). On *target* codebases jscpd remains optional — `run_audit.sh` degrades with a loud `[skip]` |
| `ruff` | Optional | `pip3 install --user ruff` | 3 C901 journey-fixture integrity checks report `[skip]` instead of running (131 → 128 scored) |
| `pytest` / `jest` + `node` | Optional | per project | The test-health-auditor's bounded probes fall back to "traced, not executed" during blind evals — honest but weaker evidence than a demonstrated flake |

## The two gates

Any change to fixtures or detection scripts goes through both, in order:

1. **Red-first** (new deterministic assertions): land the fixture + assertion first,
   run `scripts/self_test.sh` **twice**, and confirm the new assertions fail both
   times identically before writing any detector code.
2. **Green** (after detector work): `scripts/self_test.sh` twice, byte-identical,
   exit 0.

## The blind-eval recurrence rule

The ~17 agent-scored fixtures are scored **only** by the manual blind-corpus eval:
regenerate `test-fixtures/blind/` with `scripts/make_blind_corpus.sh`, run the audit
agents against the blind copy (answer key, specs, and CHANGELOG are off-limits to
them), and hand-score against `EXPECTED_FINDINGS.yaml`. **Any change to an agent
prompt, the taxonomy, or a reference a dispatched agent consumes requires re-running
this eval before release** — the date and git SHA of the current eval are recorded
in `docs/GAPS_SPEC.md`, and a release without a current eval is blocked.

Fixture-annotation convention (1.4.0+): every `PLANT`/`MUST-NOT-FLAG` annotation
line independently carries its token on its own line, so `make_blind_corpus.sh` can
strip it without collateral damage. Do not put annotations on the same line as the
planted defect (this is what makes several 1.3.0-era plants unscoreable blind — a
known, registered limitation).
