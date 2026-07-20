#!/usr/bin/env bash
# bitbucket.sh
#
# Bitbucket Data Center backend for the host adapter (host.sh). Speaks
# git + Bitbucket DC REST API and routes credentials through the
# sidecar -> keychain -> env resolver chain (see sidecar-contract.md).
# Selected by host.sh when `origin` is a Bitbucket DC remote; the byte-
# identical contract is shared with the gh-CLI backend github.sh (ADR 0013).
#
# Subcommands:
#   pr-open           --title <t> --src <branch> --dest <branch> [--body-file <path>] [--draft]
#                       -> prints PR number on stdout
#   pr-ready          --num <N>
#                       -> flips a draft PR to ready-for-review; exits 0
#   pr-state          (--num <N> | --branch <src-branch>)
#                       -> prints one of: OPEN, DRAFT, MERGED, DECLINED, NONE (--branch only)
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
#                       -> prints repo-permitted OPERATOR strategy tokens (one
#                          per line; each consumable by pr-merge --strategy).
#                          The set reflects host capability (not byte-identical
#                          across backends); the tokens are the shared vocabulary.
#   build-status      --sha <sha>
#                       -> prints aggregated state: SUCCESSFUL | FAILED | INPROGRESS | UNKNOWN
#   pr-list-ready     [--base <trunk>]
#                       -> enumerate the merge queue as TSV, one ready PR per line:
#                            <ready_ts>\t<pr_num>\t<src_branch>\t<head_sha>\t<approval>
#                          ready_ts is INTEGER EPOCH SECONDS (createdDate is DC's
#                          epoch MILLIS / 1000; DC's REST surface exposes no draft->
#                          ready transition timestamp, so createdDate is the
#                          contract's documented fallback). approval is APPROVED
#                          (>=1 reviewer and ALL reviewers approved) | PENDING.
#                          Selection: OPEN PRs whose toRef is the trunk; drafts
#                          (native draft flag or the [DRAFT] title per DRAFT_MODE)
#                          excluded. Paginates the DC list endpoint. Empty queue ->
#                          no output, exit 0. Order unspecified (the Marshal sorts).
#                          Trunk: --base > $AUTOPILOT_TRUNK > repo default-branch.
#                          (The Merge Marshal's queue primitive — see
#                           plugins/zero-trust/references/host-contract.md.)
#   repo-list         --org <PROJECT-KEY>                       (ADR 0028)
#                       -> enumerate the project's repositories as TSV, one per
#                          line: <slug>\t<clone-or-api-url> (ssh clone link
#                          preferred, else the first clone link). Paginates the
#                          DC repos endpoint; rides the same hardened path as
#                          every other subcommand (secret_get.sh, -H @file,
#                          bb_curl, die_state). Needs NO repo coordinates —
#                          only a REST host (see the lazy-derivation note).
#
# Draft PRs (AV3-06 / AV3-15). AUTOPILOT_BITBUCKET_DRAFT_MODE selects the
# mechanism:
#   native (default) -- the PR `draft` boolean field (Bitbucket DC 8.x+).
#                       pr-open --draft sets draft:true; pr-state emits DRAFT
#                       while draft && OPEN; pr-ready clears the flag.
#   title-prefix     -- a "[DRAFT] " title convention for older DC servers that
#                       predate native draft PRs. pr-open --draft prepends the
#                       prefix; pr-state emits DRAFT for a prefixed OPEN PR;
#                       pr-ready strips the prefix. (Native `draft:true` is
#                       ALSO honoured as DRAFT in either mode, so a server that
#                       later gains native drafts is never misread.)
#
# All PR/build subcommands derive PROJECT_KEY and REPO_SLUG from
# `git remote get-url origin`. Derivation is LAZY (ADR 0028): it runs from the
# dispatch for the subcommands that need repo coordinates. `repo-list` does NOT
# (its project key is the caller-supplied --org), but it still resolves BB_HOST
# — sidecar base > $AUTOPILOT_BITBUCKET_HOST > origin-derived — and dies
# `no-host-source` when none exists (host resolution is never skipped).
# Expected origin shape: https://<host>/scm/<project>/<repo>.git
#
# BB_HOST derivation (non-sidecar REST target): AUTOPILOT_BITBUCKET_HOST env
# override > https-origin host verbatim > ssh-origin host with the first
# label's `-ssh` suffix stripped (the Bitbucket DC split-SSH-endpoint
# convention — the REST API is never served on the SSH host). See the
# derivation block below; `repo-coords` (internal) prints the result.
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
# v2.4.0 fixes (see CHANGELOG.md §2.4.0, gaps A1, A9, B1, B2):
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
subcommands: pr-open pr-ready pr-state pr-comment pr-approve pr-decline pr-merge pr-merge-strategies build-status pr-list-ready repo-list
internal:    repo-coords (debug: prints derived PROJECT_KEY/REPO_SLUG/BB_HOST; not part of the host-adapter contract)
EOF
  exit 64
}

