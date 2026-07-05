#!/usr/bin/env bash
# CH-09 — spec_hash recompute · manifest_revision monotonicity · ID reuse/renumber
# (MS §9/§11/§13.11). The three history-based checks the single-file validator
# explicitly DEFERS to the PR Gate ("history checks belong to the PR Gate"). All
# git-history-based, all deterministic.
#
#   spec_hash recompute (MS §9) — recompute sha256 of the exact committed Spec
#     bytes (`git show :<spec.path> | sha256sum`, byte-for-byte, blob-hashed —
#     CRLF-safe) and compare to spec.spec_hash. Mismatch = a Spec edited without
#     a matching manifest_revision bump = a deterministic memory-rot finding.
#     Ships COMMENT-ONLY (MS §9; promotion to blocking flagged for human review,
#     not applied). Guard ⟨MS-AMEND-1⟩: spec_hash is required only at
#     completeness: complete, so the check runs only on complete manifests.
#
#   manifest_revision monotonicity (MS §3/§13.11) — compare the PR's revision to
#     the previously committed revision on main's lineage; equal-or-lower with a
#     content change, or a skipped revision, is a FINDING.
#
#   ID reuse/renumber (MS §6/§11/§13.11) — an ID reused for a DIFFERENT entry, an
#     entry renumbered, or a TOMBSTONED (withdrawn) ID reused, is the MS §11
#     BLOCKING class "ID reuse/renumber vs prior revision".
#
# Loop-safety: REPORTER. Reads committed history; mutates nothing. Exit reflects
# the worst finding class for a human-wired CI step (blocking IDs -> 1); spec_hash
# and monotonicity are surfaced but do not gate here (comment-only / report).
#
# Usage:  check_manifest_history.sh <manifest> <base-ref>
#   <base-ref> is a git ref (NOT a second file path): lineage scoping and
#   monotonicity come from committed history (git show <base-ref>:<manifest>),
#   which is what distinguishes a main-lineage revision from a branch revision.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=manifest_lib.sh
. "$SCRIPT_DIR/manifest_lib.sh"

MANIFEST="${1:-}"; BASE="${2:-}"
[ -n "$MANIFEST" ] && [ -n "$BASE" ] || { echo "usage: check_manifest_history.sh <manifest> <base-ref>" >&2; exit 64; }
[ -f "$MANIFEST" ] || { echo "[note] no manifest at '$MANIFEST' — history checks skipped (degrade, invariant 4)"; exit 0; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1; fi; }

# scoped scalar reader: value of <key> inside the top-level `<block>:` mapping.
yaml_scoped() { # $1=file $2=block $3=key
  awk -v blk="$2" -v key="$3" '
    $0 ~ ("^" blk ":") { s=1; next }
    /^[^[:space:]]/ { s=0 }
    s && $0 ~ ("^[[:space:]]*" key ":") { sub("^[[:space:]]*" key ":[[:space:]]*",""); gsub(/^"|"$/,""); print; exit }
  ' "$1"
}
yaml_top() { grep -E "^$2:[[:space:]]" "$1" 2>/dev/null | head -1 | sed -E "s/^$2:[[:space:]]*//; s/^\"|\"$//g"; }

# id<TAB>label<TAB>lifecycle for every entry (behaviors: title; journeys: name).
id_map() {
  awk '
    /^[[:space:]]*-?[[:space:]]*id:[[:space:]]*[JB]-/ {
      if (curid) print curid "\t" label "\t" life
      match($0, /[JB]-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{3}/); curid=substr($0,RSTART,RLENGTH); label=""; life="active"; next
    }
    /^[[:space:]]*(title|name):/ && curid != "" && label=="" { line=$0; sub(/^[[:space:]]*(title|name):[[:space:]]*/,"",line); gsub(/^"|"$/,"",line); label=line }
    /lifecycle:[[:space:]]*withdrawn/ && curid != "" { life="withdrawn" }
    END { if (curid) print curid "\t" label "\t" life }
  '
}

worst=0
echo "==> manifest history — manifest=$MANIFEST base=$BASE"

# prior revision on main's lineage (may be absent if the manifest is new here).
PRIOR="$(git show "$BASE:$MANIFEST" 2>/dev/null || true)"

# ── check 1: spec_hash recompute (only at completeness: complete) ─────────────
completeness="$(yaml_top "$MANIFEST" completeness)"
if [ "$completeness" = "complete" ]; then
  specpath="$(yaml_scoped "$MANIFEST" spec path)"; specpath="${specpath#./}"
  declared="$(yaml_scoped "$MANIFEST" spec spec_hash)"
  if [ -n "$specpath" ]; then
    # Pipe the blob straight into sha256 — NEVER capture the bytes via $(...),
    # which strips trailing newlines and would diverge from the canonical
    # `git show :<path> | sha256sum` definition (byte-for-byte, CRLF-safe, MS §9).
    actual=""
    if git cat-file -e ":$specpath" 2>/dev/null; then
      actual="sha256:$(git show ":$specpath" | sha256)"
    elif git cat-file -e "HEAD:$specpath" 2>/dev/null; then
      actual="sha256:$(git show "HEAD:$specpath" | sha256)"
    fi
    if [ -n "$actual" ]; then
      if [ "$actual" = "$declared" ]; then
        echo "[clean] spec_hash: recomputed $actual matches spec.spec_hash"
      else
        echo "[FINDING comment-only] spec-hash-rot: spec '$specpath' bytes hash $actual != declared $declared — Spec edited without a matching manifest_revision bump (deterministic memory-rot, MS §9). Ships COMMENT-ONLY; promotion to ADR-0004 blocking flagged for human review, not applied. fpsrc=$MANIFEST:$specpath:spec-hash-rot"
      fi
    else
      echo "[note] spec_hash: spec bytes for '$specpath' not found in git — cannot recompute (degrade)"
    fi
  fi
