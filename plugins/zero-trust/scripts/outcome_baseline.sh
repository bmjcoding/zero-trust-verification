#!/usr/bin/env bash
# outcome_baseline.sh — capture the BEFORE snapshot at adoption, frozen, once
# (ADR 0023 — the LOAD-BEARING constraint). A before/after is lost if BEFORE is
# not captured at adoption; because deploy cadence / lead time / post-merge build
# state are reconstructable from trailing git + host history, the DORA baseline is
# captured RETROACTIVELY (no forward wait). The emission-share field is asymmetric:
# it needs ONE baseline audit run and is Class-A (agent-graded), so it is captured
# but tagged agent-graded, NEVER as retroactive [det] history.
#
# The baseline is written once with frozen:true; a SECOND capture is REFUSED by the
# store writer (exit 6, file byte-untouched) — the refuse-second guarantee. This
# refusal is a safety refusal, not a merge gate (ADR 0004): it protects the frozen
# BEFORE, it blocks no human's merge.
#
# Usage:
#   outcome_baseline.sh capture --store PATH --repo PATH [--trunk main]
#       [--weeks N | --since EPOCH --until EPOCH] [--now EPOCH]
#       [--host HOST_ADAPTER --host-repo GITDIR --host-state STATE]
#       [--journeys audit/journeys.json]
#
# Exit: 0 ok · 4 schema-invalid · 5 store corrupt · 6 refuse-second · 64 usage.
# Report-only: writes ONLY the store; opens no PR, files no finding (ADR 0004/0023).
#
# Portability: bash 3.2 (macOS) + BSD userland safe.
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYDORA="$HERE/outcome_dora.py"
PYEMIT="$HERE/outcome_emission.py"
PYASM="$HERE/outcome_assemble.py"
STORE_SH="$HERE/outcome_store.sh"

py() { if command -v uv >/dev/null 2>&1 && [ -f "$HERE/../pyproject.toml" ]; then uv run --no-project python "$@"; else python3 "$@"; fi; }

iso_utc() {  # <epoch|-> ; '-' => now
  local e="$1"
  if [ "$e" = "-" ]; then date -u +%Y-%m-%dT%H:%M:%SZ; return; fi
  date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || echo "$e"
}

[ "${1:-}" = "capture" ] || { echo "usage: outcome_baseline.sh capture --store PATH --repo PATH [...]" >&2; exit 64; }
shift

STORE=""; REPO="."; TRUNK="main"; WEEKS="8"; SINCE=""; UNTIL=""; NOW=""
HOST=""; HOST_REPO=""; HOST_STATE=""; JOURNEYS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --store) STORE="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --trunk) TRUNK="$2"; shift 2;;
    --weeks) WEEKS="$2"; shift 2;;
    --since) SINCE="$2"; shift 2;;
    --until) UNTIL="$2"; shift 2;;
    --now) NOW="$2"; shift 2;;
    --host) HOST="$2"; shift 2;;
    --host-repo) HOST_REPO="$2"; shift 2;;
    --host-state) HOST_STATE="$2"; shift 2;;
    --journeys) JOURNEYS="$2"; shift 2;;
    *) echo "outcome_baseline: unknown arg: $1" >&2; exit 64;;
  esac
done
[ -n "$STORE" ] || { echo "outcome_baseline: --store required" >&2; exit 64; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM

# DORA (Class-D, retroactive)
dora_args=(--repo "$REPO" --trunk "$TRUNK" --weeks "$WEEKS")
[ -n "$SINCE" ] && dora_args+=(--since "$SINCE")
[ -n "$UNTIL" ] && dora_args+=(--until "$UNTIL")
[ -n "$NOW" ]   && dora_args+=(--now "$NOW")
[ -n "$HOST" ]  && dora_args+=(--host "$HOST")
[ -n "$HOST_REPO" ]  && dora_args+=(--host-repo "$HOST_REPO")
[ -n "$HOST_STATE" ] && dora_args+=(--host-state "$HOST_STATE")
py "$PYDORA" "${dora_args[@]}" > "$TMP/dora.json" || { echo "outcome_baseline: DORA derivation failed" >&2; exit 65; }

asm_args=(--dora-file "$TMP/dora.json" --kind baseline)

# Emission share (Class-A) from the ONE baseline audit run, if a journeys.json is given.
if [ -n "$JOURNEYS" ]; then
  py "$PYEMIT" --journeys "$JOURNEYS" > "$TMP/emit.json" || true
  asm_args+=(--emission-file "$TMP/emit.json")
  note="$(py - "$TMP/emit.json" <<'PYN' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    if d.get("note"): print(d["note"])
except Exception: pass
PYN
)"
  [ -n "${note:-}" ] && echo "outcome_baseline: $note"
fi

CAPTURED_AT="$(iso_utc "${NOW:--}")"
GIT_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
asm_args+=(--captured-at "$CAPTURED_AT" --git-sha "$GIT_SHA")

py "$PYASM" "${asm_args[@]}" > "$TMP/snapshot.json" || { echo "outcome_baseline: assemble failed" >&2; exit 64; }

bash "$STORE_SH" write-baseline --store "$STORE" --snapshot-file "$TMP/snapshot.json"
rc=$?
[ "$rc" -eq 0 ] && echo "outcome_baseline: baseline captured + frozen at $CAPTURED_AT (git_sha=$GIT_SHA)"
exit "$rc"
