---
description: Detect partially-implemented logic — stubs, placeholders, fake implementations, silent no-ops, NotImplementedError, and unhandled cases.
argument-hint: "[subdir]"
---

# /incomplete-logic

`$ARGUMENTS`: an optional subdir narrows scope.

Find logic that *looks* finished but isn't — LLM-judgment work deterministic
tools cannot do.

## Steps
1. Detect the stack. Seed with the explicit-marker grep
   (TODO/FIXME/XXX/STUB/NotImplementedError) — but do not stop there.
2. Invoke the `incomplete-logic-detector` agent; its file carries the
   taxonomy pointer, the confirm-before-HIGH rule, the output contract, and
   the guardrails (abstract methods, Protocols, `.pyi` stubs, and documented
   extension points are NOT findings).
3. Relay per-finding: `file:line` · category · severity · evidence · fix ·
   risk-if-shipped. Report only — do not auto-fix.
