#!/usr/bin/env bash
# sd_seeds.sh — SD-11 honest in-repo SEEDS for the System-Design Coverage tier.
#
# Each seed is a grep that emits CANDIDATES (never verdicts) to an audit/ file,
# every line prefixed `[candidate]`. These are priority INPUTS, not debt: never
# counted, never ratcheted, never gating (the VITAL/TX-seed precedent in
# run_audit.sh). The VERDICT layer (money-path reasoning, DST/date-boundary correctness,
# reversibility, isolation-correctness) stays agent — these seeds only surface the
# in-repo-assessable slivers the SD assessment (§2/§3) explicitly blesses as honest.
#
# Every seed carries a must_not_flag negative in the self-test (Decimal-correct,
# tz-aware, timeout-present, jittered retry, bounded queue, additive migration) so
# a precision regression reds sd_self_test.sh.
#
# DEADLOCK intentionally has NO seed here: a lock-acquisition-order regex is
# precision-hostile and violates the determinism-first "only where honest" clause
# (SD §3.9), so it stays pure agent-judgment. A self-test guard asserts none exists.
#
# Usage:  sd_seeds.sh <target-dir> <out-dir>
# Reporter: reads the target, writes only under <out-dir>, exits 0 always.
# Portability: bash 3.2 (macOS) + BSD grep. `\b` is fine in grep -E (never in sed).
set -uo pipefail

TARGET="${1:-.}"
OUT="${2:-audit}"
mkdir -p "$OUT"

# Dirs we never scan (mirrors run_audit.sh's EXCLUDE_DIRS intent). BSD + GNU grep
# both accept repeated --exclude-dir.
EXC=(--exclude-dir=.git --exclude-dir=.claude --exclude-dir=node_modules \
     --exclude-dir=.venv --exclude-dir=venv --exclude-dir=audit \
     --exclude-dir=build --exclude-dir=target --exclude-dir=vendor \
     --exclude-dir=dist --exclude-dir=__pycache__)

# Shared regexes — SINGLE-SOURCED, never re-declared here (simp review §3.6):
#   TEST_PATH_RE          canonical in debt_patterns.sh (sourced when not in env);
#   VITAL_RE, TX_RETRY_RE canonical in run_audit.sh, which exports all three when
#                         it invokes this script. A standalone run (sd_self_test)
#                         extracts the same single copies from run_audit.sh; if
#                         either cannot be resolved, fail LOUDLY — never guess.
SD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${TEST_PATH_RE:-}" ]; then . "$SD_HERE/debt_patterns.sh"; fi
[ -n "${VITAL_RE:-}" ]    || VITAL_RE="$(sed -n "s/^VITAL_RE='\(.*\)'\$/\1/p" "$SD_HERE/run_audit.sh")"
[ -n "${TX_RETRY_RE:-}" ] || TX_RETRY_RE="$(sed -n "s/^TX_RETRY_RE='\(.*\)'\$/\1/p" "$SD_HERE/run_audit.sh")"
: "${TEST_PATH_RE:?sd_seeds: TEST_PATH_RE unresolved (canonical: debt_patterns.sh)}"
: "${VITAL_RE:?sd_seeds: VITAL_RE unresolved (canonical: run_audit.sh)}"
: "${TX_RETRY_RE:?sd_seeds: TX_RETRY_RE unresolved (canonical: run_audit.sh)}"

label() { sed 's/^/[candidate] /'; }   # every line is a CANDIDATE, not a verdict

# ── 1. money-as-float ∩ VITAL (SD §2 Pack-2; the highest-value single grep the
#      suite lacked). FILE-level intersection: a money/business file whose lines
#      use float()/round()/a float literal — MINUS Decimal-correct lines (the
#      must_not_flag). The verdict (is this money?) stays agent.
: > "$OUT/sd_money_float.txt"
vital_files="$(grep -rIlE "${EXC[@]}" "$VITAL_RE" "$TARGET" 2>/dev/null || true)"
if [ -n "$vital_files" ]; then
  printf '%s\n' "$vital_files" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -HnE '(\bfloat\(|\bround\(|[0-9]+\.[0-9]+)' "$f" 2>/dev/null | grep -vE 'Decimal'
  done | label > "$OUT/sd_money_float.txt" || true
fi

