#!/usr/bin/env bash
# outcome_external.sh — external-source outcome adapters (ADR 0023; OM-05/OM-06).
# defect-escape (OM-05) and incident/MTTR/paged (OM-06) are EXTERNAL facts (ADR
# 0002/0006). When a source file is configured the number is DETERMINISTIC; when no
# source is configured the adapter derives NOTHING and reports [OUTCOME-SOURCE-ABSENT:
# <label>] — absence never blocks the report, a number is never fabricated.
#
# Usage:
#   outcome_external.sh defect-escape --store PATH [--source-file F] [--deploys N] [--now E] [--repo P]
#   outcome_external.sh incident      --store PATH [--source-file F] [--journeys J] [--now E] [--repo P]
#
# Exit 0 always (report-only). Writes ONLY the store; posts nothing.
# Portability: bash 3.2 (macOS) + BSD userland safe.
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYEXT="$HERE/outcome_external.py"
PYASM="$HERE/outcome_assemble.py"
STORE_SH="$HERE/outcome_store.sh"
py() { if command -v uv >/dev/null 2>&1 && [ -f "$HERE/../pyproject.toml" ]; then uv run --no-project python "$@"; else python3 "$@"; fi; }
iso_utc() { local e="$1"; if [ "$e" = "-" ]; then date -u +%Y-%m-%dT%H:%M:%SZ; return; fi
  date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$e"; }

[ $# -ge 1 ] || { echo "usage: outcome_external.sh {defect-escape|incident} --store PATH [...]" >&2; exit 64; }
SUB="$1"; shift
case "$SUB" in defect-escape|incident) : ;; *) echo "outcome_external: unknown metric: $SUB" >&2; exit 64;; esac

STORE=""; REPO="."; NOW=""; SOURCE=""; DEPLOYS=""; JOURNEYS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --store) STORE="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --now) NOW="$2"; shift 2;;
    --source-file) SOURCE="$2"; shift 2;;
    --deploys) DEPLOYS="$2"; shift 2;;
    --journeys) JOURNEYS="$2"; shift 2;;
    *) echo "outcome_external: unknown arg: $1" >&2; exit 64;;
  esac
done
[ -n "$STORE" ] || { echo "outcome_external: --store required" >&2; exit 64; }

ext_args=("$SUB")
[ -n "$SOURCE" ]   && ext_args+=(--source-file "$SOURCE")
[ -n "$DEPLOYS" ]  && ext_args+=(--deploys "$DEPLOYS")
[ -n "$JOURNEYS" ] && ext_args+=(--journeys "$JOURNEYS")

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM
py "$PYEXT" "${ext_args[@]}" > "$TMP/ext.json" || { echo "outcome_external: adapter failed" >&2; exit 0; }

# source-absent labels -> print the marker, write nothing.
absent="$(py - "$TMP/ext.json" <<'PYA' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1]))
for lbl in d.get("source_absent") or []:
    print("[OUTCOME-SOURCE-ABSENT: %s]" % lbl)
PYA
)"
if [ -n "$absent" ]; then
  printf '%s\n' "$absent" | while IFS= read -r l; do echo "outcome_external: $l (no source configured — field omitted, not fabricated)"; done
  exit 0
fi

CAPTURED_AT="$(iso_utc "${NOW:--}")"
GIT_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
py "$PYASM" --metrics-file "$TMP/ext.json" --kind "external-$SUB" --captured-at "$CAPTURED_AT" --git-sha "$GIT_SHA" \
  > "$TMP/snapshot.json" || { echo "outcome_external: assemble failed" >&2; exit 0; }
if bash "$STORE_SH" append-run --store "$STORE" --snapshot-file "$TMP/snapshot.json"; then
  echo "outcome_external: appended deterministic $SUB row(s) at $CAPTURED_AT -> $STORE"
else
  echo "outcome_external: store write refused (corrupt store) — nothing written" >&2
fi
exit 0
