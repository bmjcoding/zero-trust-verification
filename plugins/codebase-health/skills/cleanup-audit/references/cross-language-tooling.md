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
