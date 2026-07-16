# Org-Wide Memory (`org-memory`)

> *If an agent has to be told something twice, we've failed.*

A read-only, memory-glob-bounded **index and crawler** over the memory every repo in
the suite already commits — ADRs, `CONTEXT.md` glossaries, Verification Manifests,
`DL-###` decision logs, and journey/as-built docs — exposed to agents via a
**refuse-by-default MCP query surface**. It is a **derived view, never a second store
of truth** (ADR 0019): every record carries a `{repo, commit_sha, path, source_line}`
back-pointer to the authoritative bytes; there is no write-back, no edit surface, no
copy of a fact that outlives one crawl. Rebuild-from-empty is always correct.

Ships inside the one `zero-trust` plugin (ADR 0025; installed via the
skills-dir clone, ADR 0027).
It grants **repo READ only**, scoped to the declared memory globs — strictly *less*
surface than the audit tier (which reads the whole tree), and nothing an autonomous
drain would.

## What it does

| Stage | Script | Item |
|-------|--------|------|
| Extract one memory file → normalized JSON records | `scripts/extract_memory.sh <file>` | OWM-01 |
| Crawl a config-first repo list (bounded read surface, incremental) | `scripts/crawl.sh --config <cfg>` | OWM-03 / 03a / 04 |
| Build the single-file SQLite + FTS5 index | `scripts/index_build.sh <records.jsonl> <db>` | OWM-05 |
| Query: `lookup` / `search` / `resolve` / `decisions` | `scripts/query.sh <sub> <arg> --db <db>` | OWM-06 / 07 |
| Coverage — "what do we NOT know" | `scripts/coverage.sh --db <db>` | OWM-08 |
| Optional host org-enumeration (gh / Bitbucket DC) | `scripts/host_repo_list.sh repo-list --org <org>` | OWM-09 |
| MCP server (thin adapter over `query.sh`) | `mcp/mcp_server.py` | OWM-11 |

```
crawl.sh ──▶ records.jsonl ──▶ index_build.sh ──▶ index.db ──▶ query.sh ◀── mcp_server.py
   │  (reads ONLY the closed memory-glob allow-list; never the code tree)      (thin adapter)
   └── config-first repo list (installs standalone; host enumeration is optional)
```

## The record

One JSON Schema (`schema/org-memory/v1.schema.json`) is the sole structural source of
truth. `org_id = <repo-slug>:<kind>:<kebab-name>` is the stable cross-repo identity —
the same kebab name in two repos is two records disambiguated by `repo`, never a merge.

## Design invariants (ADR 0019)

- **Derived view, never a store of truth.** No write-back; the index is a disposable
  single-file cache keyed on `commit_sha`. Staleness is *disclosed* on every answer
  (`possibly_stale` when the indexed sha lags head, **absent** — never a false 'fresh'
  — when head is unknown), never hidden.
- **Bounded read surface (OWM-03a).** Only the closed allow-list of memory globs is
  read; a per-repo file-count + byte ceiling yields a loud `memory-surface-oversized`
  crawl_error rather than a silent hang. Never the code tree.
- **Refuse-by-default (OWM-11a).** The query tools serve ONLY repos in the configured
  allow-list; a query that would surface an out-of-scope repo returns an explicit
  refusal + reason, never the record. This is enforced on BOTH the MCP path and the
  `query.sh` / `coverage.sh` CLI (the source of truth): with no scope granted (no
  `--allow`, no `--all`) nothing is served. `--all` is an explicit operator escape.
  This is the enforcement point for a cross-repo disclosure policy that is a **human
  call** (escalated).
- **Self-exclusion (OWM-11b).** OWM never indexes its own emitted output (marked
  `owm:self-emitted`), so no citation loop can form.
- **Reuse, never fork.** The `manifest` class is parsed by the canonical
  `validate_manifest` toolchain (byte-identical vendored copy; lint V8) honoring its
  0/3/4/5 exit contract — exit 4/5 manifests index as `unparseable` carrying the
  error + code, never dropped.
- **No runtime dependency on a sibling plugin.** Config-first is the default; the
  optional host-enumeration path is vendored, never an install-time coupling.
- **Read-only.** No findings, no remediation loop, no re-plan, no write path — so
  infinite-regress / self-remediation is structurally absent, not merely guarded.

## Escalated (human_questions — not agent-decided)

- WHERE the index runs and on what cadence.
- WHICH identity enumerates the org and its READ scope.
- WHETHER private/restricted-visibility repo memory may be surfaced cross-repo
  (refuse-by-default is the safe posture until a human sets the policy).

## Honest residuals (`[drain]` — measured only against a live corpus)

- Extractor **recall** on the messy long tail of real ADR/manifest/glossary variants
  (fixtures prove the KNOWN shapes).
- Real per-repo crawl **latency** on a large corpus (the ceiling prevents runaway;
  actual timing is measured).
- FTS ranking **quality** ("does the right ADR come first") — never a `[det]` claim.
- Real org enumeration + the live credential path behind `host_repo_list.sh`.
- An agent actually reaching for the MCP tool mid-session in a foreign repo.

## Self-test

```
bash plugins/zero-trust/scripts/self_test_org_memory.sh          # all [det] assertions
```
Runs hermetically (bash 3.2 + BSD-safe; Python via `uv run`, ADR 0015). The MCP
protocol test is dependency-free (a real stdio JSON-RPC round trip); the optional
official-`mcp`-SDK interop check notes-and-skips when that package is absent.
