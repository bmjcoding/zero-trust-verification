#!/usr/bin/env bash
# bitbucket.sh
#
# Bitbucket Data Center adapter. Replaces gh CLI calls with
# git + Bitbucket DC REST API. Routes credentials through the
# sidecar -> keychain -> env resolver chain (see sidecar-contract.md).
#
# Subcommands:
#   pr-open           --title <t> --src <branch> --dest <branch> [--body-file <path>] [--draft]
#                       -> prints PR number on stdout
#   pr-state          (--num <N> | --branch <src-branch>)
#                       -> prints one of: OPEN, MERGED, DECLINED, NONE (--branch only)
#   pr-comment        --num <N> --body-file <path>
#                       -> exits 0 on success
#   pr-approve        --num <N>                                 (v2.3.0)
#                       -> approves current session's user as reviewer
#   pr-decline        --num <N>                                 (v2.3.0)
#                       -> declines the PR (state -> DECLINED)
#   pr-merge          --num <N> [--strategy merge-commit|squash|ff-only|no-ff|rebase|semi-linear]
#                       -> defaults to merge-commit (AP-10); discovers repo-enabled
#                          strategies via the settings endpoint and falls back to the
#                          closest enabled candidate (v2.4.0, was claimed in v2.1.0);
#                          retries once on 409 with fresh version GET (v2.3.0)
#   pr-merge-strategies                                         (v2.3.0)
#                       -> prints repo-permitted merge strategies (one per line)
#   build-status      --sha <sha>
#                       -> prints aggregated state: SUCCESSFUL | FAILED | INPROGRESS | UNKNOWN
#
# All subcommands derive PROJECT_KEY and REPO_SLUG from `git remote get-url origin`.
# Expected origin shape: https://<host>/scm/<project>/<repo>.git
#
# Auth routing:
#   - If sidecar_detect.sh reports MODE=sidecar AND a Bitbucket platform id
#     ("bitbucketdc" per sidecar-contract.md, or legacy "bitbucket") is in
#     PLATFORMS, route requests through ${IDENTITY_PROXY_URL}/<platform-id>/<path>
#     with NO Authorization header. AUTOPILOT_SIDECAR_MODE=1 is exported so
#     child invocations of secret_get.sh short-circuit per its tier-1 contract.
#   - Otherwise, resolve token via secret_get.sh bitbucket and send it as an
#     `Authorization: Bearer` header read from a 0600 temp file (`-H @file`),
#     so the token never appears in argv (/proc/*/cmdline).
#   - In all cases: `set +x` around credential handling; never log the token.
#
# v2.4.0 fixes (see docs/GAPS_SPEC.md A1, A9, B1, B2):
#   - bb_curl no longer runs in a command substitution: it writes the response
#     body to a caller-named file and sets HTTP_STATUS in the calling shell,
#     so status handling works and resolver failures abort the whole script.
#   - Response bodies are UTF-8-sanitised before jq (the v2.1.0 CHANGELOG
#     claimed this; it was only applied to request payloads).
#   - Sidecar platform id "bitbucketdc" (contract-canonical) accepted.
#   - curl --retry applies to GET only; retrying POSTs risks duplicate
#     PR/merge submissions on timeout.
#
# v2.3.0 additions (AP-23):
#   - UTF-8 sanitisation on JSON payloads (python3 shim).
#   - X-Atlassian-Token: no-check header on all mutating requests (XSRF guard).
#   - LAST_STATE=<value> emitted on stderr immediately before any non-zero exit.

set -u
set +x

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<EOF
usage: bitbucket.sh <subcommand> [args]
subcommands: pr-open pr-state pr-comment pr-approve pr-decline pr-merge pr-merge-strategies build-status
EOF
  exit 64
}

# Emit LAST_STATE=<value> on stderr then die with rc=1. Callers grep for
# LAST_STATE= to classify failures without parsing free-form error strings.
die_state() {
  local state="$1"; shift
  echo "LAST_STATE=${state}" >&2
  echo "bitbucket.sh: $*" >&2
  exit 1
}

die() { die_state "generic-failure" "$*"; }