else
  echo "[note] spec_hash: manifest completeness='${completeness:-?}' (not complete) — spec_hash not required, check skipped (⟨MS-AMEND-1⟩)"
fi

# ── check 2: manifest_revision monotonicity ──────────────────────────────────
cur_rev="$(yaml_top "$MANIFEST" manifest_revision)"
if [ -n "$PRIOR" ]; then
  prior_rev="$(printf '%s\n' "$PRIOR" | grep -E '^manifest_revision:[[:space:]]' | head -1 | sed -E 's/^manifest_revision:[[:space:]]*//')"
  content_changed=0
  [ "$(printf '%s' "$PRIOR")" != "$(cat "$MANIFEST")" ] && content_changed=1
  if [ -n "$cur_rev" ] && [ -n "$prior_rev" ]; then
    if [ "$content_changed" -eq 1 ] && [ "$cur_rev" -le "$prior_rev" ]; then
      echo "[FINDING] manifest-revision-non-monotonic: manifest changed but revision $cur_rev <= prior $prior_rev — a content change must bump the revision (MS §3/§13.11) fpsrc=$MANIFEST:<module>:manifest-revision-non-monotonic"
    elif [ "$cur_rev" -gt $((prior_rev + 1)) ]; then
      echo "[FINDING] manifest-revision-skip: revision jumped $prior_rev -> $cur_rev (skipped $((prior_rev + 1))) — revisions are consecutive on a lineage (MS §3/§13.11) fpsrc=$MANIFEST:<module>:manifest-revision-skip"
    else
      echo "[clean] manifest_revision: $prior_rev -> $cur_rev monotonic"
    fi
  fi
else
  echo "[note] manifest_revision: no prior revision at $BASE — first appearance on this lineage (nothing to compare)"
fi

# ── check 3: ID reuse / renumber / tombstone-reuse ───────────────────────────
if [ -n "$PRIOR" ]; then
  CUR_MAP="$(id_map < "$MANIFEST")"
  PRIOR_MAP="$(printf '%s\n' "$PRIOR" | id_map)"
  id_findings=0
  # reuse + tombstone-reuse: same ID, entry changed (label differs), or a
  # withdrawn ID resurrected.
  while IFS="$(printf '\t')" read -r id label life; do
    [ -n "$id" ] || continue
    prior_line="$(printf '%s\n' "$PRIOR_MAP" | awk -F'\t' -v i="$id" '$1==i{print; exit}')"
    [ -n "$prior_line" ] || continue
    plabel="$(printf '%s' "$prior_line" | cut -f2)"; plife="$(printf '%s' "$prior_line" | cut -f3)"
    if [ "$plife" = "withdrawn" ] && { [ "$life" = "active" ] || [ "$label" != "$plabel" ]; }; then
      echo "[FINDING blocking] id-tombstone-reuse: $id was tombstoned (lifecycle:withdrawn) on the prior revision but is reused here ('$label') — tombstoned IDs are reserved forever (MS §6) fpsrc=$MANIFEST:$id:id-tombstone-reuse"
      id_findings=$((id_findings+1))
    elif [ "$label" != "$plabel" ] && [ -n "$plabel" ]; then
      echo "[FINDING blocking] id-reuse: $id bound to a different entry ('$plabel' -> '$label') vs the prior revision (MS §11 blocking class) fpsrc=$MANIFEST:$id:id-reuse"
      id_findings=$((id_findings+1))
    fi
  done <<< "$CUR_MAP"
  # renumber: same label, different ID.
  while IFS="$(printf '\t')" read -r id label life; do
    [ -n "$label" ] || continue
    pid="$(printf '%s\n' "$PRIOR_MAP" | awk -F'\t' -v l="$label" '$2==l{print $1; exit}')"
    if [ -n "$pid" ] && [ "$pid" != "$id" ]; then
      echo "[FINDING blocking] id-renumber: entry '$label' renumbered $pid -> $id vs the prior revision (MS §11 blocking class) fpsrc=$MANIFEST:$id:id-renumber"
      id_findings=$((id_findings+1))
    fi
  done <<< "$CUR_MAP"
  [ "$id_findings" -eq 0 ] && echo "[clean] id reuse/renumber: no ID reused for a different entry, no renumber, no tombstone-reuse"
  [ "$id_findings" -gt 0 ] && worst=1
fi

echo "==> manifest history done."
exit "$worst"
