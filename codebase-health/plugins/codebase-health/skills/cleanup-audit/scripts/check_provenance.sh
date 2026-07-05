#!/usr/bin/env bash
# CH-07 — SG-8 provenance check + main-lineage ID reservation (spec-gen SG-8, MS §6).
#
# Two deterministic checks at the PR Gate:
#
#  1. PROVENANCE (SG-8 hard-contract 1, hand-edit defense). The manifest has
#     exactly ONE writer — the spec tier (MS §7). A diff that touches the
#     manifest's `confirmation`, `completeness`, or `interrogation.log` fields
#     from a NON-spec-session branch is a hand-edit. Branch provenance is
#     deterministic (branch name / spec-session marker). Per ⟨CH-AMEND-C⟩ + the
#     MS §9 spec_hash precedent, this ships COMMENT-ONLY; promoting it into the
#     ADR-0004 blocking defaults is a Bailey risk-appetite call, flagged here,
#     NOT applied.
#
#  2. MAIN-LINEAGE ID RESERVATION (MS §6, ⟨MS-AMEND-3⟩). IDs are reserved on
#     main's lineage ONLY: a never-merged branch revision does not reserve; a
#     Spec rejected at product approval frees its IDs. This is the history half
#     of CH-09's reuse/renumber check, scoped to main-lineage revisions.
#
# Loop-safety: REPORTER. Reads the diff + git history; mutates nothing; exits 0
# (the provenance finding is comment-only — it never gates here).
#
# Usage:  check_provenance.sh <base-ref> <branch-meta> [--manifest P] [--main-ref REF]
#   <branch-meta> is a file (lines `branch:` / `spec_session:`) or a bare branch name.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=manifest_lib.sh
. "$SCRIPT_DIR/manifest_lib.sh"

BASE=""; BRANCH_META=""; MANIFEST=""; MAIN_REF=""
positional=0
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --main-ref) MAIN_REF="${2:-}"; shift 2 ;;
    -*)         echo "[provenance] unknown flag: $1" >&2; shift ;;
    *) if [ "$positional" -eq 0 ]; then BASE="$1"; positional=1; else BRANCH_META="$1"; fi; shift ;;
  esac
done
[ -n "$BASE" ] && [ -n "$BRANCH_META" ] || {
  echo "usage: check_provenance.sh <base-ref> <branch-meta> [--manifest P] [--main-ref REF]" >&2; exit 64; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# ── resolve branch identity + spec-session status from branch-meta ────────────
branch=""; spec_session=0
if [ -f "$BRANCH_META" ]; then
  branch="$(grep -E '^branch:' "$BRANCH_META" 2>/dev/null | head -1 | sed -E 's/^branch:[[:space:]]*//')"
  grep -qiE '^spec_session:[[:space:]]*true' "$BRANCH_META" 2>/dev/null && spec_session=1
else
  branch="$BRANCH_META"
fi
# a `spec/…` branch is a spec session by convention even without an explicit marker
printf '%s' "$branch" | grep -qE '^spec/' && spec_session=1

# ── check 1: provenance of manifest single-writer fields ─────────────────────
# changed lines (added or removed) on the manifest, scoped to it when known.
if [ -n "$MANIFEST" ]; then
  CHANGED="$(git diff -U0 "$BASE" -- "$MANIFEST" 2>/dev/null | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)')"
else
  CHANGED="$(git diff -U0 "$BASE" -- '*.yaml' '*.yml' 2>/dev/null | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)')"
fi
# the manifest's single-writer fields (MS §7): confirmation / completeness / the
# interrogation.log (resolved_by / confirmed_by / dissent / DL-ids).
PROV_RE='(confirmation|completeness|interrogation|resolved_by|confirmed_by|dissent):|DL-[0-9]{3}'
touched_singlewriter=0
printf '%s\n' "$CHANGED" | grep -qE "$PROV_RE" && touched_singlewriter=1

echo "==> provenance — base=$BASE branch='${branch:-<unknown>}' spec_session=$spec_session"
if [ "$touched_singlewriter" -eq 1 ]; then
  if [ "$spec_session" -eq 1 ]; then
    echo "[clean] provenance: manifest single-writer fields edited from a spec-session branch — the authorized writer (MS §7)"
  else
    echo "[FINDING comment-only] sg8-provenance-hand-edit: manifest confirmation/completeness/interrogation.log edited from NON-spec branch '${branch:-<unknown>}' — the manifest has ONE writer, the spec tier (MS §7; SG-8 hard-contract 1). Ships COMMENT-ONLY (⟨CH-AMEND-C⟩); block-vs-comment flagged for async human review, not applied. fpsrc=${MANIFEST:-<manifest>}:${branch:-branch}:sg8-provenance-hand-edit"
  fi
else
  echo "[clean] provenance: no manifest single-writer field touched by this diff"
fi

# ── check 2: main-lineage ID reservation (feeds CH-09) ───────────────────────
if [ -n "$MANIFEST" ] && [ -n "$MAIN_REF" ] && [ -f "$MANIFEST" ]; then
  reserved="$(chpr_reserved_ids "$MANIFEST" "$MAIN_REF")"
  cur_ids="$(grep -oE "$CHPR_ID_RE" "$MANIFEST" 2>/dev/null | sort -u)"
  echo "==> main-lineage ID reservation (main-ref=$MAIN_REF)"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if printf '%s\n' "$reserved" | grep -qxF "$id"; then
      echo "[reserved] $id — present on main's lineage (reserved forever, MS §6)"
    else
      echo "[not-reserved] $id — only on this never-merged branch; freed if the Spec is rejected at product approval (⟨MS-AMEND-3⟩)"
    fi
  done <<< "$cur_ids"
fi
exit 0
