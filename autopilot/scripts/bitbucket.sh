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
#   pr-state          --num <N>
#                       -> prints one of: OPEN, MERGED, DECLINED
#   pr-comment        --num <N> --body-file <path>
#                       -> exits 0 on success
#   pr-approve        --num <N>                                 (v2.3.0)
#                       -> approves current session's user as reviewer
#   pr-decline        --num <N>                                 (v2.3.0)
#                       -> declines the PR (state -> DECLINED)
#   pr-merge          --num <N> [--strategy merge-commit|squash|ff-only|no-ff|rebase|semi-linear]
#                       -> defaults to merge-commit (AP-10); retries once on 409 with fresh version GET (v2.3.0)
#   pr-merge-strategies                                         (v2.3.0)
#                       -> prints repo-permitted merge strategies (one per line)
#   build-status      --sha <sha>
#                       -> prints aggregated state: SUCCESSFUL | FAILED | INPROGRESS | UNKNOWN
#
# All subcommands derive PROJECT_KEY and REPO_SLUG from `git remote get-url origin`.
# Expected origin shape: https://<host>/scm/<project>/<repo>.git
#
# Auth routing:
#   - If sidecar_detect.sh reports MODE=sidecar AND platform "bitbucket" is in
#     PLATFORMS, route requests through ${IDENTITY_PROXY_URL}/bitbucket/<path>
#     with NO Authorization header.
#   - Otherwise, resolve token via secret_get.sh bitbucket and send as
#     `Authorization: Bearer <token>` (HTTP token, NOT Basic).
#   - In all cases: `set +x` around credential handling; never log the token.
#
# v2.3.0 additions (AP-23):
#   - UTF-8 sanitisation on all JSON payloads (python3 shim) so non-UTF-8 bytes
#     do not corrupt Bitbucket DC's parser.
#   - X-Atlassian-Token: no-check header on all mutating requests (XSRF guard).
#   - LAST_STATE=<value> emitted on stderr immediately before any non-zero exit
#     so callers (dispatcher, ci_check.sh, drain-lifecycle) can classify without
#     re-parsing prior stderr lines.

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
SIDECAR_PLATFORMS=""
eval "$MODE_LINE"
if [[ "${MODE:-local}" == "sidecar" ]]; then
  case ",${PLATFORMS:-}," in
    *,bitbucket,*) SIDECAR_MODE=1; SIDECAR_BASE="${URL}" ;;
  esac
fi

build_url() {
  local rel="$1"
  if (( SIDECAR_MODE == 1 )); then
    printf '%s/bitbucket%s' "$SIDECAR_BASE" "$rel"
  else
    printf 'https://%s%s' "$BB_HOST" "$rel"
  fi
}

# Returns curl auth/CA flags as a string suitable for eval-less array expansion.
# Caller must set +x before calling and discard CURL_AUTH after use.
declare -a CURL_AUTH
prepare_curl_auth() {
  CURL_AUTH=()
  if (( SIDECAR_MODE == 1 )); then
    # No Authorization header. Add CA if configured.
    if [[ -n "${IDENTITY_PROXY_CA:-}" ]]; then
      CURL_AUTH+=(--cacert "$IDENTITY_PROXY_CA")
    fi
    return 0
  fi
  # Local mode: resolve via secret_get.sh (token captured in subshell, never echoed).
  local tok
  tok="$("$HERE/secret_get.sh" bitbucket)" || die_state "credential-unavailable" "run scripts/secret_set.sh bitbucket"
  [[ -n "$tok" ]] || die_state "credential-unavailable" "empty token"
  CURL_AUTH+=(-H "Authorization: Bearer ${tok}")
  unset tok
}

# UTF-8 sanitiser: normalises stdin to valid UTF-8, replacing invalid byte
# sequences with U+FFFD. Bitbucket DC's JSON parser rejects payloads with
# invalid UTF-8 sequences with an opaque 500; sanitising client-side surfaces
# clean errors and prevents payload corruption when bodies are sourced from
# grep/awk output or from filesystem paths with mixed encodings. (AP-23)
sanitise_utf8() {
  python3 -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read().decode("utf-8","replace").encode("utf-8"))'
}

# Run curl. Caller passes URL and any extra args. Auth headers come from CURL_AUTH.
# Method-aware: mutating methods add X-Atlassian-Token: no-check (XSRF guard).
# Returns HTTP status and body; caller inspects HTTP_STATUS global.
HTTP_STATUS=0
bb_curl() {
  local method="$1"; shift
  local url="$1"; shift
  prepare_curl_auth
  local -a extra_headers=()
  case "$method" in
    POST|PUT|PATCH|DELETE)
      # XSRF guard required by Bitbucket DC on mutating requests. (AP-23)
      extra_headers+=(-H 'X-Atlassian-Token: no-check')
      ;;
  esac
  local tmp_body
  tmp_body="$(mktemp)"
  local http_code
  http_code=$(curl -sS --max-time 30 --retry 1 --retry-delay 2 \
    -X "$method" \
    -o "$tmp_body" \
    -w '%{http_code}' \
    "${CURL_AUTH[@]}" \
    "${extra_headers[@]}" \
    -H 'Accept: application/json' \
    "$@" \
    "$url") || {
      local rc=$?
      CURL_AUTH=()
      rm -f "$tmp_body"
      die_state "curl-transport" "curl-failed: rc=$rc url=$url"
    }
  CURL_AUTH=()
  HTTP_STATUS="$http_code"
  cat "$tmp_body"
  rm -f "$tmp_body"
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

  local url
  url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests")
  local resp
  resp=$(bb_curl POST "$url" -H 'Content-Type: application/json' -d "$payload")
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    die_state "pr-open-http-${HTTP_STATUS}" "pr-open failed: $(echo "$resp" | head -c 200)"
  fi
  local num
  num=$(echo "$resp" | jq -r '.id // empty')
  [[ -n "$num" ]] || die_state "pr-open-no-id" "no PR number in response: $(echo "$resp" | head -c 200)"
  echo "$num"
}

