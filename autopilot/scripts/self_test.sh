#!/usr/bin/env bash
# self_test.sh
#
# Hermetic self-test for the autopilot skill's deterministic substrate
# (every script under scripts/), plus the cross-file consistency lint as its
# final section. (GAPS M1: v2.3.0 shipped with zero executed verification —
# which is how a Bitbucket adapter that could never succeed, a force-push
# probe that could never detect a denial, and a concurrency guard that could
# never detect a concurrent drain all shipped simultaneously.)
#
# Ground rules:
#   - Hermetic: everything runs inside a mktemp -d sandbox with local bare
#     repos and a loopback mock Bitbucket DC server. No network, no keychain,
#     no writes outside the sandbox.
#   - Every assertion cites its GAPS_SPEC.md id (Txx). A new bug found in the
#     field MUST land here as a failing assertion before (or with) its fix.
#   - Run after ANY change under scripts/ or references/.
#
# Usage: bash scripts/self_test.sh
# Exit 0 = all assertions pass; non-zero = at least one failure.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PASS=0
FAIL=0
fail() { echo "FAIL [$1] $2" >&2; FAIL=$((FAIL+1)); }
pass() { echo "ok   [$1] $2"; PASS=$((PASS+1)); }

assert_eq() {  # id desc expected actual
  if [[ "$3" == "$4" ]]; then pass "$1" "$2"; else fail "$1" "$2 — expected [$3], got [$4]"; fi
}
assert_contains() {  # id desc needle haystack
  if grep -qF -- "$3" <<<"$4"; then pass "$1" "$2"; else fail "$1" "$2 — missing [$3] in output"; fi
}
assert_not_contains() {  # id desc needle haystack
  if grep -qF -- "$3" <<<"$4"; then fail "$1" "$2 — found forbidden [$3]"; else pass "$1" "$2"; fi
}

SANDBOX="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$SANDBOX"
}
trap cleanup EXIT INT TERM

export GIT_AUTHOR_NAME=selftest GIT_AUTHOR_EMAIL=selftest@local \
       GIT_COMMITTER_NAME=selftest GIT_COMMITTER_EMAIL=selftest@local
# Neutralize any operator git config that could alter output shapes.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# ------------------------------------------------------------------------------
# Mock Bitbucket DC / sidecar server
# ------------------------------------------------------------------------------

cat > "$SANDBOX/mock_server.py" <<'PYEOF'
import http.server, json, re, sys, threading

STATE = {"pr43_merge_calls": 0, "last_merge_strategy": None, "pr43_version": 3,
         "last_pr": None, "last_put": None}

class H(http.server.BaseHTTPRequestHandler):
    def _send_json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self._send_raw(b, code)

    def _send_raw(self, b, code=200, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _strip(self):
        # Sidecar URL shape: /<platform-id>/<upstream-path>
        p = self.path
        for pid in ("/bitbucketdc", "/bitbucket"):
            if p.startswith(pid + "/"):
                return p[len(pid):]
        return p

    def do_GET(self):
        p = self._strip()
        if p.endswith("/badok/healthz"):
            self._send_raw(b"nope", 200, "text/plain"); return
        if p.endswith("/notok/healthz"):
            self._send_raw(b"not ok", 200, "text/plain"); return
        if p.endswith("/healthz"):
            self._send_raw(b"ok", 200, "text/plain"); return
        if p == "/debug/last-merge":
            self._send_json({"strategy": STATE["last_merge_strategy"]}); return
        if p == "/debug/last-pr":
            self._send_json(STATE.get("last_pr") or {}); return
        if p == "/debug/last-put":
            self._send_json(STATE.get("last_put") or {}); return
        m = re.search(r"/pull-requests/(\d+)$", p)
        if m:
            num = m.group(1)
            if num == "55":
                self._send_json({"id": 55, "state": "DECLINED", "version": 1}); return
            if num == "43":
                self._send_json({"id": 43, "state": "OPEN", "version": STATE["pr43_version"]}); return
            if num == "401":
                self._send_json({"error": "auth", "hint": "token-shaped-error-string-DO-NOT-LOG"}, 401); return
            if num == "407":
                self._send_json({"error": "sidecar misconfigured"}, 407); return
            if num == "44":
                STATE["pr44_calls"] = STATE.get("pr44_calls", 0) + 1
                if STATE["pr44_calls"] == 1:
                    b = json.dumps({"error": "rate"}).encode()
                    self.send_response(429)
                    self.send_header("Retry-After", "0")
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(b)))
                    self.end_headers()
                    self.wfile.write(b)
                    return
                self._send_json({"id": 44, "state": "OPEN", "version": 1}); return
            if num == "91":
                # AV3-15 native-draft fixture: draft flag true, OPEN.
                self._send_json({"id": 91, "state": "OPEN", "version": 1,
                                 "draft": True, "title": "Native draft PR"}); return
            if num == "92":
                # AV3-15 title-prefix fixture: no draft flag, "[DRAFT] " title.
                self._send_json({"id": 92, "state": "OPEN", "version": 2,
                                 "draft": False, "title": "[DRAFT] Prefixed PR"}); return
            self._send_json({"id": int(num), "state": "OPEN", "version": 3}); return
        if "/pull-requests?" in p:
            if "at=refs/heads/feature-x" in p:
                self._send_json({"values": [{"id": 42, "state": "OPEN"}]}); return
            self._send_json({"values": []}); return
        if "/settings/pull-requests" in p:
            self._send_json({"mergeConfig": {"strategies": [
                {"id": "squash", "enabled": True},
                {"id": "rebase-no-ff", "enabled": True},
                {"id": "no-ff", "enabled": False},
            ]}}); return
        if "/build-status/1.0/commits/" in p:
            sha = p.rsplit("/", 1)[1]
            if sha.startswith("aaa"):
                self._send_json({"values": [{"state": "SUCCESSFUL"}]}); return
            if sha.startswith("bbb"):
                self._send_json({"values": [{"state": "FAILED"}]}); return
            if sha.startswith("ccc"):
                self._send_json({"values": [{"state": "INPROGRESS"}]}); return
            self._send_json({"values": []}); return
        self._send_json({"error": "unmocked GET " + p}, 404)

    def do_POST(self):
        p = self._strip()
        ln = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(ln) if ln else b""
        if p.endswith("/pull-requests"):
            # Capture the POSTed title/draft for the AV3-15 draft-open assertions.
            try:
                bj = json.loads(body.decode("utf-8", "replace"))
                STATE["last_pr"] = {"title": bj.get("title"), "draft": bj.get("draft")}
            except Exception:
                STATE["last_pr"] = {"title": None, "draft": None}
            # T04: response body deliberately contains invalid UTF-8 bytes.
            raw = b'{"id": 77, "state": "OPEN", "title": "caf\xe9 \xff"}'
            self._send_raw(raw, 201); return
        m = re.search(r"/pull-requests/(\d+)/merge", p)
        if m:
            try:
                STATE["last_merge_strategy"] = json.loads(body.decode("utf-8", "replace")).get("strategy")
            except Exception:
                STATE["last_merge_strategy"] = "unparseable"
            if m.group(1) == "43" and STATE["pr43_merge_calls"] == 0:
                STATE["pr43_merge_calls"] += 1
                STATE["pr43_version"] += 1
                self._send_json({"error": "conflict"}, 409); return
            self._send_json({}); return
        if p.endswith("/comments") or p.endswith("/approve") or "/decline" in p:
            self._send_json({"ok": True}, 200); return
        self._send_json({"error": "unmocked POST " + p}, 404)

    def do_PUT(self):
        # AV3-15 pr-ready: the DC update endpoint. Capture the flip payload.
        p = self._strip()
        ln = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(ln) if ln else b""
        m = re.search(r"/pull-requests/(\d+)$", p)
        if m:
            try:
                bj = json.loads(body.decode("utf-8", "replace"))
                STATE["last_put"] = {"id": m.group(1), "title": bj.get("title"),
                                     "draft": bj.get("draft")}
            except Exception:
                STATE["last_put"] = {"id": m.group(1)}
            self._send_json({"id": int(m.group(1)), "state": "OPEN", "version": 99}); return
        self._send_json({"error": "unmocked PUT " + p}, 404)

    def log_message(self, *a):
        pass

srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF

# MOCK_OK gates the HTTP-mock-dependent sections. A missing uv toolchain or a
# bound-but-unreachable server (both observed in locked-down sandboxes) SKIPS
# those DC-backend HTTP tests rather than aborting the run, so the deterministic
# assertions, the gh-argv-shim GitHub-backend matrix, and the consistency lint
# always execute. (AV3-15: the GitHub backend has zero dependency on this server.)
#
# ADR 0015: the mock server launches through `uv run` (self-bootstrapping Python
# toolchain), not a bare `python3` — killing the python3-not-on-PATH fragility.
# The server is stdlib-only, so `--no-project` runs it with no dependency
# resolution and no CWD sensitivity. uv forwards SIGTERM to its python child, so
# the EXIT-trap `kill "$SERVER_PID"` still cleans the server up.
MOCK_OK=1
PORT=""
if command -v uv >/dev/null 2>&1; then
  uv run --no-project python "$SANDBOX/mock_server.py" "$SANDBOX/port" 2>/dev/null &
  SERVER_PID=$!
  for _ in $(seq 1 50); do [[ -s "$SANDBOX/port" ]] && break; sleep 0.1; done
  PORT="$(cat "$SANDBOX/port" 2>/dev/null || true)"
fi
if [[ -n "$PORT" ]] && curl -s -m 3 -o /dev/null "http://127.0.0.1:${PORT}/healthz" 2>/dev/null; then
  BASE="http://127.0.0.1:${PORT}"
else
  MOCK_OK=0
  BASE=""
  echo "note: mock Bitbucket DC server unavailable — DC-backend HTTP tests SKIPPED (deterministic + GitHub-backend + lint still run)" >&2
fi

# Fixture repo with a Bitbucket-shaped origin URL (repo-coord parsing).
API_REPO="$SANDBOX/api-repo"
git init -q "$API_REPO"
git -C "$API_REPO" remote add origin "https://bb.example.com/scm/PROJ/myrepo.git"

