#!/usr/bin/env bash
# detect_input_mode.sh
#
# GENERATE-time mode inference (ADR 0008 / MS §13.5 / AV3-01), extracted as a
# pure decision function so the mode table is deterministically self-tested.
#
# The orchestrator does the I/O: it discovers the input's companion manifest
# (`<spec-basename>.manifest.yaml`), runs `scripts/validate_manifest.sh` on it,
# and passes THIS script the manifest path (or none) plus that validator's exit
# code. This script maps (intent, manifest presence, validator exit, --yolo) to a
# single MODE token — no file reads, no network.
#
# Modes:
#   STRAIGHT_THROUGH  valid+complete manifest (validator exit 0) -> GENERATE->DRAIN,
#                     no pause, no flag (ADR 0008). This is the manifest's payoff.
#   GENERATE_PAUSE    bare markdown (no manifest) OR incomplete manifest (exit 3,
#                     consumable by nothing but a resumed spec session, MS §11) ->
#                     GENERATE then pause for operator review.
#   GENERATE_YOLO     the manifest-LESS `--yolo` override -> GENERATE->DRAIN
#                     immediately, Force-Audit-logged (AP-11). `--yolo` survives
#                     ONLY here; on a complete manifest it is a no-op (warned).
#   DRAIN / RESUME    runbook input under --drain / --resume (unchanged).
#   REFUSE-MANIFEST-INVALID      validator exit 4 -> refuse; never degrade to
#                                manifest-less (MS §11).
#   REFUSE-MANIFEST-UNSUPPORTED  validator exit 5 -> refuse (schema_version > supported).
#
# Usage:
#   detect_input_mode.sh --intent <generate|drain|resume>
#                        [--manifest <path>] [--validator-exit <n>] [--yolo]
# Output: `MODE=<token>` on stdout. A `[note] ...` on stderr for the yolo-no-op.
# Exit:   0 decidable (incl. GENERATE_PAUSE/STRAIGHT_THROUGH/YOLO/DRAIN/RESUME) ·
#         1 a REFUSE-* mode · 64 usage.
#
# Portability: bash 3.2 + BSD userland safe.

set -u

INTENT="generate"
MANIFEST=""
VEXIT=""
YOLO=0

usage() {
  echo "usage: detect_input_mode.sh --intent <generate|drain|resume> [--manifest <path>] [--validator-exit <n>] [--yolo]" >&2
  exit 64
}

while (( $# )); do
  case "$1" in
    --intent)          INTENT="${2:-}"; shift 2 || usage ;;
    --manifest)        MANIFEST="${2:-}"; shift 2 || usage ;;
    --validator-exit)  VEXIT="${2:-}"; shift 2 || usage ;;
    --yolo)            YOLO=1; shift ;;
    *) usage ;;
  esac
done

case "$INTENT" in generate|drain|resume) ;; *) usage ;; esac

emit() { echo "MODE=$1"; }

# Runbook intents are unchanged by the manifest (MS §13.5): --drain -> DRAIN,
# --resume -> RESUME. --yolo is meaningless here.
if [[ "$INTENT" == "drain" ]]; then emit DRAIN; exit 0; fi
if [[ "$INTENT" == "resume" ]]; then emit RESUME; exit 0; fi

# GENERATE intent. Decide the base mode from manifest presence + validator exit.
if [[ -z "$MANIFEST" ]]; then
  base="GENERATE_PAUSE"          # bare markdown: no companion manifest
else
  case "$VEXIT" in
    0) base="STRAIGHT_THROUGH" ;;                 # valid + complete
    3) base="GENERATE_PAUSE" ;;                    # incomplete -> manifest-less semantics
    4) emit REFUSE-MANIFEST-INVALID; exit 1 ;;     # schema-invalid: never degrade (MS §11)
    5) emit REFUSE-MANIFEST-UNSUPPORTED; exit 1 ;; # unsupported schema_version
    ''|*[!0-9]*) echo "detect_input_mode: --manifest given but --validator-exit is missing/invalid ($VEXIT)" >&2; exit 64 ;;
    *) echo "detect_input_mode: unrecognized validator exit code: $VEXIT" >&2; exit 64 ;;
  esac
fi

# Apply --yolo. It is the manifest-LESS override only.
if (( YOLO )); then
  case "$base" in
    STRAIGHT_THROUGH)
      # A complete manifest already goes straight-through; --yolo adds nothing.
      echo "[note] --yolo is a no-op on a complete manifest (already STRAIGHT_THROUGH per ADR 0008)" >&2
      emit STRAIGHT_THROUGH
      ;;
    GENERATE_PAUSE)
      emit GENERATE_YOLO         # skip review, arm the drain; Force-Audit-logged by the orchestrator
      ;;
  esac
  exit 0
fi

emit "$base"
exit 0
