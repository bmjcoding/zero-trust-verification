#!/usr/bin/env bash
# validate_plan_mapping.sh
#
# GENERATE Step G4 plan validator over the planner's emitted plan (AV3-07 + AV3-02).
# Deterministic gate the orchestrator runs after G3/G3.5 on the union of planner
# output. Two concerns, both refusing with `[GENERATE-FAILED: <token>]`:
#
#   AV3-07 (48-hour Story sizing invariant, ADR 0012) — always checked:
#     * every Subtask carries an integer `predicted_hours`
#     * S/M/L sanity: predicted_hours <= {S:4, M:16, L:48}[estimated_size]
#       (an L-labeled Subtask predicting >48 is schema-inconsistent)
#         -> [GENERATE-FAILED: story-size-inconsistent: <subtask-id>]
#     * per-Story roll-up (sum of the Story's Subtasks' predicted_hours) must be
#       <= 48; a Story predicting more is oversized and must be split into
#       sequential, independently mergeable Stories
#         -> [GENERATE-FAILED: story-oversized: <story-id>]
#
#   AV3-02 (Subtask -> Behavior-ID mapping, MS §13.6) — checked only when a
#   manifest path is given (see AV3-02 extension below):
#     * every code/test-only Subtask maps >=1 active Behavior ID
#         -> [GENERATE-FAILED: unmapped-subtask: <subtask-id>]
#     * every active Behavior is owned by >=1 Subtask
#         -> [GENERATE-FAILED: unowned-behavior: <behavior-id>]
#     * every mapped Behavior ID exists+active in the manifest
#         -> [GENERATE-FAILED: unknown-behavior: <behavior-id>]
#
# Usage:  validate_plan_mapping.sh <plan.json> [<manifest.yaml>]
# Exit:   0 valid · 1 GENERATE-FAILED (first violation printed) · 64 usage.
#
# plan.json shape (the planner's YAML rendered to JSON by the orchestrator):
#   { "subtasks": [ { "id", "parent_story", "kind",
#                     "estimated_size": "S|M|L", "predicted_hours": <int>,
#                     "behavior_ids": ["B-...", ...] }, ... ] }
#
# Portability: bash 3.2 + BSD userland; jq (already an autopilot dependency).

set -u

PLAN=""
MANIFEST=""

usage() { echo "usage: validate_plan_mapping.sh <plan.json> [<manifest.yaml>]" >&2; exit 64; }

# Positional args: plan (required), manifest (optional).
while (( $# )); do
  case "$1" in
    -*) usage ;;
    *) if [[ -z "$PLAN" ]]; then PLAN="$1"; elif [[ -z "$MANIFEST" ]]; then MANIFEST="$1"; else usage; fi; shift ;;
  esac
done

[[ -n "$PLAN" ]] || usage
[[ -f "$PLAN" ]] || { echo "validate_plan_mapping: plan not found: $PLAN" >&2; exit 64; }
command -v jq >/dev/null 2>&1 || { echo "validate_plan_mapping: jq is required" >&2; exit 64; }
jq -e . "$PLAN" >/dev/null 2>&1 || { echo "validate_plan_mapping: plan is not valid JSON: $PLAN" >&2; exit 64; }

fail() { echo "[GENERATE-FAILED: $1: $2]"; exit 1; }

# ---------------------------------------------------------------------------
# AV3-07 — 48-hour Story sizing invariant (always).
# ---------------------------------------------------------------------------

# Ceiling by declared size.
ceiling_for() { case "$1" in S) echo 4 ;; M) echo 16 ;; L) echo 48 ;; *) echo "" ;; esac; }