# Env for sidecar-routed calls. PLATFORMS uses the CONTRACT-canonical id
# "bitbucketdc" (GAPS A9 — v2.3.0 only matched legacy "bitbucket" and
# silently bypassed a conformant sidecar).
bb() {
  ( cd "$API_REPO" && \
    IDENTITY_PROXY_URL="$BASE" IDENTITY_PROXY_PLATFORMS="bitbucketdc,jira" \
    bash "$HERE/bitbucket.sh" "$@" )
}

# DC backend with an explicit AUTOPILOT_BITBUCKET_DRAFT_MODE (native|title-prefix).
bbdraft() {  # <mode> <bitbucket.sh args...>
  local mode="$1"; shift
  ( cd "$API_REPO" && \
    IDENTITY_PROXY_URL="$BASE" IDENTITY_PROXY_PLATFORMS="bitbucketdc,jira" \
    AUTOPILOT_BITBUCKET_DRAFT_MODE="$mode" \
    bash "$HERE/bitbucket.sh" "$@" )
}

# host.sh dispatched from the DC-shaped repo (must resolve backend BITBUCKET_DC).
hostbb() {
  ( cd "$API_REPO" && \
    IDENTITY_PROXY_URL="$BASE" IDENTITY_PROXY_PLATFORMS="bitbucketdc,jira" \
    bash "$HERE/host.sh" "$@" )
}

SKIP=0
skip() { echo "skip [$1] $2"; SKIP=$((SKIP+1)); }

# The byte-identical PR/build contract, exercised THROUGH host.sh so the same
# assertion set proves both backends (ADR 0013). <invoker-fn> runs the host
# adapter from the backend's fixture repo. Fixtures are aligned across the DC
# mock server and the gh argv shim so this body needs no per-backend branching.
contract_matrix() {  # <id> <invoker-fn>
  local ID="$1" H="$2" out rc bodyf
  bodyf="$SANDBOX/cm_body.md"; printf 'Summary\n' > "$bodyf"
  out=$($H pr-state --num 42 2>/dev/null); rc=$?
  assert_eq "$ID" "pr-state --num 42 exits 0" "0" "$rc"
  assert_eq "$ID" "pr-state --num 42 -> OPEN" "OPEN" "$out"
  assert_eq "$ID" "pr-state --branch feature-x -> OPEN" "OPEN" "$($H pr-state --branch feature-x 2>/dev/null)"
  assert_eq "$ID" "pr-state --branch absent -> NONE" "NONE" "$($H pr-state --branch no-pr-here 2>/dev/null)"
  out=$($H pr-open --title "t" --src b1 --dest main --body-file "$bodyf" 2>/dev/null); rc=$?
  assert_eq "$ID" "pr-open exits 0" "0" "$rc"
  assert_eq "$ID" "pr-open prints PR id 77" "77" "$out"
  $H pr-comment --num 42 --body-file "$bodyf" >/dev/null 2>&1; rc=$?
  assert_eq "$ID" "pr-comment exits 0" "0" "$rc"
  $H pr-approve --num 42 >/dev/null 2>&1; rc=$?
  assert_eq "$ID" "pr-approve exits 0" "0" "$rc"
  $H pr-decline --num 55 >/dev/null 2>&1; rc=$?
  assert_eq "$ID" "pr-decline exits 0" "0" "$rc"
  $H pr-merge --num 42 --strategy merge-commit >/dev/null 2>&1; rc=$?
  assert_eq "$ID" "pr-merge exits 0" "0" "$rc"
  assert_eq "$ID" "build-status aaa -> SUCCESSFUL" "SUCCESSFUL" "$($H build-status --sha aaa111 2>/dev/null)"
  assert_eq "$ID" "build-status bbb -> FAILED" "FAILED" "$($H build-status --sha bbb222 2>/dev/null)"
  assert_eq "$ID" "build-status ccc -> INPROGRESS" "INPROGRESS" "$($H build-status --sha ccc333 2>/dev/null)"
  assert_eq "$ID" "build-status ddd -> UNKNOWN" "UNKNOWN" "$($H build-status --sha ddd444 2>/dev/null)"
}

echo "== bitbucket.sh + DC backend (T01-T07, T35, T36, HD01-HD10) =="
if (( MOCK_OK )); then

# T01 — pr-state --num succeeds on a healthy 200 (baseline A1: always died pr-state-http-0).
out=$(bb pr-state --num 42 2>"$SANDBOX/t01.err"); rc=$?
assert_eq T01 "pr-state --num 42 exits 0" "0" "$rc"
assert_eq T01 "pr-state --num 42 prints OPEN" "OPEN" "$out"

# T02 — pr-state --branch: found and not-found.
out=$(bb pr-state --branch feature-x 2>/dev/null)
assert_eq T02 "pr-state --branch feature-x prints OPEN" "OPEN" "$out"
out=$(bb pr-state --branch no-pr-here 2>/dev/null)
assert_eq T02 "pr-state --branch no-pr-here prints NONE" "NONE" "$out"

# T03 — local mode: token reaches curl via -H @file, never argv (GAPS: token
# was in argv, visible in /proc/*/cmdline; contradicted sidecar-contract).
SHIM="$SANDBOX/shim"; mkdir -p "$SHIM"
cat > "$SHIM/curl" <<'SHIMEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${CURL_ARGV_LOG:?}"
out=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  prev="$a"
done
[[ -n "$out" ]] && printf '{"id": 42, "state": "OPEN", "version": 1}' > "$out"
printf '200'
SHIMEOF
chmod +x "$SHIM/curl"
argv_log="$SANDBOX/curl_argv.log"
( cd "$API_REPO" && \
  PATH="$SHIM:$PATH" CURL_ARGV_LOG="$argv_log" \
  AUTOPILOT_BITBUCKET_TOKEN="supersecret-token-123" \
  bash "$HERE/bitbucket.sh" pr-state --num 42 >/dev/null 2>&1 )
argv_content="$(cat "$argv_log" 2>/dev/null || true)"
assert_not_contains T03 "token never appears in curl argv" "supersecret-token-123" "$argv_content"
assert_contains T03 "auth header passed via -H @file" "@/" "$argv_content"

# T04 — pr-open: response with invalid UTF-8 still yields the PR id
# (GAPS B1: response sanitisation was claimed in v2.1.0, never implemented).
bodyf="$SANDBOX/prbody.md"; printf 'Summary\n' > "$bodyf"
out=$(bb pr-open --title "t" --src b1 --dest main --body-file "$bodyf" 2>"$SANDBOX/t04.err"); rc=$?
assert_eq T04 "pr-open exits 0 despite invalid UTF-8 in response" "0" "$rc"
assert_eq T04 "pr-open prints PR id 77" "77" "$out"

# T05 — sidecar platform id bitbucketdc is accepted and routed (GAPS A9).
# (T01 already proves routing works; here we prove the request went through
# the sidecar rather than falling back to local credentials: no token exists
# in this environment, so local mode would die credential-unavailable.)
err=$(bb pr-state --num 42 2>&1 >/dev/null || true)
assert_not_contains T05 "conformant sidecar not bypassed to local mode" "credential-unavailable" "$err"

# T06 — pr-merge discovers enabled strategies and falls back (GAPS B2:
# discovery was claimed in v2.1.0; v2.3.0 statically mapped and never called it).
err=$(bb pr-merge --num 42 --strategy merge-commit 2>&1); rc=$?
assert_eq T06 "pr-merge exits 0 with fallback strategy" "0" "$rc"
assert_contains T06 "pr-merge announces enabled-strategy fallback" "using enabled fallback 'squash'" "$err"
strategy=$(curl -s "$BASE/debug/last-merge" | sed -n 's/.*"strategy": *"\([^"]*\)".*/\1/p')
assert_eq T06 "server received the enabled strategy" "squash" "$strategy"

# T07 — pr-merge retries exactly once on 409 with a fresh version.
err=$(bb pr-merge --num 43 --strategy squash 2>&1); rc=$?
assert_eq T07 "pr-merge succeeds after one 409 retry" "0" "$rc"
assert_contains T07 "409 retry announced" "retrying with fresh version" "$err"

# T35 — auth-failure bodies are never logged (sidecar-contract rule).
err=$(bb pr-state --num 401 2>&1 >/dev/null || true)
assert_not_contains T35 "401 body not logged" "token-shaped-error-string-DO-NOT-LOG" "$err"
assert_contains T35 "401 failure still classified" "LAST_STATE=pr-state-http-401" "$err"

# T36 — sidecar error-code table: 429 honours Retry-After (1 retry), 407 is
# sidecar-session-invalid without body logging.
out=$(bb pr-state --num 44 2>"$SANDBOX/t36.err"); rc=$?
assert_eq T36 "429 retried once then succeeds" "0" "$rc"
assert_eq T36 "429 retry returns the real state" "OPEN" "$out"
assert_contains T36 "429 retry announced" "429 rate-limited; retrying once" "$(cat "$SANDBOX/t36.err")"
err=$(bb pr-state --num 407 2>&1 >/dev/null || true)
assert_contains T36 "407 classified as sidecar-session-invalid" "LAST_STATE=sidecar-session-invalid" "$err"
assert_not_contains T36 "407 body not logged" "sidecar misconfigured" "$err"

# --- AV3-15 draft surface + host.sh dispatch (DC backend) --------------------

# HD01 — native mode: a draft:true OPEN PR reports DRAFT.
assert_eq HD01 "native draft PR -> DRAFT" "DRAFT" "$(bb pr-state --num 91 2>/dev/null)"
# HD02 — native mode: an ordinary OPEN PR stays OPEN (DRAFT does not leak).
assert_eq HD02 "native non-draft PR -> OPEN" "OPEN" "$(bb pr-state --num 42 2>/dev/null)"

# HD03 — title-prefix mode: a "[DRAFT] "-titled OPEN PR reports DRAFT.
assert_eq HD03 "title-prefix PR -> DRAFT" "DRAFT" "$(bbdraft title-prefix pr-state --num 92 2>/dev/null)"
# HD03b — the "[DRAFT] " title is mode-gated: NOT interpreted under native mode.
assert_eq HD03 "title-prefix title ignored under native mode -> OPEN" "OPEN" "$(bbdraft native pr-state --num 92 2>/dev/null)"

