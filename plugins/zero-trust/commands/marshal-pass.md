---
description: Run ONE serial Merge Marshal pass — enumerate ready+approved PRs, FIFO-order them, rebase-or-refuse the head per the D7.0 budget, verify the composed state on the post-rebase build, and merge the green head (one PR in flight). Deterministic wiring; no quality judgment.
argument-hint: "[--host <path-to-host.sh>] [--pin <pr-number>]"
---

# /marshal-pass

Run a single pass of the Merge Marshal serial backstop loop (ADR 0010). This is
the same thing the cron entry runs on cadence (see
`references/marshal-loop.md`); use it to drive a pass by hand or to observe one.

**This command is WIRING, not a checker (ADR 0011).** It forms no opinion about
code quality. Every decision it takes is a timestamp, a sha, a build state, or a
file-surface intersection — all git/API-provable. Do not add judgment, do not
reorder by "importance," do not merge anything the composed-state build has not
proven green. The only override is a human hotfix pin, which is logged to the
Force Audit.

## Steps

1. Confirm the current directory is the working clone of the shared repo (its
   `origin` is the repo the Marshal merges into). If not, stop and say so.

2. Run one pass. All PR/build operations go through the host adapter; nothing
   here talks to GitHub or Bitbucket directly:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/marshal.sh"
   ```

   Pass `--pin`/host overrides through the environment, never by editing the
   script:
   - a hotfix pin: `MARSHAL_HOTFIX_PIN=<pr-number> bash …/marshal.sh`
   - an explicit adapter: `MARSHAL_HOST=/path/to/host.sh bash …/marshal.sh`

3. Relay the pass's decision log verbatim — the `marshal:` lines are the audit
   trail (`candidates … order=…`, `rebase … result=…`, `build … state=…`,
   `merge …` / `kickback … reason=…` / `wait …`, and the final `done …`
   summary). Do not paraphrase a merge or a kickback into a quality claim; the
   Marshal made none.

4. If the pass merged a PR, note that the trunk has advanced and the next pass
   (cron or a re-run) will rebase and re-verify the next PR against the new
   trunk. If it left a PR `wait`-ing, the composed build is still running; the
   next fire re-checks it. If it kicked one back, the comment on that PR says
   why (rebase budget, conflict, or a Composition Break) — that is the author's
   to fix; the Marshal does not.
