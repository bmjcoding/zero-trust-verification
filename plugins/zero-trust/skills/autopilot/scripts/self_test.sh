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
#   - Every assertion cites its gap-register id (Txx; the v2.3.0 gap register is
#     retired — its closure record is CHANGELOG.md §2.4.0). A new bug found in the
#     field MUST land here as a failing assertion before (or with) its fix.
#   - Run after ANY change under scripts/ or references/.
#
# Assertion-id legend (family -> what it covers):
#   Txx      core substrate + bitbucket.sh/DC backend (T01-T38; T03 = credential
#            never on curl argv)
#   HDxx     Bitbucket DC draft-PR handling (native draft / [DRAFT] title modes)
#   HGxx     github.sh backend via the gh argv shim (HG01-HG36)
#   H50      host.sh backend detection from the origin URL
#   HRxx     host.sh repo-list (ADR 0028): enumeration argv secrecy + the
#            lazy-coords split (repo-list outside a repo; PR ops still die)
#   AV3-x.n  v3 register assertions (the standalone register doc was retired;
#            these ids live only here now)
#   MT-x     D6.5 mutation gate (adapter, isolation, budget, verdicts)
#   W345-*   audit-w345 field-retro regressions (CHANGELOG 3.1.0)
#   Lxx      lint red-tests: planted violations that must turn lint rule Lxx red
#
# Usage: bash scripts/self_test.sh
# Exit 0 = all assertions pass; non-zero = at least one failure.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# The ONE assertion library at the repo root (ADR 0025 Wave 4). pwd -P so a
# skills-dir symlinked install (ADR 0027) still resolves into the full clone.
. "$(cd "$HERE" && pwd -P)/../../../../../scripts/test_harness.sh"
th_init A worded-skip

