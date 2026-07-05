#!/usr/bin/env bash
# CH-05 — Memory-rot facet, deterministic layer (ADR 0003 point 1; ADR 0004).
#
# Diff-scoped: for each symbol a diff DELETES (and does not move), grep the
# repo-resident memory — the Verification Manifest, audit/journeys.json, ADRs
# (docs/adr/), and as-built docs — for surviving references. A deleted symbol
# still referenced is grep-provable memory rot: the ADR-0004 BLOCKING class
# "deleted/renamed symbol still referenced by manifest, journeys, docs, or ADRs".
#
# Two suppressions keep it precise (both required by the register):
#   * RENAME / MOVE — a symbol still defined elsewhere in the tree (git log
#     --follow / symbol-grep, the audit-state-and-verify.md rename-is-not-closure
#     machinery) is retargeted, not flagged; the old fingerprint becomes an alias.
#   * TOMBSTONE — a symbol whose manifest entry is `lifecycle: withdrawn` with a
#     `withdrawn_reason` (MS §6) is intentional removal, not rot.
#
# The SEMANTIC layer (an agent judging drift on the flagged excerpts — an ADR the
# code now contradicts, a behavior-changed path) is comment-only (ADR 0004) and
# agent-owned; it is NOT implemented here (blind-eval only). This script is the
# deterministic, grep-provable half — pure shell (git/grep/awk), no toolchain.
#
# Loop-safety: REPORTER. Reads the diff + memory files; mutates nothing; the
# ratchet compares added-lines-only, so inherited references never surface here.
#
# Usage:  check_memory_rot.sh <BASE_REF> [--manifest P] [--journeys P]
set -uo pipefail

BASE=""; MANIFEST=""; JOURNEYS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --journeys) JOURNEYS="${2:-}"; shift 2 ;;
    -*)         echo "[memory-rot] unknown flag: $1" >&2; shift ;;
    *)          BASE="$1"; shift ;;
  esac