# ── 2. tz-in-production (SD §2 Pack-2): naive datetime in production paths — the
#      FLAKY_RE datetime slice inverted OUTSIDE test paths. tz-aware forms carry
#      args, so `.now()`/`.today()` require EMPTY parens; `.utcnow()` is always naive.
TZ_PROD_RE='\bdatetime\.utcnow\(\)|\bdatetime\.now\(\)|\bdatetime\.today\(\)|\bdate\.today\(\)'
grep -rIEn "${EXC[@]}" "$TZ_PROD_RE" "$TARGET" 2>/dev/null \
  | grep -vE "$TEST_PATH_RE" | label > "$OUT/sd_tz_production.txt" || true

# ── 3. timeout-kwarg-absence (SD §2 Pack-5): a blocking client call with no
#      timeout= kwarg (B113 + non-requests clients). timeout= present -> excluded.
TIMEOUT_CLIENT_RE='\brequests\.(get|post|put|delete|head|patch)\(|\bhttpx\.(get|post|put|delete|head|patch)\(|\burllib\.request\.urlopen\(|\bsocket\.create_connection\('
grep -rIEn "${EXC[@]}" "$TIMEOUT_CLIENT_RE" "$TARGET" 2>/dev/null \
  | grep -vE 'timeout[[:space:]]*=' | label > "$OUT/sd_timeout_absence.txt" || true

# ── 4. jitter-absence over retry sites (SD §2 Pack-5 thundering-herd sliver): a
#      retry construct with no jitter/randomization. jittered forms -> excluded.
grep -rIEn "${EXC[@]}" "$TX_RETRY_RE" "$TARGET" 2>/dev/null \
  | grep -viE 'jitter|full_jitter|\brandom\b|uniform' | label > "$OUT/sd_jitter_absence.txt" || true

# ── 5. Queue-without-maxsize (SD §2 Pack-5): an unbounded queue construction.
#      maxsize=/maxlen= present -> excluded (bounded).
QUEUE_RE='\bQueue\(|\bSimpleQueue\('
grep -rIEn "${EXC[@]}" "$QUEUE_RE" "$TARGET" 2>/dev/null \
  | grep -vE 'maxsize[[:space:]]*=|maxlen[[:space:]]*=' | label > "$OUT/sd_queue_unbounded.txt" || true

# ── 6. migration DDL destructive shapes (SD §2 Pack-6): DROP/ALTER COLUMN /
#      NOT-NULL-add in checked-in DDL. Additive `ADD COLUMN ... NULL` -> excluded.
#      Reversibility / lock-impact is the agent's verdict.
MIGRATION_DDL_RE='\bDROP[[:space:]]+(TABLE|COLUMN|CONSTRAINT|INDEX)\b|\bADD[[:space:]]+COLUMN\b[^;]*\bNOT[[:space:]]+NULL\b|\bSET[[:space:]]+NOT[[:space:]]+NULL\b|\bALTER[[:space:]]+COLUMN\b'
grep -rIiEn "${EXC[@]}" "$MIGRATION_DDL_RE" "$TARGET" 2>/dev/null \
  | label > "$OUT/sd_migration_ddl.txt" || true

# ── 7. least-privilege breadth seeds (SD-09 / SD §3.5): the honest in-repo slivers
#      ONLY — Dockerfile `USER root`, `GRANT ALL` in checked-in DDL, `"*"` /
#      AdministratorAccess in checked-in IAM JSON. This is NOT an access review and
#      NEVER implies audit-grade entitlement coverage (the disclaimer heads the file);
#      IAM/Terraform breadth that lives elsewhere is out of this repo's reach. Scoped
#      forms (USER appuser, GRANT SELECT, a named action) -> excluded. Breadth is the
#      agent's verdict (comment-only) — these are candidates.
LEAST_PRIV_RE='^[[:space:]]*USER[[:space:]]+root([[:space:]]|$)|\bGRANT[[:space:]]+ALL\b|"Action"[[:space:]]*:[[:space:]]*"\*"|"Resource"[[:space:]]*:[[:space:]]*"\*"|\bAdministratorAccess\b'
{
  echo "[disclaimer] least-privilege breadth is CANDIDATES ONLY, NOT an access review — never implies audit-grade entitlement coverage (SD-09 / SD §3.5); IAM/Terraform breadth living elsewhere is out of this repo's reach"
  grep -rIEn "${EXC[@]}" "$LEAST_PRIV_RE" "$TARGET" 2>/dev/null | label
} > "$OUT/sd_least_privilege.txt" || true

exit 0
