#!/usr/bin/env bash
# validate_manifest_union.sh --union
#
# GENERATE Step G4 multi-doc union validation (MS §2 / AV3-03). For a multi-doc
# invocation (`--generate @a.md @b.md`), each Spec ships its own manifest but the
# union must be coherent:
#   * Journey/Behavior IDs are unique across the union (main's-lineage reservation
#     is the PR Gate's job; THIS is the plan-time single-drain collision guard)
#         -> [GENERATE-FAILED: manifest-id-collision: <id>]
#   * observability.profile is identical across unioned manifests
#         -> [GENERATE-FAILED: manifest-union-mismatch: profile]
#   * environments is identical (as a set) across unioned manifests
#         -> [GENERATE-FAILED: manifest-union-mismatch: environments]
#
# Interrogation-log IDs (DL-###) are per-manifest scope (MS §6) and are NOT
# unioned — a DL-001 in each manifest is legal.
#
# Single-file schema/completeness validation is the canonical plugin validator
# (`plugins/zero-trust/scripts/validate_manifest.sh` — the single copy, ADR 0025);
# this script owns ONLY the union checks.
#
# Usage:  validate_manifest_union.sh --union <a.yaml> <b.yaml> [<c.yaml> ...]
# Exit:   0 union-coherent (prints OK) · 1 GENERATE-FAILED (first violation) · 64 usage.
#
# Portability: bash 3.2 + BSD userland safe (no grep -P, no GNU sed).

set -u

usage() {
  echo "usage: validate_manifest_union.sh --union <a.yaml> <b.yaml> [<c.yaml> ...]" >&2
  echo "  (single-file schema validation is the canonical plugin validator — single copy, ADR 0025)" >&2
  exit 64
}

[[ "${1:-}" == "--union" ]] || usage
shift
(( $# >= 2 )) || usage   # a union needs at least two manifests

for f in "$@"; do [[ -f "$f" ]] || { echo "validate_manifest_union: not found: $f" >&2; exit 64; }; done

fail() { echo "[GENERATE-FAILED: $1: $2]"; exit 1; }

# Journey + Behavior IDs (per §6 grammar), one per line, sorted-unique per file.
# ONLY from `id:` declaration lines (`- id: J-…` / `id: B-…`) — never from prose
# (`description:`, comments) that merely *references* another spec's ID, which
# would otherwise register a false union collision and block a legit multi-doc
# GENERATE. Journey/Behavior references (`journey:`, `compensation.ref:`) are not
# declarations and are correctly excluded.
extract_union_ids() {  # <file>
  grep -E '^[[:space:]]*(-[[:space:]]*)?id:[[:space:]]*["'\'']?[JB]-' "$1" 2>/dev/null \
    | grep -oE '[JB]-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{3}' | sort -u
}

# observability.profile value — the `profile:` UNDER `observability:` (not a decoy
# `profile:` under some other block that happens to appear first).
extract_profile() {  # <file>
  awk '
    /^observability:[[:space:]]*(#.*)?$/ { inobs=1; next }
    inobs {
      if ($0 ~ /^[[:space:]]+profile:[[:space:]]*/) {
        p=$0; sub(/^[[:space:]]+profile:[[:space:]]*/,"",p); sub(/[[:space:]]*#.*/,"",p);
        gsub(/["'\'']/,"",p); sub(/[[:space:]]*$/,"",p); print p; exit
      }
      if ($0 ~ /^[A-Za-z_]/) inobs=0
    }
  ' "$1" 2>/dev/null
}

# environments as a normalized sorted set (order-insensitive; §3 calls it "the
# primitive" — a set). Handles BOTH the inline `[a, b, c]` form AND the YAML
# block-list form (`environments:` then `  - a` lines) — a block list must not
# extract to empty and silently pass a genuine union mismatch.
extract_environments() {  # <file>
  awk '
    /^environments:[[:space:]]*\[/ {          # inline: environments: [a, b, c]
      line=$0; sub(/^environments:[[:space:]]*\[/,"",line); sub(/\].*/,"",line);
      n=split(line, a, ","); for(i=1;i<=n;i++){ gsub(/[[:space:]]/,"",a[i]); if(a[i]!="") print a[i] }
      exit
    }
    /^environments:[[:space:]]*(#.*)?$/ { inblk=1; next }   # block: environments:
    inblk {
      if ($0 ~ /^[[:space:]]+-[[:space:]]*/) {
        it=$0; sub(/^[[:space:]]+-[[:space:]]*/,"",it); sub(/[[:space:]]*#.*/,"",it);
        gsub(/["'\'']/,"",it); gsub(/[[:space:]]/,"",it);
        if (it != "") print it; next
      }
      if ($0 ~ /^[A-Za-z_]/) inblk=0            # next top-level key ends the block
    }
  ' "$1" 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//'
}

# --- ID collision across the union (each file contributes each id once, so an id
#     that appears twice in the concatenation came from two files). --------------
dupe="$( { for f in "$@"; do extract_union_ids "$f"; done; } | sort | uniq -d | head -1 )"
[[ -z "$dupe" ]] || fail manifest-id-collision "$dupe"

# --- observability.profile + environments must be identical across the union. --
first_profile="$(extract_profile "$1")"
first_envs="$(extract_environments "$1")"
for f in "$@"; do
  [[ "$(extract_profile "$f")" == "$first_profile" ]] || fail manifest-union-mismatch "profile"
  [[ "$(extract_environments "$f")" == "$first_envs" ]] || fail manifest-union-mismatch "environments"
done

echo "OK"
exit 0
