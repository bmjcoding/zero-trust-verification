#!/usr/bin/env bash
# query.sh — OWM-06/07/11: the DETERMINISTIC query surface (the retrieval source of
# truth; the MCP server is a thin adapter over THIS, never a second impl). Primitives:
#   lookup <org_id> | search <text> | resolve <term-or-alias> | decisions <topic>
# Every result carries {repo, commit_sha, path, source_line} + honest freshness.
# ACL is REFUSE-BY-DEFAULT on this source-of-truth path: with NEITHER --allow NOR
# --all, no scope is granted and every lookup is refused. --allow <s,s> serves only
# those repos (a repo outside the list is refused, never returned); --all is the
# explicit operator escape that serves every indexed repo. --head <repo=sha,...>
# enables possibly_stale disclosure.
#   usage: query.sh <lookup|search|resolve|decisions> <arg> --db <db>
#                   [--allow <s,s> | --all] [--head <repo=sha,...>]
# Exit: 0 ok · 3 refused (out-of-scope repo / no scope granted) · 64 usage.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_owm_run.sh"
owm_exec query "$@"
