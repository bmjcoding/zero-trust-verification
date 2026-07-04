---
description: Detect partially-implemented logic — stubs, placeholders, fake implementations, silent no-ops, NotImplementedError, and unhandled cases.
argument-hint: "[subdir]"
---

# /incomplete-logic

`$ARGUMENTS`: an optional subdir narrows scope.

Find logic that *looks* finished but isn't. This is LLM-judgment work — deterministic tools cannot catch syntactically-valid stubs and fake implementations.

## Steps

1. Detect stack. Seed the search by grepping for explicit markers (TODO/FIXME/XXX/STUB/NotImplementedError) — but do not stop there.
2. Invoke the `incomplete-logic-detector` agent, which reads the code against the taxonomy in `cleanup-audit` skill → `references/incomplete-logic-taxonomy.md`.
3. Prioritize the public API surface, security/auth/data-write paths, and recently AI-generated code.
4. Report each finding as `file:line` · category · severity (per the skill's `references/severity-rubric.md` — HIGH needs confirmed reachability) · evidence snippet · concrete suggested fix · risk-if-shipped. Report only — do not auto-fix.

Respect guardrails: abstract methods, Protocols, `.pyi` stubs, and documented extension points are NOT findings.
