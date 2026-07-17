#!/usr/bin/env python3
"""OWM MCP server (OWM-11) — the agent query surface, refuse-by-default.

This is a THIN adapter over `scripts/query.sh` (the deterministic retrieval source
of truth; ADR 0019). It NEVER re-implements retrieval: every tool call shells out
to query.sh and returns its stdout VERBATIM, so the MCP answer is byte-identical to
the CLI answer. The CLI answers even when this server is absent (degrade gracefully).

Transport: MCP stdio = newline-delimited JSON-RPC 2.0 (one message per line). This
server is pure stdlib — no `mcp` SDK dependency — so it runs under `uv run
--no-project` with zero extra packages, and the hermetic protocol test drives it
over a real stdio pipe.

Two loop-safety / trust invariants (ADR 0019):
  (a) REFUSE-BY-DEFAULT: every tool call passes the CONFIGURED allow-list to
      query.sh (`--allow`). A query that would surface a repo outside the allow-list
      returns query.sh's explicit refusal, never the record. With NO allow-list
      configured the safe default is to serve nothing (empty allow-list -> refuse).
  (b) SELF-EXCLUSION is enforced upstream at crawl time (the crawler skips OWM's
      own owm:self-emitted output), so the index this server reads never contains a
      citation loop.

Config (env, or a JSON --config file):
  OWM_DB          path to the SQLite index (required to answer)
  OWM_ALLOW       comma-separated allow-list of in-scope repo slugs (refuse-by-default)
  OWM_HEAD        comma-separated repo=sha map for possibly_stale disclosure (OWM-07)
  OWM_QUERY_SH    path to query.sh (defaults to ../scripts/query.sh next to this file)
  OWM_COVERAGE_SH path to coverage.sh (defaults to ../scripts/coverage.sh)
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "org-memory"
SERVER_VERSION = "2.1.0-rc.1"  # converged on plugin.json (ADR 0031: one version surface)

_HERE = Path(__file__).resolve().parent


def _cfg():
    cfg = {}
    if "--config" in sys.argv:
        i = sys.argv.index("--config")
        if i + 1 < len(sys.argv):
            cfg = json.loads(Path(sys.argv[i + 1]).read_text(encoding="utf-8"))
    db = os.environ.get("OWM_DB", cfg.get("db", ""))
    allow_env = os.environ.get("OWM_ALLOW")
    if allow_env is not None:
        allow = [x.strip() for x in allow_env.split(",") if x.strip()]
    elif "allow" in cfg:
        allow = list(cfg["allow"])
    else:
        allow = []  # refuse-by-default: no allow-list => serve nothing
    head = os.environ.get("OWM_HEAD", cfg.get("head", ""))
    query_sh = os.environ.get("OWM_QUERY_SH", cfg.get("query_sh", str(_HERE.parent / "scripts" / "query.sh")))
    coverage_sh = os.environ.get("OWM_COVERAGE_SH", cfg.get("coverage_sh", str(_HERE.parent / "scripts" / "coverage.sh")))
    return {"db": db, "allow": allow, "head": head, "query_sh": query_sh, "coverage_sh": coverage_sh}


def _run_query(cfg, sub, arg):
    """Shell out to query.sh — the SINGLE retrieval implementation. Returns
    (stdout_text, exit_code). Always passes the configured allow-list."""
    cmd = ["bash", cfg["query_sh"], sub, arg, "--db", cfg["db"], "--allow", ",".join(cfg["allow"])]
    if cfg["head"]:
        cmd += ["--head", cfg["head"]]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.stdout, proc.returncode


def _run_coverage(cfg):
    # refuse-by-default extends to the coverage resource: scope it to the allow-list so
    # out-of-scope repo names / error paths are never disclosed to the agent.
    cmd = ["bash", cfg["coverage_sh"], "--db", cfg["db"], "--allow", ",".join(cfg["allow"])]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.stdout, proc.returncode


TOOLS = [
    {
        "name": "memory_lookup",
        "description": "Look up one org-memory record by its stable cross-repo org_id "
                       "(<repo>:<kind>:<kebab-name>). Returns the record + its {repo, commit_sha, "
                       "path, source_line} source pointer and freshness. Refuses out-of-scope repos.",
        "inputSchema": {
            "type": "object",
            "properties": {"org_id": {"type": "string", "description": "e.g. myrepo:adr:async-caching"}},
            "required": ["org_id"],
        },
    },
    {
        "name": "memory_search",
        "description": "Full-text search across the org's committed memory (ADRs, glossary, manifests, "
                       "decision logs, journeys). Returns ranked records, each with its source pointer + "
                       "freshness. Records from repos outside the allow-list are never returned.",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
    },
    {
        "name": "memory_resolve_term",
        "description": "Resolve a term OR a rejected synonym to its canonical glossary definition — so an "
                       "agent that reaches for a banned alias gets the real term back (the 'told twice' killer).",
        "inputSchema": {
            "type": "object",
            "properties": {"term": {"type": "string"}},
            "required": ["term"],
        },
    },
    {
        "name": "memory_decisions",
        "description": "Look up the ADRs + decision-log entries for a topic, SUPERSESSION-AWARE: a superseded "
                       "decision is returned flagged, never as live truth.",
        "inputSchema": {
            "type": "object",
            "properties": {"topic": {"type": "string"}},
            "required": ["topic"],
        },
    },
]

_TOOL_SUB = {
    "memory_lookup": ("lookup", "org_id"),
    "memory_search": ("search", "text"),
    "memory_resolve_term": ("resolve", "term"),
    "memory_decisions": ("decisions", "topic"),
}

RESOURCES = [
    {
        "uri": "owm://coverage",
        "name": "org-memory coverage report",
        "description": "What the index does and does NOT know: repos crawled, records by kind, and every "
                       "crawl_error/unparseable with its source (OWM-08).",
        "mimeType": "application/json",
    }
]


def _result(id_, result):
    return {"jsonrpc": "2.0", "id": id_, "result": result}


def _error(id_, code, message):
    return {"jsonrpc": "2.0", "id": id_, "error": {"code": code, "message": message}}


def handle(msg, cfg):
    """Return a response dict, or None for notifications (no response)."""
    method = msg.get("method")
    id_ = msg.get("id")
    is_notification = "id" not in msg

    if method == "initialize":
        return _result(id_, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}, "resources": {}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })
    if method in ("notifications/initialized", "initialized"):
        return None
    if method == "ping":
        return _result(id_, {})
    if method == "tools/list":
        return _result(id_, {"tools": TOOLS})
    if method == "resources/list":
        return _result(id_, {"resources": RESOURCES})
    if method == "resources/read":
        uri = (msg.get("params") or {}).get("uri")
        if uri != "owm://coverage":
            return _error(id_, -32602, f"unknown resource: {uri}")
        text, _rc = _run_coverage(cfg)
        return _result(id_, {"contents": [{"uri": uri, "mimeType": "application/json", "text": text}]})
    if method == "tools/call":
        params = msg.get("params") or {}
        name = params.get("name")
        arguments = params.get("arguments") or {}
        if name not in _TOOL_SUB:
            return _error(id_, -32602, f"unknown tool: {name}")
        sub, argkey = _TOOL_SUB[name]
        arg = arguments.get(argkey, "")
        text, rc = _run_query(cfg, sub, str(arg))
        # rc == 3 is query.sh's explicit refuse-by-default; surface it AS a tool result
        # (the refusal JSON), not a transport error — the agent must see the reason.
        return _result(id_, {"content": [{"type": "text", "text": text}], "isError": False})

    if is_notification:
        return None
    return _error(id_, -32601, f"method not found: {method}")


def main():
    cfg = _cfg()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            sys.stdout.write(json.dumps(_error(None, -32700, "parse error")) + "\n")
            sys.stdout.flush()
            continue
        resp = handle(msg, cfg)
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