# mk_repo <dir> — git init + selftest identity + signing off (the fixture
# gpgsign pin, PR #39: a 1Password signing agent must never red a fixture).
mk_repo() {
  git init -q "$1"
  git -C "$1" config user.email selftest@local
  git -C "$1" config user.name selftest
  git -C "$1" config commit.gpgsign false
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
# Neutralize an operator's persistent Bitbucket host override: bitbucket.sh's
# own docs tell deployments to export AUTOPILOT_BITBUCKET_HOST in their shell
# profile, and an inherited value wins its precedence chain — every W345-BB
# BB_HOST-derivation assertion would false-red on a correct tree. Tests that
# exercise the override (W345-BB5) set it explicitly per-invocation.
unset AUTOPILOT_BITBUCKET_HOST

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
        if p.endswith("/default-branch"):
            # pr-list-ready trunk resolution (repo default branch).
            self._send_json({"id": "refs/heads/main", "displayId": "main"}); return
        if "/pull-requests?" in p:
            if "order=NEWEST" in p:
                # pr-list-ready queue enumeration (AV3-15b), served in TWO pages so
                # the DC pagination loop is exercised (isLastPage:False on page 1 is
                # the `false // true` jq trap). Page 1 (start=0) carries the fixtures
                # aligned with the gh shim for the shared contract_matrix: PR 42
                # APPROVED, PR 77 PENDING (one reviewer not approved), PR 88 a draft
                # (excluded), PR 99 a non-trunk target (excluded). Page 2 (start=100)
                # carries PR 201, targeting `page2branch` — reachable ONLY if the
                # loop honours isLastPage:False and follows nextPageStart.
                if "start=100" in p:
                    self._send_json({"isLastPage": True, "values": [
                        {"id": 201, "title": "p2", "state": "OPEN", "draft": False,
                         "createdDate": 1783250000000,
                         "fromRef": {"displayId": "feature-p2", "id": "refs/heads/feature-p2",
                                     "latestCommit": "fff201sha"},
                         "toRef": {"displayId": "page2branch", "id": "refs/heads/page2branch"},
                         "reviewers": [{"approved": True}]}]}); return
                self._send_json({"isLastPage": False, "nextPageStart": 100, "values": [
                    {"id": 42, "title": "x", "state": "OPEN", "draft": False,
                     "createdDate": 1783245600000,
                     "fromRef": {"displayId": "feature-x", "id": "refs/heads/feature-x",
                                 "latestCommit": "aaa42sha"},
                     "toRef": {"displayId": "main", "id": "refs/heads/main"},
                     "reviewers": [{"approved": True}, {"approved": True}]},
                    {"id": 77, "title": "y", "state": "OPEN", "draft": False,
                     "createdDate": 1783242000000,
                     "fromRef": {"displayId": "feature-y", "id": "refs/heads/feature-y",
                                 "latestCommit": "bbb77sha"},
                     "toRef": {"displayId": "main", "id": "refs/heads/main"},
                     "reviewers": [{"approved": True}, {"approved": False}]},
                    {"id": 88, "title": "d", "state": "OPEN", "draft": True,
                     "createdDate": 1783240000000,
                     "fromRef": {"displayId": "feature-draft", "id": "refs/heads/feature-draft",
                                 "latestCommit": "ddd88sha"},
                     "toRef": {"displayId": "main", "id": "refs/heads/main"},
                     "reviewers": [{"approved": True}]},
                    {"id": 99, "title": "r", "state": "OPEN", "draft": False,
                     "createdDate": 1783241000000,
                     "fromRef": {"displayId": "feature-rel", "id": "refs/heads/feature-rel",
                                 "latestCommit": "eee99sha"},
                     "toRef": {"displayId": "release/2.0", "id": "refs/heads/release/2.0"},
                     "reviewers": [{"approved": True}]}]}); return
            if "at=refs/heads/feature-x" in p:
                self._send_json({"values": [{"id": 42, "state": "OPEN"}]}); return
            self._send_json({"values": []}); return
        if re.search(r"/projects/[^/]+/repos\?", p):
            # ADR 0028 repo-list fixture, served in TWO pages so the DC pagination
            # cursor loop is exercised (isLastPage:False on page 1 is the
            # `false // true` jq trap — a regressed cursor drops page 2 entirely).
            # Aligned with the gh shim for the shared contract_matrix row:
            # page 1 (start=0) carries `widget`, page 2 (start=50) `pricing`.
            if "start=50" in p:
                self._send_json({"isLastPage": True, "values": [
                    {"slug": "pricing", "links": {"clone": [
                        {"name": "http", "href": "https://bb.example.com/scm/acme/pricing.git"},
                        {"name": "ssh", "href": "ssh://git@bb.example.com:7999/acme/pricing.git"}]}}]})
                return
            self._send_json({"isLastPage": False, "nextPageStart": 50, "values": [
                {"slug": "widget", "links": {"clone": [
                    {"name": "ssh", "href": "ssh://git@bb.example.com:7999/acme/widget.git"}]}}]})
            return
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
mk_repo "$API_REPO"
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

  # pr-list-ready — the Merge Marshal's queue-enumeration primitive, and the
  # REAL-BACKEND assertion the mock hid (the P0): host.sh -> {github.sh via the gh
  # shim | bitbucket.sh via the DC mock} must emit the EXACT 5-column TSV the
  # Marshal loop consumes — `ready_ts \t num \t branch \t head_sha \t approval`,
  # ready_ts an INTEGER EPOCH, drafts and non-trunk PRs excluded, APPROVED tagged.
  # Fixtures are aligned across both backends so this body needs no per-backend
  # branching. (Trunk resolves to the repo default branch — "main" — in both.)
  local TB; TB="$(printf '\t')"
  local ready
  ready="$($H pr-list-ready 2>/dev/null | sort -t"$TB" -k1,1n -k2,2n)"
  assert_eq "$ID" "pr-list-ready emits the marshal-consumable FIFO TSV" \
    "$(printf '1783242000\t77\tfeature-y\tbbb77sha\tPENDING\n1783245600\t42\tfeature-x\taaa42sha\tAPPROVED')" "$ready"
  assert_not_contains "$ID" "pr-list-ready excludes draft PRs" "feature-draft" "$ready"
  assert_not_contains "$ID" "pr-list-ready excludes non-trunk PRs" "feature-rel" "$ready"
  # The Marshal's OWN selection+order pipeline (APPROVED-only, strict FIFO by
  # ready_ts then num) applied to the REAL backend output must keep exactly PR 42
  # — proving the emitted rows are consumed as the loop expects, not just shaped.
  local picked
  picked="$($H pr-list-ready 2>/dev/null | awk -F"$TB" '$2!="" && $5=="APPROVED"' | sort -t"$TB" -k1,1n -k2,2n | awk -F"$TB" '{printf "%s,",$2}')"
  assert_eq "$ID" "marshal ordering over real output -> only APPROVED PR 42" "42," "$picked"

  # repo-list — org enumeration as a backend method (ADR 0028): the OWM-consumable
  # 2-column TSV `<slug>\t<clone-or-api-url>`. BOTH backends serve the acme
  # fixture in TWO pages (DC isLastPage/nextPageStart cursor; gh --paginate
  # concatenation), so slug completeness here IS the pagination proof. Clone
  # URLs are host-shaped, so the shared body asserts the contract shape (two
  # columns, non-empty url) + the full slug set; exact-URL assertions live in
  # the per-backend sections (HD14 / HG34).
  out="$($H repo-list --org acme 2>/dev/null)"; rc=$?
  assert_eq "$ID" "repo-list --org exits 0" "0" "$rc"
  assert_eq "$ID" "repo-list emits both pages' slugs as a 2-col TSV (url non-empty)" \
    "$(printf 'pricing\nwidget')" "$(printf '%s\n' "$out" | awk -F"$TB" 'NF==2 && $2!="" {print $1}' | sort)"
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

# HD12 — DC pr-list-ready empty queue: point the trunk at a branch no PR targets;
# every fixture PR is toRef-filtered out -> empty output, exit 0 (not an error).
out="$(AUTOPILOT_TRUNK=no-such-trunk hostbb pr-list-ready 2>/dev/null)"; rc=$?
assert_eq HD12 "DC pr-list-ready empty queue -> no output" "" "$out"
assert_eq HD12 "DC pr-list-ready empty queue -> exit 0" "0" "$rc"

# HD13 — DC pr-list-ready PAGINATES. PR 201 lives on page 2 (start=100) and targets
# `page2branch`; it is reachable ONLY if the loop honours page 1's isLastPage:False
# and follows nextPageStart. The `.isLastPage // true` jq trap (false read as true)
# stops after page 1 and drops it — with order=NEWEST that is the oldest/FIFO-head
# PR. This assertion reds on that bug.
out="$(AUTOPILOT_TRUNK=page2branch hostbb pr-list-ready 2>/dev/null | sort -t"$(printf '\t')" -k1,1n)"
assert_eq HD13 "DC pr-list-ready follows pagination to page 2 (PR 201)" \
  "$(printf '1783250000\t201\tfeature-p2\tfff201sha\tAPPROVED')" "$out"

# HD14 — DC repo-list PAGINATES (ADR 0028): `pricing` lives on page 2 (start=50),
# reachable ONLY if the cursor loop honours page 1's isLastPage:False and follows
# nextPageStart (the `.isLastPage // true` jq trap would truncate to `widget`).
# The ssh clone link is preferred over the http link (pricing carries both).
out="$(hostbb repo-list --org acme 2>/dev/null | sort)"
assert_eq HD14 "DC repo-list follows the two-page cursor; ssh clone link preferred" \
  "$(printf 'pricing\tssh://git@bb.example.com:7999/acme/pricing.git\nwidget\tssh://git@bb.example.com:7999/acme/widget.git')" "$out"

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
  mk_repo "$CLONE"
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

# --- CI_STATUS_REPORTING probe (audit-w345 retro F7: CI runs but never posts to
# the host build-status API — ci.skip_wait: false polls a void forever). The
# backend is stubbed via the AUTOPILOT_PROBE_BITBUCKET injection seam so the
# sampling paths run hermetically (same pattern as the gh argv shim).
STUB_SILENT="$SANDBOX/bb_stub_silent.sh"
cat > "$STUB_SILENT" <<'STUBEOF'
#!/usr/bin/env bash
[[ "${1:-}" == "build-status" ]] && { echo UNKNOWN; exit 0; }
exit 1
STUBEOF
chmod +x "$STUB_SILENT"
STUB_DEFINITE="$SANDBOX/bb_stub_definite.sh"
cat > "$STUB_DEFINITE" <<'STUBEOF'
#!/usr/bin/env bash
[[ "${1:-}" == "build-status" ]] && { echo SUCCESSFUL; exit 0; }
exit 1
STUBEOF
chmod +x "$STUB_DEFINITE"

# W345-F7a — CI config present + endpoint silent across the trunk sample →
# CI_STATUS_REPORTING=false (the honest ci.skip_wait auto-seed signal).
out=$( cd "$SANDBOX/ciwf-clone" && AUTOPILOT_PROBE_BITBUCKET="$STUB_SILENT" bash "$HERE/repo_shape_probe.sh" 2>/dev/null )
assert_contains W345-F7a "silent endpoint + CI files -> reporting=false" "CI_STATUS_REPORTING=false" "$out"
assert_contains W345-F7a "CI presence still true from manifests" "CI_PRESENT=true" "$out"
impure=$(grep -cvE '^[A-Z_]+=[A-Za-z0-9._/-]+$' <<<"$out" || true)
assert_eq W345-F7a "probe stdout stays KEY=VALUE-pure with the new key" "0" "$impure"

# W345-F7b — a definite build state proves both presence AND reporting, even
# with no CI config files at trunk.
out=$( cd "$SANDBOX/permissive-clone" && AUTOPILOT_PROBE_BITBUCKET="$STUB_DEFINITE" bash "$HERE/repo_shape_probe.sh" 2>/dev/null )
assert_contains W345-F7b "definite build state -> reporting=true" "CI_STATUS_REPORTING=true" "$out"
assert_contains W345-F7b "definite build state -> CI_PRESENT=true" "CI_PRESENT=true" "$out"

# W345-F7c — CI config PRESENT + backend ERRORS on every call (broken auth /
# token) -> reporting stays unknown, NEVER false: a backend error must not read
# as a silent endpoint, or a transient auth failure would auto-seed
# ci.skip_wait: true and silently disable a WORKING CI gate. This fixture pins
# the rc!=0 -> 'unavailable' guard in sample_build_status: delete that guard
# and the erroring backend falls through the sha loop to 'silent', flipping
# this run to CI_STATUS_REPORTING=false (the previous no-CI fixture passed
# either way — the false branch also requires CI_PRESENT=true).
STUB_ERROR="$SANDBOX/bb_stub_error.sh"
cat > "$STUB_ERROR" <<'STUBEOF'
#!/usr/bin/env bash
exit 1
STUBEOF
chmod +x "$STUB_ERROR"
out=$( cd "$SANDBOX/ciwf-clone" && AUTOPILOT_PROBE_BITBUCKET="$STUB_ERROR" bash "$HERE/repo_shape_probe.sh" 2>/dev/null )
assert_contains W345-F7c "backend error + CI files: reporting honestly unknown" "CI_STATUS_REPORTING=unknown" "$out"
assert_contains W345-F7c "backend error does not hide manifest-based CI presence" "CI_PRESENT=true" "$out"

# W345-F7d — dry-run emits unknown for the new key (invariant 2: unknown never
# auto-flips; dry-run performs no sampling).
out=$( cd "$SANDBOX/permissive-clone" && bash "$HERE/repo_shape_probe.sh" --dry-run 2>/dev/null )
assert_contains W345-F7d "dry-run reporting=unknown" "CI_STATUS_REPORTING=unknown" "$out"

# W345-F7e — no CI at all (no config files, unusable backend) -> reporting
# stays unknown (the original F7c scenario, kept as its own case).
out=$(run_probe "$SANDBOX/permissive-clone")
assert_contains W345-F7e "no CI: reporting honestly unknown" "CI_STATUS_REPORTING=unknown" "$out"

# W345-F7f — the sample goes BEYOND the trunk tip: a build state present ONLY
# on an ancestor commit (the just-pushed tip has not reported yet) must still
# read definite -> reporting=true. Pins the `rev-list -5` sampling depth: a
# tip-only "simplification" (-5 -> -1, or dropping the loop) turns this fixture
# silent -> reporting=false and reds here.
ANC_SHA=$(git -C "$SANDBOX/ciwf-clone" rev-parse origin/main~1)
STUB_PERSHA="$SANDBOX/bb_stub_persha.sh"
cat > "$STUB_PERSHA" <<STUBEOF
#!/usr/bin/env bash
[[ "\${1:-}" == "build-status" && "\${3:-}" == "$ANC_SHA" ]] && { echo SUCCESSFUL; exit 0; }
[[ "\${1:-}" == "build-status" ]] && { echo UNKNOWN; exit 0; }
exit 1
STUBEOF
chmod +x "$STUB_PERSHA"
out=$( cd "$SANDBOX/ciwf-clone" && AUTOPILOT_PROBE_BITBUCKET="$STUB_PERSHA" bash "$HERE/repo_shape_probe.sh" 2>/dev/null )
assert_contains W345-F7f "ancestor-only build state -> reporting=true (sample depth > 1)" "CI_STATUS_REPORTING=true" "$out"

# W345-F7g — PR-only-reporting CI (statuses keyed to PR head shas; squash-merge
# leaves trunk commits status-less) must NOT read as silent: the sample also
# covers recent PR head refs (refs/pull-requests/*/from | refs/pull/*/head).
# Pins the PR-head sample: dropping it turns this fixture silent ->
# CI_PRESENT=true + reporting=false -> auto-seed would disable a WORKING D7.5
# gate on the suite's primary Bitbucket DC deployment shape.
make_remote_and_clone pronly
( cd "$CLONE" && mkdir -p .github/workflows && printf 'on: pull_request\n' > .github/workflows/ci.yml \
  && git add .github && git commit -qm "ci: pr-only workflow" && git push -q origin main )
# The PR head commit exists ONLY under the PR ref (never merged to trunk —
# the squash-merge shape); its sha is where CI posted the build status.
( cd "$CLONE" && git checkout -qb prhead && git commit -q --allow-empty -m "pr work" \
  && git push -q origin prhead:refs/pull-requests/7/from && git checkout -q main && git branch -qD prhead )
PRHEAD_SHA=$(git -C "$CLONE" ls-remote origin 'refs/pull-requests/7/from' | awk '{print $1}')
STUB_PRONLY="$SANDBOX/bb_stub_pronly.sh"
cat > "$STUB_PRONLY" <<STUBEOF
#!/usr/bin/env bash
[[ "\${1:-}" == "build-status" && "\${3:-}" == "$PRHEAD_SHA" ]] && { echo SUCCESSFUL; exit 0; }
[[ "\${1:-}" == "build-status" ]] && { echo UNKNOWN; exit 0; }
exit 1
STUBEOF
chmod +x "$STUB_PRONLY"
out=$( cd "$CLONE" && AUTOPILOT_PROBE_BITBUCKET="$STUB_PRONLY" bash "$HERE/repo_shape_probe.sh" 2>/dev/null )
assert_contains W345-F7g "PR-head-only build state -> reporting=true (not silent)" "CI_STATUS_REPORTING=true" "$out"
assert_contains W345-F7g "PR-head-only: CI presence true" "CI_PRESENT=true" "$out"

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
mk_repo "$CS_REPO"
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

# AV3-06.7 — adversarial round (executor lens): --jira-key must be enforced on
# EVERY kind, not just code/test-only (AP-22 covers refactor/docs/config too).
csc checkout -qb autopilot/demo/story5 "$CS_TRUNK"
csci "refactor: F6 — unkeyed refactor"
out=$(acs --id F6 --base "$CS_TRUNK" --kind refactor --jira-key PROJ-7 2>&1); rc=$?
assert_eq "AV3-06.7" "unkeyed refactor reds under enforce_jira_key" "1" "$rc"
assert_contains "AV3-06.7" "refactor jira-key-missing" "[BLOCKED: jira-key-missing]" "$out"
csc checkout -qb autopilot/demo/story6 "$CS_TRUNK"
csci "docs: G7 — unkeyed docs"
out=$(acs --id G7 --base "$CS_TRUNK" --kind docs --jira-key PROJ-7 2>&1)
assert_contains "AV3-06.7" "docs jira-key-missing" "[BLOCKED: jira-key-missing]" "$out"

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

# AV3-07.7 — adversarial round (executor lens): a Subtask missing parent_story must
# be refused, else two 40h Subtasks of one 80h Story slip under the 48h cap as
# separate groups.
cat > "$SANDBOX/plan_orphan.json" <<'J'
{"subtasks":[
  {"id":"ST-1.1","parent_story":"ST-1","kind":"code","estimated_size":"L","predicted_hours":40},
  {"id":"ST-1.2","kind":"code","estimated_size":"L","predicted_hours":40}
]}
J
out=$(vpm "$SANDBOX/plan_orphan.json" 2>&1); rc=$?
assert_eq "AV3-07.7" "missing parent_story refused (no oversized masking)" "1" "$rc"
assert_eq "AV3-07.7" "orphan cites the subtask-id" "[GENERATE-FAILED: subtask-missing-parent-story: ST-1.2]" "$out"

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

echo "== validate_manifest_union.sh --union (AV3-03 multi-doc union) =="

VMU="$HERE/validate_manifest_union.sh"
# write a minimal manifest: <path> <profile> <environments-inline> <journey-id> <behavior-id>
write_manifest() {
  cat > "$1" <<Y
schema_version: 1
manifest_revision: 1
observability:
  profile: $2
environments: [$3]
journeys:
  - id: $4
    lifecycle: active
    steps:
      - name: "s"
        vital_class: null
behaviors:
  - id: $5
    lifecycle: active
    given: g
    when: w
    then: t
Y
}
write_manifest "$SANDBOX/u_a.yaml"        payments "dev, prod"       J-a-001 B-a-001
write_manifest "$SANDBOX/u_b.yaml"        payments "dev, prod"       J-b-001 B-b-001
write_manifest "$SANDBOX/u_collide.yaml"  payments "dev, prod"       J-a-001 B-c-001
write_manifest "$SANDBOX/u_prof.yaml"     fraud   "dev, prod"       J-d-001 B-d-001
write_manifest "$SANDBOX/u_env.yaml"      payments "dev, test, prod" J-e-001 B-e-001
write_manifest "$SANDBOX/u_order.yaml"    payments "prod, dev"       J-f-001 B-f-001
vmu() { bash "$VMU" "$@"; }

# AV3-03.1 — two coherent manifests (disjoint IDs, same profile+environments).
out=$(vmu --union "$SANDBOX/u_a.yaml" "$SANDBOX/u_b.yaml" 2>&1); rc=$?
assert_eq "AV3-03.1" "coherent union exits 0" "0" "$rc"
assert_eq "AV3-03.1" "coherent union prints OK" "OK" "$out"

# AV3-03.2 — a Journey/Behavior ID shared across manifests is a union collision.
out=$(vmu --union "$SANDBOX/u_a.yaml" "$SANDBOX/u_collide.yaml" 2>&1); rc=$?
assert_eq "AV3-03.2" "id collision refused" "1" "$rc"
assert_eq "AV3-03.2" "collision cites the id" "[GENERATE-FAILED: manifest-id-collision: J-a-001]" "$out"

# AV3-03.3 — mismatched observability.profile across the union.
out=$(vmu --union "$SANDBOX/u_a.yaml" "$SANDBOX/u_prof.yaml" 2>&1); rc=$?
assert_eq "AV3-03.3" "profile mismatch refused" "1" "$rc"
assert_eq "AV3-03.3" "profile mismatch token" "[GENERATE-FAILED: manifest-union-mismatch: profile]" "$out"

# AV3-03.4 — mismatched environments across the union.
out=$(vmu --union "$SANDBOX/u_a.yaml" "$SANDBOX/u_env.yaml" 2>&1); rc=$?
assert_eq "AV3-03.4" "environments mismatch refused" "1" "$rc"
assert_eq "AV3-03.4" "environments mismatch token" "[GENERATE-FAILED: manifest-union-mismatch: environments]" "$out"

# AV3-03.5 — environments compared as a SET: same members, different order = OK.
out=$(vmu --union "$SANDBOX/u_a.yaml" "$SANDBOX/u_order.yaml" 2>&1); rc=$?
assert_eq "AV3-03.5" "environments set-equality (order-insensitive) is coherent" "0" "$rc"

# AV3-03.6 — usage guardrails.
vmu "$SANDBOX/u_a.yaml" "$SANDBOX/u_b.yaml" >/dev/null 2>&1; rc=$?
assert_eq "AV3-03.6" "missing --union is usage error 64" "64" "$rc"
vmu --union "$SANDBOX/u_a.yaml" >/dev/null 2>&1; rc=$?
assert_eq "AV3-03.6" "a union of one is usage error 64" "64" "$rc"

# AV3-03.7 — adversarial round (executor lens): the union checks must not be
# fooled by legal YAML variants the canonical emitter doesn't use.
# (a) block-list `environments:` must NOT extract to empty and pass a real mismatch.
cat > "$SANDBOX/u_blk_dev.yaml" <<'Y'
observability:
  profile: payments
environments:
  - dev
  - prod
behaviors:
  - id: B-blkA-001
    lifecycle: active
Y
cat > "$SANDBOX/u_blk_stg.yaml" <<'Y'
observability:
  profile: payments
environments:
  - staging
behaviors:
  - id: B-blkB-001
    lifecycle: active
Y
out=$(vmu --union "$SANDBOX/u_blk_dev.yaml" "$SANDBOX/u_blk_stg.yaml" 2>&1); rc=$?
assert_eq "AV3-03.7" "block-list environments mismatch is caught (not empty-vs-empty)" "1" "$rc"
assert_eq "AV3-03.7" "block-list mismatch token" "[GENERATE-FAILED: manifest-union-mismatch: environments]" "$out"
# block-list, same set different order -> coherent.
cat > "$SANDBOX/u_blk_rev.yaml" <<'Y'
observability:
  profile: payments
environments:
  - prod
  - dev
behaviors:
  - id: B-blkC-001
    lifecycle: active
Y
out=$(vmu --union "$SANDBOX/u_blk_dev.yaml" "$SANDBOX/u_blk_rev.yaml" 2>&1); rc=$?
assert_eq "AV3-03.7" "block-list set-equality (order-insensitive) is coherent" "0" "$rc"
# (b) a prose *mention* of a foreign ID must NOT register a false collision.
cat > "$SANDBOX/u_prose.yaml" <<'Y'
observability:
  profile: payments
environments: [dev, prod]
behaviors:
  - id: B-ship-002
    lifecycle: active
    description: "supersedes B-a-001 from the pricing spec"
Y
out=$(vmu --union "$SANDBOX/u_a.yaml" "$SANDBOX/u_prose.yaml" 2>&1); rc=$?
assert_eq "AV3-03.7" "prose mention of a foreign id is NOT a collision" "0" "$rc"

echo "== manifest_revision_gate.sh (AV3-04 revision drift) =="

MRG="$HERE/manifest_revision_gate.sh"
cat > "$SANDBOX/mrg_manifest.yaml" <<'Y'
schema_version: 1
manifest_revision: 2
Y
cat > "$SANDBOX/mrg_ok.tracker.md" <<'M'
---
STATUS: ACTIVE
manifest_revision: 2
session_lock: null
---
M
cat > "$SANDBOX/mrg_drift.tracker.md" <<'M'
---
STATUS: ACTIVE
manifest_revision: 1
---
M
cat > "$SANDBOX/mrg_quoted.tracker.md" <<'M'
---
STATUS: ACTIVE
manifest_revision: "2"
---
M
cat > "$SANDBOX/mrg_manifestless.tracker.md" <<'M'
---
STATUS: ACTIVE
consecutive_impl_blocks: 0
---
M
cat > "$SANDBOX/mrg_paused_drift.tracker.md" <<'M'
---
STATUS: PAUSED
status_reason: manifest-revision-drift
manifest_revision: 1
---
M
cat > "$SANDBOX/mrg_paused_other.tracker.md" <<'M'
---
STATUS: PAUSED
status_reason: runtime-budget-expired
---
M
mrg() { bash "$MRG" "$@"; }

# AV3-04.1 — recorded == current: no drift.
out=$(mrg drift "$SANDBOX/mrg_ok.tracker.md" "$SANDBOX/mrg_manifest.yaml" 2>&1); rc=$?
assert_eq "AV3-04.1" "matching revision is clean (exit 0)" "0" "$rc"
assert_contains "AV3-04.1" "clean prints OK" "OK recorded=2" "$out"

# AV3-04.2 — recorded < current: drift detected (external-fault class -> PAUSE).
out=$(mrg drift "$SANDBOX/mrg_drift.tracker.md" "$SANDBOX/mrg_manifest.yaml" 2>&1); rc=$?
assert_eq "AV3-04.2" "revision drift exits 3" "3" "$rc"
assert_eq "AV3-04.2" "drift cites recorded vs current" "DRIFT recorded=1 current=2" "$out"

# AV3-04.3 — quoted YAML value parses (an LLM/yq writes manifest_revision: "2").
out=$(mrg drift "$SANDBOX/mrg_quoted.tracker.md" "$SANDBOX/mrg_manifest.yaml" 2>&1); rc=$?
assert_eq "AV3-04.3" "quoted recorded revision matches (clean)" "0" "$rc"

# AV3-04.4 — a manifest-less tracker has no recorded revision -> check is N/A.
out=$(mrg drift "$SANDBOX/mrg_manifestless.tracker.md" "$SANDBOX/mrg_manifest.yaml" 2>&1); rc=$?
assert_eq "AV3-04.4" "manifest-less drain: drift check N/A (exit 0)" "0" "$rc"
assert_eq "AV3-04.4" "manifest-less prints NO-MANIFEST" "NO-MANIFEST" "$out"

# AV3-04.5 — Resume REFUSES a drift-paused tracker and points at --generate --merge.
out=$(mrg resume-check "$SANDBOX/mrg_paused_drift.tracker.md" 2>&1); rc=$?
assert_eq "AV3-04.5" "resume refuses a drift-paused tracker (exit 2)" "2" "$rc"
assert_contains "AV3-04.5" "resume points at revision-regen" "--generate --merge" "$out"

# AV3-04.6 — a pause for any OTHER reason stays plain-resumable.
out=$(mrg resume-check "$SANDBOX/mrg_paused_other.tracker.md" 2>&1); rc=$?
assert_eq "AV3-04.6" "non-drift pause is resumable (exit 0)" "0" "$rc"
assert_eq "AV3-04.6" "non-drift pause prints RESUMABLE" "RESUMABLE" "$out"

# AV3-04.7 — usage guardrails.
mrg drift "$SANDBOX/mrg_ok.tracker.md" >/dev/null 2>&1; rc=$?
assert_eq "AV3-04.7" "drift with one arg is usage error 64" "64" "$rc"
mrg bogus-sub >/dev/null 2>&1; rc=$?
assert_eq "AV3-04.7" "unknown subcommand is usage error 64" "64" "$rc"

echo "== runbook_pr.sh + Runbook-PR fold (AV3-08) =="

RPR="$HERE/runbook_pr.sh"
cat > "$SANDBOX/rpr_body.md" <<'M'
## Summary
Extract the token bucket.

## Predicted file surface
<!-- autopilot:file-surface:begin -->
- `api/limiter.py`
- `lib/rate_limit/bucket.py`
- `tests/test_bucket.py`
<!-- autopilot:file-surface:end -->

## Checklist
M
# AV3-08.1 — the predicted file-surface block is a grep-able, machine-parseable
# list (G7 emits it into the Runbook PR body for foreign planners).
out=$(bash "$RPR" file-surface "$SANDBOX/rpr_body.md" 2>&1); rc=$?
assert_eq "AV3-08.1" "file-surface extraction exits 0" "0" "$rc"
assert_eq "AV3-08.1" "file-surface entry count" "3" "$(printf '%s\n' "$out" | grep -c .)"
assert_contains "AV3-08.1" "file-surface strips backticks/bullets" "lib/rate_limit/bucket.py" "$out"

cat > "$SANDBOX/rpr_nomarkers.md" <<'M'
## Summary
No file surface block here.
M
# AV3-08.2 — a body missing the markers is a hard format error (never silent).
bash "$RPR" file-surface "$SANDBOX/rpr_nomarkers.md" >/dev/null 2>&1; rc=$?
assert_eq "AV3-08.2" "missing file-surface markers is exit 1" "1" "$rc"
bash "$RPR" file-surface >/dev/null 2>&1; rc=$?
assert_eq "AV3-08.2" "no body arg is usage error 64" "64" "$rc"

# AV3-08.3 — tracker-fold fixture AGAINST THE RUNBOOK BRANCH: the retired rolling
# tracker PR is replaced by one bookkeeping home. The fold commit lands on
# autopilot/<slug>/runbook and carries the canonical "Tracker deltas folded in:"
# body block.
RB_REPO="$SANDBOX/rb-repo"
mk_repo "$RB_REPO"
( cd "$RB_REPO" && echo base > f && git add f && git commit -qm "chore: base" && git branch -M main \
  && git checkout -qb autopilot/demo/runbook \
  && printf 'tracker\n' > t.md && git add t.md \
  && git commit -q -m "chore: tracker fold — demo" -m "Tracker deltas folded in:
- in_progress_claim: claimed A1
- status_change: A1 pushed pr#7" )
fold_branch=$(git -C "$RB_REPO" branch --contains HEAD --format='%(refname:short)' | grep -c 'autopilot/demo/runbook')
assert_eq "AV3-08.3" "tracker fold commit is on the runbook branch" "1" "$fold_branch"
assert_contains "AV3-08.3" "fold commit carries the deltas block" "Tracker deltas folded in:" "$(git -C "$RB_REPO" log -1 --pretty=%b)"

echo "== claim_overlap.sh (AV3-09 claim consultation) =="

CO="$HERE/claim_overlap.sh"
TAB="$(printf '\t')"
# Inventory columns: pr-ref <TAB> branch <TAB> state <TAB> age_bd <TAB> comma-files
{
  printf 'gh/101\tautopilot/other/story-a\tDRAFT\t1\tapi/limiter.py,lib/x.py\n'
  printf 'gh/102\tautopilot/other/story-b\tOPEN\t0\tcore/engine.py\n'
  printf 'gh/103\tautopilot/other/story-c\tDRAFT\t5\tdocs/old.md\n'
  printf 'gh/104\tautopilot/mine/story-z\tDRAFT\t0\townpath.py\n'
} > "$SANDBOX/claim_inv.tsv"
co() { bash "$CO" --self-namespace autopilot/mine/ --inventory "$SANDBOX/claim_inv.tsv" "$@"; }

# AV3-09.1 — a fresh foreign DRAFT PR overlapping our files is a BINDING claim.
out=$(co api/limiter.py 2>&1); rc=$?
assert_eq "AV3-09.1" "foreign draft overlap blocks (exit 2)" "2" "$rc"
assert_contains "AV3-09.1" "binding claim emits blocked_by_pr" "blocked_by_pr=gh/101 class=BINDING" "$out"

# AV3-09.2 — a foreign ready (non-draft OPEN) PR is a TERMINAL claim.
out=$(co core/engine.py 2>&1); rc=$?
assert_eq "AV3-09.2" "foreign ready overlap blocks (exit 2)" "2" "$rc"
assert_contains "AV3-09.2" "terminal claim emits blocked_by_pr" "blocked_by_pr=gh/102 class=TERMINAL" "$out"

# AV3-09.3 — a branch under our OWN drain namespace is never a foreign claim
# (closes the re-GENERATE self-deadlock): only own overlap -> non-blocking.
out=$(co ownpath.py 2>&1); rc=$?
assert_eq "AV3-09.3" "own-namespace overlap does not block (exit 0)" "0" "$rc"
assert_contains "AV3-09.3" "own-namespace claim is excluded" "excluded=gh/104" "$out"

# AV3-09.4 — a foreign PR stale beyond 2 business days is ADVISORY, not blocking.
out=$(co docs/old.md 2>&1); rc=$?
assert_eq "AV3-09.4" "stale (>2bd) overlap is advisory (exit 0)" "0" "$rc"
assert_contains "AV3-09.4" "stale claim is advisory" "advisory=gh/103" "$out"

# AV3-09.5 — no shared files -> clean, silent.
out=$(co unrelated/file.py 2>&1); rc=$?
assert_eq "AV3-09.5" "no overlap is clean (exit 0)" "0" "$rc"
assert_eq "AV3-09.5" "no overlap prints nothing" "" "$out"

# AV3-09.6 — D2 eligibility: a claimed Subtask waits until its blocked_by_pr
# resolves (MERGED/DECLINED/NONE eligible; OPEN/DRAFT ineligible).
assert_eq "AV3-09.6" "blocked_by MERGED -> eligible (exit 0)" "0" "$(bash "$CO" eligibility --pr-state MERGED >/dev/null 2>&1; echo $?)"
assert_eq "AV3-09.6" "blocked_by DECLINED -> eligible" "0" "$(bash "$CO" eligibility --pr-state DECLINED >/dev/null 2>&1; echo $?)"
assert_eq "AV3-09.6" "blocked_by OPEN -> ineligible (exit 2)" "2" "$(bash "$CO" eligibility --pr-state OPEN >/dev/null 2>&1; echo $?)"
assert_eq "AV3-09.6" "blocked_by DRAFT -> ineligible (exit 2)" "2" "$(bash "$CO" eligibility --pr-state DRAFT >/dev/null 2>&1; echo $?)"

# AV3-09.7 — usage guardrails.
bash "$CO" --inventory "$SANDBOX/claim_inv.tsv" >/dev/null 2>&1; rc=$?
assert_eq "AV3-09.7" "no files is usage error 64" "64" "$rc"
bash "$CO" eligibility --pr-state BOGUS >/dev/null 2>&1; rc=$?
assert_eq "AV3-09.7" "unknown pr-state is usage error 64" "64" "$rc"

# AV3-09.8 — P2-b: D2 claim-eligibility fail-closed edge. `host.sh pr-state` emits
# UNKNOWN when a read SUCCEEDS but the PR's state is null / unmappable (github.sh
# map_state's `*)` arm / the bitbucket.sh equivalent); a genuinely unreadable read
# instead dies exit 1, leaving an empty state. EITHER shape MUST exit 64 at the
# eligibility gate (a state outside the observable OPEN|DRAFT|MERGED|DECLINED|NONE
# vocabulary), NOT 0 (fail-open onto an unresolved claim) and NOT 2 (silently
# treated as blocked). The exit-64 contract is what lifecycle.md D2 routes to
# HUMAN_NEEDED — claim-eligibility-usage-error (external fault, loop-safety invariant 3).
out=$(bash "$CO" eligibility --pr-state UNKNOWN 2>&1); rc=$?
assert_eq "AV3-09.8" "UNKNOWN pr-state fails closed as usage error 64 (not 0/eligible)" "64" "$rc"
assert_not_contains "AV3-09.8" "UNKNOWN never reads as ELIGIBLE" "ELIGIBLE" "$out"
bash "$CO" eligibility --pr-state "" >/dev/null 2>&1; rc=$?
assert_eq "AV3-09.8" "empty pr-state (host.sh pr-state died on an unreadable read) also fails closed as 64" "64" "$rc"

echo "== claim_loss_attribution.sh (AV3-10 serialize-and-replan) =="

CLA="$HERE/claim_loss_attribution.sh"

# AV3-10.1 — the rebase's conflicting hunks intersect the claim-overlap set:
# the divergence IS a claim collision -> route to D3 re-plan (within budget).
out=$(bash "$CLA" --overlap-files "api/limiter.py,lib/x.py" --conflict-files "api/limiter.py,core/z.py" 2>&1); rc=$?
assert_eq "AV3-10.1" "attributed divergence -> REPLAN (exit 0)" "0" "$rc"
assert_contains "AV3-10.1" "REPLAN cites the colliding files" "REPLAN files=api/limiter.py" "$out"

# AV3-10.2 — disjoint file sets: a genuine planning conflict, not a claim loss ->
# normal impl-block escalation.
out=$(bash "$CLA" --overlap-files "api/limiter.py" --conflict-files "core/z.py,other.py" 2>&1); rc=$?
assert_eq "AV3-10.2" "disjoint divergence -> NOT-ATTRIBUTED (exit 1)" "1" "$rc"
assert_eq "AV3-10.2" "not-attributed token" "NOT-ATTRIBUTED" "$out"

# AV3-10.3 — no recorded claim overlap -> never attributed to a claim loss.
out=$(bash "$CLA" --overlap-files "" --conflict-files "api/limiter.py" 2>&1); rc=$?
assert_eq "AV3-10.3" "no overlap set -> NOT-ATTRIBUTED (exit 1)" "1" "$rc"

# AV3-10.4 — re-plan is BOUNDED at 2 per Subtask; past that, normal escalation.
out=$(bash "$CLA" --overlap-files "api/limiter.py" --conflict-files "api/limiter.py" --replans-so-far 2 2>&1); rc=$?
assert_eq "AV3-10.4" "attributed but budget spent -> EXHAUSTED (exit 2)" "2" "$rc"
assert_contains "AV3-10.4" "exhausted token" "REPLAN-BUDGET-EXHAUSTED" "$out"

# AV3-10.5 — one re-plan already spent (1 < 2) still re-plans.
out=$(bash "$CLA" --overlap-files "api/limiter.py" --conflict-files "api/limiter.py" --replans-so-far 1 2>&1); rc=$?
assert_eq "AV3-10.5" "within re-plan budget -> REPLAN (exit 0)" "0" "$rc"

# AV3-10.6 — usage guardrail.
bash "$CLA" --overlap-files "a" >/dev/null 2>&1; rc=$?
assert_eq "AV3-10.6" "missing --conflict-files is usage error 64" "64" "$rc"

echo "== audit_behavior_binding.sh (AV3-05 behavior->test binding) =="

ABB="$HERE/audit_behavior_binding.sh"
BIND_REPO="$SANDBOX/bind-repo"
mk_repo "$BIND_REPO"
bindc() { git -C "$BIND_REPO" "$@"; }
echo base > "$BIND_REPO/f"; bindc add f; bindc commit -qm "chore: base"
BIND_BASE=$(bindc rev-parse HEAD)
# RED commits that NAME the bound test (subject or body) — the D6 evidence.
bindc commit -q --allow-empty -m "test: A1.1 RED — rejects expired lock" -m "adds tests/test_pricing.py::test_rejects_expired_lock"
bindc commit -q --allow-empty -m "feat: A1.1 GREEN — rejects expired lock"
bindc commit -q --allow-empty -m "test: A1.2 RED — accepts valid lock (test_accepts_valid_lock)"
bindc commit -q --allow-empty -m "feat: A1.2 GREEN — accepts valid lock"
abb() { ( cd "$BIND_REPO" && bash "$ABB" "$@" ); }

cat > "$SANDBOX/cov_ok.md" <<'M'
## Behavior coverage
<!-- autopilot:behavior-coverage -->
- B-pricing-001: tests/test_pricing.py::test_rejects_expired_lock
- B-pricing-002: tests/test_pricing.py::test_accepts_valid_lock
M
# AV3-05.1 — every mapped Behavior is bound to a test that a RED commit names.
out=$(abb --coverage "$SANDBOX/cov_ok.md" --base "$BIND_BASE" 2>&1); rc=$?
assert_eq "AV3-05.1" "fully-bound coverage exits 0" "0" "$rc"
assert_eq "AV3-05.1" "fully-bound coverage prints OK" "OK" "$out"

cat > "$SANDBOX/cov_unbound.md" <<'M'
- B-pricing-001: tests/test_pricing.py::test_rejects_expired_lock
- B-pricing-003:
M
# AV3-05.2 — a Behavior with no bound test node is unbound-behavior.
out=$(abb --coverage "$SANDBOX/cov_unbound.md" --base "$BIND_BASE" 2>&1); rc=$?
assert_eq "AV3-05.2" "unbound Behavior refused" "1" "$rc"
assert_eq "AV3-05.2" "unbound cites the behavior-id" "[BLOCKED: unbound-behavior] B-pricing-003" "$out"

cat > "$SANDBOX/cov_unproven.md" <<'M'
- B-pricing-001: tests/test_pricing.py::test_rejects_expired_lock
- B-pricing-009: tests/test_pricing.py::test_never_written
M
# AV3-05.3 — a bound test that no RED commit names is an unproven binding (the
# implementer's self-report is not trusted; git log is the source of truth).
out=$(abb --coverage "$SANDBOX/cov_unproven.md" --base "$BIND_BASE" 2>&1); rc=$?
assert_eq "AV3-05.3" "unproven binding refused" "1" "$rc"
assert_contains "AV3-05.3" "unproven cites the behavior + test" "[BLOCKED: unproven-binding] B-pricing-009 test_never_written" "$out"

# AV3-05.4 — usage guardrail.
abb --coverage "$SANDBOX/cov_ok.md" >/dev/null 2>&1; rc=$?
assert_eq "AV3-05.4" "missing --base is usage error 64" "64" "$rc"

# AV3-05.5 — adversarial round (executor lens): the bound test name must be matched
# as a WHOLE WORD, not a substring — `test_accepts_valid_lock` must NOT be read as
# proven when the only RED commit names `test_accepts_valid_lock_v2`.
BIND_BASE2=$(bindc rev-parse HEAD)
bindc commit -q --allow-empty -m "test: A2.1 RED — variant" -m "adds tests/test_pricing.py::test_accepts_valid_lock_v2"
cat > "$SANDBOX/cov_substr.md" <<'M'
- B-pricing-002: tests/test_pricing.py::test_accepts_valid_lock
M
out=$(abb --coverage "$SANDBOX/cov_substr.md" --base "$BIND_BASE2" 2>&1); rc=$?
assert_eq "AV3-05.5" "substring-only test name is an unproven binding" "1" "$rc"
assert_contains "AV3-05.5" "whole-word: _v2 does not prove the base name" "unproven-binding" "$out"

echo "== determinism_gate.sh (AV3-12 N=5 flaky gate) =="

DG="$HERE/determinism_gate.sh"

# AV3-12.1 — a deterministic command agrees across all 5 rounds.
out=$(bash "$DG" --cmd 'echo "2 passed"; exit 0' --random-cmd 'echo "2 passed"; exit 0' 2>/dev/null); rc=$?
assert_eq "AV3-12.1" "deterministic command exits 0" "0" "$rc"
assert_contains "AV3-12.1" "deterministic verdict" "DETERMINISTIC (5 rounds)" "$out"

# AV3-12.2 — no gates.test_random -> the order-randomized round is SKIPPED with a
# LOUD [note] (never silently), and the gate still passes.
err=$(bash "$DG" --cmd 'echo ok; exit 0' 2>&1 >/dev/null); rc=$?
assert_eq "AV3-12.2" "missing random-cmd still passes (exit 0)" "0" "$rc"
assert_contains "AV3-12.2" "skipped-randomization note is loud" "order-randomized round SKIPPED" "$err"

# AV3-12.3 — with a random-cmd, no skip note is emitted.
err=$(bash "$DG" --cmd 'echo ok; exit 0' --random-cmd 'echo ok; exit 0' 2>&1 >/dev/null)
assert_not_contains "AV3-12.3" "no skip note when randomization is available" "SKIPPED" "$err"

# AV3-12.4 — a planted-flaky test whose EXIT CODE alternates is caught.
printf '0' > "$SANDBOX/dg_cnt"
out=$(bash "$DG" --cmd "n=\$(cat $SANDBOX/dg_cnt); echo \$((n+1))>$SANDBOX/dg_cnt; [ \$((n%2)) -eq 0 ] && exit 0 || exit 1" 2>/dev/null); rc=$?
assert_eq "AV3-12.4" "exit-code-flaky test blocked (exit 1)" "1" "$rc"
assert_contains "AV3-12.4" "flaky-test token emitted" "[BLOCKED: flaky-test]" "$out"

# AV3-12.5 — same exit code every round but a DIFFERENT failing test name is
# caught via the failure fingerprint (the "failure sets" comparison).
printf '0' > "$SANDBOX/dg_cnt2"
out=$(bash "$DG" --cmd "n=\$(cat $SANDBOX/dg_cnt2); echo \$((n+1))>$SANDBOX/dg_cnt2; [ \$((n%2)) -eq 0 ] && echo FAILED_test_alpha || echo FAILED_test_beta; exit 0" 2>/dev/null); rc=$?
assert_eq "AV3-12.5" "failure-set-flaky test blocked (exit 1)" "1" "$rc"

# AV3-12.6 — volatile durations/counts (digits) must NOT false-flag a stable
# result (else the gate is useless on real runners).
printf '0' > "$SANDBOX/dg_cnt3"
out=$(bash "$DG" --cmd "n=\$(cat $SANDBOX/dg_cnt3); echo \$((n+1))>$SANDBOX/dg_cnt3; echo \"2 passed in 0.\${n}s\"; exit 0" 2>/dev/null); rc=$?
assert_eq "AV3-12.6" "volatile durations do not false-flag (exit 0)" "0" "$rc"

# AV3-12.7 — usage guardrails.
bash "$DG" >/dev/null 2>&1; rc=$?
assert_eq "AV3-12.7" "missing --cmd is usage error 64" "64" "$rc"
bash "$DG" --cmd 'exit 0' --runs 1 >/dev/null 2>&1; rc=$?
assert_eq "AV3-12.7" "runs < 2 is usage error 64" "64" "$rc"

# AV3-12.8 — P2-a: a parametrized pytest test that fails a DIFFERENT case index
# each round (`test_login[0]` then `test_login[1]`) is a common real flaky pattern.
# The exit code is stable (a failure every round) so this isolates the FINGERPRINT
# path — like AV3-12.5, but 12.5 uses letter-only names and so is still caught by
# the old blanket digit-strip; only a preserved param INDEX proves the fix.
# RED-TESTED against the pre-fix `tr -d '0-9'` logic: it collapsed both rounds to
# `test_login[]` and false-greened DETERMINISTIC (exit 0). The param index in the
# `::` node-id token must survive normalization for this to red pre-fix / green now.
printf '0' > "$SANDBOX/dg_cntp"
out=$(bash "$DG" --cmd "n=\$(cat $SANDBOX/dg_cntp); echo \$((n+1))>$SANDBOX/dg_cntp; [ \$((n%2)) -eq 0 ] && echo 'FAILED tests/test_auth.py::test_login[0]' || echo 'FAILED tests/test_auth.py::test_login[1]'; exit 1" 2>/dev/null); rc=$?
assert_eq "AV3-12.8" "param-index-flipping flaky test blocked (exit 1)" "1" "$rc"
assert_contains "AV3-12.8" "flaky-test token emitted for the param-index flip" "[BLOCKED: flaky-test]" "$out"

# AV3-12.9 — P2-a regression guard (false-RED). A DETERMINISTIC run whose STABLE
# failing node id is accompanied by a VOLATILE bracketed duration must NOT be
# flagged flaky. The fix keys on the `::` node-id token, not on brackets anywhere
# in the line — so `[123 ns]`/`[456 ns]` and `0.5s`/`0.9s` are stripped as volatile
# while `tests/test_x.py::test_render` stays stable. RED-TESTED against an over-broad
# "keep every digit inside [...]" fix: that variant preserves the bracketed nanos
# and false-REDs this (exit 1); the shipped node-id keying — and the pre-P2-a blanket
# strip — both correctly report DETERMINISTIC (exit 0).
printf '0' > "$SANDBOX/dg_cntv"
out=$(bash "$DG" --cmd "n=\$(cat $SANDBOX/dg_cntv); echo \$((n+1))>$SANDBOX/dg_cntv; echo \"FAILED tests/test_x.py::test_render took [\${n}23 ns] in 0.\${n}s\"; exit 1" 2>/dev/null); rc=$?
assert_eq "AV3-12.9" "stable node id + volatile bracketed duration stays DETERMINISTIC (exit 0)" "0" "$rc"
assert_contains "AV3-12.9" "deterministic verdict despite bracketed volatile noise" "DETERMINISTIC" "$out"

echo "== mutation_gate.sh (D6.5 anti-vacuous gate — ADR 0016 / MT-02,03,05,07,08) =="

MG="$HERE/mutation_gate.sh"
MADP="$HERE/../../cleanup-audit/scripts/mutation_adapter.sh"   # the ONE canonical map (ADR 0016/0025)

# The canonical adapter (single copy since ADR 0025) resolves +
# counts — inline canned tool output, no external fixture dependency (hermetic).
out=$(printf '3 mutants tested, 1 missed\nsrc/pay.rs:42:9: replace calc with 0\n' | bash "$MADP" normalize cargo-mutants)
assert_eq "MT-01.a" "canonical adapter normalizes cargo survivor to file:line" "src/pay.rs:42" "$out"
out=$(printf 'PASS "a.go.0" x\nFAIL "a.go.1" x\ntotal is 2\n' | bash "$MADP" normalize go-mutesting)
assert_eq "MT-01.b" "canonical adapter degrades go-mutesting survivor to file granularity" "a.go:-" "$out"
out=$(printf '10 mutants tested, 2 missed\n' | bash "$MADP" count cargo-mutants)
assert_eq "MT-01.c" "canonical adapter counts total mutants (budget input)" "10" "$out"

# A hermetic git repo whose HEAD adds line 3 (BASE..HEAD changed line = mod.py:3).
mk_mut_repo() {  # $1 = dir -> echoes BASE sha
  local d="$1"
  mk_repo "$d"
  ( cd "$d"
    printf 'def f():\n    return 1\n' > mod.py
    git add mod.py; git commit -qm base
    printf 'def f():\n    return 1\n    g(2)\n' > mod.py   # line 3 added
    git add mod.py; git commit -qm change )
  ( cd "$d" && git rev-parse HEAD~1 )
}

# MT-08 — graceful degrade: no tool → loud skip [note] on stderr, exit 0.
MR="$SANDBOX/mg_skip"; MBASE="$(mk_mut_repo "$MR")"
err=$( cd "$MR" && bash "$MG" --base "$MBASE" 2>&1 >/dev/null ); rc=$?
assert_eq "MT-08.1" "no mutation tool → D6.5 skips, exit 0" "0" "$rc"
assert_contains "MT-08.1" "skip note is loud on stderr (never silent)" "no mutation tool for the configured language — D6.5 anti-vacuous gate skipped (optional)" "$err"
err=$( cd "$MR" && bash "$MG" --tool no-such --run-cmd 'echo x' --base "$MBASE" 2>&1 >/dev/null ); rc=$?
assert_eq "MT-08.2" "unsupported tool → D6.5 skips, exit 0" "0" "$rc"
assert_contains "MT-08.2" "unsupported tool names the skip reason" "has no adapter" "$err"

# MT-02 — clean-index precheck refuses a dirty TRACKED tree (exit 64, not a block).
MR="$SANDBOX/mg_dirty"; MBASE="$(mk_mut_repo "$MR")"
( cd "$MR" && printf 'dirty\n' >> mod.py )
out=$( cd "$MR" && bash "$MG" --tool cargo-mutants --run-cmd 'echo x' --base "$MBASE" 2>&1 ); rc=$?
assert_eq "MT-02.1" "dirty tracked tree → clean-index precheck refuses (exit 64)" "64" "$rc"
assert_contains "MT-02.1" "refusal cites the clean-index precheck" "clean-index precheck FAILED" "$out"

# MT-02 — throwaway worktree is created AND torn down on normal exit; the live
# checkout is NEVER mutated (the run-cmd writes a marker only inside the throwaway).
MR="$SANDBOX/mg_iso"; MBASE="$(mk_mut_repo "$MR")"
wt_before=$( cd "$MR" && git worktree list | wc -l | tr -d ' ' )
( cd "$MR" && bash "$MG" --tool cargo-mutants --base "$MBASE" \
    --run-cmd 'touch MUTATED_IN_WT; echo "1 mutants tested, 0 missed"' >/dev/null 2>&1 )
wt_after=$( cd "$MR" && git worktree list | wc -l | tr -d ' ' )
assert_eq "MT-02.2" "throwaway worktree torn down on normal exit (count returns to baseline)" "$wt_before" "$wt_after"
if [ -f "$MR/MUTATED_IN_WT" ]; then fail "MT-02.2" "live checkout MUTATED (marker leaked out of the throwaway)"; else pass "MT-02.2" "live checkout unmodified (marker existed only in the throwaway worktree)"; fi

# MT-02 — trap fires even on injected mid-run FAILURE (tool touches a file, exit 3):
# worktree torn down, live tree unmodified, and NO false block (inconclusive).
MR="$SANDBOX/mg_crash"; MBASE="$(mk_mut_repo "$MR")"
wt_before=$( cd "$MR" && git worktree list | wc -l | tr -d ' ' )
out=$( cd "$MR" && bash "$MG" --tool cargo-mutants --base "$MBASE" --run-cmd 'touch CRASH_LEFTOVER; exit 3' 2>/dev/null ); rc=$?
wt_after=$( cd "$MR" && git worktree list | wc -l | tr -d ' ' )
assert_eq "MT-02.3" "worktree torn down after injected mid-run failure (EXIT trap fires on error)" "$wt_before" "$wt_after"
if [ -f "$MR/CRASH_LEFTOVER" ]; then fail "MT-02.3" "live tree got the crash leftover"; else pass "MT-02.3" "live tree unmodified after tool crash"; fi
assert_eq "MT-02.3" "tool crash → inconclusive, exit 0 (never a false block)" "0" "$rc"

# MT-02 — INT/TERM trap: TERM the gate mid-run; the throwaway must still be removed.
MR="$SANDBOX/mg_term"; MBASE="$(mk_mut_repo "$MR")"
wt_before=$( cd "$MR" && git worktree list | wc -l | tr -d ' ' )
# `exec` so the backgrounded subshell PID IS mutation_gate's PID — TERM must reach
# the gate itself for its INT/TERM trap to fire (a plain subshell wrapper would
# swallow the signal and orphan the gate).
( cd "$MR" && exec bash "$MG" --tool cargo-mutants --base "$MBASE" --max-seconds 60 \
    --run-cmd 'touch TERM_LEFTOVER; sleep 20; echo done' >/dev/null 2>&1 ) &
mg_pid=$!
for _i in 1 2 3 4 5 6 7 8 9 10; do
  [ "$( cd "$MR" && git worktree list | wc -l | tr -d ' ' )" -gt "$wt_before" ] && break
  sleep 1
done
kill -TERM "$mg_pid" 2>/dev/null; wait "$mg_pid" 2>/dev/null; sleep 1
( cd "$MR" && git worktree prune 2>/dev/null )
wt_after=$( cd "$MR" && git worktree list | wc -l | tr -d ' ' )
assert_eq "MT-02.4" "throwaway worktree torn down after SIGTERM (INT/TERM trap)" "$wt_before" "$wt_after"
if [ -f "$MR/TERM_LEFTOVER" ]; then fail "MT-02.4" "live tree got the TERM leftover"; else pass "MT-02.4" "live tree unmodified after SIGTERM"; fi

# MT-03 — a survivor on a CHANGED line (mod.py:3) → [BLOCKED: vacuous-test], exit 1.
MR="$SANDBOX/mg_block"; MBASE="$(mk_mut_repo "$MR")"
out=$( cd "$MR" && bash "$MG" --tool cargo-mutants --base "$MBASE" --files mod.py \
    --run-cmd 'echo "1 mutants tested, 1 missed"; echo "mod.py:3:5: replace g with ()"' 2>/dev/null ); rc=$?
assert_eq "MT-03.1" "survivor on a changed line → exit non-zero" "1" "$rc"
assert_contains "MT-03.1" "vacuous-test producer token emitted" "[BLOCKED: vacuous-test]" "$out"

# MT-03 — a genuinely-constraining test (no survivor) → pass.
out=$( cd "$MR" && bash "$MG" --tool cargo-mutants --base "$MBASE" --files mod.py \
    --run-cmd 'echo "2 mutants tested, 0 missed"' 2>/dev/null ); rc=$?
assert_eq "MT-03.2" "no survivor → NON-VACUOUS, exit 0" "0" "$rc"
assert_contains "MT-03.2" "non-vacuous verdict" "NON-VACUOUS" "$out"

# MT-03 — a survivor OFF the changed lines (mod.py:1, inherited) → pass (ratchet).
out=$( cd "$MR" && bash "$MG" --tool cargo-mutants --base "$MBASE" --files mod.py \
    --run-cmd 'echo "1 mutants tested, 1 missed"; echo "mod.py:1:1: replace f with ()"' 2>/dev/null ); rc=$?
assert_eq "MT-03.3" "inherited (off-diff) survivor never blocks (ADR-0004 ratchet)" "0" "$rc"

# MT-05 — a file-granular survivor (go-mutesting, no line) on a changed FILE cannot
# be pinned to a changed line → comment-only [note], exit 0 (never a block).
out=$( cd "$MR" && bash "$MG" --tool go-mutesting --base "$MBASE" --files mod.py \
    --run-cmd 'echo '\''FAIL "mod.py.1" with checksum'\''; echo "total is 1"' 2>/dev/null ); rc=$?
assert_eq "MT-05.1" "file-granular survivor → exit 0 (comment-only, not a block)" "0" "$rc"
assert_contains "MT-05.1" "file-granular survivor is a comment-only note" "file-granular survivor" "$out"

# MT-07 — mutant-cap exceeded → partial [note], exit 0, NO false block even though a
# changed-line survivor is present (inconclusive != survivor).
out=$( cd "$MR" && bash "$MG" --tool cargo-mutants --base "$MBASE" --files mod.py --max-mutants 2 \
    --run-cmd 'echo "10 mutants tested, 1 missed"; echo "mod.py:3:5: replace g with ()"' 2>/dev/null ); rc=$?
assert_eq "MT-07.1" "mutant-budget exceeded → exit 0 (no false block)" "0" "$rc"
assert_contains "MT-07.1" "partial budget note (N of M)" "mutation-budget-exhausted — partial (2 of 10)" "$out"
assert_not_contains "MT-07.1" "budget exhaustion never emits a block" "[BLOCKED: vacuous-test]" "$out"

# MT-07 — wall-clock budget: a run exceeding --max-seconds → partial [note], exit 0.
out=$( cd "$MR" && bash "$MG" --tool cargo-mutants --base "$MBASE" --files mod.py --max-seconds 1 \
    --run-cmd 'sleep 5; echo "1 mutants tested, 1 missed"; echo "mod.py:3:5: x"' 2>/dev/null ); rc=$?
assert_eq "MT-07.2" "wall-clock budget exceeded → exit 0 (no false block)" "0" "$rc"
assert_contains "MT-07.2" "timed-out partial note" "mutation-budget-exhausted — partial" "$out"

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

echo "== github.sh backend via gh argv shim (H-GH, HG01-HG36) =="

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
        head="$(argval --head "$@" || true)"
        base="$(argval --base "$@" || true)"
        if [[ -n "$head" ]]; then
          # pr-state --branch path (state,isDraft only).
          if [[ "$head" == "feature-x" ]]; then printf '[{"state":"OPEN","isDraft":false}]\n'; else printf '[]\n'; fi
        elif [[ "$base" == "main" ]]; then
          # pr-list-ready queue enumeration (AV3-15b) — aligned with the DC mock
          # fixture: PR 42 APPROVED, PR 77 PENDING (reviewDecision != APPROVED),
          # PR 88 a draft (excluded via isDraft). Non-trunk PRs never reach here:
          # `--base` filters server-side (the GitHub analogue of the DC toRef test).
          printf '[{"number":42,"headRefName":"feature-x","headRefOid":"aaa42sha","reviewDecision":"APPROVED","createdAt":"2026-07-05T10:00:00Z","isDraft":false},{"number":77,"headRefName":"feature-y","headRefOid":"bbb77sha","reviewDecision":"REVIEW_REQUIRED","createdAt":"2026-07-05T09:00:00Z","isDraft":false},{"number":88,"headRefName":"feature-draft","headRefOid":"ddd88sha","reviewDecision":"APPROVED","createdAt":"2026-07-05T08:00:00Z","isDraft":true}]\n'
        elif [[ "$base" == "rfrtest" ]]; then
          # ReadyForReviewEvent-refinement fixture: PR 91 was opened as a draft at
          # 08:00Z and readied-for-review later; its FIFO key must come from the
          # RFR event (see the graphql shim), NOT createdAt.
          printf '[{"number":91,"headRefName":"feature-rfr","headRefOid":"fff91sha","reviewDecision":"APPROVED","createdAt":"2026-07-05T08:00:00Z","isDraft":false}]\n'
        elif [[ "$base" == "hardening" ]]; then
          # Robustness fixture: PR 93 has a FRACTIONAL-second createdAt (must still
          # convert, not abort the whole enumeration); PR 94 has an EMPTY headRefOid
          # (must be dropped — no head sha = not a merge candidate, and an empty
          # middle column would shift the Marshal's read).
          printf '[{"number":93,"headRefName":"feature-frac","headRefOid":"fff93sha","reviewDecision":"APPROVED","createdAt":"2026-07-05T10:00:00.500Z","isDraft":false},{"number":94,"headRefName":"feature-nosha","headRefOid":"","reviewDecision":"APPROVED","createdAt":"2026-07-05T09:00:00Z","isDraft":false}]\n'
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
    # ADR 0028 repo-list drives `gh api --paginate <path>`; existing calls
    # never pass --paginate, so their argv is untouched.
    paginate=0
    if [[ "$path" == "--paginate" ]]; then paginate=1; path="${3:-}"; fi
    case "$path" in
      /orgs/acme/repos)
        # repo-list fixture: --paginate is REQUIRED argv (`gh repo list` has no
        # --paginate — the ADR 0028 correction), so a paginate-less enumeration
        # FAILS LOUD here. gh --paginate concatenates one JSON array per page;
        # emit TWO pages (widget, pricing — aligned with the DC mock) so
        # multi-page extraction is the asserted shape.
        if (( paginate )); then
          printf '[{"name":"widget","ssh_url":"git@github.com:acme/widget.git"}]\n[{"name":"pricing","ssh_url":"git@github.com:acme/pricing.git"}]\n'
        else
          printf 'ghshim: repo enumeration without --paginate\n' >&2
          exit 1
        fi ;;
      /orgs/failorg/repos)
        printf 'gh: HTTP 404: Not Found (/orgs/failorg/repos)\n' >&2
        exit 1 ;;
      /orgs/emptyorg/repos)
        printf '[]\n' ;;
      graphql)
        # ReadyForReviewEvent lookup (pr-list-ready FIFO-key refinement). Returns
        # a real event only for PR 91; every other PR was opened non-draft (empty
        # nodes -> the caller falls back to createdAt).
        gqn=""
        for a in "$@"; do case "$a" in n=*) gqn="${a#n=}" ;; esac; done
        if [[ "$gqn" == "91" ]]; then
          printf '{"data":{"repository":{"pullRequest":{"timelineItems":{"nodes":[{"__typename":"ReadyForReviewEvent","createdAt":"2026-07-05T12:00:00Z"}]}}}}}\n'
        else
          printf '{"data":{"repository":{"pullRequest":{"timelineItems":{"nodes":[]}}}}}\n'
        fi ;;
      repos/acme/widget)
        printf '{"default_branch":"main","allow_merge_commit":true,"allow_squash_merge":true,"allow_rebase_merge":false}\n' ;;
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
mk_repo "$GH_REPO_DIR"
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

