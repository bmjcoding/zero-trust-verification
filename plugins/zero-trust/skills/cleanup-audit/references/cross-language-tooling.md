# Cross-Language Tooling

The cleanup *methodology* (Phases 0–5) is language-agnostic. Only the Phase 1 deterministic tools swap out. Phases 3–5 (incomplete-logic detection, doc hygiene, safe deletion) are prompt-driven and identical in every language.

## Tool packs by language

| Phase | Python | TypeScript / JS | Rust | Go |
|---|---|---|---|---|
| Dead code / unused exports | vulture (deadcode optional) | **knip**, ts-prune | `cargo +nightly udeps`, rustc `dead_code`/`unused` lints | `golang.org/x/tools/cmd/deadcode`, staticcheck |
| Unused deps | deptry / pip-audit | knip, depcheck | `cargo machete`, `cargo +nightly udeps` | `go mod tidy` (diff), `go vet` |
| Lint / unused imports & locals | ruff | ESLint `no-unused-vars`, `tsc --noUnusedLocals --noUnusedParameters` | `cargo clippy`, rustc lints | `go vet`, staticcheck, `goimports` |
| Complexity hotspots | ruff `C901` (radon optional) | eslint complexity rules | clippy cognitive-complexity | gocyclo |
| Security (security-auditor) | bandit, pip-audit, semgrep | npm audit, semgrep, eslint-plugin-security | cargo audit, cargo-geiger | gosec, govulncheck |
| Secrets | gitleaks / trufflehog | gitleaks / trufflehog | gitleaks | gitleaks |
| Test coverage (uncovered-branch evidence) | coverage.py (`coverage report -m`) | istanbul/nyc → `lcov.info` | `cargo llvm-cov` | `go test -coverprofile` |
| Duplication / near-dup clones | **jscpd** (`--min-tokens 50`) | **same** | **same** | **same** |
| File size ladder (400/800/1600 non-blank lines) | `run_audit.sh` built-in | same | same | same |
| Commented-out code blocks | `run_audit.sh` built-in (`#` leader) | built-in (`//` leader) | built-in (`//`) | built-in (`//`) |
| Mutation testing (test-quality evidence, **ingest-only**) | mutmut, cosmic-ray | StrykerJS | cargo-mutants | go-mutesting |
| Test flakiness probes (test-health-auditor confirmation gate; snapshot/golden runners in no-write mode ONLY — `test-health.md` probe protocol) | `pytest -p randomly`, single-test reruns | `jest --ci --runInBand` diff, `CI=true vitest --sequence.shuffle` | `INSTA_UPDATE=no cargo test -- --test-threads=1` diff | `go test -shuffle=on -count=5` |
| Incomplete logic (Phase 3) | **LLM + taxonomy** | **same** | **same** | **same** |

Coverage is the cheapest deterministic incomplete-logic signal there is: a branch
the test suite never executes is where stubs and fake implementations survive.
`run_audit.sh` never *runs* the suite (the audit pass is read-only) but ingests an
existing coverage data file when present — run the suite with coverage before
auditing to get this evidence. But coverage lies in both directions: an uncovered
branch is a real gap, while a *covered* branch proves only execution, not
constraint — a vacuous test covers everything and catches nothing. A survived
mutant is deterministic proof a test constrains nothing; that is why mutation
reports are the gold-standard vacuity evidence for the test-health-auditor.

**Mutation ingestion rule (invariant 1):** mutation tools mutate the working
tree — they are NEVER run by any command, agent, or script in this plugin.
Reports are ingested exactly like coverage: mutmut's cache, Stryker's
`mutation-report.json`, cargo-mutants' `missed.txt`, or a go-mutesting report is
copied into `audit/` when present; absent → the loud
`[note] no mutation report found — run mutation testing out-of-band (optional)`.

## Mutation adapter map (MT-01 — first-class gate; ADR 0016)

Ingestion above answers *did someone run it*. The two GATE points (autopilot D6.5
drain-side, the PR-Gate sibling diff-side) additionally need, per tool, the
changed-FILES invocation AND the survivor→`file:line` resolver. That is this map —
the ONE copy in the suite (ADR 0025 deleted the autopilot vendored copy; the
drain-side doc points here — MT-09/MT-10 sole source):

<!-- vendored:mutation-adapter-map:begin -->
| tool | lang | changed-FILES invocation | survivor→`file:line` resolver | tool scoping |
|---|---|---|---|---|
| StrykerJS | TS/JS | `npx stryker run --incremental --mutate <files>` | `mutation-report.json`: `files{}.<path>.mutants[]` with `status=="Survived"` → `<path>:<location.start.line>` | LINE (`--incremental`/`--mutate` ranges) |
| cargo-mutants | Rust | `cargo mutants --in-diff <diff>` (or `-f <file>` per changed file) | `mutants.out/missed.txt` line `<file>:<line>:<col>: …` → `<file>:<line>` | LINE (`--in-diff`) |
| mutmut | Python | `mutmut run --paths-to-mutate "<files>"` then `mutmut show` | `mutmut show` unified diff: `+++ <path>` + `@@ -<line>` → `<file>:<line>` (NOT `mutmut results` — IDs only, unlocatable) | FILE at invocation; line POST-HOC |
| go-mutesting | Go | `go-mutesting <changed-packages>` | report `FAIL "<path>[.<idx>]"` (a survived mutant) → `<path>:-` (no line emitted) | FILE (no incremental mode) |

