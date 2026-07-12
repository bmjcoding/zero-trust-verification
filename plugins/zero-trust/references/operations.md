# Org-Wide Memory — operations & escalated human_questions

OWM is **formats-ready and config-first**: it lands and self-tests hermetically
against fixtures *regardless* of the hosting / auth / disclosure answers below.
These are genuine human/infra calls (ADR 0019 Consequences), degraded
gracefully in the meantime and recorded here as `human_questions`, never
agent-assumed.

## Escalated `human_questions` (a human sets these; OWM degrades until then)

1. **Where and on what cadence does the index run?**
   OWM is a rebuildable single-file SQLite cache — `crawl.sh` →
   `index_build.sh` on any schedule. Rebuild-from-empty is always correct, so
   a missed run is at worst "a rebuild behind," disclosed as `possibly_stale`.
   *Default posture:* nothing runs automatically; the operator wires the
   cadence.

2. **Which identity enumerates the org, and what is its READ scope?**
   The optional `host_repo_list.sh` (OWM-09) needs a credential to list repos
   — a security call. *Default posture:* enumeration is OFF; OWM crawls the
   explicit `config/repos.*` list (OWM-03), falling back to it with a loud
   note when enumeration auth is unavailable — it never blocks.

3. **May restricted-visibility repo memory be surfaced cross-repo?**
   A data-governance call, not agent-decidable (ADR 0019). *Default posture:*
   **refuse-by-default** — the MCP tools serve ONLY repos in the configured
   allow-list; a query that would surface an out-of-scope repo returns an
   explicit refusal + reason, never the record. Populate the allow-list with
   the repos the caller is already entitled to read at their source.

## Wiring the query surface

- **CLI (always works):** `scripts/query.sh lookup|search|resolve|decisions
  <arg> --db <index.db> --allow <slug,slug>`. ACL is **refuse-by-default even
  on the CLI** (the retrieval source of truth): with NEITHER `--allow` NOR
  `--all`, no scope is granted and every lookup is refused. `--allow` serves
  only the listed repos; `--all` is the explicit operator escape (local
  single-tenant work only). `coverage.sh` follows the same rule.
- **MCP (optional):** `mcp/mcp_server.py` is a thin adapter over `query.sh`.
  Register via `.mcp.json` (plugin root); set `OWM_DB` to the index path and
  `OWM_ALLOW` to the allow-list. With `OWM_ALLOW` unset the server refuses
  everything (safe). The CLI answers even when the server is absent.

## Freshness contract (OWM-07)

Every answer carries `indexed_at_sha` + the crawl timestamp. If the operator
supplies the current head (`--head repo=sha`), the answer also carries
`head_sha` + `possibly_stale`. When head is unknown the field is **absent** —
OWM never asserts a freshness it cannot prove (no false 'fresh').

## What OWM will NOT do (read-only posture)

No write-back, no edit surface, no findings that feed a re-plan/remediation,
no mutation testing, no independent staleness heuristic. OWM has strictly LESS
read surface than the audit tier (memory globs only, never the code tree) and
holds the suite's smallest write authority: none.