bodyf2="$SANDBOX/hd_body.md"; printf 'Body\n' > "$bodyf2"
# HD04 — native pr-open --draft posts draft:true (title untouched).
out=$(bb pr-open --draft --title "Feature" --src fb --dest main --body-file "$bodyf2" 2>/dev/null)
assert_eq HD04 "native draft pr-open prints id" "77" "$out"
lp=$(curl -s "$BASE/debug/last-pr")
assert_contains HD04 "native draft pr-open posts draft:true" '"draft": true' "$lp"
assert_contains HD04 "native draft pr-open leaves title unprefixed" '"title": "Feature"' "$lp"

# HD05 — title-prefix pr-open --draft prepends "[DRAFT] " and posts draft:false.
out=$(bbdraft title-prefix pr-open --draft --title "Feature" --src fb --dest main --body-file "$bodyf2" 2>/dev/null)
assert_eq HD05 "title-prefix draft pr-open prints id" "77" "$out"
lp=$(curl -s "$BASE/debug/last-pr")
assert_contains HD05 "title-prefix pr-open prepends [DRAFT]" '"title": "[DRAFT] Feature"' "$lp"
assert_contains HD05 "title-prefix pr-open posts draft:false" '"draft": false' "$lp"

# HD06 — pr-ready (native) clears the draft flag via PUT.
bb pr-ready --num 43 >/dev/null 2>&1; rc=$?
assert_eq HD06 "pr-ready native exits 0" "0" "$rc"
assert_contains HD06 "pr-ready native PUTs draft:false" '"draft": false' "$(curl -s "$BASE/debug/last-put")"

# HD07 — pr-ready (title-prefix) strips the "[DRAFT] " prefix on flip.
bbdraft title-prefix pr-ready --num 92 >/dev/null 2>&1; rc=$?
assert_eq HD07 "pr-ready title-prefix exits 0" "0" "$rc"
assert_contains HD07 "pr-ready title-prefix strips the prefix" '"title": "Prefixed PR"' "$(curl -s "$BASE/debug/last-put")"

# HD11 — pr-merge-strategies emits OPERATOR tokens (self-consumable by pr-merge),
# NOT raw DC ids. The mock enables `squash` + `rebase-no-ff`; the adapter must
# map those to `squash` + `rebase` (a caller must be able to feed the output
# straight back into pr-merge --strategy).
out=$(bb pr-merge-strategies 2>/dev/null)
assert_eq HD11 "DC pr-merge-strategies maps DC ids -> operator tokens" "$(printf 'squash\nrebase')" "$out"
assert_not_contains HD11 "raw DC id rebase-no-ff does not leak" "rebase-no-ff" "$out"
bb pr-merge --num 42 --strategy squash >/dev/null 2>&1; rc=$?
assert_eq HD11 "squash token is pr-merge-consumable" "0" "$rc"
bb pr-merge --num 42 --strategy rebase >/dev/null 2>&1; rc=$?
assert_eq HD11 "rebase token is pr-merge-consumable" "0" "$rc"

# HD08 — host.sh detects the DC backend from the /scm/ origin shape.
assert_eq HD08 "host.sh backend -> BITBUCKET_DC" "BITBUCKET_DC" "$(hostbb backend 2>/dev/null)"

# HD09 — host.sh passes pr-state through byte-identically to the DC backend.
assert_eq HD09 "host.sh pr-state --num 42 -> OPEN" "OPEN" "$(hostbb pr-state --num 42 2>/dev/null)"
assert_eq HD09 "host.sh pr-state --num 91 -> DRAFT" "DRAFT" "$(hostbb pr-state --num 91 2>/dev/null)"

# HD10 — the shared T01-class contract matrix, host.sh -> DC backend.
contract_matrix H-DC hostbb

else
  skip DC-bitbucket "mock Bitbucket DC server unavailable in this environment"
fi

echo "== repo_shape_probe_patterns.sh (T08) =="

# T08 — table-driven: realistic Bitbucket DC rejection strings match their
# signals (GAPS A2: the v2.3.0 parser truncated every alternation-bearing
# regex at its first '|'; 5 of 6 rows below failed to match).
# shellcheck disable=SC1091
source "$HERE/repo_shape_probe_patterns.sh"
t08() {
  local msg="$1" expect="$2" f sig=""
  f="$SANDBOX/rej.log"; printf '%s\n' "$msg" > "$f"
  if match_rejection "$f" sig; then
    assert_eq T08 "pattern for: $msg" "$expect" "$sig"
  else
    if [[ "$expect" == "NOMATCH" ]]; then pass T08 "no match (as expected): $msg"; else fail T08 "no match for: $msg (expected $expect)"; fi
  fi
}
t08 "remote: You are not permitted to force-push to this branch" FORCE_PUSH_DENIED_BRANCH_PERM
t08 "remote: you are not permitted to rewrite history on this branch" FORCE_PUSH_DENIED_BRANCH_PERM
t08 "remote: hook declined: non-fast-forward updates are not allowed" FORCE_PUSH_DENIED_HOOK
t08 "! [remote rejected] b -> b (non-fast-forward)" FORCE_PUSH_DENIED_PROTECTED
t08 "remote: denying non-fast-forward refs/heads/x (you should pull first)" FORCE_PUSH_DENIED_PROTECTED
t08 "remote: commit message must contain a valid JIRA issue key" JIRA_HOOK_MISSING_KEY
t08 "remote: no jira issue found in commit message" JIRA_HOOK_MISSING_KEY
t08 "remote: JIRA issue ABC-1 is closed" JIRA_HOOK_INVALID_KEY
t08 "totally unrelated transport gibberish" NOMATCH
# Regression pin: the probe's own outvar is named `signal`; a local of the
# same name inside match_rejection shadows it via dynamic scoping and the
# caller reads "".
signal=""
printf 'remote: You are not permitted to force-push to this branch\n' > "$SANDBOX/rej.log"
match_rejection "$SANDBOX/rej.log" signal
assert_eq T08 "outvar named 'signal' is not shadowed by a local" "FORCE_PUSH_DENIED_BRANCH_PERM" "$signal"

echo "== repo_shape_probe.sh (T09-T11, T24, T26, T29) =="

make_remote_and_clone() {  # name -> sets REMOTE, CLONE
  local name="$1"
  REMOTE="$SANDBOX/${name}.git"
  CLONE="$SANDBOX/${name}-clone"
  git init -q --bare "$REMOTE"
  git init -q "$CLONE"
  git -C "$CLONE" config user.email selftest@local
  git -C "$CLONE" config user.name selftest
  ( cd "$CLONE" && echo hello > f.txt && git add f.txt && git commit -qm init && git branch -M main \
    && git remote add origin "$REMOTE" && git push -q origin main && git remote set-head origin main )
}

run_probe() {  # cwd
  ( cd "$1" && bash "$HERE/repo_shape_probe.sh" 2>"$SANDBOX/probe.err" )
}

# T09 — deny-non-fast-forward server → FORCE_PUSH_ALLOWED=false (GAPS A3:
# v2.3.0's "rewrite" was a fast-forward, so this could never be false).
make_remote_and_clone deny
git -C "$REMOTE" config receive.denyNonFastForwards true
out=$(run_probe "$CLONE")
assert_contains T09 "deny server detected" "FORCE_PUSH_ALLOWED=false" "$out"

# T11 — stdout purity on the deny run (GAPS A4: git chatter corrupted values).
impure=$(grep -cvE '^[A-Z_]+=[A-Za-z0-9._/-]+$' <<<"$out" || true)
assert_eq T11 "probe stdout is strictly KEY=VALUE lines" "0" "$impure"

# T10 — permissive server → FORCE_PUSH_ALLOWED=true, JIRA_HOOK_ENFORCED=false.
make_remote_and_clone permissive
out=$(run_probe "$CLONE")
assert_contains T10 "permissive server detected" "FORCE_PUSH_ALLOWED=true" "$out"
assert_contains T10 "no jira hook detected" "JIRA_HOOK_ENFORCED=false" "$out"
impure=$(grep -cvE '^[A-Z_]+=[A-Za-z0-9._/-]+$' <<<"$out" || true)
assert_eq T11 "probe stdout pure on permissive run too" "0" "$impure"

# T29 — JIRA pre-receive hook → JIRA_HOOK_ENFORCED=true (concluded from the
# force-push probe's own rejection, without a second rejected push).
make_remote_and_clone jirahook
cat > "$REMOTE/hooks/pre-receive" <<'HOOKEOF'
#!/usr/bin/env bash
while read -r old new ref; do
  subjects=$(git log --format=%s "$new" --not --all 2>/dev/null || git log -1 --format=%s "$new")
  if ! grep -qE '[A-Z][A-Z0-9]+-[0-9]+' <<<"$subjects"; then
    echo "commit message must contain a valid JIRA issue key" >&2
    exit 1
  fi
done
exit 0
HOOKEOF
chmod +x "$REMOTE/hooks/pre-receive"
out=$(run_probe "$CLONE")
assert_contains T29 "jira hook detected" "JIRA_HOOK_ENFORCED=true" "$out"
assert_contains T29 "force-push verdict honestly unknown without a key" "FORCE_PUSH_ALLOWED=unknown" "$out"

# T37 — --jira-key unblinds the force-push probe on JIRA-enforcing servers.
out=$( cd "$SANDBOX/jirahook-clone" && bash "$HERE/repo_shape_probe.sh" --jira-key TEST-1 2>/dev/null )
assert_contains T37 "keyed probe reaches the force-push test" "FORCE_PUSH_ALLOWED=true" "$out"
assert_contains T37 "keyed probe: jira verdict from its own (unkeyed) push" "JIRA_HOOK_ENFORCED=true" "$out"

