#!/usr/bin/env bash
# outcome_emit.sh — the audit's journey EMISSION-share outcome step (ADR 0023, OM-04).
#
# Reads the LAST journeys.json the journey-walker AGENT already produced and emits
# the suite-unique metric: on CORE journeys, the share of money/auth vital steps
# graded OBSERVED (vs LOG-ONLY / DARK). This is Class-A (agent-graded) — the input
# is agent judgment, so every emitted row is honesty_class: agent-graded with
# provenance journeys.json@<git_sha>. It can NEVER be laundered as [det].
#
# It is a PROJECTION of grades already recorded (H6): it does NOT re-walk and does
# NOT trigger a fresh audit. It is READ-ONLY on the target repo, writes ONLY the
# outcome store, and posts NOTHING (H5 — digest posting is the Marshal's job). It
# emits NO alert_seam / paged-share (H2 — alert seams are external, ADR 0006).
#
# Degrade (loop-safety invariant 4, verbatim from journey-trace.md): an absent /
# corrupt / unknown-schema (> 2) journeys.json emits NO share row + a loud [note],
# NEVER a guessed share. Report-only: exits 0 on every path (ADR 0004).
#
# Usage:
#   outcome_emit.sh --store PATH [--journeys audit/journeys.json] [--repo PATH] [--now EPOCH]
#   (--journeys defaults to <repo>/audit/journeys.json.)
#
# Portability: bash 3.2 (macOS) + BSD userland safe.
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/../../.." && pwd)"  # .../cleanup-audit/scripts -> plugins/zero-trust
PYEMIT="$PLUGIN_ROOT/scripts/outcome_emission.py"
PYASM="$PLUGIN_ROOT/scripts/outcome_assemble.py"
STORE_SH="$PLUGIN_ROOT/scripts/outcome_store.sh"

# stdlib-only runner via the plugin's shared _py_run.sh (ADR 0025 Wave 4).
. "$(cd "$HERE" && pwd -P)/../../../scripts/_py_run.sh"
py() { py_run_noproj "$@"; }
iso_utc() { local e="$1"; if [ "$e" = "-" ]; then date -u +%Y-%m-%dT%H:%M:%SZ; return; fi
  date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$e"; }

STORE=""; JOURNEYS=""; REPO="."; NOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --store) STORE="$2"; shift 2;;
    --journeys) JOURNEYS="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --now) NOW="$2"; shift 2;;
    *) echo "outcome_emit: unknown arg: $1" >&2; exit 64;;
  esac
done
[ -n "$STORE" ] || { echo "outcome_emit: --store PATH required" >&2; exit 64; }
[ -n "$JOURNEYS" ] || JOURNEYS="$REPO/audit/journeys.json"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM

py "$PYEMIT" --journeys "$JOURNEYS" > "$TMP/emit.json" 2>/dev/null || true

# Read the projector's ok flag + note (report-only: never crash the audit).
ok="$(py - "$TMP/emit.json" <<'PYOK' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print("1" if d.get("ok") else "0")
    if d.get("note"): sys.stderr.write(d["note"]+"\n")
except Exception:
    print("0")
PYOK
)"
note="$(py - "$TMP/emit.json" <<'PYNOTE' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    if d.get("note"): print(d["note"])
except Exception: pass
PYNOTE
)"

if [ "${ok:-0}" != "1" ]; then
  echo "outcome_emit: ${note:-[note] no emission share emitted (degrade — no fabricated metric)}"
  echo "outcome_emit: nothing written to the store (report-only, degrade-to-less-action)"
  exit 0
fi
[ -n "${note:-}" ] && echo "outcome_emit: $note"

CAPTURED_AT="$(iso_utc "${NOW:--}")"
GIT_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
py "$PYASM" --emission-file "$TMP/emit.json" --kind audit-emit --captured-at "$CAPTURED_AT" --git-sha "$GIT_SHA" \
  > "$TMP/snapshot.json" || { echo "outcome_emit: assemble failed (nothing written)" >&2; exit 0; }

if bash "$STORE_SH" append-run --store "$STORE" --snapshot-file "$TMP/snapshot.json"; then
  echo "outcome_emit: appended agent-graded emission share at $CAPTURED_AT -> $STORE"
else
  echo "outcome_emit: store write refused (corrupt/unknown store) — nothing written (degrade-to-less-action)" >&2
fi
exit 0
