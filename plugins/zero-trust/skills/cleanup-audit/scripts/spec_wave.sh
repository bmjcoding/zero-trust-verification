#!/usr/bin/env bash
# spec_wave.sh — deterministic SPEC.md wave parser (health-loop substrate, ADR 0024).
#
# The /health-loop drain slices `audit/SPEC.md` into per-wave input docs for
# `/autopilot --generate` and joins each wave's items back to `audit/state.json`
# via their Fingerprint fields. This script owns ALL of that parsing — the
# orchestrating command holds no opinion about the spec's shape (the /remediate
# posture: wiring, not a checker).
#
# It reads the spec-format.md contract verbatim:
#   wave header : `## Wave <N> — <title>`   (spec-format.md "Document shape")
#   item header : `### [TAG] <short title>`
#   fingerprint : `- **Fingerprint**: `hex``
#   depends-on  : `- **Depends on**: TAG, TAG` (absent / "none" → no deps)
#
# Subcommands:
#   waves        <SPEC.md>              One `N<TAB>title<TAB>item_count` line per wave.
#                                       Exit 3 when the doc has NO wave headers
#                                       (hand-written / pre-1.4 spec — refuse, never guess).
#   slice        <SPEC.md> <N> [--out <dir>]
#                                       Write `<dir>/wave-<N>.md` (default: `<spec-dir>/waves/`)
#                                       = doc title + `## Summary` + the FULL Wave N section,
#                                       byte-preserved (silent truncation is a defect —
#                                       loop-safety invariant 6). Prints the written path.
#                                       Exit 4 wave absent · exit 6 wave has zero items ·
#                                       exit 7 out dir/file unwritable (fail closed).
#   fingerprints <SPEC.md> <N>          One fingerprint per line for Wave N's items.
#                                       Exit 4 wave absent · exit 5 if ANY item in the
#                                       wave lacks a Fingerprint field (spec defect,
#                                       loud) · exit 6 wave has zero items.
#   forward-deps <SPEC.md> <N>          Print `TAG wave=<M>` for every `Depends on` TAG of
#                                       Wave N that lives in a LATER wave (M > N), and
#                                       `TAG unresolved` for any tag-shaped dep that names
#                                       NO item in the doc (a dep that can never be
#                                       satisfied must refuse too — silent truncation is
#                                       a defect); exit 1 if any exist (refuse before
#                                       generate). Backward deps are fine — those waves
#                                       merged already.
#
# Writes only under the spec's own directory (the `audit/` detection-artifact
# namespace — loop-safety invariant 1). Never touches product code, state.json,
# or the repo tree.
#
# Portability: bash 3.2 (macOS default) + BSD userland safe. No associative
# arrays; no `grep -P`; awk is POSIX. LC_ALL=C so the em-dash in wave headers
# is matched as opaque bytes, never locale-collated.
set -uo pipefail
LC_ALL=C
export LC_ALL

usage() {
  echo "usage: spec_wave.sh waves|slice|fingerprints|forward-deps <SPEC.md> [<N>] [--out <dir>]" >&2
  exit 64
}