# Per-Subtask: predicted_hours present + integer + within its size ceiling.
# Emit "id<TAB>size<TAB>hours" rows for the shell to walk (bash 3.2: no mapfile).
while IFS="$(printf '\t')" read -r sid size hours; do
  [[ -z "$sid" ]] && continue
  case "$hours" in
    ''|*[!0-9]*) fail story-size-inconsistent "$sid" ;;  # missing / non-integer
  esac
  (( hours >= 1 )) || fail story-size-inconsistent "$sid"
  cap="$(ceiling_for "$size")"
  [[ -n "$cap" ]] || fail story-size-inconsistent "$sid"   # estimated_size not S|M|L
  (( hours <= cap )) || fail story-size-inconsistent "$sid"
done < <(jq -r '.subtasks[] | [.id, (.estimated_size // ""), (.predicted_hours // "")] | @tsv' "$PLAN")

# Per-Story roll-up: sum predicted_hours grouped by parent_story; >48 is oversized.
while IFS="$(printf '\t')" read -r story total; do
  [[ -z "$story" ]] && continue
  (( total <= 48 )) || fail story-oversized "$story"
done < <(jq -r '
  [.subtasks[] | {s: (.parent_story // "?"), h: (.predicted_hours // 0)}]
  | group_by(.s)[]
  | [ .[0].s, (map(.h) | add) ] | @tsv' "$PLAN")

# ---------------------------------------------------------------------------
# AV3-02 — Subtask <-> Behavior-ID mapping (MS §13.6). Only when a manifest is
# supplied; manifest-less inputs keep v2.4.0 semantics (no behavior_ids).
# ---------------------------------------------------------------------------
if [[ -n "$MANIFEST" ]]; then
  [[ -f "$MANIFEST" ]] || { echo "validate_plan_mapping: manifest not found: $MANIFEST" >&2; exit 64; }

  # Active manifest Behavior IDs (lifecycle: active only) — the ownership universe.
  # Walk the top-level `behaviors:` block; each item opens with `- id: B-...` and
  # carries a `lifecycle:` line. Withdrawn tombstones are excluded. No YAML lib —
  # the manifest format is regular (bash 3.2 + BSD awk safe).
  active_behaviors="$(awk '
    /^[A-Za-z_]/ { inb = ($0 ~ /^behaviors:/) }
    inb && /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ {
      id=$0; sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/,"",id);
      sub(/[[:space:]]*#.*/,"",id); gsub(/["'"'"']/,"",id); gsub(/[[:space:]]/,"",id);
      cur=id
    }
    inb && /^[[:space:]]*lifecycle:[[:space:]]*/ {
      l=$0; sub(/^[[:space:]]*lifecycle:[[:space:]]*/,"",l);
      sub(/[[:space:]]*#.*/,"",l); gsub(/[[:space:]]/,"",l);
      if (cur != "") { if (l == "active") print cur; cur="" }
    }
  ' "$MANIFEST")"

  # 1. Every code/test-only Subtask maps at least one Behavior ID
  #    (refactor/config/docs are exempt).
  while IFS="$(printf '\t')" read -r sid kind bcount; do
    [[ -z "$sid" ]] && continue
    case "$kind" in
      code|test-only) (( bcount >= 1 )) || fail unmapped-subtask "$sid" ;;
    esac
  done < <(jq -r '.subtasks[] | [.id, (.kind // ""), ((.behavior_ids // []) | length)] | @tsv' "$PLAN")

  # The set of Behavior IDs the plan claims to cover.
  mapped="$(jq -r '.subtasks[] | (.behavior_ids // [])[]' "$PLAN" | sort -u)"

  # 2. Every mapped Behavior ID exists and is active in the manifest.
  while IFS= read -r bid; do
    [[ -z "$bid" ]] && continue
    grep -qxF "$bid" <<<"$active_behaviors" || fail unknown-behavior "$bid"
  done <<< "$mapped"

  # 3. Every active manifest Behavior is owned by at least one Subtask.
  while IFS= read -r bid; do
    [[ -z "$bid" ]] && continue
    grep -qxF "$bid" <<<"$mapped" || fail unowned-behavior "$bid"
  done <<< "$active_behaviors"
fi

echo "OK"
exit 0