# --- Repo coords --------------------------------------------------------------

ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
[[ -n "$ORIGIN_URL" ]] || die_state "no-origin" "no origin remote configured"

if [[ "$ORIGIN_URL" =~ /scm/([^/]+)/([^/]+)\.git$ ]]; then
  PROJECT_KEY="${BASH_REMATCH[1]}"
  REPO_SLUG="${BASH_REMATCH[2]}"
elif [[ "$ORIGIN_URL" =~ ([^/:]+)/([^/]+)\.git$ ]]; then
  # ssh://git@host/PROJECT/repo.git or git@host:PROJECT/repo.git
  PROJECT_KEY="${BASH_REMATCH[1]}"
  REPO_SLUG="${BASH_REMATCH[2]}"
else
  die_state "origin-parse" "cannot parse origin URL: $ORIGIN_URL"
fi

# Bitbucket DC host (for non-sidecar mode).
if [[ "$ORIGIN_URL" =~ https?://([^/]+)/ ]]; then
  BB_HOST="${BASH_REMATCH[1]}"
elif [[ "$ORIGIN_URL" =~ @([^:/]+)[:/] ]]; then
  BB_HOST="${BASH_REMATCH[1]}"
else
  die_state "host-parse" "cannot parse host from origin URL"
fi

# --- Auth/routing -------------------------------------------------------------

MODE_LINE="$("$HERE/sidecar_detect.sh")"
SIDECAR_MODE=0
SIDECAR_BASE=""
SIDECAR_PLATFORM_ID=""
# sidecar_detect.sh emits `MODE=... PLATFORMS="..." URL="..."`. Parse without
# eval (the values are env-derived; eval would be an injection surface).
MODE=$(sed -n 's/^.*\bMODE=\([a-z]*\).*$/\1/p' <<<"$MODE_LINE")
PLATFORMS=$(sed -n 's/^.*\bPLATFORMS="\([^"]*\)".*$/\1/p' <<<"$MODE_LINE")
URL=$(sed -n 's/^.*\bURL="\([^"]*\)".*$/\1/p' <<<"$MODE_LINE")
if [[ "${MODE:-local}" == "sidecar" ]]; then
  # "bitbucketdc" is the contract-canonical platform id (sidecar-contract.md);
  # "bitbucket" is accepted for legacy sidecars. The matched id is used as the
  # URL path segment.
  for pid in bitbucketdc bitbucket; do
    case ",${PLATFORMS:-}," in
      *,"$pid",*) SIDECAR_MODE=1; SIDECAR_BASE="${URL}"; SIDECAR_PLATFORM_ID="$pid"; break ;;
    esac
  done
fi
if (( SIDECAR_MODE == 1 )); then
  export AUTOPILOT_SIDECAR_MODE=1
fi

build_url() {
  local rel="$1"
  if (( SIDECAR_MODE == 1 )); then
    printf '%s/%s%s' "$SIDECAR_BASE" "$SIDECAR_PLATFORM_ID" "$rel"
  else
    printf 'https://%s%s' "$BB_HOST" "$rel"
  fi
}

# Prepare curl auth flags into CURL_AUTH. In local mode the Bearer header is
# written to a 0600 temp file and passed as `-H @file` so the token never
# appears in curl's argv (visible in /proc/*/cmdline while curl runs).
declare -a CURL_AUTH=()
AUTH_HEADER_FILE=""
cleanup_auth() {
  [[ -n "$AUTH_HEADER_FILE" ]] && rm -f "$AUTH_HEADER_FILE"
  AUTH_HEADER_FILE=""
  CURL_AUTH=()
}
trap cleanup_auth EXIT

prepare_curl_auth() {
  CURL_AUTH=()
  if (( SIDECAR_MODE == 1 )); then
    # No Authorization header. Add CA if configured.
    if [[ -n "${IDENTITY_PROXY_CA:-}" ]]; then
      CURL_AUTH+=(--cacert "$IDENTITY_PROXY_CA")
    fi
    return 0
  fi
  # Local mode: resolve via secret_get.sh (token captured in subshell, written
  # only to a 0600 mktemp file, never echoed, never in argv).
  local tok
  tok="$("$HERE/secret_get.sh" bitbucket)" || die_state "credential-unavailable" "run scripts/secret_set.sh bitbucket"
  [[ -n "$tok" ]] || die_state "credential-unavailable" "empty token"
  AUTH_HEADER_FILE="$(mktemp)"   # mktemp creates 0600
  printf 'Authorization: Bearer %s' "$tok" > "$AUTH_HEADER_FILE"
  unset tok
  CURL_AUTH+=(-H "@${AUTH_HEADER_FILE}")
}

# UTF-8 sanitiser: normalises stdin to valid UTF-8, replacing invalid byte
# sequences with U+FFFD. Applied to request payloads (Bitbucket DC's JSON
# parser rejects invalid UTF-8 with an opaque 500) AND to response bodies
# before jq (v2.4.0 — non-UTF-8 bytes in PR titles/descriptions made jq
# fail and pr-open misreport "no PR number in response"). (AP-23 / GAPS B1)
sanitise_utf8() {
  python3 -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read().decode("utf-8","replace").encode("utf-8"))'
}