# T32 — --dry-run performs NO git-state or network operation (the v2.4.0
# adversarial round proved ls-remote + remote branch-deletes ran in dry-run).
tracef="$SANDBOX/dryrun.trace"
out=$( cd "$SANDBOX/permissive-clone" && GIT_TRACE=1 bash "$HERE/repo_shape_probe.sh" --dry-run 2>"$tracef" )
assert_contains T32 "dry-run emits unknown force-push" "FORCE_PUSH_ALLOWED=unknown" "$out"
impure=$(grep -cvE '^[A-Z_]+=[A-Za-z0-9._/-]+$' <<<"$out" || true)
assert_eq T32 "dry-run stdout stays KEY=VALUE-pure" "0" "$impure"
assert_contains T32 "dry-run prints the operation plan" "probe[dry-run]: would create + push temp branch" "$(cat "$tracef")"
mutating=$(grep -cE "built-in: git (push|fetch|ls-remote)" "$tracef" || true)
assert_eq T32 "dry-run runs no push/fetch/ls-remote" "0" "$mutating"

# T33 — --show-patterns emits intact registry rows (was word-split garbage).
out=$(bash "$HERE/repo_shape_probe.sh" --show-patterns)
assert_contains T33 "alternation pattern printed intact" "you are not permitted to (force[- ]push|rewrite history)|FORCE_PUSH_DENIED_BRANCH_PERM" "$out"

# T26 — unmatched rejection surfaces the corpus-growth message (GAPS B4).
make_remote_and_clone weirdhook
cat > "$REMOTE/hooks/pre-receive" <<'HOOKEOF'
#!/usr/bin/env bash
echo "die: blocked by corporate policy XYZ-9000" >&2
exit 1
HOOKEOF
chmod +x "$REMOTE/hooks/pre-receive"
out=$(run_probe "$CLONE")
err="$(cat "$SANDBOX/probe.err")"
assert_contains T26 "unknown rejection reported for registry growth" "unknown rejection pattern; please add to repo_shape_probe_patterns.sh" "$err"

# T24 — CI manifest detection sees .github/workflows (GAPS A10: non-recursive
# ls-tree could never match the nested path).
make_remote_and_clone ciwf
( cd "$CLONE" && mkdir -p .github/workflows && printf 'on: push\n' > .github/workflows/ci.yml \
  && git add .github && git commit -qm "ci: add workflow" && git push -q origin main )
out=$(run_probe "$CLONE")
assert_contains T24 "workflow manifest detected" "CI_PRESENT=true" "$out"

echo "== detect_concurrent_drain.sh (T12-T16) =="

DCD="$HERE/detect_concurrent_drain.sh"
TRK="$SANDBOX/drain.tracker.md"

# T12 — missing tracker (valid .md path) → 0.
CLAUDE_SESSION_ID=sess-A bash "$DCD" "$SANDBOX/absent.tracker.md" >/dev/null 2>&1; rc=$?
assert_eq T12 "missing tracker is clean" "0" "$rc"

# T13 — live foreign lock → 2 (GAPS A5b: v2.3.0 read legacy field names and
# returned 0 here).
cat > "$TRK" <<EOF
---
STATUS: ACTIVE
session_lock: sess-B
session_lock_expires_at: 2099-01-01T00:00:00Z
last_heartbeat_at: 2020-01-01T00:00:00Z
---
EOF
out=$(CLAUDE_SESSION_ID=sess-A bash "$DCD" "$TRK" 2>/dev/null); rc=$?
assert_eq T13 "live foreign lock refused" "2" "$rc"
assert_contains T13 "foreign session id reported" "lock-held-by-other:sess-B" "$out"
# Note the stale heartbeat above: expiry alone governs (GAPS A5c — the old
# 5-minute heartbeat window would steal a healthy */30-cadence drain's lock).

# T14 — expired foreign lock → 3.
cat > "$TRK" <<EOF
---
STATUS: ACTIVE
session_lock: sess-B
session_lock_expires_at: 2020-01-01T00:00:00Z
---
EOF
CLAUDE_SESSION_ID=sess-A bash "$DCD" "$TRK" >/dev/null 2>&1; rc=$?
assert_eq T14 "expired foreign lock reclaimable" "3" "$rc"

# T15 — corrupt lock state (lock without expiry) → 4, fail closed (GAPS A5d).
cat > "$TRK" <<EOF
---
STATUS: ACTIVE
session_lock: sess-B
---
EOF
CLAUDE_SESSION_ID=sess-A bash "$DCD" "$TRK" >/dev/null 2>&1; rc=$?
assert_eq T15 "corrupt lock state fails closed" "4" "$rc"

# T15b — own lock → 0; null lock → 0.
cat > "$TRK" <<EOF
---
STATUS: ACTIVE
session_lock: sess-A
session_lock_expires_at: 2099-01-01T00:00:00Z
---
EOF
CLAUDE_SESSION_ID=sess-A bash "$DCD" "$TRK" >/dev/null 2>&1; rc=$?
assert_eq T15 "own lock is clean" "0" "$rc"
cat > "$TRK" <<EOF
---
STATUS: ACTIVE
session_lock: null
session_lock_expires_at: null
---
EOF
CLAUDE_SESSION_ID=sess-A bash "$DCD" "$TRK" >/dev/null 2>&1; rc=$?
assert_eq T15 "null lock is clean" "0" "$rc"

# T16 — slug-shaped arg (the pre-v2.4 G1 call convention) is rejected loudly
# instead of silently passing (GAPS A5a).
CLAUDE_SESSION_ID=sess-A bash "$DCD" "my-slug" >/dev/null 2>&1; rc=$?
assert_eq T16 "bare slug argument rejected" "64" "$rc"

# T34 — quoted YAML values are parsed (an LLM/yq legitimately writes
# `session_lock: "sess-A"`; unquoted-only parsing made an OWN lock look
# foreign and then bricked on the quoted expiry with exit 4).
cat > "$TRK" <<EOF
---
STATUS: ACTIVE
session_lock: "sess-A"
session_lock_expires_at: "2099-01-01T00:00:00Z"
---
EOF
CLAUDE_SESSION_ID=sess-A bash "$DCD" "$TRK" >/dev/null 2>&1; rc=$?
assert_eq T34 "quoted OWN lock is clean" "0" "$rc"
cat > "$TRK" <<EOF
---
STATUS: ACTIVE
session_lock: "sess-B"
session_lock_expires_at: "2099-01-01T00:00:00Z"
---
EOF
CLAUDE_SESSION_ID=sess-A bash "$DCD" "$TRK" >/dev/null 2>&1; rc=$?
assert_eq T34 "quoted foreign live lock refused" "2" "$rc"

echo "== ci_check.sh (T17-T20) =="

ci() {
  ( cd "$API_REPO" && \
    IDENTITY_PROXY_URL="$BASE" IDENTITY_PROXY_PLATFORMS="bitbucketdc" \
    bash "$HERE/ci_check.sh" "$@" )
}

if (( MOCK_OK )); then
# T17 — the pre-v2.4 documented invocation (bare positional PR number) is a
# usage error, and stays one (GAPS A6: D7.5 once documented exactly this call,
# routing every first CI poll to HUMAN_NEEDED).
ci 42 >/dev/null 2>&1; rc=$?
assert_eq T17 "positional invocation is usage error 64" "64" "$rc"

# T18 — --once GREEN.
out=$(ci --sha aaa111 --pr 42 --once 2>"$SANDBOX/t18.err"); rc=$?
assert_eq T18 "--once GREEN exit 0" "0" "$rc"
assert_eq T18 "--once GREEN verdict" "VERDICT=GREEN" "$out"
assert_contains T18 "LAST_STATE carries actual build state" "LAST_STATE=SUCCESSFUL" "$(cat "$SANDBOX/t18.err")"

# T19 — --once PENDING on INPROGRESS (exit 5; the cross-fire dispatch row).
out=$(ci --sha ccc333 --pr 42 --once 2>/dev/null); rc=$?
assert_eq T19 "--once INPROGRESS exit 5" "5" "$rc"
assert_eq T19 "--once INPROGRESS verdict" "VERDICT=PENDING" "$out"
# UNKNOWN (no statuses) is also PENDING under --once:
out=$(ci --sha ddd444 --pr 42 --once 2>/dev/null); rc=$?
assert_eq T19 "--once UNKNOWN exit 5" "5" "$rc"

# T20 — --once PR_DECLINED (exit 4) + RED (exit 1).
out=$(ci --sha aaa111 --pr 55 --once 2>/dev/null); rc=$?
assert_eq T20 "--once declined PR exit 4" "4" "$rc"
assert_eq T20 "--once declined verdict" "VERDICT=PR_DECLINED" "$out"
out=$(ci --sha bbb222 --pr 42 --once 2>/dev/null); rc=$?
assert_eq T20 "--once RED exit 1" "1" "$rc"
else
  skip ci_check "mock Bitbucket DC server unavailable in this environment"
fi

echo "== hot_file_audit.sh (T21-T23) =="

HFA="$HERE/hot_file_audit.sh"
make_remote_and_clone churn
( cd "$CLONE" \
  && for i in 1 2 3; do echo "$i" >> hot.py; git add hot.py; git commit -qm "touch hot $i"; done \
  && echo x > cold.py && git add cold.py && git commit -qm "touch cold" \
  && git push -q origin main )

# T21 — --churn implements the G4 contract (GAPS A8: unimplemented pre-v2.4;
# the documented no-arg call was a usage error and the overlap mode was
# structurally empty at GENERATE time).
out=$( cd "$CLONE" && bash "$HFA" --churn --days 30 --top 5 )
hotline=$(grep -F 'hot.py' <<<"$out" | awk '{print $1}')
assert_eq T21 "churn counts hot.py commits" "3" "$hotline"
top=$(head -1 <<<"$out" | awk -F'\t' '{print $2}')
assert_eq T21 "most-churned file ranks first" "hot.py" "$top"

# T22 — --subtasks overlap mode: two subtask branches touching the same file.
( cd "$CLONE" \
  && git checkout -qb autopilot/demo/setup main && git push -q origin HEAD \
  && git checkout -qb autopilot/demo/A1 && echo a >> shared.py && git add shared.py && git commit -qm "A1" \
  && git checkout -qb autopilot/demo/B2 autopilot/demo/setup && echo b >> shared.py && git add shared.py && git commit -qm "B2" \
  && git checkout -q main )
