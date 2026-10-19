#!/bin/sh
# agent-vault-bootstrap.sh [--rotate] — ADR-0061 Decision 5. Run once, by the
# operator, right after the agent-vault Application first syncs.
#
#   1. If Infisical's AGENT_VAULT_TOKEN still authenticates and --rotate is
#      absent: done, nothing changes.
#   2. Else: registers the owner if the instance is uninitialized (first user
#      = owner, no verification without SMTP), logs in as it, and rotates — or
#      creates, instance role `member` — the `fleet-provisioner` agent's token.
#   3. Writes that token to Infisical agent-fleet-nygh /agent-vault
#      AGENT_VAULT_TOKEN, which agent-fleet's provisioner mounts.
#
# Fails closed: an Infisical read error, or any vault answer other than 200 /
# 401 / 403 to the token check, aborts before anything rotates. Only a missing
# key or a refused token leads to step 2.
#
# --rotate is an outage: the old token dies at once, and the provisioner is
# locked out until Infisical (60s) + kubelet (<=60s) deliver the new one. If
# step 3 fails after a rotation, the new token is kept in a 0600 file and the
# retry command is printed: retry the write, do not rotate again.
#
# Never prints a credential, and none goes on the operator machine's argv: the
# inner script, the current token and the owner password ride the pod's stdin;
# the new token comes back on stdout into a 0600 file that `infisical secrets
# set --file` reads. The owner password lives in /agent-vault-owner, a folder
# no InfisicalSecret syncs, so it is in no pod's env. Inside the vault
# container the current and session tokens are on busybox wget's argv — the
# one process tree that already holds every credential (accepted, ADR-0061).
#
# Overrides, for testing (test-agent-vault-bootstrap.sh): AV_NAMESPACE
# (agent-vault), AV_INFISICAL_PATH (/agent-vault), AV_OWNER_PATH
# (/agent-vault-owner), AV_NODE (k9s-dashboard), AV_NODE_SH (ansible's node.sh).
set -eu
ROTATE=0
[ "${1:-}" = --rotate ] && ROTATE=1
NS="${AV_NAMESPACE:-agent-vault}"
INF="--projectId=ae771c2c-5115-452a-8f1c-1e03fa0e2b9a --env=dev --domain https://infisical.bnei.dev --silent"
TOK_PATH="--path=${AV_INFISICAL_PATH:-/agent-vault}"
NODE="${AV_NODE_SH:-$(cd "$(dirname "$0")/../../ansible/scripts" && pwd)/node.sh}"
umask 077
F=$(mktemp)
KEEP=
trap '[ -n "$KEEP" ] || rm -f "$F" "$F.env"' EXIT

# Only these characters are passed on: the pod parses CUR=/OWN= as shell.
safe() { case "$1" in "" | *[!A-Za-z0-9_-]*) return 1 ;; esac; }
is_token() { case "$1" in av_agt_?*) safe "$1" ;; *) return 1 ;; esac; }

# A missing key is exit 0 with no output; any request failure is non-zero and
# aborts here (set -e), so a broken login never reads as "no token stored".
# shellcheck disable=SC2086 # $INF is a flag list on purpose
CUR=$(infisical secrets get AGENT_VAULT_TOKEN $INF "$TOK_PATH" --plain)
is_token "$CUR" || CUR=
# shellcheck disable=SC2086
OWN=$(infisical secrets get AGENT_VAULT_OWNER_PASSWORD $INF "--path=${AV_OWNER_PATH:-/agent-vault-owner}" --plain)
safe "$OWN" || { echo "agent-vault-bootstrap: AGENT_VAULT_OWNER_PASSWORD missing or not [A-Za-z0-9_-]" >&2; exit 1; }

{
  printf 'CUR=%s\nROT=%s\nOWN=%s\n' "$CUR" "$ROTATE" "$OWN"
  cat <<'EOF'
set -eu
A=http://127.0.0.1:14321
E=agent-vault-owner@bnei.dev
export HOME="$(mktemp -d)"   # the CLI's session file, off the PVC
S="$HOME/.agent-vault/session.json"
tok() { sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$S" 2>/dev/null || true; }
# Revoke the owner session server-side, not just the local file.
bye() {
  T=$(tok)
  [ -z "$T" ] || wget -qO- --header "Authorization: Bearer $T" --post-data "" "$A/v1/auth/logout" >/dev/null 2>&1 || true
  rm -rf "$HOME"
}
trap bye EXIT
# HTTP status of GET $1 with bearer $2: 200, or the 4xx/5xx busybox wget names.
code() {
  if e=$(wget -qO- --header "Authorization: Bearer $2" "$1" 2>&1 >/dev/null); then echo 200; return; fi
  for c in 401 403 404; do case "$e" in *" $c "*) echo "$c"; return ;; esac; done
  echo "agent-vault-bootstrap: GET $1: $e" >&2
  echo err
}
# Uninitialized (first run, or a lost PVC): no stored token can be valid, and
# every authenticated route answers 503 until the owner exists.
if wget -qO- "$A/v1/status" | grep -q '"initialized":false'; then
  printf %s "$OWN" | agent-vault auth register --address "$A" --email "$E" --password-stdin >/dev/null
elif [ "$ROT" = 0 ] && [ -n "$CUR" ]; then
  case "$(code "$A/v1/vaults" "$CUR")" in
    200) exit 0 ;;
    401 | 403) ;;          # stored token refused: replace it
    *) exit 1 ;;           # vault unhealthy or unreachable: change nothing
  esac
fi
# The first user's register saves a session; otherwise log in. On an
# initialized instance a failed login here means someone else is the owner.
[ -s "$S" ] || printf %s "$OWN" | agent-vault auth login --address "$A" --email "$E" --password-stdin >/dev/null
T=$(tok)
case "$(code "$A/v1/agents/fleet-provisioner" "$T")" in
  200) agent-vault agent rotate fleet-provisioner --token-only ;;
  404) agent-vault agent create fleet-provisioner --role member --token-only ;;
  *) exit 1 ;;
esac
EOF
} | "$NODE" "${AV_NODE:-k9s-dashboard}" "kubectl -n $NS exec -i deploy/agent-vault -- sh -s" >"$F"

[ -s "$F" ] || { echo "agent-vault-bootstrap: current token works, nothing changed (--rotate to force)"; exit 0; }
# From here the old token may be dead and $F may hold the only copy of the new
# one: never delete it on failure.
KEEP=1
NEW=$(cat "$F")
is_token "$NEW" || { echo "agent-vault-bootstrap: pod output is not exactly one agent token; kept in $F (0600), inspect without printing" >&2; exit 1; }
printf 'AGENT_VAULT_TOKEN=%s\n' "$NEW" >"$F.env"
# shellcheck disable=SC2086
if ! infisical secrets set --file="$F.env" $INF "$TOK_PATH" >/dev/null; then
  echo "agent-vault-bootstrap: Infisical write failed; the new token is in $F.env (0600). Retry: infisical secrets set --file=$F.env $INF $TOK_PATH && rm -f $F $F.env" >&2
  exit 1
fi
KEEP=
echo "agent-vault-bootstrap: AGENT_VAULT_TOKEN written"