# Run curl. v2.4.0 contract (GAPS A1): NOT for use in command substitution.
#   bb_curl <METHOD> <URL> <BODY_OUTFILE> [extra curl args...]
# - Writes the UTF-8-sanitised response body to BODY_OUTFILE.
# - Sets HTTP_STATUS in the calling shell.
# - Mutating methods get the XSRF guard header; GET gets --retry 1
#   (retrying mutating methods on TRANSPORT errors risks duplicate
#   submissions on timeout).
# - Sidecar error-code table (sidecar-contract.md): 429 honours Retry-After
#   (max 1 retry — safe for any method: 429 means the request was not
#   processed); 502 retries once with backoff; 407 aborts as
#   sidecar-session-invalid without logging the body.
# - Transport failure or resolver failure aborts the whole script.
HTTP_STATUS=0
bb_curl() {
  local method="$1"; shift
  local url="$1"; shift
  local body_out="$1"; shift
  local -a extra=()
  case "$method" in
    POST|PUT|PATCH|DELETE)
      # XSRF guard required by Bitbucket DC on mutating requests. (AP-23)
      extra+=(-H 'X-Atlassian-Token: no-check')
      ;;
  esac
  # Retries are owned HERE, not by curl --retry: curl's built-in retry also
  # fires on 429/5xx, which would bypass this table's bounded Retry-After
  # handling (and could double-submit mutating requests on timeout).
  local attempt tmp_raw tmp_hdr http_code rc
  for attempt in 1 2; do
    prepare_curl_auth
    tmp_raw="$(mktemp)"; tmp_hdr="$(mktemp)"; rc=0
    http_code=$(curl -sS --max-time 30 \
      -X "$method" \
      -o "$tmp_raw" \
      -D "$tmp_hdr" \
      -w '%{http_code}' \
      "${CURL_AUTH[@]}" \
      "${extra[@]}" \
      -H 'Accept: application/json' \
      "$@" \
      "$url") || rc=$?
    cleanup_auth
    if (( rc != 0 )); then
      rm -f "$tmp_raw" "$tmp_hdr"
      # Transport-level retry is safe for GET only (a timed-out mutating
      # request may have been processed).
      if [[ "$method" == "GET" && $attempt == 1 ]]; then
        echo "bb_curl: transport failure rc=$rc on GET; retrying once after 2s" >&2
        sleep 2
        continue
      fi
      die_state "curl-transport" "curl-failed: rc=$rc url=$url"
    fi
    if [[ "$http_code" == "429" && $attempt == 1 ]]; then
      # Honour Retry-After, bounded to 30s; default 2s when absent.
      local ra
      ra=$(awk -F': *' 'tolower($1)=="retry-after" {gsub(/\r/,"",$2); print $2; exit}' "$tmp_hdr")
      [[ "$ra" =~ ^[0-9]+$ ]] || ra=2
      (( ra > 30 )) && ra=30
      rm -f "$tmp_raw" "$tmp_hdr"
      echo "bb_curl: 429 rate-limited; retrying once after ${ra}s" >&2
      sleep "$ra"
      continue
    fi
    if [[ "$http_code" == "502" && $attempt == 1 ]]; then
      rm -f "$tmp_raw" "$tmp_hdr"
      echo "bb_curl: 502 upstream; retrying once after 2s" >&2
      sleep 2
      continue
    fi
    if [[ "$http_code" == "407" ]]; then
      # Sidecar misconfigured. Body deliberately NOT logged (contract:
      # 401/403/407 bodies may contain token-shaped strings).
      rm -f "$tmp_raw" "$tmp_hdr"
      die_state "sidecar-session-invalid" "sidecar returned 407 for $method $url"
    fi
    sanitise_utf8 < "$tmp_raw" > "$body_out"
    rm -f "$tmp_raw" "$tmp_hdr"
    HTTP_STATUS="$http_code"
    return 0
  done
}

