#!/usr/bin/env bash
# outcome_annotate.sh — the human-annotated fallback for external outcome facts
# (ADR 0023; OM-05/OM-06). When no deterministic source is configured for an
# external metric (defect-escape, incident count/MTTR, paged-share), an operator
# may enter the value BY HAND. It is stored honesty_class: human-annotated — NEVER
# presented as derived, NEVER model-estimated. This is the ONLY way a non-derived
# number enters the store, and it is always labeled as such.
#
# Usage:
#   outcome_annotate.sh <metric-name> --store PATH --value V
#       [--unit U] [--count N] [--window W] [--now E] [--repo P]
#   e.g. outcome_annotate.sh defect-escape --store S --count 3 --window 8w --value 0.05
#
# Exit: 0 ok · 4 schema-invalid · 5 store corrupt · 64 usage.
# Report-only: writes ONLY the store; opens no PR, files no finding.
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYASM="$HERE/outcome_assemble.py"
STORE_SH="$HERE/outcome_store.sh"
py() { if command -v uv >/dev/null 2>&1 && [ -f "$HERE/../pyproject.toml" ]; then uv run --no-project python "$@"; else python3 "$@"; fi; }
iso_utc() { local e="$1"; if [ "$e" = "-" ]; then date -u +%Y-%m-%dT%H:%M:%SZ; return; fi
  date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$e"; }

[ $# -ge 1 ] || { echo "usage: outcome_annotate.sh <metric-name> --store PATH --value V [...]" >&2; exit 64; }
METRIC="$1"; shift
# normalize a kebab metric label to the store's snake metric name.
case "$METRIC" in
  defect-escape) MNAME="defect_escape_rate" ;;
  incident-count) MNAME="incident_count" ;;
  mttr-incident) MNAME="mttr_incident" ;;
  paged-share) MNAME="paged_share" ;;
  *) MNAME="$METRIC" ;;
esac

STORE=""; VALUE=""; UNIT="ratio"; COUNT=""; WINDOW=""; NOW=""; REPO="."
while [ $# -gt 0 ]; do
  case "$1" in
    --store) STORE="$2"; shift 2;;
    --value) VALUE="$2"; shift 2;;
    --unit) UNIT="$2"; shift 2;;
    --count) COUNT="$2"; shift 2;;
    --window) WINDOW="$2"; shift 2;;
    --now) NOW="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    *) echo "outcome_annotate: unknown arg: $1" >&2; exit 64;;
  esac
done
[ -n "$STORE" ] || { echo "outcome_annotate: --store required" >&2; exit 64; }
[ -n "$VALUE" ] || { echo "outcome_annotate: --value required" >&2; exit 64; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM
# build the human-annotated metric row (report-only, explicitly labeled).
MNAME="$MNAME" VALUE="$VALUE" UNIT="$UNIT" COUNT="$COUNT" WINDOW="$WINDOW" \
py - > "$TMP/row.json" <<'PYROW'
import json, os
prov = "annotated:operator"
extra = []
if os.environ.get("COUNT"):  extra.append("count=%s" % os.environ["COUNT"])
if os.environ.get("WINDOW"): extra.append("window=%s" % os.environ["WINDOW"])
if extra: prov += " (" + " ".join(extra) + ")"
try:
    val = float(os.environ["VALUE"])
    if val == int(val): val = int(val) if os.environ.get("UNIT") == "count" else val
except ValueError:
    val = None
row = {"name": os.environ["MNAME"], "value": val, "unit": os.environ["UNIT"] or None,
       "honesty_class": "human-annotated", "provenance": prov}
print(json.dumps({"ok": True, "metrics": [row]}))
PYROW

CAPTURED_AT="$(iso_utc "${NOW:--}")"
GIT_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
py "$PYASM" --metrics-file "$TMP/row.json" --kind annotate --captured-at "$CAPTURED_AT" --git-sha "$GIT_SHA" \
  > "$TMP/snapshot.json" || { echo "outcome_annotate: assemble failed" >&2; exit 64; }
bash "$STORE_SH" append-run --store "$STORE" --snapshot-file "$TMP/snapshot.json"
rc=$?
[ "$rc" -eq 0 ] && echo "outcome_annotate: appended HUMAN-ANNOTATED $MNAME=$VALUE at $CAPTURED_AT (never presented as derived)"
exit "$rc"
