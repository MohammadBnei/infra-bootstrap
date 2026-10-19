#!/bin/sh
# agent-vault-bootstrap.sh [--rotate] [--lan] — ADR-0061 Decision 5. Run once, by the
# operator, right after the agent-vault Application first syncs.
#
#   1. If Infisical's AGENT_VAULT_TOKEN still authenticates and --rotate is
#      absent: done, nothing changes.
#   2. Else: registers the owner if the instance is uninitialized (first user
#      = owner, no verification without SMTP), logs in as it, closes
#      self-registration (invite_only), and rotates — or creates, instance
#      role `member` — the `fleet-provisioner` agent's token. A refused owner
#      login on an initialized instance is an incident: someone else owns it,
#      or reset the password (ADR-0061).
#   3. Writes that token to Infisical agent-fleet-nygh /agent-vault
#      AGENT_VAULT_TOKEN, which agent-fleet's provisioner mounts.
#
# Fails closed: an Infisical read error, an unreachable /v1/status, or any
# vault answer other than 200 / 401 / 403 to the token check, aborts before
# anything rotates. Only a missing key or a refused token leads to step 2.
# INCIDENT is printed only for a 401 owner login, never a transport error.
#
# --rotate is an outage: the old token dies at once, and the provisioner is
# locked out until Infisical (60s) + kubelet (<=60s) deliver the new one. If
# step 3 fails after a rotation, or the pod session fails after printing, the
# new token is kept in a 0600 file: retry the write, do not rotate again.
#
# --lan: reach k9s-dashboard over the LAN (node.sh --lan) when NetBird is down.
#
# Never prints a credential, and none goes on the operator machine's argv: the
# inner script, the current token and the owner password ride the pod's stdin;
# the new token comes back on stdout into a 0600 file that `infisical secrets
# set --file` reads. The owner password shares /agent-vault-server with the
# master password, but the vault's InfisicalSecret syncs only the master key
# (infisical.keys), so it is in no pod's env. Inside the vault
# container the current and session tokens are on busybox wget's argv — the
# one process tree that already holds every credential (accepted, ADR-0061).
#
# AV_NODE_SH overrides ansible's node.sh (test-agent-vault-bootstrap.sh).
set -eu
ROTATE=0
LAN=
for a; do
  case "$a" in
    --rotate) ROTATE=1 ;;
    --lan) LAN=--lan ;;
    *) echo "usage: $0 [--rotate] [--lan]" >&2; exit 2 ;;
  esac
done
INF="--projectId=ae771c2c-5115-452a-8f1c-1e03fa0e2b9a --env=dev --domain https://infisical.bnei.dev --silent"
TOK_PATH=--path=/agent-vault
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
OWN=$(infisical secrets get AGENT_VAULT_OWNER_PASSWORD $INF --path=/agent-vault-server --plain)
safe "$OWN" || { echo "agent-vault-bootstrap: AGENT_VAULT_OWNER_PASSWORD missing or not [A-Za-z0-9_-]" >&2; exit 1; }