# Excerpt a response body for an error message, per sidecar-contract.md:
# 401/403 bodies are never logged (token-shaped error strings); 407 never
# reaches here (bb_curl aborts). Credentialed URLs in other bodies are
# redacted defensively.
body_excerpt() {
  case "$HTTP_STATUS" in
    401|403|407) printf '[body redacted: auth-failure responses may contain token-shaped strings]' ;;
    *) head -c 200 "$1" | sed -E 's#(https?://)[^/@[:space:]]+@#\1[redacted]@#g' ;;
  esac
}

# --- jq helper (minimal, no external dep beyond jq) ---------------------------

require_jq() {
  command -v jq >/dev/null 2>&1 || die_state "missing-dep" "jq is required"
}

require_python3() {
  command -v python3 >/dev/null 2>&1 || die_state "missing-dep" "python3 is required for UTF-8 sanitisation"
}

# --- Subcommands --------------------------------------------------------------

cmd_pr_open() {
  require_jq; require_python3
  local title="" src="" dest="" body_file="" draft=0
  while (( $# > 0 )); do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --src) src="$2"; shift 2 ;;
      --dest) dest="$2"; shift 2 ;;
      --body-file) body_file="$2"; shift 2 ;;
      --draft) draft=1; shift ;;
      *) die_state "arg-parse" "pr-open: unknown arg $1" ;;
    esac
  done
  [[ -n "$title" && -n "$src" && -n "$dest" ]] || die_state "arg-parse" "pr-open: --title --src --dest required"

  local body=""
  if [[ -n "$body_file" ]]; then
    [[ -f "$body_file" ]] || die_state "arg-parse" "pr-open: body-file not found: $body_file"
    body=$(sanitise_utf8 < "$body_file")
  fi
  # Also sanitise title (may come from grep/awk).
  title=$(printf '%s' "$title" | sanitise_utf8)

  local payload
  payload=$(jq -n \
    --arg title "$title" \
    --arg desc "$body" \
    --arg src "$src" \
    --arg dest "$dest" \
    --arg slug "$REPO_SLUG" \
    --arg proj "$PROJECT_KEY" \
    --argjson draft "$draft" \
    '{
      title: $title,
      description: $desc,
      state: "OPEN",
      open: true,
      closed: false,
      draft: ($draft == 1),
      fromRef: { id: ("refs/heads/" + $src), repository: { slug: $slug, project: { key: $proj } } },
      toRef:   { id: ("refs/heads/" + $dest), repository: { slug: $slug, project: { key: $proj } } },
      locked: false,
      reviewers: []
    }')

  local url resp_f
  url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests")
  resp_f=$(mktemp)
  bb_curl POST "$url" "$resp_f" -H 'Content-Type: application/json' -d "$payload"
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    local excerpt; excerpt=$(body_excerpt "$resp_f"); rm -f "$resp_f"
    die_state "pr-open-http-${HTTP_STATUS}" "pr-open failed: $excerpt"
  fi
  local num
  num=$(jq -r '.id // empty' < "$resp_f")
  if [[ -z "$num" ]]; then
    local excerpt; excerpt=$(body_excerpt "$resp_f"); rm -f "$resp_f"
    die_state "pr-open-no-id" "no PR number in response: $excerpt"
  fi
  rm -f "$resp_f"
  echo "$num"
}

