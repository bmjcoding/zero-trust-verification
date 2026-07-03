# Memory-rot enforcement is three-point; the PR Gate is a diff-scoped mode of the audit tier, not a fourth checker

---
status: agent-decided
date: 2026-07-03
---

The "docs describe code that no longer exists, and nobody invokes the audit" problem is solved by enforcement *points*, not a new checker. Three points: (1) **PR Gate** — every PR (autopilot-authored AND human-authored) runs a diff-scoped freshness check: deterministic layer greps the manifest, journey maps, as-built docs, ADRs, and decision log for paths/symbols the diff deletes or renames; agent layer judges semantic drift on the flagged excerpts only. (2) **Scheduled ambient audit** — the full audit runs on a CI cron, catching rot that accumulates outside any single diff; no human invocation required. (3) **On-demand full audit** — the existing manual surface, unchanged.

The PR Gate is implemented as a **diff-scoped mode of the codebase-health audit plugin** (reusing its facets, fixtures, FLAKY_RE/debt patterns, ratchet state, and loop-safety posture — the CI surface is already strict-by-default per the v1.4.0 spec, Decision 1), not as a fourth plugin. The eventual long-running ADLC/PR-review agent is **wiring, not a checker**: it schedules and reacts to PR events, invokes the audit's diff mode plus the manifest coverage check (were the behavior IDs this PR claims actually implemented — evidence from tests/git log, not the implementer's self-report), and posts findings. It holds no quality logic of its own, so there is never a fourth opinion to keep consistent.

## Considered Options

- **Standalone PR-review plugin with its own checks** (adversarial position): cleaner install story for teams that only want PR review; rejected because it duplicates the audit's detection logic behind a second implementation that will drift — the exact C-class contradiction failure this suite exists to kill. The install-story win is preserved anyway: the audit plugin is independently installable and the PR Gate is one of its modes.
- **Rely on autopilot's same-PR docs rule alone**: insufficient — humans also write PRs, and rot arrives through deletions in PRs that never touched the docs.

## Consequences

- The audit plugin grows a `--diff <range>` surface as a v1 requirement (was implicitly whole-repo).
- Manifest behavior-ID coverage verification ("was what was claimed actually implemented") lives at the PR Gate, giving the suite its answer to "who checks the checker" on every PR, not just at audit time.