# HG31 — pr-list-ready FIFO-key refinement: PR 91 was opened as a draft at 08:00Z
# and readied-for-review at 12:00Z. Its ready_ts MUST be the ReadyForReviewEvent
# epoch (1783252800), NOT createdAt's 1783238400 — else a readied-from-draft PR
# would jump the FIFO queue. This is what makes the refinement non-vacuous.
out="$(ggh pr-list-ready --base rfrtest 2>/dev/null)"
assert_eq HG31 "readied-from-draft PR keys off the ReadyForReviewEvent, not createdAt" \
  "$(printf '1783252800\t91\tfeature-rfr\tfff91sha\tAPPROVED')" "$out"
# HG32 — an empty queue is empty output + exit 0 (no rows, not an error).
out="$(ggh pr-list-ready --base emptybase 2>/dev/null)"; rc=$?
assert_eq HG32 "empty queue -> no output" "" "$out"
assert_eq HG32 "empty queue -> exit 0" "0" "$rc"

# HG33 — robustness: a fractional-second createdAt (PR 93) still converts to the
# whole-second epoch (1783245600) rather than aborting the WHOLE enumeration, and
# a PR with an EMPTY head sha (PR 94) is dropped. Output is exactly PR 93.
out="$(ggh pr-list-ready --base hardening 2>/dev/null)"
assert_eq HG33 "fractional createdAt converts + empty-head-sha PR dropped (one bad row != whole-queue abort)" \
  "$(printf '1783245600\t93\tfeature-frac\tfff93sha\tAPPROVED')" "$out"