done
[ -n "$BASE" ] || { echo "usage: check_memory_rot.sh <BASE_REF> [--manifest P] [--journeys P]" >&2; exit 64; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
if ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1; then
  echo "[memory-rot] cannot resolve base ref '$BASE' — nothing was checked." >&2
  exit 0   # degrade: say so, do less (invariant 4/6); the ratchet never blocks on a bad base here
fi

SLUG="memory-rot-dangling-ref"

# sha1 fingerprint (audit-state-and-verify.md: 12 hex of sha1("<path>:<symbol>:<slug>")).
# Pure-shell: sha1sum (Linux) or shasum -a 1 (macOS); empty if neither exists.
fp() {
  local s="$1:$2:$3"
  if command -v sha1sum >/dev/null 2>&1; then printf '%s' "$s" | sha1sum | cut -c1-12
  elif command -v shasum  >/dev/null 2>&1; then printf '%s' "$s" | shasum -a 1 | cut -c1-12
  fi
}

# Extract def/class/function/const symbol names from a stream of diff lines.
extract_syms() {
  grep -oE '\b(def|class|function)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*|\b(const|let|var)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' 2>/dev/null \
    | sed -E 's/^(def|class|function|const|let|var)[[:space:]]+//' | sort -u
}

DIFF="$(git diff -M "$BASE" -- . 2>/dev/null)"

# Removed vs added symbol sets. A symbol removed here AND added (anywhere) is a
# move/rename, not a deletion — dropped from the deleted set below.
removed_syms="$(printf '%s\n' "$DIFF" | grep -E '^-' | grep -vE '^---' | extract_syms)"
added_syms="$(printf '%s\n'   "$DIFF" | grep -E '^\+' | grep -vE '^\+\+\+' | extract_syms)"

# Map each removed symbol to the file it was removed from (the `--- a/<path>`).
removed_files="$(printf '%s\n' "$DIFF" | awk '
  /^--- a\// { af=substr($0,7) }
  /^-/ && $0 !~ /^---/ {
    line=$0
    if (match(line, /(def|class|function)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
      s=substr(line,RSTART,RLENGTH); sub(/^(def|class|function)[ \t]+/,"",s); print af "\t" s
    } else if (match(line, /(const|let|var)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
      s=substr(line,RSTART,RLENGTH); sub(/^(const|let|var)[ \t]+/,"",s); print af "\t" s
    }
  }')"

# Memory set (repo-resident only; PR bodies are GitHub API objects, not files —
# they stay in the semantic layer). Bounded (invariant 1): committed files, md +
# the supplied manifest/journeys; the audit/ output and .git are excluded.
MEM=()
[ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] && MEM+=("$MANIFEST")
[ -n "$JOURNEYS" ] && [ -f "$JOURNEYS" ] && MEM+=("$JOURNEYS")
while IFS= read -r f; do [ -n "$f" ] && MEM+=("$f"); done < <(
  find . -type d \( -name .git -o -name audit -o -name node_modules \) -prune -o \
       -type f -name '*.md' -print 2>/dev/null | sort -u | head -500)

# Still-defined-in-tree probe: a surviving DEFINITION of the symbol anywhere
# (excluding memory docs, which reference by name, never `def`) means it moved.
still_defined() {
  local s="$1"
  grep -rIlE "\b(def|class|function|const|let|var)[[:space:]]+$s\b" . \
    --exclude-dir=.git --exclude-dir=audit --exclude-dir=node_modules 2>/dev/null | head -1
}

# Tombstone probe: the symbol appears inside a manifest list-entry (delimited by
# a 2-space `- ` marker; nested step lists indent deeper and fold into the parent)
# that also carries `lifecycle: withdrawn`. MS §6 intentional removal, not rot.
tombstoned() {
  local s="$1"
  [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || return 1
  awk -v sym="$s" '
    function checkentry() { if (have && buf ~ ("(^|[^A-Za-z0-9_])" sym "([^A-Za-z0-9_]|$)") && buf ~ /lifecycle:[ \t]*withdrawn/) hit=1 }
    /^  - / { checkentry(); buf=$0 "\n"; have=1; next }
    have    { buf=buf $0 "\n" }
    END     { checkentry(); exit (hit?0:1) }
  ' "$MANIFEST"
}

findings=0
echo "==> memory-rot (deterministic layer) — base=$BASE"
# here-string loop keeps the counter in THIS shell (a `... | while` subshell
# would drop it); removed_syms is small and bounded by the diff.
while IFS= read -r s; do
  [ -n "$s" ] || continue
  # move/rename: still added in this diff OR still defined elsewhere in the tree
  if printf '%s\n' "$added_syms" | grep -qxF "$s"; then
    echo "[rot-suppressed alias] rename: '$s' removed and re-added in this diff (moved) — reference target updated, not rot (fingerprint alias)"
    continue
  fi
  newloc="$(still_defined "$s")"
  if [ -n "$newloc" ]; then
    echo "[rot-suppressed alias] rename: '$s' still defined at $newloc (git-follow/symbol-grep) — reference target updated, not rot (fingerprint alias)"
    continue
  fi
  # tombstone: intentional withdrawal
  if tombstoned "$s"; then
    echo "[rot-suppressed tombstone] '$s' has a lifecycle:withdrawn manifest entry — intentional removal, not rot (MS §6)"
    continue
  fi
  # deleted and not moved/tombstoned: any surviving reference in memory is rot
  path="$(printf '%s\n' "$removed_files" | awk -F'\t' -v s="$s" '$2==s{print $1; exit}')"
  [ -n "$path" ] || path="<unknown-path>"
  refs=""
  if [ "${#MEM[@]}" -gt 0 ]; then
    refs="$(grep -lE "\b$s\b" "${MEM[@]}" 2>/dev/null | sort -u | tr '\n' ' ')"
  fi
  if [ -n "$refs" ]; then
    h="$(fp "$path" "$s" "$SLUG")"
    echo "[FINDING blocking] $SLUG: '$s' deleted from $path but still referenced by: ${refs% } (deterministic; ADR-0004 blocking class) fpsrc=$path:$s:$SLUG${h:+ fp=$h}"
    findings=$((findings+1))
  fi
done <<< "$removed_syms"

echo "==> memory-rot done — $findings dangling-ref finding(s). (Semantic-drift layer is agent-owned, comment-only — ADR 0004.)"
# memory-rot-dangling-ref is the ADR-0004 BLOCKING class: a real dangling ref
# raises the CI-surface exit so a human-wired gate — and pr_gate's aggregate
# high-water — can consult it, exactly like check_behavior_coverage.sh (CH-06)
# and check_manifest_history.sh (CH-09) do for their blocking classes. Still a
# reporter: nothing is mutated, and this facet never runs on the warn-only hook
# surface (which stays exit-0 unconditionally).
[ "$findings" -eq 0 ] && exit 0 || exit 1
