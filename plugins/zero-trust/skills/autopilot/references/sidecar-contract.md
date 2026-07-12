# Sidecar Contract v0

The contract between autopilot's REST-calling scripts (`bitbucket.sh`, `ci_check.sh`, `secret_get.sh`) and the workspace's optional identity-proxy sidecar. The sidecar is OPTIONAL: when absent (`sidecar_detect.sh` outputs `MODE=local`), scripts fall back to the OS-native keychain, then environment variables (the resolver chain at the bottom).

Versioned: v0 is the current minimum. Implementations MUST NOT reject unknown headers from the sidecar and MUST surface unknown error codes as opaque failures — so v1 additions can't break v0 callers.

## Environment variables (sidecar mode)

Guaranteed set in the workspace container when `MODE=sidecar`:

| Variable | Purpose | Example |
|---|---|---|
| `IDENTITY_PROXY_URL` | Base URL of the sidecar. Always HTTPS in production; may be HTTP on `localhost` in dev. | `https://identity-proxy.workspace.svc:8443` |
| `IDENTITY_PROXY_PLATFORMS` | Comma-separated platform ids the sidecar can proxy; scripts MUST check it before issuing a request. Canonical Bitbucket DC id is `bitbucketdc`; consumers also accept legacy `bitbucket` and use the matched id as the URL path segment. | `bitbucketdc,jira,github` |
| `WORKSPACE_SESSION_ID` | Opaque session id mapping requests to the authenticated user (OBO). Treat as a credential — never log. | `ws-7a3f2e1d9c8b4f56` |
| `WORKSPACE_USER_SUB` | User's stable subject id (NOT a credential — safe to log); for user-scoped audit trails. | `u_42198765` |

Absence of `IDENTITY_PROXY_URL` is the canonical sidecar-unavailable signal. `sidecar_detect.sh` additionally pings `${IDENTITY_PROXY_URL}/healthz`: implementations MUST return HTTP 200 with a body containing `ok` — a 200 with a different body is treated as sidecar-unavailable (local fallback).

## URL shape

```
{IDENTITY_PROXY_URL}/{platform}/{upstream-path}
```

E.g. `${IDENTITY_PROXY_URL}/bitbucketdc/rest/api/1.0/projects/PROJ/repos/repo/pull-requests`, `${IDENTITY_PROXY_URL}/bitbucketdc/rest/build-status/1.0/commits/<sha>`. Never URL-encode the `{platform}` segment; URL-encode path components inside `{upstream-path}` per RFC 3986.

## Authentication