# HG34 — repo-list (ADR 0028) drives `gh api --paginate /orgs/<org>/repos` —
# NEVER `gh repo list` (it has no --paginate): the shim EXITS 1 on a
# paginate-less enumeration, so this assertion also pins the argv. Both
# concatenated pages land in the 2-column TSV, in page order.
out="$(hgh repo-list --org acme 2>/dev/null)"
assert_eq HG34 "gh repo-list: --paginate argv + both pages in the 2-col TSV" \
  "$(printf 'widget\tgit@github.com:acme/widget.git\npricing\tgit@github.com:acme/pricing.git')" "$out"

# HG35 — gh's exit status is SURFACED (no 2>/dev/null discard): a failed
# enumeration is die_state + gh's own stderr, never an empty-TSV false success
# (the retired transport's silent-failure defect).
err="$(hgh repo-list --org failorg 2>&1 >/dev/null)"; rc=$?
assert_eq HG35 "gh enumeration failure -> exit 1 (never a silent empty TSV)" "1" "$rc"
assert_contains HG35 "failure classified via LAST_STATE" "LAST_STATE=repo-list-failed" "$err"
assert_contains HG35 "gh's own stderr passes through (not discarded)" "HTTP 404" "$err"

# HG36 — a genuinely-empty org is DISTINGUISHABLE from failure: empty TSV, exit 0.
out="$(hgh repo-list --org emptyorg 2>/dev/null)"; rc=$?
assert_eq HG36 "empty org -> no output" "" "$out"
assert_eq HG36 "empty org -> exit 0" "0" "$rc"

