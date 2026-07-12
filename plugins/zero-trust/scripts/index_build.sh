#!/usr/bin/env bash
# index_build.sh — OWM-05: build the single-file SQLite + FTS5 index from a records
# JSONL. Rebuild-from-empty is always correct (drops + recreates). A rebuild from
# the same input is byte-comparable via `dump`.
#   usage: index_build.sh <records.jsonl> <out.db>
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_owm_run.sh"
owm_exec index-build "$@"
