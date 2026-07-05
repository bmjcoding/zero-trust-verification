#!/usr/bin/env bash
# manifest_revision_gate.sh
#
# Manifest-revision drift gate (MS §6 / AV3-04), extracted so both halves are
# deterministically testable:
#
#   drift  <tracker> <manifest>   D1 hydrate check. Compares the tracker's
#          recorded `manifest_revision` (frozen at GENERATE) against the manifest's
#          current `manifest_revision`. Drift means the Spec was amended by a new
#          revision under a live drain — an EXTERNAL fault: the in-flight Subtask
#          finishes its commit pair, then the drain halts `STATUS: PAUSED —
#          manifest-revision-drift` (no counter increment, NOT --force-bypassable,
#          cron deleted, draft Story PRs stay draft).
#            exit 0 OK / no-manifest (manifest-less drain: check N/A) ·
#            exit 3 DRIFT (prints `DRIFT recorded=<a> current=<b>`) · 64 usage.
#
#   resume-check <tracker>        Resume-mode refusal. A tracker paused with
#          `status_reason: manifest-revision-drift` is NOT plain-resumable — plain
#          resume would re-plan nothing against the new revision. Point the operator
#          at the `--generate --merge` revision-regen path instead.
#            exit 0 resumable · exit 2 REFUSE (prints the revision-regen pointer) · 64 usage.
#
# Portability: bash 3.2 + BSD userland safe. Quoted YAML values tolerated (an
# LLM/yq legitimately writes `manifest_revision: "2"`), mirroring the
# detect_concurrent_drain.sh parsing contract.

set -u

usage() {
  cat >&2 <<EOF
usage: manifest_revision_gate.sh drift <tracker> <manifest>
       manifest_revision_gate.sh resume-check <tracker>
EOF
  exit 64
}

# Read a scalar frontmatter/top-level key: first `key:` line, quotes + inline
# comment stripped. Empty when absent.
yaml_scalar() {  # <file> <key>
  sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" "$1" 2>/dev/null | head -1 \
    | sed 's/[[:space:]]*#.*//; s/^["'\'']//; s/["'\'']$//; s/[[:space:]]*$//'
}

SUB="${1:-}"; shift || usage

case "$SUB" in
  drift)
    TRACKER="${1:-}"; MANIFEST="${2:-}"
    [[ -n "$TRACKER" && -n "$MANIFEST" ]] || usage
    [[ -f "$TRACKER" ]] || { echo "manifest_revision_gate: tracker not found: $TRACKER" >&2; exit 64; }
    [[ -f "$MANIFEST" ]] || { echo "manifest_revision_gate: manifest not found: $MANIFEST" >&2; exit 64; }
    recorded="$(yaml_scalar "$TRACKER" manifest_revision)"
    current="$(yaml_scalar "$MANIFEST" manifest_revision)"
    # Manifest-less drain: the tracker never recorded a revision -> drift is N/A.
    if [[ -z "$recorded" ]]; then echo "NO-MANIFEST"; exit 0; fi
    if [[ -z "$current" ]]; then echo "manifest_revision_gate: manifest has no manifest_revision" >&2; exit 64; fi
    if [[ "$recorded" == "$current" ]]; then echo "OK recorded=$recorded"; exit 0; fi
    echo "DRIFT recorded=$recorded current=$current"
    exit 3
    ;;
  resume-check)
    TRACKER="${1:-}"
    [[ -n "$TRACKER" ]] || usage
    [[ -f "$TRACKER" ]] || { echo "manifest_revision_gate: tracker not found: $TRACKER" >&2; exit 64; }
    reason="$(yaml_scalar "$TRACKER" status_reason)"
    if [[ "$reason" == "manifest-revision-drift" ]]; then
      echo "RESUME-REFUSED: manifest-revision-drift — re-run with '--generate --merge' (revision-regen mode); plain --resume cannot re-plan open Subtasks against the new revision"
      exit 2
    fi
    echo "RESUMABLE"
    exit 0
    ;;
  *) usage ;;
esac