echo "== host.sh backend detection (H50) =="

det() { ( cd "$1" && bash "$HERE/host.sh" backend 2>/dev/null ); }
# H50 — the two canonical origin URL shapes resolve to their backends.
assert_eq H50 "DC /scm/ https origin -> BITBUCKET_DC" "BITBUCKET_DC" "$(det "$API_REPO")"
assert_eq H50 "github.com https origin -> GITHUB" "GITHUB" "$(det "$GH_REPO_DIR")"
# H50 — an ssh github origin also resolves to GITHUB.
SSHGH="$SANDBOX/sshgh"; mk_repo "$SSHGH"
git -C "$SSHGH" remote add origin "git@github.com:acme/widget.git"
assert_eq H50 "git@github.com ssh origin -> GITHUB" "GITHUB" "$(det "$SSHGH")"
# H50 — a trailing-slash github origin: host.sh routes GITHUB AND github.sh
# parses it (it strips the trailing slash), so a PR op actually succeeds rather
# than dying origin-parse.
TSGH="$SANDBOX/tsgh"; mk_repo "$TSGH"
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
UNK="$SANDBOX/unk-repo"; mk_repo "$UNK"
git -C "$UNK" remote add origin "https://gitlab.example.com/group/proj.git"
out=$( cd "$UNK" && bash "$HERE/host.sh" backend 2>&1 >/dev/null || true )
assert_contains H50 "unrecognised origin names the override knob" "AUTOPILOT_HOST_BACKEND" "$out"
# H50 — host.sh refuses an unknown subcommand with usage exit 64.
( cd "$GH_REPO_DIR" && bash "$HERE/host.sh" bogus-sub >/dev/null 2>&1 ); rc=$?
assert_eq H50 "unknown subcommand -> usage 64" "64" "$rc"