out=$( cd "$CLONE" && bash "$HFA" --subtasks demo )
assert_contains T22 "overlap mode flags shared.py at count 2" "2	shared.py" "$out"

# T23 — no-args is a usage error.
bash "$HFA" >/dev/null 2>&1; rc=$?
assert_eq T23 "hot_file_audit without mode is usage error" "64" "$rc"

# T31 — an empty churn window is a clean empty result, not exit 1 (quiet
# repos made G4 look like a script failure under pipefail).
make_remote_and_clone quiet
( cd "$CLONE" && GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" \
  git commit -q --allow-empty --amend --no-edit --date "2020-01-01T00:00:00Z" && git push -qf origin main )
out=$( cd "$CLONE" && bash "$HFA" --churn --days 30 ); rc=$?
assert_eq T31 "empty churn window exits 0" "0" "$rc"
assert_eq T31 "empty churn window prints nothing" "" "$out"

echo "== audit_commit_shape.sh (AV3-06 D6.2 Story-range audit) =="

ACS="$HERE/audit_commit_shape.sh"
CS_REPO="$SANDBOX/cs-repo"
git init -q "$CS_REPO"
git -C "$CS_REPO" config user.email selftest@local
git -C "$CS_REPO" config user.name selftest
csc() { git -C "$CS_REPO" "$@"; }
csci() { csc commit -q --allow-empty -m "$1"; }
echo base > "$CS_REPO/f"; csc add f; csci "chore: base"; csc branch -M main
CS_TRUNK=$(csc rev-parse HEAD)
acs() { ( cd "$CS_REPO" && bash "$ACS" "$@" ); }

# One Story branch accumulates Subtask A1's commit series, then B2's — the
# PR-per-Story shape (AV3-06): the branch carries the WHOLE Story, D6.2 audits
# only the Subtask that just landed.
csc checkout -qb autopilot/demo/story1
csci "test: A1.1 RED — a1 behavior 1"
csci "feat: A1.1 GREEN — a1 behavior 1"
CS_PREV=$(csc rev-parse HEAD)          # in_progress.prev_pushed_sha after A1
csci "test: B2.1 RED — b2 behavior 1"
csci "feat: B2.1 GREEN — b2 behavior 1"
csci "test: B2.2 RED — b2 behavior 2"
csci "feat: B2.2 GREEN — b2 behavior 2"

# AV3-06.1 — the range fix: auditing B2 over prev_pushed_sha..HEAD sees ONLY B2's
# commits, so a Story branch carrying A1's prior commits yields no scope-leak.
out=$(acs --id B2 --base "$CS_PREV" 2>&1); rc=$?
assert_eq "AV3-06.1" "Story-range B2 audit exits 0" "0" "$rc"
assert_eq "AV3-06.1" "Story-range B2 audit is clean" "OK" "$out"

# AV3-06.2 — the OLD whole-branch range (origin/<trunk>..HEAD) false-flags
# tdd-scope-leak on A1's accumulated commits: exactly the regression the fix kills.
out=$(acs --id B2 --base "$CS_TRUNK" 2>&1); rc=$?
assert_eq "AV3-06.2" "whole-branch range reds B2" "1" "$rc"
assert_contains "AV3-06.2" "whole-branch range is a scope-leak false-positive" "[BLOCKED: tdd-scope-leak]" "$out"

# AV3-06.3 — RED/GREEN pairing + ordering enforced within the Subtask's own range.
csc checkout -qb autopilot/demo/story2 "$CS_TRUNK"
csci "test: C3.1 RED — missing green"
out=$(acs --id C3 --base "$CS_TRUNK" 2>&1); rc=$?
assert_eq "AV3-06.3" "RED without GREEN reds" "1" "$rc"
assert_contains "AV3-06.3" "no-green reason emitted" "[BLOCKED: tdd-no-green]" "$out"
csci "feat: C3.2 GREEN — green with no red for behavior 2"
out=$(acs --id C3 --base "$(csc rev-parse HEAD~1)" 2>&1)
assert_contains "AV3-06.3" "GREEN before RED is out-of-order" "[BLOCKED: tdd-out-of-order]" "$out"

# AV3-06.4 — jira-key enforcement over the range (AP-22).
csc checkout -qb autopilot/demo/story3 "$CS_TRUNK"
csci "test: D4.1 [PROJ-7] RED — keyed"
csci "feat: D4.1 [PROJ-7] GREEN — keyed"
out=$(acs --id D4 --base "$CS_TRUNK" --jira-key PROJ-7 2>&1); rc=$?
assert_eq "AV3-06.4" "keyed commits pass jira audit" "0" "$rc"
csci "test: D4.2 RED — unkeyed"
out=$(acs --id D4 --base "$(csc rev-parse HEAD~1)" --jira-key PROJ-7 2>&1)
assert_contains "AV3-06.4" "unkeyed commit reds under enforce_jira_key" "[BLOCKED: jira-key-missing]" "$out"

# AV3-06.5 — refactor / docs kinds have their own shapes.
csc checkout -qb autopilot/demo/story4 "$CS_TRUNK"
csci "refactor: E5 — decouple validator from registry"
out=$(acs --id E5 --base "$CS_TRUNK" --kind refactor 2>&1); rc=$?
assert_eq "AV3-06.5" "single refactor commit is valid refactor shape" "0" "$rc"
csci "feat: E5.1 GREEN — behavior snuck into a refactor subtask"
out=$(acs --id E5 --base "$CS_TRUNK" --kind refactor 2>&1)
assert_contains "AV3-06.5" "test/feat in a refactor subtask is refactor-shape-wrong" "[BLOCKED: refactor-shape-wrong]" "$out"

# AV3-06.6 — usage guardrails: missing args + unknown base.
acs --id B2 >/dev/null 2>&1; rc=$?
assert_eq "AV3-06.6" "missing --base is usage error 64" "64" "$rc"
acs --id B2 --base deadbeefdeadbeef >/dev/null 2>&1; rc=$?
assert_eq "AV3-06.6" "unknown base ref is usage error 64" "64" "$rc"

echo "== validate_plan_mapping.sh (AV3-07 sizing + AV3-02 behavior-mapping) =="

VPM="$HERE/validate_plan_mapping.sh"
vpm() { bash "$VPM" "$@"; }

cat > "$SANDBOX/plan_valid.json" <<'J'
{"subtasks":[
  {"id":"A1","parent_story":"S-foo","kind":"code","estimated_size":"M","predicted_hours":12},
  {"id":"A2","parent_story":"S-foo","kind":"code","estimated_size":"S","predicted_hours":3},
  {"id":"B1","parent_story":"S-bar","kind":"code","estimated_size":"L","predicted_hours":48}
]}
J
# AV3-07.1 — a plan whose Stories all predict <=48h with size-consistent hours is valid.
out=$(vpm "$SANDBOX/plan_valid.json" 2>&1); rc=$?
assert_eq "AV3-07.1" "size-consistent, <=48h plan is valid" "0" "$rc"
assert_eq "AV3-07.1" "valid plan prints OK" "OK" "$out"

cat > "$SANDBOX/plan_oversized.json" <<'J'
{"subtasks":[
  {"id":"A1","parent_story":"S-big","kind":"code","estimated_size":"M","predicted_hours":16},
  {"id":"A2","parent_story":"S-big","kind":"code","estimated_size":"M","predicted_hours":16},
  {"id":"A3","parent_story":"S-big","kind":"code","estimated_size":"M","predicted_hours":16},
  {"id":"A4","parent_story":"S-big","kind":"code","estimated_size":"S","predicted_hours":4}
]}
J
# AV3-07.2 — a Story whose Subtasks roll up past 48h is oversized and must split.
out=$(vpm "$SANDBOX/plan_oversized.json" 2>&1); rc=$?
assert_eq "AV3-07.2" "oversized Story refused" "1" "$rc"
assert_eq "AV3-07.2" "oversized cites the story-id" "[GENERATE-FAILED: story-oversized: S-big]" "$out"

cat > "$SANDBOX/plan_inconsistent.json" <<'J'
{"subtasks":[{"id":"A1","parent_story":"S-x","kind":"code","estimated_size":"S","predicted_hours":9}]}
J
# AV3-07.3 — an S-labeled Subtask predicting >4h violates the S/M/L sanity mapping.
out=$(vpm "$SANDBOX/plan_inconsistent.json" 2>&1); rc=$?
assert_eq "AV3-07.3" "size-inconsistent Subtask refused" "1" "$rc"
assert_eq "AV3-07.3" "size-inconsistent cites the subtask-id" "[GENERATE-FAILED: story-size-inconsistent: A1]" "$out"

cat > "$SANDBOX/plan_missing_hours.json" <<'J'
{"subtasks":[{"id":"A1","parent_story":"S-x","kind":"code","estimated_size":"M"}]}
J
# AV3-07.4 — a Subtask missing predicted_hours (or non-integer) is schema-inconsistent.
out=$(vpm "$SANDBOX/plan_missing_hours.json" 2>&1); rc=$?
assert_eq "AV3-07.4" "missing predicted_hours refused" "1" "$rc"
assert_contains "AV3-07.4" "missing-hours reason is size-inconsistent" "story-size-inconsistent" "$out"

# AV3-07.5 — boundary: an L-labeled Subtask at exactly 48h, sole Subtask of its
# Story, is valid (<=48 both per-size and per-Story).
cat > "$SANDBOX/plan_boundary.json" <<'J'
{"subtasks":[{"id":"L1","parent_story":"S-edge","kind":"code","estimated_size":"L","predicted_hours":48}]}
J
out=$(vpm "$SANDBOX/plan_boundary.json" 2>&1); rc=$?
assert_eq "AV3-07.5" "48h L-Subtask at the boundary is valid" "0" "$rc"

# AV3-07.6 — usage guardrails.
vpm >/dev/null 2>&1; rc=$?
assert_eq "AV3-07.6" "no plan arg is usage error 64" "64" "$rc"
vpm "$SANDBOX/does-not-exist.json" >/dev/null 2>&1; rc=$?
assert_eq "AV3-07.6" "absent plan file is usage error 64" "64" "$rc"

# --- AV3-02: Subtask <-> Behavior-ID mapping (validate_plan_mapping.sh + manifest) --
cat > "$SANDBOX/manifest.yaml" <<'Y'
schema_version: 1
manifest_revision: 1
observability:
  profile: payments
environments: [dev, prod]
behaviors:
  - id: B-x-001
    title: "one"
    lifecycle: active
    given: "g"
    when: "w"
    then: "t"
  - id: B-x-002
    title: "two"
    lifecycle: active
    given: "g"
    when: "w"
    then: "t"
  - id: B-x-003
    title: "gone"
    lifecycle: withdrawn
    withdrawn_reason: "superseded"
Y
MF="$SANDBOX/manifest.yaml"

cat > "$SANDBOX/map_valid.json" <<'J'
{"subtasks":[
  {"id":"A1","parent_story":"S","kind":"code","estimated_size":"S","predicted_hours":3,"behavior_ids":["B-x-001"]},
  {"id":"A2","parent_story":"S","kind":"test-only","estimated_size":"S","predicted_hours":2,"behavior_ids":["B-x-002"]},
  {"id":"A3","parent_story":"S","kind":"refactor","estimated_size":"S","predicted_hours":2,"behavior_ids":[]}
]}
J
# AV3-02.1 — full active coverage + a refactor Subtask exempt from mapping is valid.
out=$(vpm "$SANDBOX/map_valid.json" "$MF" 2>&1); rc=$?
assert_eq "AV3-02.1" "mapped plan (refactor exempt) is valid" "0" "$rc"
assert_eq "AV3-02.1" "valid mapped plan prints OK" "OK" "$out"

cat > "$SANDBOX/map_unmapped.json" <<'J'
{"subtasks":[
  {"id":"A1","parent_story":"S","kind":"code","estimated_size":"S","predicted_hours":3,"behavior_ids":[]},
  {"id":"A2","parent_story":"S","kind":"code","estimated_size":"S","predicted_hours":2,"behavior_ids":["B-x-001","B-x-002"]}
]}
J
# AV3-02.2 — a code Subtask with no Behavior IDs is unmapped-subtask.
out=$(vpm "$SANDBOX/map_unmapped.json" "$MF" 2>&1); rc=$?
assert_eq "AV3-02.2" "unmapped code Subtask refused" "1" "$rc"
assert_eq "AV3-02.2" "unmapped cites the subtask-id" "[GENERATE-FAILED: unmapped-subtask: A1]" "$out"

cat > "$SANDBOX/map_unowned.json" <<'J'
{"subtasks":[{"id":"A1","parent_story":"S","kind":"code","estimated_size":"S","predicted_hours":3,"behavior_ids":["B-x-001"]}]}
J
# AV3-02.3 — an active manifest Behavior owned by no Subtask is unowned-behavior.
out=$(vpm "$SANDBOX/map_unowned.json" "$MF" 2>&1); rc=$?
assert_eq "AV3-02.3" "unowned active Behavior refused" "1" "$rc"
assert_eq "AV3-02.3" "unowned cites the behavior-id" "[GENERATE-FAILED: unowned-behavior: B-x-002]" "$out"

cat > "$SANDBOX/map_unknown.json" <<'J'
{"subtasks":[
  {"id":"A1","parent_story":"S","kind":"code","estimated_size":"S","predicted_hours":3,"behavior_ids":["B-x-001"]},
  {"id":"A2","parent_story":"S","kind":"code","estimated_size":"S","predicted_hours":2,"behavior_ids":["B-x-002","B-x-003"]}
]}
J
# AV3-02.4 — mapping a withdrawn / nonexistent Behavior is unknown-behavior
# (B-x-003 is a tombstone; the active universe excludes it).
out=$(vpm "$SANDBOX/map_unknown.json" "$MF" 2>&1); rc=$?
assert_eq "AV3-02.4" "mapping a withdrawn Behavior refused" "1" "$rc"
assert_eq "AV3-02.4" "unknown cites the behavior-id" "[GENERATE-FAILED: unknown-behavior: B-x-003]" "$out"

# AV3-02.5 — manifest-LESS input keeps v2.4.0 semantics: no behavior_ids required.
out=$(vpm "$SANDBOX/map_unmapped.json" 2>&1); rc=$?
assert_eq "AV3-02.5" "manifest-less plan needs no behavior_ids" "0" "$rc"

echo "== detect_input_mode.sh (AV3-01 mode inference) =="

DIM="$HERE/detect_input_mode.sh"
dim() { bash "$DIM" "$@"; }

# AV3-01.1 — a valid+complete manifest goes straight through (ADR 0008), no flag.
out=$(dim --intent generate --manifest m.yaml --validator-exit 0 2>/dev/null); rc=$?
assert_eq "AV3-01.1" "complete manifest exits 0" "0" "$rc"
assert_eq "AV3-01.1" "complete manifest -> STRAIGHT_THROUGH" "MODE=STRAIGHT_THROUGH" "$out"

# AV3-01.2 — bare markdown (no companion manifest) -> GENERATE+pause.
assert_eq "AV3-01.2" "bare markdown -> GENERATE_PAUSE" "MODE=GENERATE_PAUSE" "$(dim --intent generate 2>/dev/null)"
# incomplete manifest is manifest-less (MS §11) -> also GENERATE_PAUSE.
assert_eq "AV3-01.2" "incomplete manifest -> GENERATE_PAUSE" "MODE=GENERATE_PAUSE" "$(dim --intent generate --manifest m.yaml --validator-exit 3 2>/dev/null)"

# AV3-01.3 — --yolo is the manifest-LESS override only.
assert_eq "AV3-01.3" "manifest-less --yolo -> GENERATE_YOLO" "MODE=GENERATE_YOLO" "$(dim --intent generate --yolo 2>/dev/null)"
assert_eq "AV3-01.3" "incomplete + --yolo -> GENERATE_YOLO" "MODE=GENERATE_YOLO" "$(dim --intent generate --manifest m.yaml --validator-exit 3 --yolo 2>/dev/null)"

# AV3-01.4 — --yolo on a complete manifest is a no-op WARNING, mode unchanged.
out=$(dim --intent generate --manifest m.yaml --validator-exit 0 --yolo 2>"$SANDBOX/dim_yolo.err"); rc=$?
assert_eq "AV3-01.4" "yolo-on-complete stays STRAIGHT_THROUGH" "MODE=STRAIGHT_THROUGH" "$out"
assert_eq "AV3-01.4" "yolo-on-complete exits 0" "0" "$rc"
assert_contains "AV3-01.4" "yolo-on-complete warns no-op" "--yolo is a no-op on a complete manifest" "$(cat "$SANDBOX/dim_yolo.err")"

# AV3-01.5 — schema-invalid (4) and unsupported (5) REFUSE; never degrade, never
# --yolo-bypassable (MS §11).
out=$(dim --intent generate --manifest m.yaml --validator-exit 4 2>/dev/null); rc=$?
assert_eq "AV3-01.5" "schema-invalid refuses (exit 1)" "1" "$rc"
assert_eq "AV3-01.5" "schema-invalid -> REFUSE-MANIFEST-INVALID" "MODE=REFUSE-MANIFEST-INVALID" "$out"
out=$(dim --intent generate --manifest m.yaml --validator-exit 4 --yolo 2>/dev/null); rc=$?
assert_eq "AV3-01.5" "--yolo cannot bypass a schema-invalid manifest" "1" "$rc"
assert_eq "AV3-01.5" "unsupported -> REFUSE-MANIFEST-UNSUPPORTED" "MODE=REFUSE-MANIFEST-UNSUPPORTED" "$(dim --intent generate --manifest m.yaml --validator-exit 5 2>/dev/null)"

# AV3-01.6 — runbook intents are unchanged.
assert_eq "AV3-01.6" "--drain -> DRAIN" "MODE=DRAIN" "$(dim --intent drain 2>/dev/null)"
assert_eq "AV3-01.6" "--resume -> RESUME" "MODE=RESUME" "$(dim --intent resume 2>/dev/null)"

# AV3-01.7 — usage guardrails: a manifest with no validator exit, and a bad intent.
dim --intent generate --manifest m.yaml >/dev/null 2>&1; rc=$?
assert_eq "AV3-01.7" "manifest without validator-exit is usage error 64" "64" "$rc"
dim --intent bogus >/dev/null 2>&1; rc=$?
assert_eq "AV3-01.7" "unknown intent is usage error 64" "64" "$rc"

echo "== secret_get.sh (T25) =="

# T25 — candidate list matches the documented resolver conventions
# (GAPS B3: v2.1.0 claimed <service>-token:<host> and $BITBUCKET_HOST
# support; neither existed).
out=$( cd "$API_REPO" && BITBUCKET_HOST=cluster03.example.com bash "$HERE/secret_get.sh" bitbucket --list-candidates )
assert_contains T25 "canonical candidate" "autopilot-bitbucket" "$out"
assert_contains T25 "as-host candidate" "autopilot-bitbucket-cluster03-example-com" "$out"
assert_contains T25 "community colon convention candidate" "bitbucket-token:cluster03.example.com" "$out"
assert_contains T25 "community candidate" "bitbucket-token" "$out"
first=$( AUTOPILOT_BITBUCKET_KEYCHAIN_NAME=my-override bash "$HERE/secret_get.sh" bitbucket --list-candidates | head -1 )
assert_eq T25 "operator override probes first" "my-override" "$first"
# Env tier resolves when no keychain entry exists.
out=$( AUTOPILOT_BITBUCKET_TOKEN=env-tier-token bash "$HERE/secret_get.sh" bitbucket )
assert_eq T25 "env tier resolves" "env-tier-token" "$out"
# Sidecar short-circuit returns empty success.
out=$( AUTOPILOT_SIDECAR_MODE=1 AUTOPILOT_BITBUCKET_TOKEN=should-not-print bash "$HERE/secret_get.sh" bitbucket ); rc=$?
assert_eq T25 "sidecar mode short-circuits with exit 0" "0" "$rc"
assert_eq T25 "sidecar mode prints nothing" "" "$out"

echo "== sidecar_detect.sh (T28, T38) =="

# Deterministic (no server): absent proxy URL -> local mode.
out=$( env -u IDENTITY_PROXY_URL bash "$HERE/sidecar_detect.sh" )
assert_eq T28 "no proxy url is local mode" "MODE=local" "$out"

if (( MOCK_OK )); then
out=$( IDENTITY_PROXY_URL="$BASE" IDENTITY_PROXY_PLATFORMS="bitbucketdc" bash "$HERE/sidecar_detect.sh" )
assert_contains T28 "healthy sidecar detected" "MODE=sidecar" "$out"
out=$( IDENTITY_PROXY_URL="$BASE/badok" bash "$HERE/sidecar_detect.sh" 2>/dev/null )
assert_eq T28 "200 without ok body is local mode" "MODE=local" "$out"

# T38 — "not ok" must NOT pass the body check (substring matching did).
out=$( IDENTITY_PROXY_URL="$BASE/notok" bash "$HERE/sidecar_detect.sh" 2>/dev/null )
assert_eq T38 "'not ok' body is local mode" "MODE=local" "$out"
else
  skip sidecar_detect "mock Bitbucket DC server unavailable in this environment"
fi

echo "== secret_set.sh with keychain shims (T30) =="

# Faithful macOS shims: `uname` -> Darwin; `security` with exit-44-on-missing
# semantics, attribute dump without -g, and `-i` stdin command mode. The
# v2.4.0 adversarial round proved (a) the old stderr-parsing probe made every
# FIRST-EVER macOS secret_set abort exit 5, and (b) `-w "$TOKEN"` put the
# secret in the process table.
SHIM2="$SANDBOX/shim2"; mkdir -p "$SHIM2"
KC_DIR="$SANDBOX/kc"; mkdir -p "$KC_DIR"
cat > "$SHIM2/uname" <<'EOF'
#!/usr/bin/env bash
echo Darwin
EOF
cat > "$SHIM2/security" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${SEC_ARGV_LOG:?}"
KC="${SEC_KC_DIR:?}"
if [[ "${1:-}" == "-i" ]]; then
  while IFS= read -r line; do
    printf '%s\n' "$line" >> "${SEC_STDIN_LOG:?}"
    if [[ "$line" =~ -s\ \"([^\"]+)\" ]]; then touch "$KC/${BASH_REMATCH[1]}"; fi
  done
  exit 0
fi
if [[ "${1:-}" == "find-generic-password" ]]; then
  shift; name=""; want_pw=0
  while (( $# )); do
    case "$1" in -s) name="$2"; shift 2 ;; -w) want_pw=1; shift ;; *) shift ;; esac
  done
  if [[ -n "$name" && -f "$KC/$name" ]]; then
    if (( want_pw )); then echo "stored-password"; else printf '    "acct"<blob>="%s"\n    "icmt"<blob>="autopilot-managed"\n' "$(id -un)"; fi
    exit 0
  fi
  echo "security: SecKeychainSearchCopyNext: The specified item could not be found." >&2
  exit 44
fi
exit 0
EOF
chmod +x "$SHIM2/uname" "$SHIM2/security"
sset() {
  PATH="$SHIM2:$PATH" SEC_ARGV_LOG="$SANDBOX/sec_argv.log" SEC_STDIN_LOG="$SANDBOX/sec_stdin.log" SEC_KC_DIR="$KC_DIR" \
    bash "$HERE/secret_set.sh" "$@"
}
: > "$SANDBOX/sec_argv.log"; : > "$SANDBOX/sec_stdin.log"
printf 'tok-abc-123' | sset bitbucket >/dev/null 2>&1; rc=$?
assert_eq T30 "first-ever macOS secret_set succeeds (was exit 5)" "0" "$rc"
assert_not_contains T30 "token never on security argv" "tok-abc-123" "$(cat "$SANDBOX/sec_argv.log")"
assert_contains T30 "token delivered via security -i stdin" "tok-abc-123" "$(cat "$SANDBOX/sec_stdin.log")"
printf 'tok-abc-456' | sset bitbucket >/dev/null 2>&1; rc=$?
assert_eq T30 "update of an autopilot-managed entry succeeds" "0" "$rc"
touch "$KC_DIR/bitbucket-token"
err=$(printf 'tok-abc-789' | sset bitbucket 2>&1 >/dev/null); rc=$?
assert_eq T30 "cross-candidate collision aborts exit 5" "5" "$rc"
assert_contains T30 "collision names the foreign entry" "operator-owned credential detected at bitbucket-token" "$err"
rm -f "$KC_DIR/bitbucket-token"
err=$(printf 'tok-abc-000' | sset bitbucket --force 2>&1 >/dev/null); rc=$?
assert_eq T30 "--force bypasses the aborts" "0" "$rc"

echo "== deterministic-seam chain (T27) =="

# T27 — probe fact -> flag flip -> canonical tracker seed -> concurrency guard.
# This is the scripts-calling-scripts seam a real GENERATE fire exercises.
out=$(run_probe "$SANDBOX/deny-clone")
if grep -q 'FORCE_PUSH_ALLOWED=false' <<<"$out"; then
  NFP=true
else
  NFP=false
fi
assert_eq T27 "probe fact feeds branching.no_force_push" "true" "$NFP"
CHAIN_TRK="$SANDBOX/chain.tracker.md"
cat > "$CHAIN_TRK" <<EOF
---
STATUS: ACTIVE
consecutive_impl_blocks: 0
consecutive_ci_blocks: 0
branching:
  no_force_push: ${NFP}
session_lock: sess-OWNER
session_lock_expires_at: 2099-01-01T00:00:00Z
last_heartbeat_at: 2099-01-01T00:00:00Z
---

## Drift Notes

## Pending Tracker Deltas (batched)
_(empty)_
EOF
CLAUDE_SESSION_ID=sess-OWNER bash "$DCD" "$CHAIN_TRK" >/dev/null 2>&1; rc=$?
assert_eq T27 "owner session passes the guard" "0" "$rc"
CLAUDE_SESSION_ID=sess-INTRUDER bash "$DCD" "$CHAIN_TRK" >/dev/null 2>&1; rc=$?
assert_eq T27 "second session is refused" "2" "$rc"

echo "== github.sh backend via gh argv shim (H-GH, HG01-HG28) =="

# A fake `gh` that answers exactly the argv github.sh drives. This is the
# GitHub counterpart to the DC mock server (ADR 0013: the same T01-class
# contract matrix, run against both backends). It needs NO network / python,
# so it runs even when MOCK_OK=0.
GHSHIM="$SANDBOX/ghshim"; mkdir -p "$GHSHIM"
cat > "$GHSHIM/gh" <<'SHIMEOF'
#!/usr/bin/env bash
# Fake gh CLI for self_test: emulates the subset github.sh drives.
set -u
STATE="${GH_SHIM_STATE:-/tmp}"
sub="${1:-}"; sub2="${2:-}"
argval() {  # <flag> <args...> -> prints the value following <flag>
  local want="$1"; shift
  while (( $# )); do
    if [[ "$1" == "$want" ]]; then printf '%s' "${2:-}"; return 0; fi
    shift
  done
  return 1
}
case "$sub" in
  pr)
    case "$sub2" in
      create)
        draft=0
        for a in "$@"; do [[ "$a" == "--draft" ]] && draft=1; done
        if (( draft )); then
          printf 'draft' > "$STATE/pr88"
          printf 'https://github.com/acme/widget/pull/88\n'
        else
          printf 'https://github.com/acme/widget/pull/77\n'
        fi
        ;;
      ready)  printf 'ready' > "$STATE/pr${3:-x}" ;;
      view)
        num="${3:-}"; state=OPEN; isdraft=false
        case "$num" in
          60) state=MERGED ;;
          55) state=CLOSED ;;
          88) [[ -f "$STATE/pr88" && "$(cat "$STATE/pr88")" == "ready" ]] || isdraft=true ;;
        esac
        printf '{"state":"%s","isDraft":%s}\n' "$state" "$isdraft"
        ;;
      list)
        if [[ "$(argval --head "$@" || true)" == "feature-x" ]]; then
          printf '[{"state":"OPEN","isDraft":false}]\n'
        else
          printf '[]\n'
        fi
        ;;
      comment|review|close) exit 0 ;;
      merge)
        for a in "$@"; do
          case "$a" in --merge|--squash|--rebase) printf '%s' "$a" > "$STATE/last_merge_flag" ;; esac
        done
        ;;
      *) printf 'ghshim: unhandled pr %s\n' "$sub2" >&2; exit 1 ;;
    esac
    ;;
  api)
    path="${2:-}"
    case "$path" in
      repos/acme/widget)
        printf '{"allow_merge_commit":true,"allow_squash_merge":true,"allow_rebase_merge":false}\n' ;;
      */commits/*/status)
        sha="${path%/status}"; sha="${sha##*/commits/}"
        case "$sha" in
          aaa*) printf '{"state":"success","total_count":1,"statuses":[{"state":"success"}]}\n' ;;
          bbb*) printf '{"state":"failure","total_count":1,"statuses":[{"state":"failure"}]}\n' ;;
          fff*) printf '{"state":"success","total_count":1,"statuses":[{"state":"success"}]}\n' ;;
          *)    printf '{"state":"pending","total_count":0,"statuses":[]}\n' ;;
        esac ;;
      */commits/*/check-runs)
        sha="${path%/check-runs}"; sha="${sha##*/commits/}"
        case "$sha" in
          ccc*) printf '{"total_count":1,"check_runs":[{"status":"in_progress","conclusion":null}]}\n' ;;
          fff*) printf '{"total_count":1,"check_runs":[{"status":"completed","conclusion":"stale"}]}\n' ;;
          ggg*) printf '{"total_count":2,"check_runs":[{"status":"completed","conclusion":"success"}]}\n' ;;
          *)    printf '{"total_count":0,"check_runs":[]}\n' ;;
        esac ;;
      *) printf '{}\n' ;;
    esac ;;
  *) printf 'ghshim: unhandled %s\n' "$sub" >&2; exit 1 ;;
