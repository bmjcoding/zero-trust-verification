# Shared helpers for the manifest-reading PR-Gate siblings (CH-01/03/06/09).
# Sourced, never executed. Extended-regex (grep -E) syntax throughout.
#
# The manifest schema + validator are VENDORED per ADR 0001 (the one permitted
# bootstrap): CH items CONSUME `scripts/validate_manifest.sh` + the vendored
# `schema/verification-manifest/v1.schema.json`, never re-implement the schema.
# In this monorepo the validator lives at the repo root; when the audit plugin
# is installed standalone the vendored copy travels with it. Both cases resolve
# through chpr_find_validator below (env override first, then an upward walk),
# so nothing here hard-codes a path.

# Locate validate_manifest.sh. Resolution order (first hit wins):
#   1. $VALIDATE_MANIFEST env override (the self-test + a vendored install set it)
#   2. walk up from the manifest file's own directory (a real audit: the manifest
#      is colocated with a Spec inside the target repo)
#   3. walk up from $PWD
#   4. walk up from this library's own directory
# Prints the absolute path on stdout and returns 0; returns 1 (silent) if none.
chpr_find_validator() {
  local manifest="${1:-}" d
  if [ -n "${VALIDATE_MANIFEST:-}" ] && [ -x "$VALIDATE_MANIFEST" ]; then
    printf '%s\n' "$VALIDATE_MANIFEST"; return 0
  fi
  local starts=()
  [ -n "$manifest" ] && starts+=("$(cd "$(dirname "$manifest")" 2>/dev/null && pwd)")
  starts+=("$PWD")
  starts+=("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
  for d in "${starts[@]}"; do
    [ -n "$d" ] || continue
    while [ -n "$d" ] && [ "$d" != "/" ]; do
      if [ -x "$d/scripts/validate_manifest.sh" ]; then
        printf '%s\n' "$d/scripts/validate_manifest.sh"; return 0
      fi
      d="$(dirname "$d")"
    done
  done
  return 1
}

# Manifest ID token (journey/behavior): J-.../B-... per the schema regexes.
CHPR_ID_RE='\b[JB]-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{3}\b'

# List the manifest IDs RESERVED on main's lineage (CH-07/CH-09). An ID is
# reserved if it appears in the manifest at ANY commit reachable from <main-ref>
# — so a tombstoned-then-removed ID stays reserved forever (MS §6), and an ID
# that only ever lived on a never-merged branch is NOT reserved (⟨MS-AMEND-3⟩).
# Args: <manifest repo-relative path> <main-ref>. Prints sorted-unique IDs.
chpr_reserved_ids() {
  local path="$1" ref="$2" c
  git rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || return 0
  # git log restricted to <ref> gives only commits on main's lineage (reachable
  # from main-ref) — a never-merged branch's commits are unreachable, so its IDs
  # never appear here.
  for c in $(git log --format=%H "$ref" -- "$path" 2>/dev/null); do
    git show "$c:$path" 2>/dev/null | grep -oE "$CHPR_ID_RE"
  done | sort -u
}

# Read the manifest's declared schema_version (integer) without a YAML parser —
# a top-level `schema_version: N` line. Used only for the loud UNSUPPORTED note;
# the validator remains the authority on the exit-code contract.
chpr_schema_version() {
  local manifest="$1"
  grep -m1 -E '^schema_version:[[:space:]]*[0-9]+' "$manifest" 2>/dev/null \
    | sed -E 's/^schema_version:[[:space:]]*([0-9]+).*/\1/'
}
