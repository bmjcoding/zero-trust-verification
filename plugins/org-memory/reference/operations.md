# Org-Wide Memory — operations & escalated human_questions

OWM is designed **formats-ready and config-first** so OWM-01..08 land and self-test
hermetically against fixtures *regardless* of the hosting / auth / disclosure answers
below. The build never blocks on these — they are genuine human/infra calls (ADR 0019
Consequences), degraded gracefully in the meantime, and recorded here as
`human_questions`, never agent-assumed.

## Escalated `human_questions` (a human sets these; OWM degrades until then)

1. **Where and on what cadence does the index run?**
   OWM is a rebuildable single-file SQLite cache — `crawl.sh` → `index_build.sh` on
   any schedule (a cron, a CI job, an operator's laptop). Rebuild-from-empty is always
   correct, so a missed run is at worst "a rebuild behind," disclosed as
   `possibly_stale`. *Default posture:* nothing runs automatically; the operator wires
   the cadence.

2. **Which identity enumerates the org, and what is its READ scope?**
   The optional `host_repo_list.sh` (OWM-09) needs a credential to list repos. Its READ
   scope and blast radius are a security call. *Default posture:* enumeration is OFF;
   OWM crawls the explicit `config/repos.*` list (OWM-03). If enumeration auth is
   unavailable, OWM falls back to that config list with a loud note — it never blocks.

3. **May restricted-visibility repo memory be surfaced cross-repo?**
   Can an agent working in repo A see repo B's private ADRs / decision log? This is a
   data-governance call, not agent-decidable (ADR 0019). *Default posture:*
   **refuse-by-default** — the MCP tools serve ONLY repos in the configured allow-list;
   a query that would surface an out-of-scope repo returns an explicit refusal + reason,
   never the record. Populate the allow-list with the repos the caller is already
   entitled to read at their source.

## Wiring the query surface

- **CLI (always works):** `scripts/query.sh lookup|search|resolve|decisions <arg>
  --db <index.db> --allow <slug,slug>`. The `--allow` list is the refuse-by-default
  ACL; omit it only for local single-tenant use.
- **MCP (optional):** `mcp/mcp_server.py` is a thin adapter over `query.sh`. Register it
  via `.mcp.json` (see the plugin root). Set `OWM_DB` to the index path and `OWM_ALLOW`
  to the in-scope allow-list. With `OWM_ALLOW` unset the server refuses everything
  (safe). The CLI answers even when the server is absent.

## Freshness contract (OWM-07)

Every answer carries `indexed_at_sha` + the crawl timestamp. If the operator supplies
the current head (`--head repo=sha`), the answer also carries `head_sha` +
`possibly_stale`. When head is unknown the field is **absent** — OWM never asserts a
freshness it cannot prove (no false 'fresh').

## What OWM will NOT do (read-only posture)

No write-back, no edit surface, no findings that feed a re-plan/remediation, no mutation
testing, no independent staleness heuristic. OWM has strictly LESS read surface than the
audit tier (memory globs only, never the code tree) and holds the suite's smallest write
authority: none.
