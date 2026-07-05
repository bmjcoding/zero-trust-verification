#!/usr/bin/env bash
# validate_manifest.sh --union
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
# Single-file schema/completeness validation is the spec tier's `validate_manifest.sh`
# (vendored per ADR 0001); this autopilot copy owns ONLY the union checks.
#
# Usage:  validate_manifest.sh --union <a.yaml> <b.yaml> [<c.yaml> ...]
# Exit:   0 union-coherent (prints OK) · 1 GENERATE-FAILED (first violation) · 64 usage.
#
# Portability: bash 3.2 + BSD userland safe (no grep -P, no GNU sed).

set -u

usage() {
  echo "usage: validate_manifest.sh --union <a.yaml> <b.yaml> [<c.yaml> ...]" >&2
  echo "  (single-file schema validation is the spec-tier validator, vendored per ADR 0001)" >&2
  exit 64
}

[[ "${1:-}" == "--union" ]] || usage
shift
(( $# >= 2 )) || usage   # a union needs at least two manifests

for f in "$@"; do [[ -f "$f" ]] || { echo "validate_manifest: not found: $f" >&2; exit 64; }; done

fail() { echo "[GENERATE-FAILED: $1: $2]"; exit 1; }

# Journey + Behavior IDs (per §6 grammar), one per line, sorted-unique per file.
extract_union_ids() {  # <file>
  grep -oE '[JB]-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{3}' "$1" 2>/dev/null | sort -u
}

# observability.profile value (indented under `observability:`; take the first).
extract_profile() {  # <file>
  sed -n 's/^[[:space:]]\{1,\}profile:[[:space:]]*//p' "$1" 2>/dev/null \
    | head -1 | sed 's/[[:space:]]*#.*//; s/^["'\'']//; s/["'\'']$//; s/[[:space:]]*$//'
}

# environments as a normalized sorted set (order-insensitive; §3 calls it "the
# primitive" — a set). Handles the inline `[a, b, c]` form the spec tier emits.
extract_environments() {  # <file>
  sed -n 's/^environments:[[:space:]]*//p' "$1" 2>/dev/null | head -1 \
    | sed 's/[][]//g; s/#.*//' | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort | tr '\n' ',' | sed 's/,$//'
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
