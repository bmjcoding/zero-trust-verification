# Conflict Resolution Protocol

You are the orchestrator (not the implementer agent), running this protocol inline when D7.0's `git rebase origin/<base>` reports `UU` conflicts.

## HARD BUDGET

Resolve at most **3 conflict hunks across at most 2 files** — cumulative across the whole rebase. Past that, `git rebase --abort` and write `[BLOCKED: rebase-too-large]` (impl), no retry: a larger rebase signals a planner ownership-overlap failure that needs human re-plan. Count with:

```bash
files_with_conflicts=$(git diff --name-only --diff-filter=U)
file_count=$(printf '%s\n' "$files_with_conflicts" | grep -c . || true)

hunk_count=0
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    n=$(grep -c '^<<<<<<<' "$f" 2>/dev/null || true)
    hunk_count=$((hunk_count + n))
done <<< "$files_with_conflicts"

if [[ $file_count -gt 2 || $hunk_count -gt 3 ]]; then
  git rebase --abort
  # Write tracker entry: [BLOCKED: rebase-too-large] (impl)
  exit
fi
```

## PROTOCOL

### 1. See the current state

```bash
git status
git log --oneline origin/<base>..HEAD          # what your branch added (the D4 per-cycle commits)
git log --oneline HEAD..origin/<base>          # what trunk added since you forked
git diff --name-only --diff-filter=U           # conflicting files
```

Read each conflicting file in FULL with markers visible — short previews hide context that changes the resolution.

### 2. Find the primary sources

Per hunk, you are looking for INTENT — why did each side want its change:

- Your branch's most recent commit touching this region (`git log --oneline -1 --follow -- <file>`, then `git show <sha>`) — per AP-1 typically a `test:`/`feat:` per-cycle commit that names EXACTLY which behavior was being implemented.
- Trunk's most recent commit touching this region; follow any PR/ticket it references.

### 3. Resolve each hunk

By intent, not mechanical preference:

- **Both intents compatible** → preserve both (e.g. both sides added a struct field → keep both).
- **Semantically incompatible** → pick the side matching THIS Subtask's `acceptance_criteria`; note the trade-off for the PR body (below).
- **Can't tell** → `git rebase --abort`, `[BLOCKED: rebase-ambiguous]` (impl). No guessing.

**Tiebreaker when both candidates are defensible:** (1) the resolution keeping the hunk's tests green wins; (2) both green → the one matching `acceptance_criteria`; (3) neither resolves it → abort `[BLOCKED: rebase-ambiguous]` (impl).

**Never invent new behavior** to satisfy both sides — "preserving both" that requires logic in neither side is invention; abort. **Never abort casually** either: abort only on budget overflow or genuine ambiguity — otherwise resolve.

### 4. Re-run gates after each file resolved (AP-15 scoping)

```bash
git add <resolved-file>
# Run the runbook's gates, scoped to the resolved file
# (Python defaults shown; substitute your runbook's gates: commands):
#   gates.lint        e.g. ruff check <resolved-file>
#   gates.typecheck   e.g. mypy <resolved-file>
#   gates.test_scoped e.g. pytest -x -q <test-files-touching-resolved-file>   # SCOPED — never full suite during rebase
```

A gate failing on the resolution means the resolution is wrong: try again, or abort `[BLOCKED: rebase-broke-gates]` (impl).

### 5. Continue rebase

`git rebase --continue`. New conflicts at the next commit → repeat from step 1 with the budget still in effect (cumulative). On clean finish: `git status` (clean), `git log --oneline -5` (your commits on top of `origin/<base>`).

### 6. Verify the per-cycle shape survived (AP-1 invariant)

```bash
git log --oneline origin/<base>..HEAD --pretty=format:"%s"
```

The RED/GREEN pairs must still be present in order — a rebase resolves textual conflicts in file contents, never alters the commits themselves. Re-ordered or dropped per-cycle commits (should be impossible without `--rebase-merges`) → abort `[BLOCKED: rebase-shape-broken]` (impl).

## NOTES IN THE COMMIT BODY

A resolution that involved a trade-off (semantic incompatibility, one side picked) gets a `Rebase note:` line in the D7.3 PR body — the per-cycle commits stay untouched (AP-1); the note lives in the PR description:

```
Rebase note: Resolved conflict in lib/foo.py with origin/main's
rename (validate_input → check_input). This subtask's call site was
updated to match. Old name no longer exists.
```

## DO NOT

- `git rebase --abort` to "make the conflict go away" before trying.
- `git checkout --ours`/`--theirs` blindly across files — per-hunk only, after reading intent.
- Resolve by re-running the implementer agent — it doesn't know the rebase context.
- Squash the per-cycle commits to simplify the rebase — they are the evidence D6 audits.
- Run the full test suite during rebase — always scope to changed files (AP-15).
- Skip the post-resolution gate run.