# Shared awk prologue: track the current `## Wave N` section and the current
# `### [TAG]` item. Wave headers are matched structurally (`## Wave <digits>`
# then a separator) so title text can never confuse the parser.
AWK_WAVE_PRELUDE='
  function wave_of(line) {
    if (line ~ /^## Wave [0-9]+([^0-9]|$)/) {
      n = line; sub(/^## Wave /, "", n); sub(/[^0-9].*$/, "", n)
      return n + 0
    }
    return -1
  }
'

SUB="${1:-}"; [ -n "$SUB" ] || usage
shift

SPEC="${1:-}"; [ -n "$SPEC" ] || usage
shift || true
[ -f "$SPEC" ] || { echo "spec_wave: spec not found: $SPEC" >&2; exit 64; }

require_waves() {
  # Refuse (exit 3) when the doc has no wave structure at all — a wave-less
  # spec is not an error in the doc, it is this tool being the wrong tool.
  if ! grep -qE '^## Wave [0-9]+' "$SPEC"; then
    echo "spec_wave: no '## Wave N' headers in $SPEC — not a wave-structured spec (refusing, never guessing)" >&2
    exit 3
  fi
}

case "$SUB" in
  waves)
    [ $# -eq 0 ] || usage
    require_waves
    awk "$AWK_WAVE_PRELUDE"'
      {
        w = wave_of($0)
        if (w >= 0) {
          if (cur != "") printf "%s\t%s\t%d\n", cur, title, items
          cur = w
          title = $0
          sub(/\r$/, "", title)
          sub(/^## Wave [0-9]+[[:space:]]*/, "", title)
          # strip a leading separator token (em-dash, hyphen) but never a word
          if (title ~ /^[^A-Za-z0-9(]/) sub(/^[^[:space:]]+[[:space:]]*/, "", title)
          items = 0
          next
        }
        if (cur != "" && $0 ~ /^### \[/) items++
        # a new non-wave H2 ends the current wave section
        if (cur != "" && $0 ~ /^## / && wave_of($0) < 0) { printf "%s\t%s\t%d\n", cur, title, items; cur = "" }
      }
      END { if (cur != "") printf "%s\t%s\t%d\n", cur, title, items }
    ' "$SPEC"
    ;;

  slice)
    N="${1:-}"; [ -n "$N" ] || usage
    shift
    OUT_DIR=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --out) OUT_DIR="${2:-}"; [ -n "$OUT_DIR" ] || usage; shift 2 ;;
        *) usage ;;
      esac
    done
    case "$N" in (*[!0-9]*|'') usage ;; esac
    require_waves
    if ! grep -qE "^## Wave 0*${N}([^0-9]|\$)" "$SPEC"; then
      echo "spec_wave: Wave $N not present in $SPEC" >&2
      exit 4
    fi
    [ -n "$OUT_DIR" ] || OUT_DIR="$(dirname "$SPEC")/waves"
    mkdir -p "$OUT_DIR" || { echo "spec_wave: cannot create out dir: $OUT_DIR (fail closed, exit 7)" >&2; exit 7; }
    OUT_FILE="$OUT_DIR/wave-${N}.md"
    # Byte-preserving extraction: doc title line + `## Summary` section + the
    # full Wave N section (header through the next `^## ` or EOF).
    awk -v want="$N" "$AWK_WAVE_PRELUDE"'
      NR == 1 && $0 ~ /^# / { print; print ""; next }
      /^## Summary([^A-Za-z]|$)/ { insum = 1; print; next }
      {
        w = wave_of($0)
        if (w >= 0)            { insum = 0; inwave = (w == want); if (inwave) print; next }
        if ($0 ~ /^## /)       { insum = 0; inwave = 0 }
        if (insum || inwave) print
      }
    ' "$SPEC" > "$OUT_FILE" || { rm -f "$OUT_FILE"; echo "spec_wave: cannot write $OUT_FILE (fail closed, exit 7)" >&2; exit 7; }
    ITEMS="$(grep -cE '^### \[' "$OUT_FILE" || true)"
    if [ "${ITEMS:-0}" -eq 0 ]; then
      rm -f "$OUT_FILE"
      echo "spec_wave: Wave $N has zero items — nothing to drain (not writing an empty slice)" >&2
      exit 6
    fi
    echo "$OUT_FILE"
    ;;

  fingerprints)
    N="${1:-}"; [ -n "$N" ] || usage
    [ $# -eq 1 ] || usage
    case "$N" in (*[!0-9]*|'') usage ;; esac
    require_waves
    grep -qE "^## Wave 0*${N}([^0-9]|\$)" "$SPEC" || { echo "spec_wave: Wave $N not present in $SPEC" >&2; exit 4; }
    # Emit `fp` per item; an item with no Fingerprint field emits `MISSING <tag-line>`
    # so the defect is named, then the whole call fails (exit 5) — a wave item
    # that can't join back to state.json can never be gated, so it must never drain.
    RES="$(awk -v want="$N" "$AWK_WAVE_PRELUDE"'
      {
        w = wave_of($0)
        if (w >= 0)      { inwave = (w == want); next }
        if ($0 ~ /^## /) { inwave = 0 }
        if (!inwave) next
        if ($0 ~ /^### \[/) {
          if (initem && !seenfp) printf "MISSING\t%s\n", itemtag
          initem = 1; seenfp = 0; itemtag = $0; sub(/^### /, "", itemtag)
          next
        }
        if (initem && $0 ~ /^-[[:space:]]*\*\*Fingerprint\*\*:/) {
          fp = $0
          sub(/^-[[:space:]]*\*\*Fingerprint\*\*:[[:space:]]*/, "", fp)
          gsub(/[`[:space:]]/, "", fp)
          if (fp != "") { printf "%s\n", fp; seenfp = 1 }
        }
      }
      END { if (initem && !seenfp) printf "MISSING\t%s\n", itemtag }
    ' "$SPEC")"
    if [ -z "$RES" ]; then
      echo "spec_wave: Wave $N has zero items — nothing to fingerprint" >&2
      exit 6
    fi
    printf '%s\n' "$RES"
    if printf '%s\n' "$RES" | grep -q '^MISSING'; then
      echo "spec_wave: Wave $N has item(s) with no **Fingerprint** field — spec defect, cannot join to state.json" >&2
      exit 5
    fi
    ;;

  forward-deps)
    N="${1:-}"; [ -n "$N" ] || usage
    [ $# -eq 1 ] || usage
    case "$N" in (*[!0-9]*|'') usage ;; esac
    require_waves
    grep -qE "^## Wave 0*${N}([^0-9]|\$)" "$SPEC" || { echo "spec_wave: Wave $N not present in $SPEC" >&2; exit 4; }
    # Pass 1 builds TAG→wave for every item in the doc; pass 2 checks Wave N's
    # `Depends on` TAGs against it. A TAG in a LATER wave is a forward dep —
    # the wave-serialized drain cannot satisfy it — and a tag-shaped dep that
    # resolves to NO item can never be satisfied either; both refuse. Only
    # tag-shaped tokens (`XX-YY`, spec-format "carry the tags verbatim") are
    # judged, so `none` and prose never false-refuse.
    VIOL="$(awk -v want="$N" "$AWK_WAVE_PRELUDE"'
      function tag_of(line,   t) {
        t = line
        if (match(t, /\[[A-Za-z0-9][A-Za-z0-9_-]*\]/)) return substr(t, RSTART + 1, RLENGTH - 2)
        return ""
      }
      NR == FNR {
        w = wave_of($0); if (w >= 0) { cw = w; next }
        if ($0 ~ /^## /) { cw = -1 }
        if (cw > 0 && $0 ~ /^### \[/) { t = tag_of($0); if (t != "") tagwave[t] = cw }
        next
      }
      {
        w = wave_of($0)
        if (w >= 0)      { inwave = (w == want); next }
        if ($0 ~ /^## /) { inwave = 0 }
        if (!inwave) next
        if ($0 ~ /^-[[:space:]]*\*\*Depends on\*\*:/) {
          deps = $0
          sub(/^-[[:space:]]*\*\*Depends on\*\*:[[:space:]]*/, "", deps)
          n = split(deps, toks, /[,[:space:]]+/)
          for (i = 1; i <= n; i++) {
            t = toks[i]
            gsub(/[^A-Za-z0-9_-]/, "", t)
            if (t !~ /^[A-Za-z0-9]+-[A-Za-z0-9_-]+$/) continue
            if (!(t in tagwave))       printf "%s unresolved\n", t
            else if (tagwave[t] > want) printf "%s wave=%d\n", t, tagwave[t]
          }
        }
      }
    ' "$SPEC" "$SPEC")"
    if [ -n "$VIOL" ]; then
      printf '%s\n' "$VIOL"
      echo "spec_wave: Wave $N has forward or unresolvable dependencies above — refuse to drain this wave order" >&2
      exit 1
    fi
    ;;

  *) usage ;;
esac
