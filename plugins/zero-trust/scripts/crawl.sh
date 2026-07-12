#!/usr/bin/env bash
# crawl.sh — OWM-03/03a/04: crawl a CONFIG-FIRST repo list, reading ONLY the closed
# memory-glob allow-list (never the code tree), enforcing a per-repo file+byte
# ceiling (memory-surface-oversized crawl_error), self-excluding OWM's own output,
# and (with --incremental --state) skipping unchanged heads by commit-sha cache-key.
#   usage: crawl.sh --config <cfg> [--incremental --state <s.json>]
#                   [--trace-opens <f>] [--max-files N] [--max-bytes N]
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_owm_run.sh"
owm_exec crawl "$@"