esac
SHIMEOF
chmod +x "$GHSHIM/gh"

GH_REPO_DIR="$SANDBOX/gh-repo"
git init -q "$GH_REPO_DIR"
git -C "$GH_REPO_DIR" remote add origin "https://github.com/acme/widget.git"
GH_STATE="$SANDBOX/ghstate"; mkdir -p "$GH_STATE"

# host.sh dispatched from the GitHub-shaped repo, gh shim ahead on PATH.
hgh() { ( cd "$GH_REPO_DIR" && PATH="$GHSHIM:$PATH" GH_SHIM_STATE="$GH_STATE" bash "$HERE/host.sh" "$@" ); }
# github.sh invoked directly (backend-scoped), same shim.
ggh() { ( cd "$GH_REPO_DIR" && PATH="$GHSHIM:$PATH" GH_SHIM_STATE="$GH_STATE" bash "$HERE/github.sh" "$@" ); }

# HG01 — host.sh detects the GitHub backend from the github.com origin.
assert_eq HG01 "host.sh backend -> GITHUB" "GITHUB" "$(hgh backend 2>/dev/null)"

# HG02..HG12 — the shared T01-class contract matrix, host.sh -> GitHub backend.
contract_matrix H-GH hgh

# --- GitHub draft surface ----------------------------------------------------
rm -f "$GH_STATE/pr88"
# HG20 — pr-open --draft returns the draft PR number.
assert_eq HG20 "gh pr-open --draft prints id 88" "88" "$(hgh pr-open --draft --title Feature --src fb --dest main 2>/dev/null)"
# HG21 — a freshly-opened draft PR reports DRAFT.
assert_eq HG21 "gh draft PR -> DRAFT" "DRAFT" "$(hgh pr-state --num 88 2>/dev/null)"
# HG22 — pr-ready flips it to ready-for-review...
hgh pr-ready --num 88 >/dev/null 2>&1; rc=$?
assert_eq HG22 "gh pr-ready exits 0" "0" "$rc"
# HG23 — ...and pr-state now reports OPEN.
assert_eq HG23 "gh readied PR -> OPEN" "OPEN" "$(hgh pr-state --num 88 2>/dev/null)"

