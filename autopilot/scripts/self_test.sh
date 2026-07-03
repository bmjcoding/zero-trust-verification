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

STATE = {"pr43_merge_calls": 0, "last_merge_strategy": None, "pr43_version": 3}

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
            self._send_json({"id": int(num), "state": "OPEN", "version": 3}); return
        if "/pull-requests?" in p:
            if "at=refs/heads/feature-x" in p:
                self._send_json({"values": [{"id": 42, "state": "OPEN"}]}); return
            self._send_json({"values": []}); return
        if "/settings/pull-requests" in p:
            self._send_json({"mergeConfig": {"strategies": [
                {"id": "squash", "enabled": True},
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

    def log_message(self, *a):
        pass

srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF

python3 "$SANDBOX/mock_server.py" "$SANDBOX/port" &
SERVER_PID=$!
for _ in $(seq 1 50); do [[ -s "$SANDBOX/port" ]] && break; sleep 0.1; done
PORT="$(cat "$SANDBOX/port")"
[[ -n "$PORT" ]] || { echo "mock server failed to start" >&2; exit 1; }
BASE="http://127.0.0.1:${PORT}"

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

echo "== bitbucket.sh (T01-T07) =="

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

out=$( IDENTITY_PROXY_URL="$BASE" IDENTITY_PROXY_PLATFORMS="bitbucketdc" bash "$HERE/sidecar_detect.sh" )
assert_contains T28 "healthy sidecar detected" "MODE=sidecar" "$out"
out=$( IDENTITY_PROXY_URL="$BASE/badok" bash "$HERE/sidecar_detect.sh" 2>/dev/null )
assert_eq T28 "200 without ok body is local mode" "MODE=local" "$out"
out=$( env -u IDENTITY_PROXY_URL bash "$HERE/sidecar_detect.sh" )
assert_eq T28 "no proxy url is local mode" "MODE=local" "$out"

# T38 — "not ok" must NOT pass the body check (substring matching did).
out=$( IDENTITY_PROXY_URL="$BASE/notok" bash "$HERE/sidecar_detect.sh" 2>/dev/null )
assert_eq T38 "'not ok' body is local mode" "MODE=local" "$out"

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

echo "== consistency lint (L1-L15) =="

if bash "$HERE/lint_consistency.sh" >/dev/null 2>&1; then
  pass LINT "lint_consistency.sh passes (15 rules)"
else
  fail LINT "lint_consistency.sh reports violations (run it directly for detail)"
fi

echo
echo "self_test: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 )) || exit 1
exit 0
