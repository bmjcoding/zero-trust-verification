---
description: Run a full codebase health audit — dead code, redundancy, doc hygiene, incomplete logic, test-suite health, security, performance, architecture, and documented journeys — seven specialist agents producing a prioritized report with measured coverage.
argument-hint: "[subdir] [--focus <area>]"
---

# /health-audit

The report-only subset of `/audit`: a comprehensive, read-only health audit
producing **one artifact**, `audit/HEALTH_REPORT.md`. Detection only — never
delete or modify code. (For the full pipeline including `SPEC.md`,
`state.json` updates, and the HTML render, use `/audit`.)

Parse `$ARGUMENTS`: an optional subdir narrows scope; `--focus <area>` runs a
subset of agents.

Follow the `/audit` pipeline (`commands/audit.md`, this plugin) steps 1–8 with
these deltas:

- **Write only `audit/HEALTH_REPORT.md`** plus the deterministic pass's own
  `audit/` evidence files — skip the `state.json` write, `SPEC.md` derivation
  (step 9), and the HTML render (step 10).
- Everything else applies unchanged: journey-walker first with the
  proceed-on-failure rule, coverage inventory + completeness loop, adversarial
  verification of HIGH+, fingerprint dedup per the precedence chain, the
  mandatory **Not covered** section, and the one severity scale.
- End the report with a prioritized, SAFE-first action plan. For confirmed
  HIGH correctness bugs, recommend `/diagnose-bug` to verify + lock down with
  a regression test before fixing — and `/verify` after fixes land to grade
  closure.