echo "== bitbucket.sh repo-coords / BB_HOST derivation (W345-BB) =="

# audit-w345 retro rec 1: Bitbucket DC deployments commonly publish a dedicated
# SSH endpoint host (`bb-ssh.example.com`) beside the HTTPS/REST host
# (`bb.example.com`); a BB_HOST derived from an SSH remote must strip the
# `-ssh` suffix or every REST call needs a manual workaround. Deterministic —
# repo-coords is offline (no HTTP).
coords() { ( cd "$1" && bash "$HERE/bitbucket.sh" repo-coords 2>/dev/null ); }

SSH_REPO="$SANDBOX/sshhost-repo"; mk_repo "$SSH_REPO"
git -C "$SSH_REPO" remote add origin "ssh://git@bb-ssh.example.com:7999/PROJ/myrepo.git"
out="$(coords "$SSH_REPO")"
assert_contains W345-BB1 "ssh origin: -ssh suffix stripped from BB_HOST" "BB_HOST=bb.example.com" "$out"
assert_contains W345-BB1 "ssh origin: project key parsed" "PROJECT_KEY=PROJ" "$out"
assert_contains W345-BB1 "ssh origin: repo slug parsed" "REPO_SLUG=myrepo" "$out"

SCP_REPO="$SANDBOX/scphost-repo"; mk_repo "$SCP_REPO"
git -C "$SCP_REPO" remote add origin "git@bb-ssh.example.com:PROJ/myrepo.git"
assert_contains W345-BB2 "scp-form origin: -ssh suffix stripped" "BB_HOST=bb.example.com" "$(coords "$SCP_REPO")"

