# Incomplete-Logic Detection Taxonomy

The detection catalog for Phase 3 — patterns deterministic tools **cannot** find because the code is syntactically valid and often passes type checks. Finding these requires reading and reasoning about intent. You (the LLM) are the detector.

Scan priority order:
1. Public API surface (incomplete logic here ships to consumers).
2. Code that looks recently AI-generated (large functions appearing fully-formed, uniform style, generic names).
3. Error-handling and edge-case branches (where "I'll finish this later" hides).
4. Anything touched in the last N commits if doing a targeted pass.

For every finding emit: `file:line` · category · severity (per `severity-rubric.md`) · evidence snippet · concrete suggested fix.

---

## Category A — Explicit incompleteness markers
Easy to grep; judge whether each is genuinely unfinished vs. an intentional extension point.
- `TODO`, `FIXME`, `XXX`, `HACK`, `STUB`, `WIP`, `TBD`, `PLACEHOLDER`, `@todo`, "fix later", "implement later", "for now", "stopgap", "temporary hack/fix/workaround". (The grep in `scripts/debt_patterns.sh` mirrors this list exactly — change them together.)
- `raise NotImplementedError` in a non-abstract method.
- `pass` or `...` as the entire body of a function named/typed as if it does something (outside stubs/`.pyi`/`Protocol`/`abstractmethod`).
- Severity: HIGH if on the public API path or in auth/security/data-writes; MED otherwise.

## Category B — Placeholder / fake implementations (the dangerous ones)
These *look* complete and pass tests but don't do the work. Read the body and ask "does this fulfill the name/docstring/signature?"
- **Identity returns** — a builder/wither returning `self`/the input unchanged where a derived object is implied.
- **Hardcoded success** — validators/auth checks that `return True` or only check non-empty.
- **Hardcoded sample data** — literal placeholders (`return "127.0.0.1"`, `return {"id": 1}`) where real lookup is implied.
- **Swallowed work** — `try: ... except: pass` hiding an unimplemented path.
- **Echo/passthrough** — a "transform" returning its input untouched.
- Severity: usually HIGH — silent correctness bugs, worse than a crash.

## Category C — Silent no-ops & dead branches
- Side-effect-named functions (`save_`, `flush_`, `register_`, `cleanup_`) whose body never performs the side effect.
- Unreachable or always-false branches; empty registered handlers; feature flags permanently off gating unfinished code.
- Disambiguation: a side-effect function that DOES perform its effect but emits no business event is `journey/uninstrumented` (`references/business-vitals.md`), not C — only the observability is missing.

## Category D — Partial coverage of inputs
- `match`/`if-elif` over an enum/type that omits cases without `else: raise`.
- Happy path handled, `# TODO` for errors, retries, pagination, empty input, None.
- `async` functions that never await (a half-done conversion).
- Type hints promising more than the body delivers.

## Category E — Inconsistent / half-wired integration
- A code path added but never registered in the dispatch table / registry / `__all__` / router.
- Config keys read but never written, or written but never read.
- A comment claiming a dedicated path where the code piggybacks on an unrelated one.
- Parameters accepted but ignored.

## Category F — Comment/docstring vs. code contradiction
(Overlaps with Phase 4; flag here when it signals incomplete logic.) Docstrings describing behavior the code lacks; "temporary"/"placeholder" comments still present.

## Category G — Suppressed diagnostics
Every suppression is a diagnostic someone chose to hide instead of fix — the most institutionalized form of debt. `run_audit.sh` collects them into `audit/suppressions.txt`; judge each:
- `# noqa`, `# type: ignore`, `# pylint: disable`, `# pragma: no cover`; `@ts-ignore`, `@ts-expect-error`, `eslint-disable*`; `#[allow(...)]`; `//nolint`, `#nosec`.
- A suppression with a why-comment and narrow scope is acceptable; a bare suppression on a public/security path is a finding (MED default; HIGH if it hides a confirmed defect). Clusters in one file signal a module forced past the tools rather than finished.
- Test-scope suppressions of nondeterminism (`@pytest.mark.flaky`, retry wrappers) are graded under test-health T7 (`references/test-health.md`), not here.

---

## Category naming rule (adding a category? read this first)

