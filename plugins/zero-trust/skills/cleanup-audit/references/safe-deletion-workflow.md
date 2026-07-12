# Safe Deletion Workflow

High-reward, high-risk. The rule: **prove "unused" with evidence, delete in
small batches, verify with tests, log everything.**

## Why SDKs are special
A library's exports are consumed *externally*. Dead-code tools only see
*internal* references, so they will confidently flag your entire public API as
"unused." Treat public exports as DANGER by default.

## Step 1 — Establish a green baseline
Run the project's full test + build/typecheck before touching anything. If it
isn't green first, stop — you can't attribute later failures.

## Step 2 — Grade every candidate

| Grade | What | Examples |
|---|---|---|
| **SAFE** | Clearly unreferenced internal symbols | private helpers, unused locals, unused dev deps, dead test helpers |
| **CAUTION** | May have dynamic/indirect refs | shared utilities, things hit via `getattr`/registry/`importlib`, plugin hooks |
| **DANGER** | External or framework contract | `__all__` exports, documented public API, entry points, config schema, anything in `__init__.py` |

Public-API symbols go through a **deprecation cycle**, not deletion: add
`DeprecationWarning`, document, keep for ≥1 minor release, then remove.

## Step 3 — Delete in small batches
- One category at a time, SAFE first. Never mix dead-code deletion with
  behavior refactors in the same commit.
- After each batch: full test + build/typecheck. Red → roll back that batch,
  narrow, retry. Keep batches small enough that a failure points to an obvious
  cause.

## Step 4 — Maintain `docs/DELETION_LOG.md`
Per removal: **what** was removed, **why it's safe** (tool report + grep
evidence + grade), **what replaced it**, **verification** (build + test
result, commit SHA). This kills the "six months later nobody knows why" cost
and gives a clean revert path.

## Common mis-deletion traps
- Dynamic dispatch / reflection: `getattr`, plugin registries, entry-point
  loading, self-registering decorators/macros, Rust `inventory`/`linkme`, Go
  `init()` side-effects.
- Lazy / conditional imports inside functions; lazy export shims (PEP 562
  `__getattr__`, JS dynamic `import()`, re-export barrels).
- Symbols referenced only from docs examples, notebooks, or downstream test
  suites; CLI/script entrypoints used by CI; codegen / build-time-only
  modules.
- Public API of a library/SDK: nothing internal imports it, but external
  consumers depend on it. Always DANGER.

## When unsure
Mark as **candidate**, leave in place, note it for human review. A false
"keep" costs nothing; a false delete breaks consumers.