Honest capability (ADR 0016, not laundered): only cargo-mutants (`--in-diff`) and
StrykerJS (`--incremental`) scope at line/diff level at the TOOL. mutmut and
go-mutesting scope to changed FILES; the survivor→changed-LINE filter is applied
POST-HOC in the join (MT-05). A tool that yields no line (go-mutesting) degrades
every survivor to `<path>:-` (file granularity) and caps at comment-only on the
PR side (MT-05/MT-06).

The executable form of this map is the canonical `mutation_adapter.sh` beside
this file (`normalize <tool>` reads raw tool output on stdin → the normalized
`<path>:<line>` survivor set; `invocation <tool> <files…>`) — the ONE resolver
both consumers call: autopilot D6.5 (produces, via
`skills/autopilot/scripts/mutation_gate.sh`) and the codebase-health PR-Gate
sibling (consumes). Single copy since ADR 0025; the `[BLOCKED: vacuous-test]`
producer / `mutant-on-core-path` consumer tokens live in those two scripts
(MT-09).
<!-- vendored:mutation-adapter-map:end -->

Notes:
- **TypeScript** is the best-tooled for cleanup — knip alone covers files, exports, types, deps, and members in one pass (~27M npm downloads/month; used by Vercel, Adobe, Datadog).
- **Rust**'s compiler is itself a strong dead-code detector (unused warnings are first-class) and catches many Category C/D incomplete-logic issues at build time that dynamic languages let through silently — but it's weaker across the public-crate boundary (same public-surface caveat as any library).
- **Go**: dead-code analysis and `staticcheck` are solid; `init()` side-effects and interface satisfaction are the dynamic-dispatch traps to watch.
- **jscpd** is one tool for all four columns (token-based, language-aware). On *target* repos it is optional with a graceful degrade: `run_audit.sh` uses `--min-tokens 50` by default, writes normalized output to `audit/dup_jscpd.json` (stderr to the `dup_jscpd.err` sidecar), and when jscpd is absent emits the loud `miss jscpd "npm i -g jscpd (optional — agents still hunt near-dups manually)"` — we cannot mandate npm on user machines. For this suite's OWN `scripts/self_test.sh`, jscpd is a REQUIRED dev dependency (Decision 8): the self-test fails loudly at startup if it is missing, so the ND1 near-duplicate fixture is scored deterministically, never shim-only.
- **File size ladder — why 400/800/1600** (non-blank lines, written to `audit/giant_files.txt`): the rungs are attention thresholds for the machine reader, not style rules. Around **400** an agent editing the file can no longer hold all of it with full fidelity next to the task context — worth attention; at **800** partial reads become the norm and missed edits start (warn); at **1600** no single read window covers the file — god-file. The rungs are triage priority for architecture-reviewer, never verdicts: see the giant-file triage guidance in `architecture-and-strictness.md` (cohesive generated file ≠ finding).
- **Commented-out blocks** are detected built-in via `debt_patterns.sh` (`CODE_COMMENT_RE`, code token anchored immediately after the `#`/`//` leader so prose never matches; ≥3 consecutive comment lines, ≥2 code-shaped) → `audit/commented_code.txt`. Per-language: `#` for Python, `//` for TS/JS/Rust/Go; block comments (`/* */`, docstrings) are deliberately unmatched — agents still judge those forms.
- **Flakiness probes** are the test-health-auditor's confirmation gate, bounded per `loop-safety.md` invariant 1: single test/file, N≤10 repeats, shuffled vs file order, TZ-varied rerun; never while-until-fail, never the whole suite, never a test whose body, fixtures, or collection-time setup performs real network mutation or destructive I/O (that unsafety IS the finding — trace only).

## Adding a new language
1. Add a column above with the four core tool roles (dead code, deps, lint, complexity) and security/secrets; add the duplication and mutation-tool cells if the ecosystem has them. The size ladder and commented-code rows are `run_audit.sh` built-ins — at most add the comment leader.
2. Add a detection branch in `scripts/run_audit.sh` that runs them into `audit/`.
3. Nothing else changes — Phases 3–5 are language-independent.

## On porting an existing project (Python → TS or Rust)
Frame honestly rather than cheerleading:

**Potential gains** — TS: huge ecosystem reach, best cleanup/editor tooling, easy web/Node distribution. Rust: performance, memory safety, single-binary distribution, and a compiler that catches many incomplete-logic bugs at build time.

**Real costs** — a port is a *rewrite*, not a translation: idioms, error handling, async models, and packaging all differ. You lose dynamic flexibility (registries/`getattr` dispatch don't translate 1:1). Two languages = two test suites, two release pipelines, two consumer bases during transition. Rust's ownership model reshapes API design and has a steep curve.

**Pragmatic path** — (1) finish the cleanup in the current language first so you port a *clean* surface, not the cruft; (2) define what the gain must be (perf? distribution? safety?) and measure whether the current language already gets you there — e.g. a Rust extension via PyO3 for hot paths, or a thin TS client wrapper — which is often ~80% of the benefit at ~20% of the cost of a full rewrite.