cmd_pr_state() {
  require_jq
  local num=""
  while (( $# > 0 )); do
    case "$1" in
      --num) num="$2"; shift 2 ;;
      *) die_state "arg-parse" "pr-state: unknown arg $1" ;;
    esac
  done
  [[ -n "$num" ]] || die_state "arg-parse" "pr-state: --num required"
  local url
  url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests/${num}")
  local resp
  resp=$(bb_curl GET "$url")
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    die_state "pr-state-http-${HTTP_STATUS}" "pr-state failed"
  fi
  echo "$resp" | jq -r '.state // "UNKNOWN"'
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
  local url
  url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests/${num}/comments")
  local resp
  resp=$(bb_curl POST "$url" -H 'Content-Type: application/json' -d "$payload")
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    die_state "pr-comment-http-${HTTP_STATUS}" "pr-comment failed: $(echo "$resp" | head -c 200)"
  fi
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
  local url
  url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests/${num}/approve")
  local resp
  resp=$(bb_curl POST "$url")
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    die_state "pr-approve-http-${HTTP_STATUS}" "pr-approve failed: $(echo "$resp" | head -c 200)"
  fi
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
  local v_url v_resp version
  v_url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests/${num}")
  v_resp=$(bb_curl GET "$v_url")
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    die_state "pr-decline-version-http-${HTTP_STATUS}" "cannot resolve PR version"
  fi
  version=$(echo "$v_resp" | jq -r '.version // empty')
  [[ -n "$version" ]] || die_state "pr-decline-no-version" "PR version missing"

  local url resp
  url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests/${num}/decline?version=${version}")
  resp=$(bb_curl POST "$url")
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    die_state "pr-decline-http-${HTTP_STATUS}" "pr-decline failed: $(echo "$resp" | head -c 200)"
  fi
}

# v2.3.0: pr-merge-strategies. Lists strategies allowed by repo settings.
# Falls back to the AP-10 default (merge-commit) if the endpoint is not
# available on this Bitbucket DC version.
cmd_pr_merge_strategies() {
  require_jq
  local url resp
  url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/settings/pull-requests")
  resp=$(bb_curl GET "$url")
  if (( HTTP_STATUS == 404 )); then
    # Older Bitbucket DC without the settings endpoint. Assume the safe default.
    echo "merge-commit"
    return 0
  fi
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    die_state "pr-merge-strategies-http-${HTTP_STATUS}" "pr-merge-strategies failed"
  fi
  # Response shape varies across DC versions; try common paths.
  echo "$resp" | jq -r '
    (.mergeConfig.strategies // .strategies // []) as $ss
    | if ($ss | length) == 0 then "merge-commit"
      else ($ss | .[] | (.id // .name // empty)) end
  '
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

  # AP-10 default. Map operator-facing names to Bitbucket DC strategy ids.
  local bb_strategy
  case "$strategy" in
    merge-commit|no-ff) bb_strategy="no-ff" ;;
    squash)             bb_strategy="squash" ;;
    ff-only)            bb_strategy="ff-only" ;;
    rebase)             bb_strategy="rebase" ;;
    semi-linear)        bb_strategy="squash-ff-only" ;;
    *) die_state "arg-parse" "pr-merge: unknown strategy: $strategy" ;;
  esac

  # v2.3.0: retry once on 409 (version conflict) with a fresh version GET.
  local attempt
  for attempt in 1 2; do
    local v_url v_resp version
    v_url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests/${num}")
    v_resp=$(bb_curl GET "$v_url")
    if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
      die_state "pr-merge-version-http-${HTTP_STATUS}" "cannot resolve PR version"
    fi
    version=$(echo "$v_resp" | jq -r '.version // empty')
    [[ -n "$version" ]] || die_state "pr-merge-no-version" "cannot resolve PR version"

    local url payload resp
    url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests/${num}/merge?version=${version}")
    payload=$(jq -n --arg s "$bb_strategy" '{strategy: $s}')
    resp=$(bb_curl POST "$url" -H 'Content-Type: application/json' -d "$payload")
    if (( HTTP_STATUS >= 200 && HTTP_STATUS < 300 )); then
      return 0
    fi
    if (( HTTP_STATUS == 409 && attempt == 1 )); then
      # Version conflict; refetch and retry once.
      echo "pr-merge: 409 on attempt 1, retrying with fresh version" >&2
      continue
    fi
    die_state "pr-merge-http-${HTTP_STATUS}" "pr-merge failed: $(echo "$resp" | head -c 200)"
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
  local url
  url=$(build_url "/rest/build-status/1.0/commits/${sha}")
  local resp
  resp=$(bb_curl GET "$url")
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    die_state "build-status-http-${HTTP_STATUS}" "build-status failed"
  fi
  # Aggregate: any FAILED -> FAILED; any INPROGRESS (and no FAILED) -> INPROGRESS;
  # all SUCCESSFUL -> SUCCESSFUL; empty -> UNKNOWN.
  echo "$resp" | jq -r '
    (.values // []) as $vs
    | if ($vs | length) == 0 then "UNKNOWN"
      elif ($vs | any(.state == "FAILED")) then "FAILED"
      elif ($vs | any(.state == "INPROGRESS")) then "INPROGRESS"
      elif ($vs | all(.state == "SUCCESSFUL")) then "SUCCESSFUL"
      else "UNKNOWN" end
  '
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
