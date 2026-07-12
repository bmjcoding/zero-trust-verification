#!/usr/bin/env bash
# outcome_capture.sh — the Marshal's DORA outcome-capture mode (ADR 0023, OM-03).
#
# A NEW retroactive read (ADR 0011: NOT "the stream the Marshal already watches").
# Derives the four DORA-family metrics DETERMINISTICALLY (Class-D) over a trailing
# window — deploy frequency + lead time from `git log` first-parent, change-failure
# rate from reverts + post-merge `build-status`, build-MTTR from `build-status` —
# and appends ONE runs[] row to the outcome store. Every field honesty_class:
# deterministic.
#
# All build-status goes through the host adapter ($MARSHAL_HOST -> host.sh, ADR
# 0013) so Bitbucket DC and GitHub yield the same assertion set. The mode is
# READ-ONLY on the target repo and on every PR: it calls only `build-status`
# (read), NEVER pr-comment / pr-merge / any write, opens no PR, files no finding
# (ADR 0004/0023). It writes ONLY the outcome store.
#
# Usage:
#   marshal.sh outcome-capture --store PATH [--repo PATH] [--trunk main]
#       [--weeks N | --since EPOCH --until EPOCH] [--now EPOCH]
#       [--host HOST_ADAPTER --host-repo GITDIR --host-state STATE]
#   (--host defaults to $MARSHAL_HOST; --repo defaults to CWD, the working clone.)
#
# Exit: 0 ok · 4 schema-invalid · 5 store corrupt · 64 usage · 65 not-a-repo.
# Portability: bash 3.2 (macOS) + BSD userland safe.
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(cd "$HERE/../../.." && pwd)"   # plugins/zero-trust/scripts -> repo root
PYDORA="$SUITE_ROOT/scripts/outcome_dora.py"
PYASM="$SUITE_ROOT/scripts/outcome_assemble.py"
STORE_SH="$SUITE_ROOT/scripts/outcome_store.sh"

py() { if command -v uv >/dev/null 2>&1 && [ -f "$SUITE_ROOT/pyproject.toml" ]; then uv run --no-project python "$@"; else python3 "$@"; fi; }
iso_utc() { local e="$1"; if [ "$e" = "-" ]; then date -u +%Y-%m-%dT%H:%M:%SZ; return; fi
  date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$e"; }

STORE="${OUTCOME_STORE:-}"; REPO="."; TRUNK="${MARSHAL_MAIN:-main}"; WEEKS="8"
SINCE=""; UNTIL=""; NOW=""
HOST="${MARSHAL_HOST:-$HERE/../../autopilot/scripts/host.sh}"; HOST_REPO=""; HOST_STATE=""
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
    --no-host) HOST=""; shift;;
    *) echo "outcome_capture: unknown arg: $1" >&2; exit 64;;
  esac
done
[ -n "$STORE" ] || { echo "outcome_capture: --store PATH (or \$OUTCOME_STORE) required" >&2; exit 64; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM

dora_args=(--repo "$REPO" --trunk "$TRUNK" --weeks "$WEEKS")
[ -n "$SINCE" ] && dora_args+=(--since "$SINCE")
[ -n "$UNTIL" ] && dora_args+=(--until "$UNTIL")
[ -n "$NOW" ]   && dora_args+=(--now "$NOW")
if [ -n "$HOST" ] && [ -f "$HOST" ]; then
  dora_args+=(--host "$HOST")
  [ -n "$HOST_REPO" ]  && dora_args+=(--host-repo "$HOST_REPO")
  [ -n "$HOST_STATE" ] && dora_args+=(--host-state "$HOST_STATE")
fi
py "$PYDORA" "${dora_args[@]}" > "$TMP/dora.json" || { echo "outcome_capture: DORA derivation failed" >&2; exit 65; }

CAPTURED_AT="$(iso_utc "${NOW:--}")"
GIT_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
py "$PYASM" --dora-file "$TMP/dora.json" --kind run --captured-at "$CAPTURED_AT" --git-sha "$GIT_SHA" \
  > "$TMP/snapshot.json" || { echo "outcome_capture: assemble failed" >&2; exit 64; }

bash "$STORE_SH" append-run --store "$STORE" --snapshot-file "$TMP/snapshot.json"
rc=$?
[ "$rc" -eq 0 ] && echo "outcome_capture: appended DORA run at $CAPTURED_AT (git_sha=$GIT_SHA) -> $STORE"
exit "$rc"
