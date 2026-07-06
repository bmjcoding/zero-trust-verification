# Conflict Resolution Protocol


You are the orchestrator (not the implementer agent) running this
protocol inline when D7.0's `git rebase origin/<base>` reports `UU`
conflicts.


## HARD BUDGET


Resolve at most **3 conflict hunks across at most 2 files**. Past that,
abort with `[BLOCKED: rebase-too-large]` (impl). No retry — larger rebases
signal a planner ownership-overlap failure that needs human re-plan.


Count conflict markers:


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
git log --oneline origin/<base>..HEAD          # what your branch added (the per-cycle commits from D4)
git log --oneline HEAD..origin/<base>          # what trunk added since you forked
git diff --name-only --diff-filter=U           # conflicting files
```


For each conflicting file, read the full file content with conflict
markers visible. Don't trust short previews — read the full file.


### 2. Find the primary sources


For each conflicting hunk:


- Read the commit message of the most recent commit on YOUR branch that touched this region: `git log --oneline -1 --follow -- <file>` then `git show <sha>`. Per AP-1 this is typically a `test:` or `feat:` per-cycle commit, which tells you EXACTLY which behavior was being implemented.
- Read the commit message of the most recent commit on TRUNK that touched this region: `git log --oneline origin/<base> -1 --follow -- <file>` then `git show <sha>`.
- If those commits reference PRs or tickets, read those too.


You are looking for INTENT. Why did your branch want this change?
Why did trunk want the conflicting change? What was each trying to achieve?


### 3. Resolve each hunk


Choose the resolution per hunk by intent, not by mechanical preference:


- **Both intents are compatible** → preserve both. Combine the code such that both effects land. Example: both branches added a new field to a struct → keep both fields.
- **Intents are semantically incompatible** → pick the one that matches THIS Subtask's stated `acceptance_criteria`. Note the trade-off in the eventual commit body. Example: trunk renamed a function; your branch added a call site to the old name → update your call site to the new name.
- **You can't tell which is right** → abort. `git rebase --abort`. Write `[BLOCKED: rebase-ambiguous]` (impl). No guessing.


**Tiebreaker rule.** When both candidate resolutions are semantically
defensible:


1. The resolution that keeps the tests touching this hunk green wins.
2. If both candidates leave the relevant tests green, the resolution
   that matches THIS Subtask's `acceptance_criteria` wins.
3. If neither tiebreaker resolves it, abort with
   `[BLOCKED: rebase-ambiguous]` (impl). No guessing.


**Never invent new behavior** to satisfy both sides. If "preserving both" requires NEW logic that wasn't in either side, that's invention; abort.


**Never `git rebase --abort` casually.** Abort only on the budget overflow or genuine ambiguity above. Otherwise: always resolve.


### 4. Re-run gates after each file resolved (AP-15 scoping)


```bash
git add <resolved-file>
# Run the runbook's gates, scoped to the resolved file
# (Python defaults shown; substitute your runbook's gates: commands):
#   gates.lint        e.g. ruff check <resolved-file>
#   gates.typecheck   e.g. mypy <resolved-file>
#   gates.test_scoped e.g. pytest -x -q <test-files-touching-resolved-file>   # SCOPED — never full suite during rebase
```


If any gate fails on the resolution, the resolution is wrong. Try
again, or abort with `[BLOCKED: rebase-broke-gates]` (impl).


### 5. Continue rebase


```bash
git rebase --continue
```


If more conflicts appear at the next commit, repeat from step 1 with
the BUDGET still in effect (cumulative across all hunks).


When the rebase finishes cleanly:


```bash
git status                # clean
git log --oneline -5      # confirm your commits land on top of origin/<base>
```


### 6. Verify per-cycle commit shape survived the rebase (AP-1 invariant)


After the rebase, the per-cycle commit shape from D4 MUST be preserved. Run:


```bash
git log --oneline origin/<base>..HEAD --pretty=format:"%s"
```


Confirm the RED/GREEN pairs are still present in order. A rebase should never have to alter the per-cycle commits themselves — only resolve textual conflicts in their file contents. If you find that the rebase has somehow re-ordered or dropped per-cycle commits (this should be impossible under `git rebase` with `--rebase-merges` disabled, which is the default), abort with `[BLOCKED: rebase-shape-broken]` (impl).


## NOTES IN THE COMMIT BODY


If a conflict resolution involved a trade-off (semantic incompatibility
where you picked one side), the eventual PR body produced by Step
D7.3 should include a `Rebase note:` line explaining the choice. The
per-cycle commits themselves remain untouched (AP-1); the rebase note
lives in the PR description, not in any individual commit.


```
Rebase note: Resolved conflict in lib/foo.py with origin/main's
rename (validate_input → check_input). This subtask's call site was
updated to match. Old name no longer exists.
```


## DO NOT


- `git rebase --abort` to "make the conflict go away" before trying.
- `git checkout --ours` or `--theirs` blindly across files. Per-hunk only, after reading intent.
- Resolve a conflict by running the implementer agent again. The implementer doesn't know about the rebase context.
- Squash the per-cycle commits to simplify the rebase. The per-cycle shape is the evidence D6 audits.
- Run the full test suite during rebase — always scope to changed files (AP-15).
- Skip the post-resolution gate run.