# Set before the pipeline, in this shell: $F may hold the only copy of a new
# token even if the stream then fails, so the EXIT trap must not delete it.
KEEP=1
RC=
# shellcheck disable=SC2086 # $LAN is empty or one flag
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
  [ -z "$T" ] || wget -qO- --header "Authorization: Bearer $T" --post-data "" "$A/v1/auth/logout" >/dev/null 2>&1 ||
    echo "agent-vault-bootstrap: owner logout failed; revoke the owner's session in the vault UI" >&2
  rm -rf "$HOME"
}
trap bye EXIT
trap 'exit 1' HUP INT TERM PIPE   # a dropped stream still runs bye
# HTTP status of GET $1 with bearer $2: 200, or the 4xx/5xx busybox wget names.
code() {
  if e=$(wget -qO- --header "Authorization: Bearer $2" "$1" 2>&1 >/dev/null); then echo 200; return; fi
  for c in 401 403 404; do case "$e" in *" $c "*) echo "$c"; return ;; esac; done
  echo "agent-vault-bootstrap: GET $1: $e" >&2
  echo err
}
# Uninitialized (first run, or a lost PVC): no stored token can be valid, and
# every authenticated route answers 503 until the owner exists.
# Reachability is a precondition: an unreachable vault must never read as
# "initialized" and fall through to a login whose failure looks like an incident.
st=$(wget -qO- "$A/v1/status") || { echo "agent-vault-bootstrap: vault API unreachable; nothing changed" >&2; exit 1; }
case "$st" in
  *'"initialized":false'*)
    printf %s "$OWN" | agent-vault auth register --address "$A" --email "$E" --password-stdin >/dev/null ;;
  *'"initialized":true'*)
    if [ "$ROT" = 0 ] && [ -n "$CUR" ]; then
      case "$(code "$A/v1/vaults" "$CUR")" in
        200) echo NOOP; exit 0 ;;
        401 | 403) ;;          # stored token refused: replace it
        *) exit 1 ;;           # vault unhealthy or unreachable: change nothing
      esac
    fi ;;
  *) echo "agent-vault-bootstrap: unexpected /v1/status answer; nothing changed" >&2; exit 1 ;;
esac
# The first user's register saves a session; otherwise log in. Only a 401
# (the CLI's "invalid email or password") is an incident; a transport or
# server error is not, and must not lead anyone to wipe the PVC.
if [ ! -s "$S" ] && ! e=$(printf %s "$OWN" | agent-vault auth login --address "$A" --email "$E" --password-stdin 2>&1 >/dev/null); then
  case "$e" in
    *"invalid email or password"*)
      echo "agent-vault-bootstrap: INCIDENT: owner login refused on an initialized vault (owner taken or password reset), ADR-0061 Decision 5" >&2 ;;
    *) echo "agent-vault-bootstrap: owner login failed, not an auth refusal; nothing changed: $e" >&2 ;;
  esac
  exit 1
fi
# No second account, ever: registration stays open by default (no SMTP).
agent-vault owner config set --invite-only >/dev/null
T=$(tok)
case "$(code "$A/v1/agents/fleet-provisioner" "$T")" in
  200) agent-vault agent rotate fleet-provisioner --token-only ;;
  404) agent-vault agent create fleet-provisioner --role member --token-only ;;
  *) exit 1 ;;
esac
EOF
} | "$NODE" $LAN k9s-dashboard "kubectl -n agent-vault exec -i deploy/agent-vault -- sh -s" >"$F" || RC=$?

NEW=$(cat "$F")
[ "$NEW" != NOOP ] || [ -n "$RC" ] || { KEEP=; echo "agent-vault-bootstrap: current token works, nothing changed (--rotate to force)"; exit 0; }
# Empty output: a failed pod session wrote nothing; a clean exit with nothing
# printed means rotate/create returned no token (the old one may be dead).
[ -s "$F" ] || { KEEP=; [ -n "$RC" ] && echo "agent-vault-bootstrap: the pod session failed (rc=$RC); nothing was written" >&2 ||
  echo "agent-vault-bootstrap: the pod printed no token; the stored one may be dead: re-run with --rotate" >&2; exit 1; }
[ -z "$RC" ] || { echo "agent-vault-bootstrap: the pod session failed (rc=$RC) after printing; kept in $F (0600), inspect without printing" >&2; exit 1; }
is_token "$NEW" || { echo "agent-vault-bootstrap: pod output is not exactly one agent token; kept in $F (0600), inspect without printing" >&2; exit 1; }
printf 'AGENT_VAULT_TOKEN=%s\n' "$NEW" >"$F.env"
# shellcheck disable=SC2086
if ! infisical secrets set --file="$F.env" $INF "$TOK_PATH" >/dev/null; then
  echo "agent-vault-bootstrap: Infisical write failed; the new token is in $F.env (0600). Retry: infisical secrets set --file=$F.env $INF $TOK_PATH && rm -f $F $F.env" >&2
  exit 1
fi
KEEP=
echo "agent-vault-bootstrap: AGENT_VAULT_TOKEN written"
