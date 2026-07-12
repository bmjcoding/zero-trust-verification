---
description: Run ONE serial Merge Marshal pass — enumerate ready+approved PRs, FIFO-order them, rebase-or-refuse the head per the D7.0 budget, verify the composed state on the post-rebase build, and merge the green head (one PR in flight). Deterministic wiring; no quality judgment.
argument-hint: "[--host <path-to-host.sh>] [--pin <pr-number>]"
---

# /marshal-pass

Run a single pass of the Merge Marshal serial backstop loop (ADR 0010) — the
same thing the cron entry runs on cadence (`references/marshal-loop.md`).

**This command is WIRING, not a checker (ADR 0011).** Every decision it takes
is a timestamp, a sha, a build state, or a file-surface intersection — all
git/API-provable. Do not add judgment, do not reorder by "importance", do not
merge anything the composed-state build has not proven green. The only
override is a human hotfix pin, logged to the Force Audit.

## Steps

1. Confirm the current directory is the working clone of the shared repo (its
   `origin` is the repo the Marshal merges into). If not, stop and say so.

2. Run one pass — all PR/build operations go through the host adapter:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/marshal.sh"
   ```

   Pass overrides through the environment, never by editing the script: a
   hotfix pin via `MARSHAL_HOTFIX_PIN=<pr-number>`, an explicit adapter via
   `MARSHAL_HOST=/path/to/host.sh`.

3. Relay the pass's decision log verbatim — the `marshal:` lines are the
   audit trail. Do not paraphrase a merge or a kickback into a quality claim;
   the Marshal made none.

4. Route the outcome: merged → the trunk advanced; the next fire re-evaluates
   the rest against it. `wait` → the composed build is still running; the
   next fire re-checks. Kickback → the comment on that PR names the reason
   (rebase budget, conflict, or a Composition Break) — the author's to fix.