The sidecar terminates the user's credentials: scripts pass NO `Authorization` and NO `Cookie` header. The sidecar injects upstream auth based on `WORKSPACE_SESSION_ID` (read from the TLS-terminated connection, not the request). **The upstream token never enters the workspace process tree** — which makes sidecar mode strictly more secure than keychain mode, where the token is read into a subshell and written to a 0600 temp header file consumed via curl's `-H @file` (never curl argv, which is world-readable via /proc/*/cmdline), briefly existing in process memory and on tmpfs.

**TLS termination:** the sidecar terminates TLS for the upstream host at its own boundary. Scripts MUST set `--cacert ${IDENTITY_PROXY_CA:-<system default>}`; a self-signed CA bundle is mounted at the path advertised via `IDENTITY_PROXY_CA`.

**Session scoping:** sessions live as long as the workspace container; there is no renewal API in v0. On container restart all sessions are invalid — scripts surface `407` as `[BLOCKED: sidecar-session-invalid]` (impl) and exit; the user reconnects the workspace.

## Error codes

| Sidecar HTTP status | Meaning | Script behavior |
|---|---|---|
| `200..299` | Success; body is the upstream response verbatim. | Forward to caller. |
| `401 unauthorized` | Upstream credentials expired/revoked; sidecar re-auth failed. | `[BLOCKED: bitbucket-token-missing]` (impl); the workspace UI prompts re-auth on the next interactive turn. |
| `403 forbidden` | Authenticated but lacks scope. | `[BLOCKED: bitbucket-scope-denied]` (impl) with the operation name. |
| `407 sidecar misconfigured` | Sidecar's own config broken (missing platform mapping, expired service cert). NOT a user fault. | `[BLOCKED: sidecar-session-invalid]` (impl) and CronDelete; operator triage. |
| `502 upstream` | Upstream 5xx/timeout after the sidecar's own retries. | Retry once with backoff; second 502 → transient failure (NOT a BLOCKED — per-script retry logic decides). |
| `429 rate-limited` | Rate limit; body includes `Retry-After`. | Honor `Retry-After`; max 1 retry per invocation. |
| `4xx other` | Upstream 4xx passed through verbatim. | Surface the original error code in the BLOCKED reason. |

Never log response bodies for `401`, `403`, or `407` — they may contain token-shaped error strings.

## Resolver chain (used by `secret_get.sh`)

1. **Sidecar (preferred)** — `MODE=sidecar`: scripts call the sidecar directly; `secret_get.sh` is not invoked; the token never exists in the workspace process tree.
2. **OS-native keychain (local-dev)** — macOS `security find-generic-password -s autopilot-bitbucket -w`; Linux `secret-tool lookup service autopilot-bitbucket`. Lookups are scoped by service name only (not account), so entries created by other tools under the conventional names stay resolvable — see the candidate list in `secret_get.sh`. The token is read into a subshell, written to a 0600 temp file as a complete `Authorization:` header line, passed to a single `curl` via `-H @file` (deleted immediately after) — no exported variables, no argv exposure, no echo, no log. The automode classifier permits the keychain read because it's invoked from a script and the token never enters Claude's input or output.
3. **Environment variable (CI / Windows fallback)** — `AUTOPILOT_BITBUCKET_TOKEN` (the `AUTOPILOT_<SERVICE>_TOKEN` pattern; the bare `BITBUCKET_TOKEN` name is NOT read). The only fallback for platforms without a supported keychain (e.g. Windows VDIs); reachable on every platform before the resolver gives up.
4. **No token** — `[BLOCKED: bitbucket-token-missing]` (impl); the user runs `bash scripts/secret_set.sh` once.

At no point is the token: a positional script argument (visible in `ps`); written to a file outside `~/.cache/autopilot/` (and then only keychain-owned encrypted blobs); echoed to stdout/stderr; or visible in `set -x` traces (scripts disable `-x` around the resolver call).

## Implementation checklist for scripts

1. `MODE=$(bash ${SKILL_DIR}/scripts/sidecar_detect.sh)` first.
2. `MODE=sidecar` → sidecar URL, no Authorization header, export `AUTOPILOT_SIDECAR_MODE=1` for children. `MODE=local` → `secret_get.sh bitbucket` (the service name) and a 0600 `-H @file`.
3. `set +x` immediately before any credentialed curl.
4. Handle every HTTP status per the table.
5. Never echo response headers; parse and forward the body only.

## Probe budget under sidecar mode

Applies to `scripts/repo_shape_probe.sh` (G1.5) only. The probe is a one-shot capability discovery; its upstream exposure is bounded BY CONSTRUCTION — the script has no loops. A full probe performs at most:

| Operation | Transport | Count |
|---|---|---|
| Trunk detection (`ls-remote`, symref) | git | ≤ 2 |
| CI check: trunk-tip `build-status` GET | REST (via `bitbucket.sh`) | ≤ 1 |
| CI check: tree listing | git (local) + ≤1 fetch | ≤ 1 |
| Force-push probe (fetch, push, force-push) | git | ≤ 3 |
| JIRA-hook probe (push) | git | ≤ 1 |
| Temp-branch cleanup (delete pushes) | git | ≤ 2 |

The single sidecar-mediated call is the `build-status` GET, inheriting `bitbucket.sh` error handling (429/407 per the table). If it fails, `CI_PRESENT` falls back to manifest inspection or `unknown` — a probe failure never auto-flips a flag (`unknown` never seeds). Probe pushes to `autopilot/probe-*-<PID>` temp branches can still trigger server-side webhooks and hook validations; operators with sensitive receive-hooks review `--dry-run` first or skip with `--no-probe` (the runbook then carries hand-authored `Repo constraints (detected)` values, or defaults).

## What's NOT in v0

Deliberately omitted (addable in v1+ behind opt-in env vars/headers): session renewal (407 is terminal); multi-platform token bundling; WebSocket/SSE channels; sidecar-side audit-log query; encryption-at-rest for `WORKSPACE_SESSION_ID` (already short-lived and credential-handled).
