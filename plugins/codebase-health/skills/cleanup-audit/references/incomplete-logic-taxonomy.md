# Incomplete-Logic Detection Taxonomy

This is the detection catalog for Phase 3 — the patterns that deterministic tools (vulture, ruff, deadcode) **cannot** find because the code is syntactically valid and often even passes type checks. Finding these requires reading and reasoning about intent. You (the LLM) are the detector here.

Scan priority order:
1. Public API surface (anything exported / documented — incomplete logic here ships to consumers).
2. Code that looks recently AI-generated (large functions appearing fully-formed, uniform style, generic names).
3. Error-handling and edge-case branches (where "I'll finish this later" hides).
4. Anything touched in the last N commits if doing a targeted pass.

For every finding emit: `file:line` · category · severity (per `severity-rubric.md`) · evidence snippet · concrete suggested fix.

---

## Category A — Explicit incompleteness markers
Easy to grep, but you must judge whether each is genuinely unfinished vs. an intentional extension point.
- `TODO`, `FIXME`, `XXX`, `HACK`, `STUB`, `WIP`, `TBD`, `PLACEHOLDER`, `@todo`, "fix later", "implement later", "for now", "stopgap", "temporary hack/fix/workaround". (The grep in `scripts/debt_patterns.sh` mirrors this list exactly — change them together.)
- `raise NotImplementedError` in a non-abstract method (abstract base methods are fine; concrete classes raising it are red flags).
- `pass` as the entire body of a function that is named/typed as if it does something.
- `...` (Ellipsis) as a body outside of stubs/`.pyi` files or `Protocol`/`abstractmethod`.
- Severity: HIGH if on the public API path or in auth/security/data-writes; MED otherwise.

## Category B — Placeholder / fake implementations (the dangerous ones)
These *look* complete and pass tests but don't actually do the work. Read the body and ask "does this fulfill the name/docstring/signature?"
- **Identity returns**: `WithContext(...)` / `with_fields(...)` that returns `self` or the same object unchanged instead of producing a derived object.
- **Hardcoded success**: validators / auth checks that `return True`, or only check non-empty (`if token: return True`) instead of real validation.
- **Hardcoded sample data**: functions returning a literal placeholder (e.g. `return "127.0.0.1"`, `return {"id": 1, "name": "example"}`, `return []` where real lookup is implied).
- **Swallowed work**: `try: ... except: pass` that hides the fact the real path is unimplemented.
- **Echo/passthrough**: a "transform" that returns its input untouched.
- Severity: usually HIGH — these are silent correctness bugs, worse than a crash.

## Category C — Silent no-ops & dead branches
- Functions with side-effect names (`save_`, `flush_`, `register_`, `cleanup_`) whose body never performs the side effect.
- `if`/`elif` branches that are unreachable or always-false (often left from a refactor).
- Event handlers / callbacks registered but empty.
- Feature flags permanently off, gating code that was never finished.
- Disambiguation: a side-effect function that DOES perform its effect but emits
  no business event is `journey/uninstrumented` (`references/business-vitals.md`),
  not C — the work happens; only the observability is missing.

## Category D — Partial coverage of inputs
- `match`/`if-elif` over an enum or type that omits cases (and lacks a clear `else: raise`).
- Functions that handle the happy path but `# TODO: handle <case>` for errors, retries, pagination, Windows/path edge cases, empty input, None.
- Async functions that are declared `async` but never `await` anything (often a half-done conversion).
- Type hints promising more than the body delivers (returns `Optional[X]` but only ever returns `None`; declares it raises but never does).

## Category E — Inconsistent / half-wired integration
- A new code path added but not registered in the dispatch table / registry / `__all__`.
- Config keys read but never written, or written but never read.
- A "registration endpoint" comment where the code actually reuses an unrelated endpoint (e.g. piggybacking on heartbeat) — a sign the dedicated path was never built.
- Parameters accepted but ignored in the body.

## Category F — Comment/docstring vs. code contradiction
(Overlaps with Phase 4, but flag here when it signals incomplete logic.)
- Docstring describes behavior the code does not implement.
- Comment says "this also handles X" but no code handles X.
- "Temporary" / "placeholder" / "will be replaced" comments still present.