# --- GitHub state-vocabulary mapping -----------------------------------------
# HG24 — MERGED maps straight through.
assert_eq HG24 "gh MERGED -> MERGED" "MERGED" "$(hgh pr-state --num 60 2>/dev/null)"
# HG25 — CLOSED (closed-not-merged) maps to the shared DECLINED token.
assert_eq HG25 "gh CLOSED -> DECLINED" "DECLINED" "$(hgh pr-state --num 55 2>/dev/null)"

# --- GitHub strategy discovery + mapping -------------------------------------
out=$(hgh pr-merge-strategies 2>/dev/null)
assert_contains HG26 "merge-commit permitted" "merge-commit" "$out"
assert_contains HG26 "squash permitted" "squash" "$out"
assert_not_contains HG26 "rebase not permitted (allow_rebase_merge=false)" "rebase" "$out"
# HG27 — squash intent maps to gh --squash.
ggh pr-merge --num 42 --strategy squash >/dev/null 2>&1
assert_eq HG27 "squash intent -> gh --squash" "--squash" "$(cat "$GH_STATE/last_merge_flag" 2>/dev/null)"
# HG28 — an unknown strategy is a clean arg error, not a silent merge.
ggh pr-merge --num 42 --strategy bogus >/dev/null 2>&1; rc=$?
assert_eq HG28 "unknown strategy -> exit 1" "1" "$rc"

