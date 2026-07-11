# Safe Deletion Workflow

High-reward, high-risk. The rule: **prove "unused" with evidence, delete in small batches, verify with tests, log everything.** Adapted from the community `/refactor-clean` methodology, hardened for SDKs with a public API surface.

## Why SDKs are special
A library's exports are consumed *externally*. Dead-code tools only see *internal* references, so they will confidently flag your entire public API as "unused." Deleting on that signal breaks every downstream consumer. Treat public exports as DANGER by default.

## Step 1 — Establish a green baseline
Run the full test + build/typecheck before touching anything, using the project's stack:
- Python: `pytest -q && python -m build` (+ mypy/pyright/ruff check)
- TS/JS: `npm test && npm run build` (+ `tsc --noEmit`)
- Rust: `cargo test && cargo build` (+ `cargo clippy`)
- Go: `go test ./... && go build ./...` (+ `go vet`)
If it isn't green first, stop — you can't attribute later failures.

## Step 2 — Grade every candidate

| Grade | What | Examples |
|---|---|---|
| **SAFE** | Clearly unreferenced internal symbols | private helpers, unused locals, unused dev deps, dead test helpers |
| **CAUTION** | May have dynamic/indirect refs | shared utilities, things hit via `getattr`/registry/`importlib`, plugin hooks |
| **DANGER** | External or framework contract | `__all__` exports, documented public API, entry points, config schema, anything in `__init__.py` |

Public-API symbols go through a **deprecation cycle**, not deletion: add `DeprecationWarning`, document, keep for ≥1 minor release, then remove.

## Step 3 — Delete in small batches
- One category at a time, SAFE first. Never mix dead-code deletion with behavior refactors in the same commit.
- After each batch: `pytest -q && build/typecheck`. If red → roll back that batch, narrow, retry.
- Keep batches small enough that a failure points to an obvious cause.

## Step 4 — Maintain `docs/DELETION_LOG.md`
For each removal record:
- **What** was removed (files / functions / exports / deps).
- **Why it's safe** (tool report + grep evidence + grade).
- **What replaced it** (if deduped).
- **Verification** (build + test result, commit SHA).

Purpose: kill the "six months later nobody knows why this was removed" cost, and give you a clean revert path.

## Common mis-deletion traps
- Dynamic dispatch / reflection: `getattr`, plugin registries, entry-point loading, decorators or macros that self-register, Rust `inventory`/`linkme`, Go `init()` side-effects.
- Lazy / conditional imports inside functions.
- Symbols only referenced from docs examples, notebooks, or downstream/external test suites.
- CLI/script entrypoints used by CI but not by library code.
- Codegen / build-time-only modules.
- Language-specific lazy export shims (Python PEP 562 `__getattr__`, JS dynamic `import()`, re-export barrels) — exports that exist but aren't statically visible.
- Public API of a library/SDK: nothing *internal* imports it, but external consumers depend on it. Always DANGER.

## When unsure
Mark as **candidate**, leave in place, and note it in the report for human review. A false "keep" costs nothing; a false delete breaks consumers.