## Category G — Suppressed diagnostics
Every suppression is a diagnostic someone chose to hide instead of fix — the most
institutionalized form of debt because the tooling now actively agrees to ignore it.
`run_audit.sh` collects these into `audit/suppressions.txt`; judge each one:
- `# noqa`, `# type: ignore`, `# pylint: disable`, `# pragma: no cover` (Python)
- `@ts-ignore`, `@ts-expect-error`, `eslint-disable*` (TS/JS)
- `#[allow(...)]` — especially `allow(dead_code)`, `allow(unused)` (Rust)
- `//nolint`, `#nosec` (Go / security scanners)
- Judgment: a suppression with a comment explaining *why* and a narrow scope is
  acceptable; a bare suppression on a public/security path is a finding (MED
  default; HIGH if it hides a confirmed defect). Clusters of suppressions in one
  file signal a module that was forced past the tools rather than finished.
- Test-scope suppressions of nondeterminism (`@pytest.mark.flaky`, retry
  wrappers around a test) are graded under test-health T7
  (`references/test-health.md`), not here.

---

## Category naming rule (adding a category? read this first)

Letters freeze at **A–G**. New categories take **word-keys**, not letters: in
the tag grammar H already means HIGH severity (`IL-H1` = incomplete-logic HIGH
#1, per `spec-format.md`), so "Category H" would be ambiguous to anyone fluent
in the tags — and taking I while skipping H invites the same drift. Hence
**Category LOG** and **Category TX** below, and every future category follows
suit.

## Category LOG — Logging & observability anti-patterns
The code runs; nobody can see it run. (`LOGGING_RE` in `scripts/debt_patterns.sh`
mirrors the stdout-channel list here — change them together. `run_audit.sh`
collects hits into `audit/stdout_logging.txt` as candidates, not verdicts.)
- **Stdout/stderr as production log channel**: `print`, `sys.stdout.write`,
  `console.log/info/debug`, `fmt.Println` on library/server/request-serving
  paths — unleveled, unstructured, invisible to log aggregation. Debug prints
  LOW; library/server paths MED.
- **Log-and-swallow** — Category B's stricter cousin: `except Exception as e:
  log.error(e)` then carry on as if the operation succeeded. Worse than a bare
  `except: pass` in one way: the log line makes it LOOK handled. HIGH with
  confirmed reachability on data-write/auth/payment paths.
- **Sensitive values in logs**: tokens, passwords, PII in log lines (CWE-532).
  This is a security lens — precedence (see `audit-state-and-verify.md`) routes
  the finding to `security/logging` with `incomplete-logic/LOG` in lenses.
- **Absence of structured logging / correlation IDs**: a module whose
  request-serving paths emit nothing traceable, or logs that cannot be joined
  across a request. An absence finding names WHICH facets are absent —
  structured emission, correlation/request-ID propagation — explicitly;
  hitting one facet does not cover the other. File at the narrowest honest
  scope: `<module>`-level when the absence is file-wide (a single-line
  citation never stands in for a module-wide gap), and only on demonstrably
  request-serving paths. Absence findings always carry the
  **needs-verification** mark per the severity-rubric absence cap
  (`severity-rubric.md`, 1.4.0 amendments — cite the amendment, never
  restate it here).
- Guardrails: CLI/user-facing output, `__main__` blocks, tests, dev scripts,
  and shell `echo` are CORRECT uses of stdout — not findings.

## Category TX — Missing transactional integrity on critical operations
Money moves, state transitions, side effects fire — what happens when the
request arrives twice, or dies halfway?
- **Missing idempotency-key/dedup guard** on non-GET handlers and
  webhook/queue consumers (at-least-once delivery is the default; a consumer
  without a processed-key check double-executes).
- **Unsafe retry around a non-idempotent call**: a retry loop wrapping a
  charge/POST/write with no idempotency key — the retry IS the duplicate
  deliverer.
- **Double-submit windows**: check-then-act gaps where a second submission
  slips through before the first commits.
- **Missing compensating action** on multi-step sequences (step 2 fails, step
  1's side effect is never undone).
- **Missing audit trail** on money-like transitions (who/when/what is
  unrecoverable after the fact).
- Priority seeds: `audit/vital_candidates.txt ∩ tx_retries.txt − tx_guards.txt`
  (the seed regexes live in `run_audit.sh` — change them together with this
  category).
- Owners: security-auditor (file-scoped) and journey-walker (journey-scoped) —
  shared the way Category G is; precedence dedups to
  `security/transactional-integrity` with journey in lenses.
- Canonical slugs: `non-idempotent-handler`, `missing-dedup-guard`,
  `unsafe-retry`, `double-submit-window`, `missing-compensation`,
  `missing-audit-trail`.
- Severity: a traced double-execution or partial-failure path on a money path
  is the rubric's existing CRITICAL data-corruption row — and CRITICAL still
  requires naming who can deliver the duplicate. Inferred-but-untraced caps at
  MED needs-verification.
- Guardrails — idempotent-by-construction is NOT a finding: pure reads,
  PUT-style upserts, `ON CONFLICT` writes, key-checked handlers, SDK
  `idempotency_key=` usage.

---

## Per-language pattern equivalents

The categories are language-agnostic; the *idioms* aren't. When scanning non-Python
code, translate:

| Pattern | Python | TypeScript / JS | Rust | Go |
|---|---|---|---|---|
| Explicit stub (A) | `raise NotImplementedError`, `pass`/`...` body | `throw new Error("not implemented")`, empty body | `unimplemented!()`, `todo!()` | `panic("not implemented")`, empty func |
| Swallowed failure (B) | `except: pass` | empty `catch {}`, `.catch(() => {})` | `let _ = result;`, `.ok()` discarding Err | `_ = err`, `if err != nil {}` empty |
| Hardcoded success (B) | `return True` validator | `return true` validator | `Ok(())` without doing the work | `return nil` without doing the work |
| Placeholder value (B) | `return {"id": 1}` literal | `return { id: 1 }` literal | `Default::default()` where real data implied | zero-value struct where real data implied |
| Missing case (D) | `if/elif` without `else: raise` | `switch` without `default` throw / non-exhaustive union | `match` with catch-all `_ => {}` arm doing nothing | `switch` without `default` |
| Half-async (D) | `async def` that never awaits | `async` that never awaits | `async fn` returning ready futures only | goroutine that never signals its WaitGroup/channel |
| Silent no-op (C) | `save_*` that never writes | handler registered with empty body / `noop` | side-effect fn whose body only constructs and drops | method that logs "saving..." and returns |
| Doc contradiction (F) | docstring promises behavior body lacks | JSDoc/TSDoc drift from implementation | `///` doc comment vs body drift | godoc comment vs body drift |
| Unregistered path (E) | missing from `__all__`/registry | missing from barrel export / router table | not wired into the dispatch `match` / inventory | not registered in `init()` / route table |
| Stdout logging (LOG) | `print(...)` / `sys.stdout.write` on a server path | `console.log/info/debug` in server/lib code | `println!`/`dbg!` outside CLI output | `fmt.Println` where `log`/`slog` belongs |
| Log-and-swallow (LOG) | `except ... : log.error(e)` then proceed | `catch (e) { console.error(e) }` and continue | `if let Err(e) = r { error!(..) }` and proceed | `if err != nil { log.Println(err) }` and fall through |
| No correlation ID (LOG) | handler logs without request/trace id | handler logs without request-id middleware/context | handler without `tracing` span/fields | logs without request-scoped `context.Context` fields |
| Non-idempotent consumer (TX) | webhook/queue handler with no processed-key check | webhook route with no event-id dedup | consumer without dedup lookup before side effect | consumer without processed-ID check before write |
| Unsafe retry (TX) | `for attempt in range(n):` around a keyless POST/charge | axios/fetch retry wrapper around a POST | retry crate around a non-idempotent call | retry loop around `http.Post` without a key |

Rust and Go compilers catch some C/D instances at build time — do not re-report
what the compiler already rejects; focus on what compiles cleanly and still lies.

---

## Reporting template (per finding)

```
### [SEVERITY] <short title>
- Location: path/to/file.py:123
- Category: B — fake implementation
- Evidence:
    def validate_api_key(self, key: str) -> bool:
        return bool(key)          # only checks non-empty
- Why it's incomplete: signature/name promise real validation; body accepts any non-empty string.
- Suggested fix: validate against the key store / signature / expiry; reject unknown keys.
- Risk if shipped: auth bypass — any non-empty string authenticates.
```

## Judgment guardrails
- An abstract method, `Protocol`, or `.pyi` stub raising `NotImplementedError` / using `...` is **correct**, not a finding.
- A documented extension point (plugin authors override it) is not incomplete — check docstring/ABC.
- Test fixtures and mocks legitimately return canned data — canned data consumed by a real assertion is fine; a test that constrains nothing at all is test-health territory (`references/test-health.md`), owned by the test-health-auditor, not Category B.
- When unsure, mark as **candidate / needs human review**, never as a confirmed fix.
