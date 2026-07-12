#!/usr/bin/env bash
# coverage.sh — OWM-08: the "what do we NOT know" surface. Emits, per org, the repos
# crawled, records by kind, and every crawl_error/unparseable WITH its source +
# error code — so a question the index cannot answer shows WHY, not a silent empty.
# The report carries the owm:self-emitted marker so the crawler never re-ingests it.
# ACL is REFUSE-BY-DEFAULT here too: with NEITHER --allow NOR --all the report is
# empty (scoped_to_allow_list:true, no repo names / error paths disclosed). --allow
# <s,s> scopes it to those repos; --all is the explicit operator escape for a full
# report. The MCP coverage resource always passes the configured allow-list.
#   usage: coverage.sh --db <db> [--allow <s,s> | --all]
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_owm_run.sh"
owm_exec coverage "$@"
