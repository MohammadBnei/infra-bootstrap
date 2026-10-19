#!/bin/sh
# agent-vault-bootstrap.sh [--rotate] — ADR-0061 Decision 5. Run once, by the
# operator, after the agent-vault Application first syncs.
#
#   1. If Infisical's AGENT_VAULT_TOKEN still authenticates and --rotate is
#      absent: done, nothing changes (safe to re-run any time).
#   2. Else: registers the owner if the instance is uninitialized (first user
#      = owner, no verification without SMTP), logs in as it, and rotates — or
#      creates, instance role `member` — the `fleet-provisioner` agent's token.
#   3. Writes that token to Infisical agent-fleet-nygh /agent-vault
#      AGENT_VAULT_TOKEN, which agent-fleet's provisioner mounts.
#
# --rotate is an outage: the old token dies at once, and the provisioner is
# locked out until Infisical (60s) + kubelet (<=60s) deliver the new one. If
# step 3 fails after a rotation, re-run with --rotate.
#
# Never prints a credential, and none goes on the operator machine's argv: the
# inner script and the current token ride the pod's stdin, the new token comes
# back on stdout into a 0600 file that `infisical secrets set --file` reads.
# Inside the vault container the current token is on busybox wget's argv —
# the one process tree that already holds every credential (accepted, ADR-0061).
#
# Overrides, for testing against a throwaway copy: AV_NAMESPACE (agent-vault),
# AV_INFISICAL_PATH (/agent-vault), AV_NODE (k9s-dashboard).
set -eu
ROTATE=0
[ "${1:-}" = --rotate ] && ROTATE=1
NS="${AV_NAMESPACE:-agent-vault}"
INF="--projectId=ae771c2c-5115-452a-8f1c-1e03fa0e2b9a --env=dev --path=${AV_INFISICAL_PATH:-/agent-vault} --domain https://infisical.bnei.dev --silent"
NODE="$(cd "$(dirname "$0")/../../ansible/scripts" && pwd)/node.sh"
umask 077
F=$(mktemp)
trap 'rm -f "$F" "$F.env"' EXIT

# shellcheck disable=SC2086 # $INF is a flag list on purpose
CUR=$(infisical secrets get AGENT_VAULT_TOKEN $INF --plain 2>/dev/null || true)
# Only a well-formed agent token is passed on: the pod parses CUR= as shell.
case "$CUR" in
  *[!A-Za-z0-9_-]*) CUR= ;;
  av_agt_?*) ;;
  *) CUR= ;;
esac

{
  printf 'CUR=%s\nROT=%s\n' "$CUR" "$ROTATE"
  cat <<'EOF'
set -eu
export HOME="$(mktemp -d)"   # the CLI's session file, off the PVC
trap 'rm -rf "$HOME"' EXIT
A=http://127.0.0.1:14321
if [ "$ROT" = 0 ] && [ -n "$CUR" ] && wget -qO- --header "Authorization: Bearer $CUR" "$A/v1/vaults" >/dev/null 2>&1; then
  exit 0
fi
if wget -qO- "$A/v1/status" | grep -q '"initialized":false'; then
  printf %s "$AGENT_VAULT_OWNER_PASSWORD" | agent-vault auth register --address "$A" --email "$AGENT_VAULT_OWNER_EMAIL" --password-stdin >/dev/null
fi
# register does not leave a session behind; login always does.
printf %s "$AGENT_VAULT_OWNER_PASSWORD" | agent-vault auth login --address "$A" --email "$AGENT_VAULT_OWNER_EMAIL" --password-stdin >/dev/null
agent-vault agent rotate fleet-provisioner --token-only 2>/dev/null \
  || agent-vault agent create fleet-provisioner --role member --token-only
EOF
} | "$NODE" "${AV_NODE:-k9s-dashboard}" "kubectl -n $NS exec -i deploy/agent-vault -- sh -s" >"$F"

[ -s "$F" ] || { echo "agent-vault-bootstrap: current token works, nothing changed (--rotate to force)"; exit 0; }
case "$(head -c 7 "$F")" in
  av_agt_) ;;
  *) echo "agent-vault-bootstrap: no agent token returned" >&2; exit 1 ;;
esac
printf 'AGENT_VAULT_TOKEN=%s\n' "$(cat "$F")" >"$F.env"
# shellcheck disable=SC2086
infisical secrets set --file="$F.env" $INF >/dev/null
echo "agent-vault-bootstrap: AGENT_VAULT_TOKEN written"
