# `## Behavior coverage` PR-body format (canonical, one source)

> Status: accepted · 2026-07-05 · the ONE datum the autopilot AV3-05 **producer**
> and the codebase-health CH-06 **consumer** must agree on byte-for-byte. Both
> vendor the format from HERE (ADR 0001 single-source rule; MS §13.3). The
> repo-level `scripts/lint_consistency.sh` pins this — neither plugin restates it.

A PR that touches behavior-bearing code carries a `## Behavior coverage` section
in its PR body mapping each Verification-Manifest behavior ID to the test node(s)
that exercise it. It is **grep-able** by construction so a deterministic consumer
can verify the claim against proof (git-log + test-node existence) without an LLM.

## The format

```
## Behavior coverage

- <behavior-id>: <test-path>::<test-node>
- <behavior-id>: <test-path>::<test-node>
```

- Header: a Markdown H2 whose text is exactly `Behavior coverage`
  (case-insensitive on the first letter; matched by `^##[[:space:]]+[Bb]ehavior[[:space:]]+coverage`).
- One list item per claimed behavior: `- <behavior-id>: <node>`.
  - `<behavior-id>` matches the manifest behavior-ID regex `B-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{3}`.
  - `<node>` is a test node id `<path>::<name>` (pytest / jest node syntax).
- The section ends at the next `## ` header or end of body.
- Additional prose in the section is ignored; only the `- <id>: <node>` lines are claims.

## Producer / consumer

- **Producer** — autopilot AV3-05 writes this section from the Subtask's
  `behaviors_to_test[]` (`autopilot/references/validator-prompts.md`). Human PRs
  may write it by hand in the same shape.
- **Consumer** — codebase-health CH-06 `check_behavior_coverage.sh` parses the
  section and verifies each claim: a claimed behavior with no RED commit in the
  range and no existing test node is the ADR-0004 blocking class "manifest
  behavior-IDs claimed but unproven." Evidence is git-log + test-node existence,
  never the implementer's self-report (ADR 0003).

Changing this format is a cross-plugin change: update this file, then both the
producer prose and the consumer parser, and re-run `scripts/lint_consistency.sh`.