cmd_pr_state() {
  require_jq
  local num="" branch=""
  while (( $# > 0 )); do
    case "$1" in
      --num) num="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      *) die_state "arg-parse" "pr-state: unknown arg $1" ;;
    esac
  done
  [[ -n "$num" || -n "$branch" ]] || die_state "arg-parse" "pr-state: --num or --branch required"

  local url resp_f
  resp_f=$(mktemp)
  if [[ -n "$num" ]]; then
    url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests/${num}")
    bb_curl GET "$url" "$resp_f"
    if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
      rm -f "$resp_f"
      die_state "pr-state-http-${HTTP_STATUS}" "pr-state failed"
    fi
    jq -r '.state // "UNKNOWN"' < "$resp_f"
  else
    # v2.4.0: look up the most recent PR whose source ref is <branch>
    # (needed by the tracker-PR availability check, which knows the branch
    # name but not the PR number). Prints NONE when no PR exists.
    url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests?state=ALL&direction=OUTGOING&at=refs/heads/${branch}&limit=1")
    bb_curl GET "$url" "$resp_f"
    if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
      rm -f "$resp_f"
      die_state "pr-state-http-${HTTP_STATUS}" "pr-state failed"
    fi
    jq -r '(.values // []) | if length == 0 then "NONE" else (.[0].state // "UNKNOWN") end' < "$resp_f"
  fi
  rm -f "$resp_f"
}

cmd_pr_comment() {
  require_jq; require_python3
  local num="" body_file=""
  while (( $# > 0 )); do
    case "$1" in
      --num) num="$2"; shift 2 ;;
      --body-file) body_file="$2"; shift 2 ;;
      *) die_state "arg-parse" "pr-comment: unknown arg $1" ;;
    esac
  done
  [[ -n "$num" && -n "$body_file" ]] || die_state "arg-parse" "pr-comment: --num --body-file required"
  [[ -f "$body_file" ]] || die_state "arg-parse" "pr-comment: body-file not found"
  local payload
  payload=$(sanitise_utf8 < "$body_file" | jq -Rs '{text: .}')
  local url resp_f
  url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests/${num}/comments")
  resp_f=$(mktemp)
  bb_curl POST "$url" "$resp_f" -H 'Content-Type: application/json' -d "$payload"
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    local excerpt; excerpt=$(body_excerpt "$resp_f"); rm -f "$resp_f"
    die_state "pr-comment-http-${HTTP_STATUS}" "pr-comment failed: $excerpt"
  fi
  rm -f "$resp_f"
}

# v2.3.0: pr-approve. Approves current session's user as reviewer.
cmd_pr_approve() {
  require_jq
  local num=""
  while (( $# > 0 )); do
    case "$1" in
      --num) num="$2"; shift 2 ;;
      *) die_state "arg-parse" "pr-approve: unknown arg $1" ;;
    esac
  done
  [[ -n "$num" ]] || die_state "arg-parse" "pr-approve: --num required"
  local url resp_f
  url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests/${num}/approve")
  resp_f=$(mktemp)
  bb_curl POST "$url" "$resp_f"
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    local excerpt; excerpt=$(body_excerpt "$resp_f"); rm -f "$resp_f"
    die_state "pr-approve-http-${HTTP_STATUS}" "pr-approve failed: $excerpt"
  fi
  rm -f "$resp_f"
}

