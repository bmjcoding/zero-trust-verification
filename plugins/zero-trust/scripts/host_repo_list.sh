#!/usr/bin/env bash
# host_repo_list.sh — OWM-09 (OPTIONAL): org-enumeration as a genuinely NEW backend
# method behind the ADR 0013 adapter pattern. Org enumeration is NOT pre-solved by
# autopilot's host.sh (that is a 104-line PR/build pass-through with NO repo listing;
# ADR 0019). This is a NEW capability: `repo-list [--org <org>]` implemented by BOTH
# backends (GitHub `gh`, Bitbucket DC REST) against the SAME T01-class mock matrix.
#
# It lives INSIDE org-memory (vendored, not a runtime dependency on the autopilot
# plugin — ADR 0011 independent installability). It is CONFIG-FIRST + OPTIONAL: OWM
# crawls the explicit OWM-03 config list by DEFAULT and only uses this to ENRICH that
# list when enumeration auth is available. If enumeration is unavailable OWM falls
# back to the explicit config list (degrade gracefully) — the build never blocks on
# the credential decision.
#
#   host_repo_list.sh backend                 -> print detected backend id
#   host_repo_list.sh repo-list [--org <org>] -> TSV: <slug><TAB><clone-or-api-url>
#
# The enumeration credential's READ scope + cross-repo disclosure policy are
# ESCALATED (human_questions), NOT assumed here — this only shapes the contract.
#
# Backend detection (first match wins), mirroring host.sh:
#   1. $OWM_HOST_BACKEND (BITBUCKET_DC | GITHUB) is authoritative.
#   2. origin host github.com     -> GITHUB
#   3. origin path contains /scm/ -> BITBUCKET_DC
# The backend binaries are taken from PATH (gh; curl) so the T01 mock matrix injects
# shims via PATH — the exact hermetic pattern the Marshal e2e uses. $BITBUCKET_URL /
# $BITBUCKET_TOKEN scope the DC REST call.
#
# Exit: 0 ok · 3 enumeration unavailable (caller should fall back to OWM-03 config) ·
#       64 usage · 69 backend binary missing.
# Portability: bash 3.2 (macOS default) + BSD userland safe.
set -u

usage() { echo "usage: host_repo_list.sh <backend|repo-list [--org <org>]>" >&2; exit 64; }

detect_backend() {
  if [ -n "${OWM_HOST_BACKEND:-}" ]; then printf '%s\n' "$OWM_HOST_BACKEND"; return 0; fi
  local url=""
  url="$(git config --get remote.origin.url 2>/dev/null || true)"
  case "$url" in
    *github.com*) printf 'GITHUB\n'; return 0 ;;
    */scm/*)      printf 'BITBUCKET_DC\n'; return 0 ;;
  esac
  return 1
}

# GitHub backend: `gh repo list <org> --json name,sshUrl` -> TSV slug<TAB>url.
gh_repo_list() {
  local org="$1"
  command -v gh >/dev/null 2>&1 || { echo "host_repo_list: gh not found" >&2; return 69; }
  # --limit keeps enumeration bounded; the mock shim ignores flags it doesn't need.
  gh repo list "$org" --json name,sshUrl --limit 1000 2>/dev/null \
    | _json_name_url
}

# Bitbucket DC backend: REST /rest/api/1.0/projects/<org>/repos -> TSV slug<TAB>url.
bb_repo_list() {
  local org="$1"
  command -v curl >/dev/null 2>&1 || { echo "host_repo_list: curl not found" >&2; return 69; }
  local base="${BITBUCKET_URL:-https://bitbucket.example/rest/api/1.0}"
  local auth=()
  [ -n "${BITBUCKET_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${BITBUCKET_TOKEN}")
  curl -s "${auth[@]+"${auth[@]}"}" "${base}/projects/${org}/repos?limit=1000" \
    | _bb_json_name_url
}

# Parse gh's `[{name,sshUrl}...]` JSON into TSV. Prefer python3 (present per ADR 0015);
# no jq hard-dependency in OWM. NOTE: `python3 -c` (not `python3 - <<heredoc`) so the
# piped JSON stays on stdin instead of being shadowed by the script.
_json_name_url() {
  python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in data or []:
    name = r.get("name") or ""
    url = r.get("sshUrl") or r.get("url") or ""
    if name:
        print("%s\t%s" % (name, url))
'
}

# Parse Bitbucket DC `{values:[{slug, links:{clone:[{href}...]}}...]}` into TSV.
_bb_json_name_url() {
  python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in (data or {}).get("values", []):
    slug = r.get("slug") or r.get("name") or ""
    url = ""
    for c in (r.get("links", {}) or {}).get("clone", []) or []:
        if c.get("name") == "ssh" or not url:
            url = c.get("href") or url
    if slug:
        print("%s\t%s" % (slug, url))
'
}

main() {
  [ $# -ge 1 ] || usage
  local cmd="$1"; shift
  case "$cmd" in
    backend)
      detect_backend || { echo "host_repo_list: cannot detect backend; set \$OWM_HOST_BACKEND" >&2; exit 3; }
      ;;
    repo-list)
      local org=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --org) org="${2:-}"; shift 2 ;;
          *) usage ;;
        esac
      done
      local backend rc
      backend="$(detect_backend || true)"
      if [ -z "$backend" ]; then
        echo "host_repo_list: enumeration unavailable (no backend); fall back to the OWM-03 explicit config list" >&2
        exit 3
      fi
      case "$backend" in
        GITHUB)       gh_repo_list "$org"; rc=$? ;;
        BITBUCKET_DC) bb_repo_list "$org"; rc=$? ;;
        *) echo "host_repo_list: unknown backend '$backend'" >&2; exit 64 ;;
      esac
      if [ "${rc:-0}" -ne 0 ]; then
        echo "host_repo_list: '$backend' enumeration failed; fall back to the OWM-03 explicit config list" >&2
        exit 3
      fi
      ;;
    *) usage ;;
  esac
}

main "$@"