# HG29 — build-status hardening. A `stale` check-run must NOT poison an
# otherwise-green build (dropped as neutral), and an unseen check-run page must
# FAIL SAFE to INPROGRESS rather than a false SUCCESSFUL.
assert_eq HG29 "stale check-run dropped; status green -> SUCCESSFUL" "SUCCESSFUL" "$(hgh build-status --sha fff555 2>/dev/null)"
assert_eq HG29 "partial check-run page -> INPROGRESS (never false-green)" "INPROGRESS" "$(hgh build-status --sha ggg666 2>/dev/null)"

# HG30 — ci_check.sh drives the host adapter, so the D7.5 CI poll is
# host-agnostic: the SAME ci_check run turns GREEN against the GitHub backend.
out=$( cd "$GH_REPO_DIR" && PATH="$GHSHIM:$PATH" GH_SHIM_STATE="$GH_STATE" \
       bash "$HERE/ci_check.sh" --sha aaa111 --pr 42 --once 2>/dev/null )
assert_eq HG30 "ci_check GREEN via GitHub backend" "VERDICT=GREEN" "$out"

echo "== host.sh backend detection (H50) =="

det() { ( cd "$1" && bash "$HERE/host.sh" backend 2>/dev/null ); }
# H50 — the two canonical origin URL shapes resolve to their backends.
assert_eq H50 "DC /scm/ https origin -> BITBUCKET_DC" "BITBUCKET_DC" "$(det "$API_REPO")"
assert_eq H50 "github.com https origin -> GITHUB" "GITHUB" "$(det "$GH_REPO_DIR")"
# H50 — an ssh github origin also resolves to GITHUB.
SSHGH="$SANDBOX/sshgh"; git init -q "$SSHGH"
git -C "$SSHGH" remote add origin "git@github.com:acme/widget.git"
assert_eq H50 "git@github.com ssh origin -> GITHUB" "GITHUB" "$(det "$SSHGH")"
# H50 — a trailing-slash github origin: host.sh routes GITHUB AND github.sh
# parses it (it strips the trailing slash), so a PR op actually succeeds rather
# than dying origin-parse.
TSGH="$SANDBOX/tsgh"; git init -q "$TSGH"
git -C "$TSGH" remote add origin "https://github.com/acme/widget/"
assert_eq H50 "trailing-slash github origin -> GITHUB" "GITHUB" "$(det "$TSGH")"
out=$( cd "$TSGH" && PATH="$GHSHIM:$PATH" GH_SHIM_STATE="$GH_STATE" bash "$HERE/github.sh" pr-state --num 42 2>/dev/null )
assert_eq H50 "github.sh parses a trailing-slash origin (pr-state succeeds)" "OPEN" "$out"
# H50 — AUTOPILOT_HOST_BACKEND override wins over the URL heuristic.
out=$( cd "$API_REPO" && AUTOPILOT_HOST_BACKEND=GITHUB bash "$HERE/host.sh" backend 2>/dev/null )
assert_eq H50 "override wins over origin heuristic" "GITHUB" "$out"
# H50 — an invalid override is a hard error (not a silent default).
( cd "$API_REPO" && AUTOPILOT_HOST_BACKEND=BOGUS bash "$HERE/host.sh" backend >/dev/null 2>&1 ); rc=$?
assert_eq H50 "invalid override errors" "1" "$rc"
# H50 — an unrecognised origin refuses with actionable guidance.
UNK="$SANDBOX/unk-repo"; git init -q "$UNK"
git -C "$UNK" remote add origin "https://gitlab.example.com/group/proj.git"
out=$( cd "$UNK" && bash "$HERE/host.sh" backend 2>&1 >/dev/null || true )
assert_contains H50 "unrecognised origin names the override knob" "AUTOPILOT_HOST_BACKEND" "$out"
# H50 — host.sh refuses an unknown subcommand with usage exit 64.
( cd "$GH_REPO_DIR" && bash "$HERE/host.sh" bogus-sub >/dev/null 2>&1 ); rc=$?
assert_eq H50 "unknown subcommand -> usage 64" "64" "$rc"

echo "== consistency lint (L1-L18) =="

if bash "$HERE/lint_consistency.sh" >/dev/null 2>&1; then
  pass LINT "lint_consistency.sh passes (18 rules)"
else
  fail LINT "lint_consistency.sh reports violations (run it directly for detail)"
fi

# L16 must actually red the retired single-host framing (planted-drift pin):
# copy the skill into the sandbox, plant the forbidden line, run the copied lint.
planted_dir="$SANDBOX/planted-lint"
cp -R "$ROOT" "$planted_dir"
printf '\nBitbucket Data Center is the source-of-truth host.\n' >> "$planted_dir/references/loop-safety.md"
if bash "$planted_dir/scripts/lint_consistency.sh" >/dev/null 2>&1; then
  fail L16 "L16 did NOT red a planted 'source-of-truth host' line"
else
  pass L16 "L16 reds planted 'source-of-truth host' framing"
fi

# L17 must red a planted one-PR-per-Subtask framing (AV3-06 / AV3-16a acceptance):
# fresh clean copy so the L16 plant above doesn't mask the result.
planted17="$SANDBOX/planted-lint-17"
cp -R "$ROOT" "$planted17"
printf '\nAutopilot opens one PR per Subtask against the host.\n' >> "$planted17/references/loop-safety.md"
if bash "$planted17/scripts/lint_consistency.sh" >/dev/null 2>&1; then
  fail L17 "L17 did NOT red a planted 'one PR per Subtask' line"
else
  pass L17 "L17 reds planted 'one PR per Subtask' framing"
fi

# L18 must red an AP-3 allow-list that drops a pinned planner-schema field:
# fresh copy, strip behavior_ids from the projection, expect the copied lint to red.
planted18="$SANDBOX/planted-lint-18"
cp -R "$ROOT" "$planted18"
grep -v 'behavior_ids:' "$planted18/references/plan-reviewer-projection.md" > "$planted18/references/proj.tmp"
mv "$planted18/references/proj.tmp" "$planted18/references/plan-reviewer-projection.md"
if bash "$planted18/scripts/lint_consistency.sh" >/dev/null 2>&1; then
  fail L18 "L18 did NOT red an AP-3 allow-list missing behavior_ids"
else
  pass L18 "L18 reds an AP-3 allow-list that drops behavior_ids"
fi

echo
echo "self_test: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
(( FAIL == 0 )) || exit 1
exit 0
