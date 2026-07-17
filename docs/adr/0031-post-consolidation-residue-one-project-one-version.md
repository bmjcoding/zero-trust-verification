# ADR 0031 — Post-consolidation residue: the outcome family lives in the plugin; one uv project; one version surface

- **Status:** Agent-decided (2026-07-17)
- **Date:** 2026-07-17
- **Supersedes/amends:** completes ADR 0025 Wave 1's "one copy of everything" for the artifacts it missed; narrows ADR 0023's file placement.

## Context

Verified residue of the six-plugin world:

- **Ten outcome runtime files at repo root** (`scripts/outcome_{store,report,
  dora,emission,external,assemble,annotate,baseline}.*`) while all three
  production callers live inside the plugin and escape via
  `SUITE_ROOT="$HERE/../../.."`. README:126 claims "everything installable
  lives here" (the plugin); README:138 mislabels these runtime files "dev
  tooling". Works only because the ADR 0027 skills-dir symlink sits inside a
  full clone.
- **Two uv projects** with byte-identical dependency graphs (`ruamel.yaml`,
  `jsonschema`; one 2-line uv.lock delta: name/version) — two lockfiles to
  keep in sync for one dependency set.
- **Five version identities:** plugin.json `2.1.0-rc.1`, plugin pyproject
  `2.0.0rc1`, README `v2.0.0-rc.1`, `mcp/mcp_server.py` `0.1.0`, root
  pyproject `0.1.0`. No v2.x git tag exists to anchor any of them.
- **Name collisions** that force disambiguating prose: two
  `validate_manifest.sh` (canonical validator vs autopilot's `--union`-only
  tool), two `run_cases.py`, two `mock_host.sh` with different contracts, two
  `lint_consistency.sh` sharing the `L<n>` id namespace.
- **Autopilot CHANGELOG** carries v2.x history (entries ≤2.4.0, lines
  281-511) in the live file; the v1 archive precedent already exists.

## Decision

1. **Outcome family moves into `plugins/zero-trust/scripts/`.** Callers drop
   the `SUITE_ROOT` escape; `outcome_self_test.sh` (dev tooling, stays at
   root) re-points in the same PR. Lint V11 needs *no* re-point (verified:
   its grep inputs — schema glob, `.md` block scans, register tag lines —
   are path-stable under the move); instead
   `docs/specs/outcome-measurement-register.md` gets a dated correction note
   for its `[det]` acceptance lines citing the old `scripts/outcome_*.sh`
   paths (append-only, never rewritten). The `.sh`/`.py` pairing is kept
   (sh = CLI/uv bootstrap, py = logic — deliberate).
2. **One uv project: the plugin's.** Root `pyproject.toml` + `uv.lock` are
   deleted; every harness that `--project`s the repo root re-points to the
   plugin — the full verified inventory: root `scripts/self_test.sh`,
   `sd_self_test.sh:46-50`, `tests/codebase-health/self_test.sh:43-47`,
   `outcome_self_test.sh:32`, `outcome_store.sh`, **and the three plugin
   self-tests that hard-code `uv run --project "$ROOT"` with ROOT = repo
   root and no fallback** (`self_test_triage.sh:30`,
   `self_test_org_memory.sh:26`, `self_test_marshal.sh:26` — these fail
   outright, not silently, if missed; the sd/codebase-health pair degrade
   *silently* to bare python3, so the re-point is verified by grep, not just
   by the suite going red). The cleanup-audit `py_run.sh` plugin-pin (never
   sync a *target* repo's deps during an audit) is preserved by
   construction — the surviving project *is* the plugin. The `_owm_run.sh`/
   `_triage_run.sh` nearest-pyproject walkers already resolve to the plugin;
   their "repo root" comments are corrected as touched.
3. **One version surface: `plugin.json`.** It reads `2.1.0-rc.1`; the plugin
   pyproject, README status line, and MCP server converge on it (pyproject as
   PEP 440 `2.1.0rc1` — semantic convergence; no rule requires byte
   equality). Tags are cut only at release (unchanged policy).
4. **Renames, semantics untouched:** autopilot's `validate_manifest.sh` →
   `validate_manifest_union.sh`; plugin spec-gen `lint_consistency.sh` →
   `lint_spec_gen.sh`; plugin `tests/run_cases.py` → `run_spec_gen_cases.py`;
   `fixtures/host/mock_host.sh` → `mock_pr_host.sh`. Callers, docs, and
   self-test references update in the same PR.
5. **Archive autopilot CHANGELOG ≤2.4.0** to
   `plugins/zero-trust/docs/autopilot/CHANGELOG-v2.md` (v1 precedent). The
   release-gate header keeps its rule (every behavioral claim cites a
   self-test assertion id) and drops its pointer to the deleted
   `docs/GAPS_SPEC.md`. Archived history is moved verbatim, never rewritten;
   the archive header notes that GAPS references inside are historical.
6. **Housekeeping:** delete the untracked on-disk residue
   (`plugins/{codebase-health,org-memory,spec-gen,triage}/` venv/pycache
   remains, `scripts/__pycache__`, stale worktree copies) — it actively
   suggests six plugins still exist.

## Consequences

- The README's "everything installable lives in the plugin" sentence becomes
  true; the last structural lie of the six-plugin era is gone.
- One lockfile, one dependency graph, one version string; `/plugin` UI,
  pyproject, and README can no longer disagree.
- Rename fallout is mechanical and same-PR: lint path references, self-test
  invocations, `lifecycle.md`/SKILL.md pointers.
- SUITE_STRICT zero-skip green is the merge gate for every step; assertion
  counts are floors (ADR 0025).