# v2.3.0: pr-decline. Declines the PR.
cmd_pr_decline() {
  require_jq
  local num=""
  while (( $# > 0 )); do
    case "$1" in
      --num) num="$2"; shift 2 ;;
      *) die_state "arg-parse" "pr-decline: unknown arg $1" ;;
    esac
  done
  [[ -n "$num" ]] || die_state "arg-parse" "pr-decline: --num required"

  # Resolve version.
  local v_url version resp_f
  v_url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests/${num}")
  resp_f=$(mktemp)
  bb_curl GET "$v_url" "$resp_f"
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    rm -f "$resp_f"
    die_state "pr-decline-version-http-${HTTP_STATUS}" "cannot resolve PR version"
  fi
  version=$(jq -r '.version // empty' < "$resp_f")
  [[ -n "$version" ]] || { rm -f "$resp_f"; die_state "pr-decline-no-version" "PR version missing"; }

  local url
  url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests/${num}/decline?version=${version}")
  bb_curl POST "$url" "$resp_f"
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    local excerpt; excerpt=$(body_excerpt "$resp_f"); rm -f "$resp_f"
    die_state "pr-decline-http-${HTTP_STATUS}" "pr-decline failed: $excerpt"
  fi
  rm -f "$resp_f"
}

# v2.3.0: pr-merge-strategies. Lists strategies allowed by repo settings.
# Falls back to the AP-10 default (merge-commit) if the endpoint is not
# available on this Bitbucket DC version.
cmd_pr_merge_strategies() {
  require_jq
  local url resp_f
  url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/settings/pull-requests")
  resp_f=$(mktemp)
  bb_curl GET "$url" "$resp_f"
  if (( HTTP_STATUS == 404 )); then
    # Older Bitbucket DC without the settings endpoint. Assume the safe default.
    rm -f "$resp_f"
    echo "merge-commit"
    return 0
  fi
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    rm -f "$resp_f"
    die_state "pr-merge-strategies-http-${HTTP_STATUS}" "pr-merge-strategies failed"
  fi
  # Response shape varies across DC versions; try common paths. Strategies may
  # be objects ({id, enabled}) or bare ids; filter enabled=false when present.
  # NB: jq's `//` treats false like null (`false // true` == true), so the
  # enabled check must use has()+or, not `.enabled // true`.
  jq -r '
    (.mergeConfig.strategies // .strategies // []) as $ss
    | if ($ss | length) == 0 then "merge-commit"
      else ($ss | .[] | if type == "object"
                        then (if ((has("enabled") | not) or .enabled) then (.id // .name // empty) else empty end)
                        else . end) end
  ' < "$resp_f"
  rm -f "$resp_f"
}

cmd_pr_merge() {
  require_jq
  local num="" strategy="merge-commit"
  while (( $# > 0 )); do
    case "$1" in
      --num) num="$2"; shift 2 ;;
      --strategy) strategy="$2"; shift 2 ;;
      *) die_state "arg-parse" "pr-merge: unknown arg $1" ;;
    esac
  done
  [[ -n "$num" ]] || die_state "arg-parse" "pr-merge: --num required"

  # AP-10 default. Map operator-facing intent to an ORDERED candidate list of
  # Bitbucket DC strategy ids, most-preferred first.
  local -a candidates
  case "$strategy" in
    merge-commit|no-ff) candidates=(no-ff squash ff-only) ;;
    squash)             candidates=(squash squash-ff-only no-ff) ;;
    ff-only)            candidates=(ff-only rebase-ff-only no-ff) ;;
    rebase)             candidates=(rebase-no-ff rebase-ff-only no-ff) ;;
    semi-linear)        candidates=(rebase-no-ff squash-ff-only no-ff) ;;
    *) die_state "arg-parse" "pr-merge: unknown strategy: $strategy" ;;
  esac

  # v2.4.0 (GAPS B2, claimed in v2.1.0): discover which strategies the repo
  # has enabled and pick the first candidate that is enabled. On discovery
  # parse-miss (older DC), fall back to the first candidate.
  local enabled bb_strategy=""
  enabled=$(cmd_pr_merge_strategies 2>/dev/null || true)
  if [[ -n "$enabled" && "$enabled" != "merge-commit" ]]; then
    local c
    for c in "${candidates[@]}"; do
      if grep -qx "$c" <<<"$enabled"; then bb_strategy="$c"; break; fi
    done
  fi
  # Discovery empty, parse miss, or "merge-commit" sentinel (no restriction
  # information): fall back to the most-preferred candidate. When discovery
  # DID return a strategy list and none of our candidates is enabled, say so
  # before attempting anyway (the server will 400 with its own list).
  if [[ -z "$bb_strategy" && -n "$enabled" && "$enabled" != "merge-commit" ]]; then
    echo "pr-merge: none of the candidate strategies (${candidates[*]}) is enabled by the repo ($(tr '\n' ' ' <<<"$enabled")); attempting '${candidates[0]}' anyway" >&2
  fi
  [[ -n "$bb_strategy" ]] || bb_strategy="${candidates[0]}"
  if [[ "$bb_strategy" != "${candidates[0]}" ]]; then
    echo "pr-merge: requested '$strategy' -> '${candidates[0]}' not enabled; using enabled fallback '$bb_strategy'" >&2
  fi

  # v2.3.0: retry once on 409 (version conflict) with a fresh version GET.
  local attempt resp_f
  resp_f=$(mktemp)
  for attempt in 1 2; do
    local v_url version
    v_url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests/${num}")
    bb_curl GET "$v_url" "$resp_f"
    if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
      rm -f "$resp_f"
      die_state "pr-merge-version-http-${HTTP_STATUS}" "cannot resolve PR version"
    fi
    version=$(jq -r '.version // empty' < "$resp_f")
    [[ -n "$version" ]] || { rm -f "$resp_f"; die_state "pr-merge-no-version" "cannot resolve PR version"; }

    local url payload
    url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests/${num}/merge?version=${version}")
    payload=$(jq -n --arg s "$bb_strategy" '{strategy: $s}')
    bb_curl POST "$url" "$resp_f" -H 'Content-Type: application/json' -d "$payload"
    if (( HTTP_STATUS >= 200 && HTTP_STATUS < 300 )); then
      rm -f "$resp_f"
      return 0
    fi
    if (( HTTP_STATUS == 409 && attempt == 1 )); then
      # Version conflict; refetch and retry once.
      echo "pr-merge: 409 on attempt 1, retrying with fresh version" >&2
      continue
    fi
    local excerpt; excerpt=$(body_excerpt "$resp_f"); rm -f "$resp_f"
    die_state "pr-merge-http-${HTTP_STATUS}" "pr-merge failed: $excerpt"
  done
}

