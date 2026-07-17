# Changelog — org-memory

All notable changes to the Org-Wide Memory plugin. Format: Keep a Changelog; the
suite pins semver per plugin (ADR 0001 — independent versions).

## [0.1.0] — 2026-07-06

Initial release. The fifth independently-installable plugin (ADR 0019) *[since
consolidated into the zero-trust plugin, ADR 0025; marketplace retired, ADR 0027]*:
a read-only, memory-glob-bounded index/crawler over repo-resident memory, exposed
via a refuse-by-default MCP query surface — never a second store of truth.

### Added
- **OWM-01** — typed per-memory-class extractors (`scripts/extract_memory.sh`):
  `adr` (post-title-frontmatter shape), `manifest` (reuses the canonical
  `validate_manifest` toolchain; exit 4/5 → `unparseable`, never dropped), `glossary`
  (`**Term**:` + `_Avoid_` aliases), `decision-log` (`DL-###`), `journey` / `as-built`.
- **OWM-02** — one record JSON Schema (`schema/org-memory/v1.schema.json`);
  `org_id = <repo-slug>:<kind>:<kebab-name>`; cross-repo id collisions disambiguated
  by `repo`; same-repo same-name ADR revision treated as supersession.
- **OWM-03 / 03a** — config-first crawler (`scripts/crawl.sh`) reading ONLY the closed
  memory-glob allow-list, with a per-repo file+byte ceiling → `memory-surface-oversized`
  crawl_error. Per-repo failure isolated; installs and runs standalone.
- **OWM-04** — incremental crawl keyed by `commit_sha` (unchanged head → proven no-op;
  a single-repo change re-extracts ONLY that repo).
- **OWM-05** — single-file SQLite + FTS5 index (`scripts/index_build.sh`);
  rebuild-from-empty; byte-comparable canonical `dump`.
- **OWM-06 / 07** — deterministic query surface (`scripts/query.sh`): `lookup`,
  `search`, `resolve` (alias → canonical term), `decisions` (supersession-aware).
  Every result carries `{repo, commit_sha, path, source_line}` + honest freshness
  (`possibly_stale` absent when head is unknown).
- **OWM-08** — coverage / crawl-error report (`scripts/coverage.sh`).
- **OWM-09** (optional) — host org-enumeration (`scripts/host_repo_list.sh`) as a NEW
  `repo-list` backend method for GitHub (`gh`) and Bitbucket DC (REST), against a
  T01-class mock matrix; falls back to the explicit config list. No runtime dependency
  on the autopilot plugin.
- **OWM-11** — MCP server (`mcp/mcp_server.py`): read-only `memory_lookup`,
  `memory_search`, `memory_resolve_term`, `memory_decisions` + a coverage resource,
  as a thin adapter over `query.sh` (output byte-identical to the CLI). Refuse-by-default
  on out-of-scope repos; self-exclusion of OWM's own output.
- **OWM-10 / 12** — packaging: registered as the fifth plugin in the root marketplace
  *[since consolidated into the zero-trust plugin, ADR 0025; marketplace retired, ADR 0027]*;
  `lint_consistency.sh` V6 grows four→five; new V8 vendoring lint pins OWM's
  manifest-parse path to the canonical validator; `suite_self_test.sh` gains the
  `org-memory` component + the V8 planted-drift RED-test.

### Escalated (human_questions — not agent-decided)
- Where/when the index runs; the enumeration identity's READ scope; whether
  restricted-visibility repo memory may be surfaced cross-repo (refuse-by-default until
  answered).