Letters freeze at **A–G**. New categories take **word-keys**, not letters: in the tag grammar H already means HIGH severity (`IL-H1` = incomplete-logic HIGH #1, per `spec-format.md`), so "Category H" would be ambiguous to anyone fluent in the tags. Hence **Category LOG** and **Category TX**, and every future category follows suit.

## Category LOG — Logging & observability anti-patterns
The code runs; nobody can see it run. (`LOGGING_RE` in `scripts/debt_patterns.sh` mirrors the stdout-channel list here — change them together. `run_audit.sh` collects hits into `audit/stdout_logging.txt` as candidates, not verdicts.)
- **Stdout/stderr as production log channel**: `print`, `sys.stdout.write`, `console.log/info/debug`, `fmt.Println` on library/server/request-serving paths — unleveled, unstructured, invisible to log aggregation. Debug prints LOW; library/server paths MED.
- **Log-and-swallow** — Category B's stricter cousin: caught, logged, then carried on as if the operation succeeded. Worse than a bare `except: pass` in one way: the log line makes it LOOK handled. HIGH with confirmed reachability on data-write/auth/payment paths.
- **Sensitive values in logs** (CWE-532) — a security lens; precedence (`audit-state-and-verify.md`) routes the finding to `security/logging` with `incomplete-logic/LOG` in lenses.
- **Absence of structured logging / correlation IDs**: request-serving paths emitting nothing traceable. An absence finding names WHICH facets are absent — structured emission, correlation/request-ID propagation — explicitly; hitting one facet does not cover the other. File at the narrowest honest scope: `<module>`-level when the absence is file-wide, and only on demonstrably request-serving paths. Absence findings always carry the **needs-verification** mark per the severity-rubric absence cap (`severity-rubric.md`, 1.4.0 amendments — cite the amendment, never restate it here).
- Guardrails: CLI/user-facing output, `__main__` blocks, tests, dev scripts, and shell `echo` are CORRECT uses of stdout — not findings.

## Category TX — Missing transactional integrity on critical operations
Money moves, state transitions, side effects fire — what happens when the request arrives twice, or dies halfway?
- **Missing idempotency-key/dedup guard** on non-GET handlers and webhook/queue consumers (at-least-once delivery is the default).
- **Unsafe retry around a non-idempotent call** — the retry IS the duplicate deliverer.
- **Double-submit windows** — check-then-act gaps.
- **Missing compensating action** on multi-step sequences.
- **Missing audit trail** on money-like transitions.
- Priority seeds: `audit/vital_candidates.txt ∩ tx_retries.txt − tx_guards.txt` (the seed regexes live in `run_audit.sh` — change them together with this category).
- Owners: security-auditor (file-scoped) and journey-walker (journey-scoped) — shared the way Category G is; precedence dedups to `security/transactional-integrity` with journey in lenses.
- Canonical slugs: `non-idempotent-handler`, `missing-dedup-guard`, `unsafe-retry`, `double-submit-window`, `missing-compensation`, `missing-audit-trail`.
- Severity: a traced double-execution or partial-failure path on a money path is the rubric's existing CRITICAL data-corruption row — and CRITICAL still requires naming who can deliver the duplicate. Inferred-but-untraced caps at MED needs-verification.
- Guardrails — idempotent-by-construction is NOT a finding: pure reads, PUT-style upserts, `ON CONFLICT` writes, key-checked handlers, SDK `idempotency_key=` usage.

---

## Per-language pattern equivalents

The categories are language-agnostic; the *idioms* aren't. Translate:

| Pattern | Python | TypeScript / JS | Rust | Go |
|---|---|---|---|---|
| Explicit stub (A) | `raise NotImplementedError`, `pass`/`...` body | `throw new Error("not implemented")`, empty body | `unimplemented!()`, `todo!()` | `panic("not implemented")`, empty func |
| Swallowed failure (B) | `except: pass` | empty `catch {}`, `.catch(() => {})` | `let _ = result;`, `.ok()` discarding Err | `_ = err`, `if err != nil {}` empty |
| Hardcoded success (B) | `return True` validator | `return true` validator | `Ok(())` without doing the work | `return nil` without doing the work |
| Missing case (D) | `if/elif` without `else: raise` | `switch` without `default` throw | `match` catch-all `_ => {}` doing nothing | `switch` without `default` |
| Silent no-op (C) | `save_*` that never writes | handler registered with empty body | side-effect fn that constructs and drops | method that logs "saving..." and returns |
| Unregistered path (E) | missing from `__all__`/registry | missing from barrel export / router table | not wired into the dispatch `match` | not registered in `init()` / route table |
| Log-and-swallow (LOG) | `except ...: log.error(e)` then proceed | `catch (e) { console.error(e) }` and continue | `if let Err(e) = r { error!(..) }` and proceed | `if err != nil { log.Println(err) }` and fall through |
| Non-idempotent consumer (TX) | webhook/queue handler with no processed-key check | webhook route with no event-id dedup | consumer without dedup lookup before side effect | consumer without processed-ID check before write |
| Unsafe retry (TX) | `for attempt in range(n):` around a keyless POST/charge | fetch retry wrapper around a POST | retry crate around a non-idempotent call | retry loop around `http.Post` without a key |

Rust and Go compilers catch some C/D instances at build time — do not re-report what the compiler already rejects; focus on what compiles cleanly and still lies.

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
- Abstract methods, `Protocol`/ABC bodies, `.pyi` stubs, and documented extension points are **correct**, not findings.
- Test fixtures and mocks legitimately return canned data — canned data consumed by a real assertion is fine; a test that constrains nothing at all is test-health territory (`references/test-health.md`), owned by the test-health-auditor, not Category B.
- When unsure, mark as **candidate / needs human review**, never as a confirmed fix.