assert_contains W345-BB3 "https origin: host verbatim (already the REST host)" "BB_HOST=bb.example.com" "$(coords "$API_REPO")"

HTTPS_SSHNAME="$SANDBOX/httpssshname-repo"; mk_repo "$HTTPS_SSHNAME"
git -C "$HTTPS_SSHNAME" remote add origin "https://bb-ssh.example.com/scm/PROJ/myrepo.git"
assert_contains W345-BB4 "https origin is NEVER stripped (strip is ssh-branch-only)" "BB_HOST=bb-ssh.example.com" "$(coords "$HTTPS_SSHNAME")"

out=$( cd "$SSH_REPO" && AUTOPILOT_BITBUCKET_HOST=rest.example.com bash "$HERE/bitbucket.sh" repo-coords 2>/dev/null )
assert_contains W345-BB5 "AUTOPILOT_BITBUCKET_HOST override wins over derivation" "BB_HOST=rest.example.com" "$out"

# W345-BB6 — dotless single-label intranet host (DNS-search-domain deployments):
# the whole host IS the first label, so the strip must fire without a trailing
# dot (`bitbucket-ssh` -> `bitbucket`). assert_eq on the extracted value — a
# substring check on "BB_HOST=bitbucket" would vacuously match the UNstripped
# "BB_HOST=bitbucket-ssh".
DOTLESS_REPO="$SANDBOX/dotless-repo"; mk_repo "$DOTLESS_REPO"
git -C "$DOTLESS_REPO" remote add origin "git@bitbucket-ssh:PROJ/myrepo.git"
out="$(coords "$DOTLESS_REPO")"
val=$(sed -n 's/^BB_HOST=//p' <<<"$out")
assert_eq W345-BB6 "dotless intranet host: -ssh suffix stripped" "bitbucket" "$val"

