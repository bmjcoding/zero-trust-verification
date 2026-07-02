# Sidecar Contract v0


This document defines the contract between autopilot's REST-calling scripts (`bitbucket.sh`, `ci_check.sh`, `secret_get.sh`) and the workspace's optional identity-proxy sidecar.


The sidecar is OPTIONAL. When absent (`sidecar_detect.sh` outputs `MODE=local`), scripts fall back to the OS-native keychain (macOS Keychain, Linux libsecret) and then to environment variables. The whole resolver chain is documented at the bottom of this file.


This contract is versioned. v0 is the current minimum; future versions may add headers, error codes, or session-renewal semantics. Implementations MUST NOT reject unknown headers from the sidecar; they MUST surface unknown error codes as opaque failures.


## Environment variables (sidecar mode)


When `sidecar_detect.sh` reports `MODE=sidecar`, the following env vars are guaranteed to be set in the workspace container:


| Variable | Purpose | Example |
|---|---|---|
| `IDENTITY_PROXY_URL` | Base URL of the sidecar. Always reachable from the workspace. Always HTTPS in production; may be HTTP on `localhost` in dev. | `https://identity-proxy.workspace.svc:8443` |
| `IDENTITY_PROXY_PLATFORMS` | Comma-separated list of platforms the sidecar can proxy. Scripts MUST check this before issuing a request. | `bitbucketdc,jira,github` |
| `WORKSPACE_SESSION_ID` | Opaque session identifier the sidecar uses to map requests back to the authenticated user (OBO). Treat as a credential — do not log. | `ws-7a3f2e1d9c8b4f56` |
| `WORKSPACE_USER_SUB` | User's stable subject identifier (NOT a credential — safe to log). Used by scripts when they need to construct user-scoped audit trails. | `u_42198765` |


Absence of `IDENTITY_PROXY_URL` is the canonical signal that sidecar mode is unavailable. `sidecar_detect.sh` checks this and additionally pings `${IDENTITY_PROXY_URL}/healthz` to confirm reachability.


## URL shape


All sidecar requests follow this shape:


```
{IDENTITY_PROXY_URL}/{platform}/{upstream-path}
```


Examples:
- `${IDENTITY_PROXY_URL}/bitbucketdc/rest/api/1.0/projects/PROJ/repos/repo/pull-requests`
- `${IDENTITY_PROXY_URL}/bitbucketdc/rest/build-status/1.0/commits/<sha>`
- `${IDENTITY_PROXY_URL}/jira/rest/api/3/issue/PROJ-1234`


Scripts MUST NOT URL-encode the `{platform}` segment. They MUST URL-encode path components inside `{upstream-path}` per RFC 3986.


## Authentication


The sidecar terminates the user's credentials. Scripts pass NO `Authorization` header and NO `Cookie` header to the sidecar. The sidecar injects the appropriate upstream auth (OAuth on-behalf-of, service-account token, etc.) based on `WORKSPACE_SESSION_ID` (passed via the workspace container's TLS-terminated socket; the sidecar reads it from the connection, not from the request).


**This means the upstream token NEVER enters the workspace process tree.** It is held by the sidecar process and only exists in the sidecar's memory. This is the property that makes sidecar mode strictly more secure than keychain mode: in keychain mode the token is read into a subshell `$(...)` to construct curl headers, which means it briefly exists in the workspace process memory. In sidecar mode it never does.


### TLS termination


The sidecar terminates TLS for the upstream (bitbucket-dc.example.internal) at its own boundary. Scripts MUST set `--cacert ${IDENTITY_PROXY_CA:-<system default>}` when calling the sidecar; the sidecar's self-signed CA bundle (if any) is mounted into the workspace at a path advertised via `IDENTITY_PROXY_CA`.


## Session scoping


Sidecar sessions are scoped to the lifetime of the workspace container. There is no session-renewal API in v0; if the workspace container restarts, all in-flight sidecar sessions are invalidated. Scripts MUST surface `407 sidecar misconfigured` as `[BLOCKED: sidecar-session-invalid]` (impl) and exit; the user reconnects the workspace to get a fresh session.


## Error codes