# Draft-PR mechanism selector (see the header block). Default: native.
DRAFT_MODE="${AUTOPILOT_BITBUCKET_DRAFT_MODE:-native}"
DRAFT_PREFIX="[DRAFT] "

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
# Lazy derivation (ADR 0028): the dispatch calls derive_repo_coords +
# derive_bb_host for every PR/build subcommand (preserving the historical
# no-origin -> origin-parse -> host-parse failure order); repo-list calls
# ONLY derive_bb_host, and only outside sidecar mode.

ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"

PROJECT_KEY=""
REPO_SLUG=""
derive_repo_coords() {
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
}

# Bitbucket DC host (for non-sidecar mode). Precedence:
#   1. $AUTOPILOT_BITBUCKET_HOST — explicit operator override; the escape hatch
#      for deployments whose REST host cannot be derived from origin at all.
#   2. https origin — the URL host verbatim (it already serves REST).
#   3. ssh origin   — the URL host with a `-ssh` suffix stripped from the FIRST
#      hostname label (`bb-ssh.example.com` -> `bb.example.com`; dotless
#      search-domain-resolved intranet hosts too: `bitbucket-ssh` ->
#      `bitbucket`). Bitbucket DC
#      deployments commonly publish a dedicated SSH endpoint host alongside the
#      HTTPS/REST host; REST calls against the `-ssh` host always fail, so a
#      host derived from an SSH remote must map back to the REST host. (Field
#      evidence: 20+ REST calls per drain needed a manual workaround before
#      this strip.) A deployment whose REST host genuinely contains `-ssh.`
#      sets AUTOPILOT_BITBUCKET_HOST instead.
BB_HOST=""
derive_bb_host() {
  if [[ -n "${AUTOPILOT_BITBUCKET_HOST:-}" ]]; then
    BB_HOST="$AUTOPILOT_BITBUCKET_HOST"
    return 0
  fi
  # Reachable with an empty origin ONLY via repo-list (PR/build subcommands die
  # no-origin in derive_repo_coords first): outside a repo the REST target has
  # no source at all — die usefully rather than fabricating a host (ADR 0028).
  [[ -n "$ORIGIN_URL" ]] || die_state "no-host-source" \
    "repo-list needs a REST host: run inside a repo with a Bitbucket origin, or set AUTOPILOT_BITBUCKET_HOST (or use the sidecar)"
  if [[ "$ORIGIN_URL" =~ https?://([^/]+)/ ]]; then
    BB_HOST="${BASH_REMATCH[1]}"
  elif [[ "$ORIGIN_URL" =~ @([^:/]+)[:/] ]]; then
    BB_HOST="${BASH_REMATCH[1]}"
    # Split-SSH-endpoint convention (see the precedence note above). The `(\.|$)`
    # alternation covers dotless single-label intranet hosts (`bitbucket-ssh`),
    # where the whole host IS the first label — a dot-anchored pattern never
    # fired on them and left every REST call pointed at the SSH endpoint.
    BB_HOST="$(printf '%s' "$BB_HOST" | sed -E 's/^([^.]+)-ssh(\.|$)/\1\2/')"
  else
    die_state "host-parse" "cannot parse host from origin URL"
  fi
}

# --- Auth/routing -------------------------------------------------------------

MODE_LINE="$("$HERE/sidecar_detect.sh")"
SIDECAR_MODE=0
SIDECAR_BASE=""
SIDECAR_PLATFORM_ID=""
# sidecar_detect.sh emits `MODE=... PLATFORMS="..." URL="..."`. Parse without
# eval (the values are env-derived; eval would be an injection surface). The
# key tokens are single-occurrence in the controlled mode-line, so an anchored
# match is unambiguous WITHOUT a `\b` word boundary — and `\b` is a GNU-sed
# extension BSD/macOS sed does not honour (it would silently yield empty and
# force every call to local mode). Portable across GNU and BSD sed.
MODE=$(sed -n 's/^.*MODE=\([a-z]*\).*$/\1/p' <<<"$MODE_LINE")
PLATFORMS=$(sed -n 's/^.*PLATFORMS="\([^"]*\)".*$/\1/p' <<<"$MODE_LINE")
URL=$(sed -n 's/^.*URL="\([^"]*\)".*$/\1/p' <<<"$MODE_LINE")
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
    # ${arr[@]+"${arr[@]}"} guard: bash 3.2 (the macOS default shell) treats a
    # bare "${empty[@]}" as an unbound-variable error under set -u. CURL_AUTH is
    # empty in sidecar-mode-without-CA, and extra[] is empty on every GET, so
    # both MUST use the alternate-expansion guard to stay portable.
    http_code=$(curl -sS --max-time 30 \
      -X "$method" \
      -o "$tmp_raw" \
      -D "$tmp_hdr" \
      -w '%{http_code}' \
      ${CURL_AUTH[@]+"${CURL_AUTH[@]}"} \
      ${extra[@]+"${extra[@]}"} \
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

  # Draft handling. Native sets the `draft` payload boolean; title-prefix
  # rewrites the title with the "[DRAFT] " convention for servers predating
  # native draft PRs (the boolean stays false there).
  local draft_bool=false
  if (( draft == 1 )); then
    if [[ "$DRAFT_MODE" == "title-prefix" ]]; then
      title="${DRAFT_PREFIX}${title}"
    else
      draft_bool=true
    fi
  fi

  local payload
  payload=$(jq -n \
    --arg title "$title" \
    --arg desc "$body" \
    --arg src "$src" \
    --arg dest "$dest" \
    --arg slug "$REPO_SLUG" \
    --arg proj "$PROJECT_KEY" \
    --argjson draft "$draft_bool" \
    '{
      title: $title,
      description: $desc,
      state: "OPEN",
      open: true,
      closed: false,
      draft: $draft,
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
    # DRAFT is emitted for an OPEN PR that is either natively draft
    # (draft:true) or, in title-prefix mode, carries the "[DRAFT] " title.
    jq -r --arg mode "$DRAFT_MODE" --arg pfx "$DRAFT_PREFIX" '
      (.state // "UNKNOWN") as $st
      | ((.draft // false) == true) as $ndraft
      | (($mode == "title-prefix") and (((.title // "") | startswith($pfx)))) as $pdraft
      | if $st == "OPEN" and ($ndraft or $pdraft) then "DRAFT" else $st end
    ' < "$resp_f"
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
    jq -r --arg mode "$DRAFT_MODE" --arg pfx "$DRAFT_PREFIX" '
      (.values // [])
      | if length == 0 then "NONE"
        else .[0] as $pr
          | ($pr.state // "UNKNOWN") as $st
          | (($pr.draft // false) == true) as $ndraft
          | (($mode == "title-prefix") and ((($pr.title // "") | startswith($pfx)))) as $pdraft
          | if $st == "OPEN" and ($ndraft or $pdraft) then "DRAFT" else $st end
        end
    ' < "$resp_f"
  fi
  rm -f "$resp_f"
}

# pr-ready: flip a draft PR to ready-for-review. Native mode clears the
# `draft` boolean; title-prefix mode also strips the "[DRAFT] " title prefix.
# Idempotent on an already-ready PR. (AV3-06 / AV3-15)
cmd_pr_ready() {
  require_jq
  local num=""
  while (( $# > 0 )); do
    case "$1" in
      --num) num="$2"; shift 2 ;;
      *) die_state "arg-parse" "pr-ready: unknown arg $1" ;;
    esac
  done
  [[ -n "$num" ]] || die_state "arg-parse" "pr-ready: --num required"

  # Resolve current version + title (the DC update endpoint requires version).
  local url resp_f version title
  url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests/${num}")
  resp_f=$(mktemp)
  bb_curl GET "$url" "$resp_f"
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    rm -f "$resp_f"
    die_state "pr-ready-version-http-${HTTP_STATUS}" "cannot resolve PR version"
  fi
  version=$(jq -r '.version // empty' < "$resp_f")
  title=$(jq -r '.title // ""' < "$resp_f")
  [[ -n "$version" ]] || { rm -f "$resp_f"; die_state "pr-ready-no-version" "PR version missing"; }

  # In title-prefix mode, strip a leading "[DRAFT] " so the ready PR has a
  # clean title. Native mode leaves the title untouched.
  local ready_title="$title"
  if [[ "$DRAFT_MODE" == "title-prefix" ]]; then
    case "$title" in
      "$DRAFT_PREFIX"*) ready_title="${title#"$DRAFT_PREFIX"}" ;;
    esac
  fi

  local payload
  payload=$(jq -n --arg t "$ready_title" --argjson v "$version" \
    '{version: $v, title: $t, draft: false}')
  bb_curl PUT "$url" "$resp_f" -H 'Content-Type: application/json' -d "$payload"
  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    local excerpt; excerpt=$(body_excerpt "$resp_f"); rm -f "$resp_f"
    die_state "pr-ready-http-${HTTP_STATUS}" "pr-ready failed: $excerpt"
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

# dc_enabled_strategies: RAW Bitbucket DC strategy ids the repo has enabled
# (e.g. no-ff, squash, rebase-no-ff, squash-ff-only). Internal — cmd_pr_merge
# matches its DC candidate ids against these. Prints the "merge-commit" sentinel
# when the settings endpoint is absent (older DC = no restriction info).
dc_enabled_strategies() {
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

# pr-merge-strategies (public): the OPERATOR-vocabulary tokens the repo permits
# — exactly the tokens `pr-merge --strategy` accepts, so the output is
# self-consumable (feeding a token back into pr-merge never errors). Mapped from
# the raw DC ids. The available SET reflects host capability, so it is NOT
# byte-identical across backends; each token IS shared and consumable.
cmd_pr_merge_strategies() {
  local raw
  raw=$(dc_enabled_strategies)
  if [[ -z "$raw" || "$raw" == "merge-commit" ]]; then
    echo "merge-commit"
    return 0
  fi
  # DC id -> operator token; dedup preserving first-seen order. Unknown ids pass
  # through unchanged (never silently drop a capability). BSD-awk safe.
  printf '%s\n' "$raw" | awk '
    {
      id = $0
      if (id == "no-ff") t = "no-ff"
      else if (id == "ff" || id == "ff-only") t = "ff-only"
      else if (id == "squash" || id == "squash-ff-only") t = "squash"
      else if (id == "rebase-no-ff" || id == "rebase-ff-only") t = "rebase"
      else t = id
      if (t != "" && !(t in seen)) { seen[t] = 1; print t }
    }'
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
  enabled=$(dc_enabled_strategies 2>/dev/null || true)
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

# resolve_trunk: the base branch the merge queue targets. Precedence:
#   1. --base <b>  2. $AUTOPILOT_TRUNK  3. the repo's DC default-branch  4. "main".
#   Symmetric with github.sh so the adapter is host-agnostic.
resolve_trunk() {  # <explicit-base-or-empty> -> echoes the trunk branch name
  local explicit="$1"
  if [[ -n "$explicit" ]]; then printf '%s' "$explicit"; return 0; fi
  if [[ -n "${AUTOPILOT_TRUNK:-}" ]]; then printf '%s' "$AUTOPILOT_TRUNK"; return 0; fi
  local url resp_f db=""
  url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/default-branch")
  resp_f=$(mktemp)
  bb_curl GET "$url" "$resp_f"
  if (( HTTP_STATUS >= 200 && HTTP_STATUS < 300 )); then
    db=$(jq -r '.displayId // empty' < "$resp_f" 2>/dev/null || true)
  fi
  rm -f "$resp_f"
  [[ -n "$db" ]] || db="main"
  printf '%s' "$db"
}

# pr-list-ready: enumerate the merge queue as the marshal-consumable 5-column TSV
#   <ready_ts>\t<pr_num>\t<src_branch>\t<head_sha>\t<approval>
# See the header block and plugins/zero-trust/references/host-contract.md.
cmd_pr_list_ready() {
  require_jq
  local base=""
  while (( $# > 0 )); do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      *) die_state "arg-parse" "pr-list-ready: unknown arg $1" ;;
    esac
  done
  local trunk
  trunk="$(resolve_trunk "$base")"

  # Paginate the DC pull-requests list (OPEN, all target branches — DC has no
  # server-side toRef filter on this endpoint, so trunk selection is client-side).
  # Every emitted field is non-empty and the ready_ts/approval are computed in jq,
  # so the output is a clean 5-column TSV with no shifting.
  local resp_f start=0 page=0 last nps
  resp_f=$(mktemp)
  while (( page < 1000 )); do   # hard page cap: a runaway-pagination backstop
    page=$((page+1))
    local url
    url=$(build_url "/rest/api/1.0/projects/${PROJECT_KEY}/repos/${REPO_SLUG}/pull-requests?state=OPEN&order=NEWEST&withProperties=false&limit=100&start=${start}")
    bb_curl GET "$url" "$resp_f"
    if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
      rm -f "$resp_f"
      die_state "pr-list-ready-http-${HTTP_STATUS}" "pr-list-ready failed"
    fi
    jq -r --arg trunk "$trunk" --arg mode "$DRAFT_MODE" --arg pfx "$DRAFT_PREFIX" '
      (.values // [])
      | .[]
      # target the trunk (toRef displayId, or its refs/heads/ id form)
      | select( ((.toRef.displayId // "") == $trunk)
                or ((.toRef.id // "") == ("refs/heads/" + $trunk)) )
      # exclude drafts: native draft flag, or (title-prefix mode) the [DRAFT] title
      | ((.draft // false) == true) as $ndraft
      | (($mode == "title-prefix") and (((.title // "") | startswith($pfx)))) as $pdraft
      | select(($ndraft or $pdraft) | not)
      # a PR with no source head commit is not a merge candidate (drop it; an empty
      # head_sha field would also shift the Marshal read under IFS=TAB)
      | select((.fromRef.latestCommit // "") != "")
      # approval: >=1 reviewer AND all reviewers approved (all-of-empty is true, so
      # the count guard keeps a reviewer-less PR PENDING)
      | ( ((.reviewers // []) | length) as $rn
          | (if $rn > 0 and ((.reviewers // []) | all(.approved == true))
             then "APPROVED" else "PENDING" end) ) as $approval
      | [ ((.createdDate // 0) / 1000 | floor),
          .id,
          (.fromRef.displayId // ((.fromRef.id // "") | ltrimstr("refs/heads/"))),
          .fromRef.latestCommit,
          $approval ]
      | @tsv
    ' < "$resp_f" 2>/dev/null || { rm -f "$resp_f"; die_state "pr-list-ready-parse" "cannot parse DC pull-request list"; }

    # DC pagination cursor. jq's `//` treats false like null (`false // true` ==
    # true), so isLastPage MUST be read via has()+else — `.isLastPage // true` would
    # misread a genuine `false` as `true` and stop after page 1, dropping the OLDEST
    # (order=NEWEST) PRs, i.e. exactly the FIFO head the Marshal merges first.
    last=$(jq -r 'if has("isLastPage") then .isLastPage else true end' < "$resp_f" 2>/dev/null || echo true)
    [[ "$last" == "true" ]] && break
    nps=$(jq -r '.nextPageStart // empty' < "$resp_f" 2>/dev/null || echo "")
    # No advancing cursor -> stop (never loop forever on a malformed page).
    [[ -n "$nps" && "$nps" != "$start" ]] || break
    start="$nps"
  done
  rm -f "$resp_f"
}

# repo-list: enumerate a project's repositories as the OWM-consumable 2-column
# TSV `<slug>\t<clone-or-api-url>` (ADR 0028 — org enumeration is a backend
# method behind host.sh, never a parallel transport; see host-contract.md).
# The lazy-coords split: --org IS the project key, so PROJECT_KEY/REPO_SLUG are
# never derived here; BB_HOST resolution still runs (non-sidecar) and dies
# no-host-source when neither origin nor AUTOPILOT_BITBUCKET_HOST supplies one.
cmd_repo_list() {
  require_jq; require_python3
  local org=""
  while (( $# > 0 )); do
    case "$1" in
      --org) org="$2"; shift 2 ;;
      *) die_state "arg-parse" "repo-list: unknown arg $1" ;;
    esac
  done
  [[ -n "$org" ]] || die_state "arg-parse" "repo-list: --org required"
  (( SIDECAR_MODE == 1 )) || derive_bb_host

  # Paginate the DC repos endpoint — the same cursor loop as pr-list-ready.
  local resp_f start=0 page=0 last nps
  resp_f=$(mktemp)
  while (( page < 1000 )); do   # hard page cap: a runaway-pagination backstop
    page=$((page+1))
    local url
    url=$(build_url "/rest/api/1.0/projects/${org}/repos?limit=100&start=${start}")
    bb_curl GET "$url" "$resp_f"
    if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
      rm -f "$resp_f"
      die_state "repo-list-http-${HTTP_STATUS}" "repo-list failed for project ${org}"
    fi
    # slug + clone URL (ssh link preferred, else the first clone link). These
    # are STRING fields, so jq `//` alternates are safe here; the boolean-
    # carrying isLastPage cursor below stays on the has() guard.
    jq -r '
      (.values // [])
      | .[]
      | (.slug // .name // "") as $slug
      | select($slug != "")
      | ((.links.clone // []) | map(select((.name // "") == "ssh")) | (.[0].href // "")) as $ssh
      | ((.links.clone // []) | (.[0].href // "")) as $first
      | [ $slug, (if $ssh != "" then $ssh else $first end) ]
      | @tsv
    ' < "$resp_f" 2>/dev/null || { rm -f "$resp_f"; die_state "repo-list-parse" "cannot parse DC repository list"; }

    # DC pagination cursor — identical discipline to pr-list-ready: isLastPage is
    # a BOOLEAN, and jq's `//` treats false like null (`false // true` == true),
    # so it MUST be read via has()+else or a genuine `false` stops after page 1.
    last=$(jq -r 'if has("isLastPage") then .isLastPage else true end' < "$resp_f" 2>/dev/null || echo true)
    [[ "$last" == "true" ]] && break
    nps=$(jq -r '.nextPageStart // empty' < "$resp_f" 2>/dev/null || echo "")
    # No advancing cursor -> stop (never loop forever on a malformed page).
    [[ -n "$nps" && "$nps" != "$start" ]] || break
    start="$nps"
  done
  rm -f "$resp_f"
}

# repo-coords: internal debug/self-test surface (NOT part of the host-adapter
# contract; host.sh does not delegate it). Prints the derived repo coordinates
# so origin-URL/host derivation — including the SSH `-ssh` suffix strip and the
# AUTOPILOT_BITBUCKET_HOST override — is deterministically testable offline.
cmd_repo_coords() {
  printf 'PROJECT_KEY=%s\nREPO_SLUG=%s\nBB_HOST=%s\n' "$PROJECT_KEY" "$REPO_SLUG" "$BB_HOST"
}

# --- Dispatch -----------------------------------------------------------------

(( $# >= 1 )) || usage
SUB="$1"; shift
# Lazy-coords split (ADR 0028): repo-list needs no PROJECT_KEY/REPO_SLUG (it
# resolves BB_HOST itself); every other subcommand derives the full coordinate
# set here, preserving the historical failure order (no-origin -> origin-parse
# -> host-parse) the H50 / W345-BB families pin.
case "$SUB" in
  repo-list) : ;;
  repo-coords|pr-open|pr-ready|pr-state|pr-comment|pr-approve|pr-decline|pr-merge|pr-merge-strategies|build-status|pr-list-ready)
    derive_repo_coords
    derive_bb_host
    ;;
esac
case "$SUB" in
  repo-coords)          cmd_repo_coords "$@" ;;
  pr-open)              cmd_pr_open "$@" ;;
  pr-ready)             cmd_pr_ready "$@" ;;
  pr-state)             cmd_pr_state "$@" ;;
  pr-comment)           cmd_pr_comment "$@" ;;
  pr-approve)           cmd_pr_approve "$@" ;;
  pr-decline)           cmd_pr_decline "$@" ;;
  pr-merge)             cmd_pr_merge "$@" ;;
  pr-merge-strategies)  cmd_pr_merge_strategies "$@" ;;
  build-status)         cmd_build_status "$@" ;;
  pr-list-ready)        cmd_pr_list_ready "$@" ;;
  repo-list)            cmd_repo_list "$@" ;;
  *) usage ;;
esac
