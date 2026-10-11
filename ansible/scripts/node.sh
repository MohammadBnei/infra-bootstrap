#!/usr/bin/env bash
# Reach any ukubi machine by its one name (ansible/playbooks/vars/bnei-lan-records.yml).
#
#   node.sh [-l user] <name> [command...]
#       NetBird SSH as the netbird-agent identity (ADR-0055 amendment). No
#       browser, no host key file, works off-LAN; the caller must be a NetBird
#       peer in platform-admins (today: the operator's laptop). Default user root.
#   node.sh --lan <name> [command...]
#       Fallback when NetBird or authentik is down: LAN address, user and key
#       from the ansible inventories; Infisical-held keys go to a 0600 temp file.
#   node.sh --token
#       Print a fresh NetBird SSH JWT (for another SSH client). Treat as a secret.
#
# How the mesh path authenticates: NetBird's SSH server takes, as the SSH
# password, a JWT from its embedded Dex with aud netbird-cli and iat < 600s.
#   1. authentik client_credentials, username netbird-agent + its app password
#      (NETBIRD_AGENT_APP_PASSWORD) -> authentik id_token;
#   2. RFC 8693 token exchange at Dex (public client netbird-cli) -> Dex JWT
#      whose sub is the agent's NetBird user id.
# The JWT is cached in a 0600 file for 540s, so a loop of calls mints once.
#
# hermesagent has no inbound SSH: node.sh ex-laptop pct exec 101 -- <command>
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INF=(--projectId=8a3fa54f-be22-488a-bf51-55158f65c0f2 --env=dev --domain=https://infisical.bnei.dev --plain)
# Dex connector id of the authentik upstream: field 2 of any NetBird user id
# that came through authentik (base64url protobuf). Changes only if the
# identity provider is re-created in the dashboard.
DEX_CONNECTOR_ID="${NETBIRD_DEX_CONNECTOR_ID:-db5q6h0g15ss73edt1eg}"
CACHE="${TMPDIR:-/tmp}/node-sh-netbird-jwt"

secret() { infisical secrets get "$1" "${INF[@]}" 2>/dev/null; }

mint() {
  if [ -s "$CACHE" ] && [ $(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE") )) -lt 540 ]; then
    cat "$CACHE"; return
  fi
  local client_id id_token jwt
  client_id="$(secret NETBIRD_OIDC_CLIENT_ID)"
  id_token="$(secret NETBIRD_AGENT_APP_PASSWORD | curl -sf https://authentik.bnei.dev/application/o/token/ \
    -d grant_type=client_credentials -d "client_id=$client_id" -d username=netbird-agent \
    --data-urlencode password@- -d 'scope=openid profile email' | jq -r '.id_token // empty')"
  [ -n "$id_token" ] || { echo "authentik refused the netbird-agent client_credentials grant" >&2; exit 1; }
  jwt="$(printf '%s' "$id_token" | curl -sf https://netbird.bnei.dev/oauth2/token \
    -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange -d client_id=netbird-cli \
    -d "connector_id=$DEX_CONNECTOR_ID" --data-urlencode subject_token@- \
    -d subject_token_type=urn:ietf:params:oauth:token-type:id_token \
    -d 'scope=openid profile email' | jq -r '.access_token // empty')"
  [ -n "$jwt" ] || { echo "Dex refused the token exchange" >&2; exit 1; }
  (umask 177; printf '%s' "$jwt" >"$CACHE")
  printf '%s' "$jwt"
}

case "${1:-}" in
  --token) mint; echo; exit 0 ;;
  --lan) shift; lan=1 ;;
  *) lan=0 ;;
esac
user=root
[ "${1:-}" = -l ] && { user="$2"; shift 2; }
name="${1:?usage: node.sh [--lan] [-l user] <name> [command...] | node.sh --token}"
shift

if [ "$lan" = 0 ]; then
  mint >/dev/null
  askpass="$(mktemp)"
  trap 'rm -f "$askpass"' EXIT
  printf '#!/bin/sh\ncat %q\n' "$CACHE" >"$askpass"
  chmod 700 "$askpass"
  # -F none: skip NetBird's managed ssh_config, whose `netbird ssh proxy`
  # wants a browser. Host keys are not pinned, as in that managed config:
  # the WireGuard tunnel already authenticates the peer.
  SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force ssh -F none \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout=15 "$user@$name.bnei.mesh" "$@"
  exit
fi

INV=(-i "$REPO/ansible/inventories/mesh/hosts.yml"
     -i "$REPO/ansible/inventories/garage/hosts.yml"
     -i "$REPO/ansible/inventories/nfs/hosts.yml")
vars="$(ansible-inventory "${INV[@]}" --host "$name" 2>/dev/null)" || {
  echo "$name: not in the mesh, garage or nfs inventory" >&2; exit 1; }
host="$(jq -r '.ansible_host' <<<"$vars")"
luser="$(jq -r '.ansible_user // "root"' <<<"$vars")"
ksecret="$(jq -r '.node_ssh_key_secret // empty' <<<"$vars")"
key="$(jq -r '.ansible_ssh_private_key_file // empty' <<<"$vars")"
if [ -n "$ksecret" ]; then
  key="$(mktemp)"
  trap 'rm -f "$key"' EXIT
  (umask 177; secret "$ksecret" >"$key")
fi
key="${key/#\~/$HOME}"
# By IP on purpose: NetBird's managed ssh_config sends bare peer names
# through `netbird ssh proxy`, which wants a browser login.
ssh -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 "$luser@$host" "$@"
