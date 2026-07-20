#!/usr/bin/env bash
# extract_memory.sh — OWM-01: emit the normalized JSON record set for ONE memory
# file, dispatching to the typed per-memory-class extractor (adr / manifest /
# glossary / decision-log / journey / as-built). The `manifest` class reuses the
# CANONICAL validate_manifest toolchain (never a forked parser; single copy since
# ADR 0025 — the V8 byte-identity lint retired with the vendored copies).
#   usage: extract_memory.sh <file> [--repo <slug>] [--commit <sha>] [--kind <k>]
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_owm_run.sh"
owm_exec extract "$@"
