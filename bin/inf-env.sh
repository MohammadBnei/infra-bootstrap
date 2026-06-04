#!/usr/bin/env bash
# inf-env.sh — source this to set INFISICAL_TOKEN and INFISICAL_API_URL in
# your current shell. Re-source any time the token expires (it's a short-lived
# JWT, usually ~1h).
#
#   $ source ~/.hermes/cache/inf-env.sh
#   $ infisical secrets get MY_SECRET --projectId=... --env=...
#   $ infisical export --projectId=... --env=prod --format=json
#
# Reads client_id and client_secret from disk (NOT command line) so the
# secret never appears in `ps` or shell history.
set -euo pipefail

CID_FILE=${INFISICAL_CLIENT_ID_FILE:-/home/hermes/.hermes/cache/inf-cid}
CSEC_FILE=${INFISICAL_CLIENT_SECRET_FILE:-/home/hermes/.hermes/cache/inf-csec}
DOMAIN=${INFISICAL_DOMAIN:-https://infisical.bnei.dev}

: "${INFISICAL_TOKEN:=$(/usr/bin/infisical login \
  --method=universal-auth \
  --client-id="$(cat "$CID_FILE")" \
  --client-secret="$(cat "$CSEC_FILE")" \
  --domain="$DOMAIN" \
  --silent --plain)}"

export INFISICAL_TOKEN
export INFISICAL_API_URL="$DOMAIN/api"