cmd_build_status() {
  require_jq
  local sha=""
  while (( $# > 0 )); do
    case "$1" in
      --sha) sha="$2"; shift 2 ;;
      *) die_state "arg-parse" "build-status: unknown arg $1" ;;
    esac
  done
  [[ -n "$sha" ]] || die_state "arg-parse" "build-status: --sha required"
  local url resp_f
  url=$(build_url "/rest/build-status/1.0/commits/${sha}")
  resp_f=$(mktemp)
  bb_curl GET "$url" "$resp_f"
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    rm -f "$resp_f"
    die_state "build-status-http-${HTTP_STATUS}" "build-status failed"
  fi
  # Aggregate: any FAILED -> FAILED; any INPROGRESS (and no FAILED) -> INPROGRESS;
  # all SUCCESSFUL -> SUCCESSFUL; empty -> UNKNOWN.
  jq -r '
    (.values // []) as $vs
    | if ($vs | length) == 0 then "UNKNOWN"
      elif ($vs | any(.state == "FAILED")) then "FAILED"
      elif ($vs | any(.state == "INPROGRESS")) then "INPROGRESS"
      elif ($vs | all(.state == "SUCCESSFUL")) then "SUCCESSFUL"
      else "UNKNOWN" end
  ' < "$resp_f"
  rm -f "$resp_f"
}

# --- Dispatch -----------------------------------------------------------------

(( $# >= 1 )) || usage
SUB="$1"; shift
case "$SUB" in
  pr-open)              cmd_pr_open "$@" ;;
  pr-state)             cmd_pr_state "$@" ;;
  pr-comment)           cmd_pr_comment "$@" ;;
  pr-approve)           cmd_pr_approve "$@" ;;
  pr-decline)           cmd_pr_decline "$@" ;;
  pr-merge)             cmd_pr_merge "$@" ;;
  pr-merge-strategies)  cmd_pr_merge_strategies "$@" ;;
  build-status)         cmd_build_status "$@" ;;
  *) usage ;;
esac