echo "== host.sh repo-list — ADR 0028 lazy-coords split + argv secrecy (HR01-HR04) =="

# Deterministic (no mock server): a curl PATH-shim answers the REAL bitbucket.sh
# bb_curl invocation shape (-o <body> / -w %{http_code}) and logs argv, so the
# enumeration path's transport shape is asserted offline.
HRSHIM="$SANDBOX/hrshim"; mkdir -p "$HRSHIM"
cat > "$HRSHIM/curl" <<'SHIMEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${CURL_ARGV_LOG:?}"
out=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  prev="$a"
done
[[ -n "$out" ]] && printf '{"isLastPage": true, "values": [{"slug": "argvrepo", "links": {"clone": [{"name": "ssh", "href": "ssh://git@bb.example.com/acme/argvrepo.git"}]}}]}' > "$out"
printf '200'
SHIMEOF
chmod +x "$HRSHIM/curl"

# HR01 — T03-analog for the enumeration path (ADR 0028): the token reaches curl
# via -H @file, NEVER argv — the exact hardening the retired host_repo_list.sh
# transport lacked (it interpolated `Bearer $TOKEN` into curl's command line).
hr_argv_log="$SANDBOX/hr_curl_argv.log"; : > "$hr_argv_log"
out=$( cd "$API_REPO" && PATH="$HRSHIM:$PATH" CURL_ARGV_LOG="$hr_argv_log" \
  AUTOPILOT_BITBUCKET_TOKEN="supersecret-enum-token-999" \
  bash "$HERE/host.sh" repo-list --org acme 2>/dev/null )
assert_eq HR01 "repo-list rides the hardened transport (TSV emitted)" \
  "$(printf 'argvrepo\tssh://git@bb.example.com/acme/argvrepo.git')" "$out"
hr_argv="$(cat "$hr_argv_log" 2>/dev/null || true)"
assert_not_contains HR01 "enumeration token never appears on curl argv" "supersecret-enum-token-999" "$hr_argv"
assert_contains HR01 "enumeration auth header passed via -H @file" "@/" "$hr_argv"

# HR02 — repo-list works OUTSIDE a repo when $AUTOPILOT_HOST_BACKEND steers the
# backend and a host source exists (the documented env-override path — the
# lazy-coords split: repo-list derives no PROJECT_KEY/REPO_SLUG).
HR_NOREPO="$SANDBOX/hr-norepo"; mkdir -p "$HR_NOREPO"
out=$( cd "$HR_NOREPO" && PATH="$HRSHIM:$PATH" CURL_ARGV_LOG="$hr_argv_log" \
  AUTOPILOT_HOST_BACKEND=BITBUCKET_DC AUTOPILOT_BITBUCKET_HOST=bb.example.com \
  AUTOPILOT_BITBUCKET_TOKEN="supersecret-enum-token-999" \
  bash "$HERE/host.sh" repo-list --org acme 2>/dev/null )
assert_contains HR02 "repo-list outside a repo (override + explicit host) works" "argvrepo" "$out"

# HR03 — outside a repo with NO host source at all, repo-list dies with a USEFUL
# LAST_STATE (host resolution is never skipped — ADR 0028 Decision 4).
err=$( cd "$HR_NOREPO" && AUTOPILOT_HOST_BACKEND=BITBUCKET_DC \
  bash "$HERE/host.sh" repo-list --org acme 2>&1 >/dev/null ); rc=$?
assert_eq HR03 "repo-list with no host source -> exit 1" "1" "$rc"
assert_contains HR03 "…classified no-host-source" "LAST_STATE=no-host-source" "$err"
assert_contains HR03 "…and names the AUTOPILOT_BITBUCKET_HOST knob" "AUTOPILOT_BITBUCKET_HOST" "$err"

# HR04 — lazy-coords REGRESSION PIN: every existing subcommand still dies
# no-origin outside a repo (the split must relax repo-list ONLY).
err=$( cd "$HR_NOREPO" && bash "$HERE/bitbucket.sh" pr-state --num 1 2>&1 >/dev/null ); rc=$?
assert_eq HR04 "bitbucket.sh pr-state outside a repo still exits 1" "1" "$rc"
assert_contains HR04 "bitbucket.sh existing subcommand still dies no-origin" "LAST_STATE=no-origin" "$err"
err=$( cd "$HR_NOREPO" && bash "$HERE/github.sh" pr-state --num 1 2>&1 >/dev/null ); rc=$?
assert_eq HR04 "github.sh pr-state outside a repo still exits 1" "1" "$rc"
assert_contains HR04 "github.sh existing subcommand still dies no-origin" "LAST_STATE=no-origin" "$err"

echo "== consistency lint (L1-L23) =="

if bash "$HERE/lint_consistency.sh" >/dev/null 2>&1; then
  pass LINT "lint_consistency.sh passes (23 rules)"
else
  fail LINT "lint_consistency.sh reports violations (run it directly for detail)"
fi

# Planted-lint red-tests. plant_and_expect_red copies the skill into a FRESH
# sandbox dir (no plant masks another), runs the given plant command with the
# copy dir appended, then expects the COPIED lint to red. Three plant
# mechanisms: printf-append, line-scrub (grep -v + mv), sed rewrite. Every
# pre-existing plant is preserved verbatim; each block is exactly one assertion.
PLANT_N=0
plant_and_expect_red() {  # <lint-id> <what> <plant-cmd...>
  local id="$1" what="$2"; shift 2
  PLANT_N=$((PLANT_N+1))
  local d="$SANDBOX/planted-lint-$PLANT_N"
  cp -R "$ROOT" "$d"
  "$@" "$d"
  if bash "$d/scripts/lint_consistency.sh" >/dev/null 2>&1; then
    fail "$id" "$id did NOT red $what"
  else
    pass "$id" "$id reds $what"
  fi
}
plant_append() {  # <rel-file> <line> <copy-dir>
  printf '\n%s\n' "$2" >> "$3/$1"
}
plant_scrub() {   # <rel-file> <grep-v-pattern> <copy-dir>
  grep -v "$2" "$3/$1" > "$3/$1.tmp"
  mv "$3/$1.tmp" "$3/$1"
}
plant_sed() {     # <rel-file> <sed-expr> <copy-dir>
  sed "$2" "$3/$1" > "$3/$1.tmp"
  mv "$3/$1.tmp" "$3/$1"
}
# L18b's plant: scrub ONLY the line-anchored allow-list entry
# (`  invalidated_seams: [...]`) and self-check the fixture — NO-GO rule 9's
# "`invalidated_seams: []` is a legal explicit declaration" prose must survive,
# the stale-template drift shape a whole-file scrub cannot distinguish from an
# entry drop (invalidated_seams pinned in planner schema AND allow-list —
# audit-w345 F3).
plant_l18b() {  # <copy-dir>
  plant_scrub references/plan-reviewer-projection.md '^[[:space:]]*invalidated_seams: \[' "$1"
  grep -q 'invalidated_seams' "$1/references/plan-reviewer-projection.md" \
    || fail L18 "L18b fixture self-check: prose mention should survive the entry-only scrub"
}

# L16 — the retired single-host framing (planted-drift pin).
plant_and_expect_red L16 "a planted 'source-of-truth host' framing" \
  plant_append references/loop-safety.md 'Bitbucket Data Center is the source-of-truth host.'
# L17 — a planted one-PR-per-Subtask framing (AV3-06 / AV3-16a acceptance).
plant_and_expect_red L17 "a planted 'one PR per Subtask' framing" \
  plant_append references/loop-safety.md 'Autopilot opens one PR per Subtask against the host.'
# L18 — an AP-3 allow-list that drops a pinned planner-schema field.
plant_and_expect_red L18 "an AP-3 allow-list that drops behavior_ids" \
  plant_scrub references/plan-reviewer-projection.md 'behavior_ids:'
# L18b — an allow-list ENTRY drop of the v3.1.0 seam-inventory field while
# prose mentions survive (see plant_l18b above).
plant_and_expect_red L18 "an AP-3 allow-list ENTRY drop of invalidated_seams (prose mention still present)" \
  plant_l18b
# L19 — a doc that reasserts the retired rolling-tracker-PR framing.
plant_and_expect_red L19 "a planted active 'rolling tracker PR' framing" \
  plant_append references/loop-safety.md 'Bookkeeping lands on the rolling tracker PR every fire.'
# L20 — a lifecycle.md whose Behavior-coverage marker was dropped.
plant_and_expect_red L20 "a dropped Behavior-coverage marker" \
  plant_scrub references/lifecycle.md 'autopilot:behavior-coverage'
# L21 — an implementer prompt that drops an anti-flakiness rule.
plant_and_expect_red L21 "a dropped anti-flakiness rule" \
  plant_scrub references/implementer-prompt.md 'Faked transport'
# L22 — drift between the two vendored ADR-0002 escalation POINTER blocks
# (since ADR 0025 the criterion text lives in the canonical
# references/escalation-criterion.md; the prompts carry an identical pointer —
# a reworded pointer in ONE prompt is the same silent-policy-fork drift).
plant_and_expect_red L22 "a drifted vendored escalation copy" \
  plant_sed references/implementer-prompt.md 's#references/escalation-criterion.md#references/REWORDED-DRIFT.md#'
# L23 — an integration validator that drops the as-built docs rule.
plant_and_expect_red L23 "a dropped as-built docs validator rule" \
  plant_scrub references/validator-prompts.md 'As-built docs are Story deliverables'

th_summary
