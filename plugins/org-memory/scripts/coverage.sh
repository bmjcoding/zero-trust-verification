#!/usr/bin/env bash
# coverage.sh — OWM-08: the "what do we NOT know" surface. Emits, per org, the repos
# crawled, records by kind, and every crawl_error/unparseable WITH its source +
# error code — so a question the index cannot answer shows WHY, not a silent empty.
# The report carries the owm:self-emitted marker so the crawler never re-ingests it.
#   usage: coverage.sh --db <db>
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_owm_run.sh"
owm_exec coverage "$@"
