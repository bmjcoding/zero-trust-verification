---
description: Sweep in-flight branches for the 48h trunk-based ceiling — flag any branch whose last commit is older than the ceiling as a planning failure (ADR 0012), and check open claims for file-surface overlap (ADR 0009). Deterministic; comments/flags, never merges.
argument-hint: "[--max-age-hours <N>] [--refs <glob>]"
---

# /marshal-staleness

Run the Marshal's watcher side (ADRs 0009 + 0012): the staleness / branch-age
sweep and the claim-overlap check. Neither touches the merge path — they only
flag. Like the merge loop, both are pure, git/API-provable functions.

## Steps

1. **Branch age (ADR 0012).** A trunk-based branch older than 48 hours by its
   last commit is a planning failure — the same class D7.0 assigns an oversized
   rebase. Sweep the in-flight branches:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/branch_age_watcher.sh" \
     --refs 'refs/heads/story/*' --max-age-hours 48
   ```

   Each `<age-hours>\t<branch>` line is a branch to flag/comment as stale
   (demote its binding claim to advisory, ADR 0009). Override the ceiling with
   `--max-age-hours` or the ref set with `--refs` as the repo's branch naming
   requires.

2. **Claim overlap (ADR 0009).** Feed the open PRs' file surfaces as
   `<pr-id>\t<file>` pairs to the vendored check and report contended files:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/claim_overlap.sh" < claims.tsv
   # or, "does PR-123's surface overlap an existing claim?":
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/claim_overlap.sh" --for PR-123 < claims.tsv
   ```

   This is the SAME kernel autopilot's G4 planner vendors — keep the two copies
   byte-identical (see the header in `scripts/claim_overlap.sh`).

3. Report the flags plainly. These are nudges (ADR 0009: enforce by nudge, not
   gate) — comment and move on; nothing here blocks or merges.
