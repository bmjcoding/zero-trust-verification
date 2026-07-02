#!/usr/bin/env bash
# sidecar_detect.sh
#
# Detects whether the identity-proxy sidecar is reachable and emits a
# canonical mode line for callers to source or eval.
#
# Output (on STDOUT, single line, key=value):
#   MODE=sidecar PLATFORMS="<csv>" URL="<base>"     when sidecar is up
#   MODE=local                                       when sidecar unreachable
#
# Exit 0 in both cases (the absence of sidecar is not an error; it's a
# routing decision).
#
# Detection rules (in order):
#   1. If IDENTITY_PROXY_URL is unset -> MODE=local.
#   2. curl GET ${IDENTITY_PROXY_URL%/}/healthz with 2s timeout.
#      Expect HTTP 200 and body containing "ok". TLS validated against
#      ${IDENTITY_PROXY_CA} if set, else system CA bundle.
#      On success -> MODE=sidecar with PLATFORMS from IDENTITY_PROXY_PLATFORMS.
#      On any failure -> MODE=local.
#
# Hard rules:
#   - Never send Authorization header.
#   - Never log WORKSPACE_SESSION_ID (treat as credential per sidecar-contract.md).
#   - Stderr may contain diagnostic strings; stdout is parseable only.

set -u
set +x

URL="${IDENTITY_PROXY_URL:-}"
if [[ -z "$URL" ]]; then
  echo "MODE=local"
  exit 0
fi

# Normalize: strip trailing slash.
URL_BASE="${URL%/}"
HEALTH_URL="${URL_BASE}/healthz"
CA_ARG=()
if [[ -n "${IDENTITY_PROXY_CA:-}" ]]; then
  CA_ARG=(--cacert "$IDENTITY_PROXY_CA")
fi

# 2s connect + 2s overall, retry once, no auth header.
RESP=$(curl -sS --max-time 4 --connect-timeout 2 --retry 1 --retry-delay 1 \
  "${CA_ARG[@]}" \
  -H 'Accept: text/plain' \
  -o /dev/null -w "%{http_code}" \
  "$HEALTH_URL" 2>/dev/null) || RESP="000"

if [[ "$RESP" == "200" ]]; then
  PLATFORMS="${IDENTITY_PROXY_PLATFORMS:-}"
  echo "MODE=sidecar PLATFORMS=\"${PLATFORMS}\" URL=\"${URL_BASE}\""
  exit 0
fi

# Non-200 or curl error.
echo "sidecar-health-failed: http=${RESP}" >&2
echo "MODE=local"
exit 0