| Sidecar HTTP status | Meaning | Script behavior |
|---|---|---|
| `200..299` | Success. Body is the upstream's response verbatim. | Forward to caller. |
| `401 unauthorized` | User's upstream credentials expired or revoked. Sidecar attempted re-auth and failed. | Surface as `[BLOCKED: bitbucket-token-missing]` (impl). The wider system (workspace UI) will prompt re-auth on the user's next interactive turn. |
| `403 forbidden` | User authenticated but lacks scope for this operation. | Surface as `[BLOCKED: bitbucket-scope-denied]` (impl) with the operation name. |
| `407 sidecar misconfigured` | Sidecar's own configuration is broken (missing platform mapping, expired service cert, etc.). NOT a user fault. | Surface as `[BLOCKED: sidecar-session-invalid]` (impl) and CronDelete. Operator triage required. |
| `502 upstream` | Upstream (Bitbucket DC) returned 5xx or timed out. Sidecar gave up after its own retry policy. | Retry once with backoff; on second 502 surface as transient failure (NOT a BLOCKED — the orchestrator's per-script retry logic decides). |
| `429 rate-limited` | Sidecar or upstream rate-limit hit. Body includes `Retry-After`. | Honor `Retry-After`; max 1 retry per script invocation. |
| `4xx other` | Upstream returned a 4xx that the sidecar passed through verbatim. | Surface as the original Bitbucket error code in the BLOCKED reason. |


Scripts MUST NOT log response bodies for `401`, `403`, or `407` — those may contain token-shaped error strings.


## Resolver chain (used by `secret_get.sh`)


Scripts that need a token follow this order:


1. **Sidecar mode (preferred)** — if `sidecar_detect.sh` returns `MODE=sidecar`, scripts call the sidecar directly. `secret_get.sh` is not invoked in this path; the token never exists in the workspace process tree.
2. **OS-native keychain (local-dev preferred)** — on macOS: `security find-generic-password -s autopilot-bitbucket -a $USER -w 2>/dev/null`. On Linux with libsecret: `secret-tool lookup service autopilot-bitbucket account $USER`. The token is read into a subshell `$(...)` and embedded in the `-H` header argument of a single `curl` call; no intermediate variables, no echo, no log. The Claude Code automode classifier permits the keychain read because it's invoked from a script (not from Claude's tool calls) and the token never enters Claude's input or output.
3. **Environment variable (CI / Windows fallback)** — if `BITBUCKET_TOKEN` is set in the workspace environment, use it. This is the only fallback for Windows VDIs without libsecret support; users are expected to source a `.env` file at workspace start.
4. **No token available** — surface as `[BLOCKED: bitbucket-token-missing]` (impl). The user runs `bash scripts/secret_set.sh` once to populate the keychain entry.


At no point in the chain is the token ever:
- Passed as a positional argument to a script (visible in `ps`)
- Written to a file outside `~/.cache/autopilot/` (and then only encrypted blobs that the keychain owns)
- Echoed to stdout or stderr
- Logged in `set -x` trace output (scripts MUST disable `-x` around the resolver call)


## Implementation checklist for scripts


Any script that talks to Bitbucket must:


1. Run `MODE=$(bash ${SKILL_DIR}/scripts/sidecar_detect.sh)` first.
2. Branch on `$MODE`:
   - `MODE=sidecar`: construct sidecar URL; call with no Authorization header.
   - `MODE=local`: call `secret_get.sh bitbucket-token` and embed in a single `curl -H` argument via subshell.
3. Set `set +x` immediately before any curl call that includes credentials.
4. Treat any HTTP status code documented above according to the table.
5. Never echo response headers; only parse and forward the body.


## Probe budget under sidecar mode

> Added v2.3.0 (AP-23). Applies to `scripts/repo_shape_probe.sh` (G1.5) only.

The repo-shape probe is a one-shot capability discovery that runs at G1.5 on
the first drain against a new runbook, or on any drain invoked with
`--reprobe`. Under sidecar mode the probe consumes upstream API budget in a
way that differs from steady-state drain traffic: probe pushes to short-lived
temp branches (`autopilot/probe-force-push-<PID>`, `autopilot/probe-jira-hook-<PID>`)
can trigger PR-webhook chains, JIRA-hook validations, and branch-permission
rejection paths that the sidecar's default rate-limit accounting is not tuned
for. To prevent the probe from exhausting an operator's sidecar quota for the
rest of the drain, the following budget contract applies:

| Probe operation                     | Max requests | Reset window            | Failure behavior                      |
|-------------------------------------|--------------|-------------------------|---------------------------------------|
| Force-push probe (push + rollback)  | 4            | Per drain               | `FORCE_PUSH_ALLOWED=unknown`, no flip |
| JIRA-hook probe (push + rollback)   | 4            | Per drain               | `JIRA_HOOK_ENFORCED=unknown`, no flip |
| Trunk / CI-presence GETs            | 12           | Per drain               | `CI_PRESENT=unknown`, `TRUNK=main`    |
| Total probe upstream calls          | 24           | Per drain               | Abort probe, seed all values `unknown`|

On a 429 (rate-limited) response during any probe operation, the probe MUST:

1. Honor the sidecar's `Retry-After` header (max 1 retry per operation, same
   as the general error-code table).
2. If the second attempt also 429s, mark that specific value `unknown` and
   proceed to the next probe operation — do NOT retry the whole probe.
3. Record the 429 in the runbook's `Repo constraints (detected)` block under
   `notes:` with an `rl429` tag and the timestamp.

On a 407 (sidecar misconfigured) during any probe operation, the probe MUST
abort immediately, seed all four values as `unknown`, and surface
`[BLOCKED: sidecar-session-invalid]` (impl) exactly as the general contract
requires. No auto-seed flag flip happens on a 407 abort.

Operators MAY skip the probe entirely by passing `--no-probe`; the runbook is
then assumed to carry hand-authored `Repo constraints (detected)` values (or
none, in which case defaults apply per SKILL.md override-scoping).

Under `MODE=local` (no sidecar) the budget still applies as a self-imposed
guardrail against upstream rate-limits, but the 407 path is not reachable
— upstream 429s route to the same `unknown` seeding as above.

## What's NOT in v0


Deliberately omitted from this version:


- Session renewal API (scripts handle 407 as terminal).
- Multi-platform token bundling (each platform is a separate sidecar call).
- WebSocket or SSE channels (sidecar is request/response only).
- Sidecar-side audit log query (workspace doesn't read sidecar logs).
- Encryption-at-rest for `WORKSPACE_SESSION_ID` (it's already short-lived and treated as a credential by callers).


These can be added in v1+ without breaking v0 callers — every v1 addition will be opt-in via an additional env var or header.
