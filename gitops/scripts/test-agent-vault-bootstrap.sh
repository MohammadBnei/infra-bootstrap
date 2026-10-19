#!/bin/sh
# Offline check for agent-vault-bootstrap.sh: stub `infisical`, node.sh (runs
# the pod script locally), busybox `wget` and the `agent-vault` CLI, then
# assert the fail-closed branches. No cluster, no Infisical. Run from CI.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir "$D/bin"
OK=av_agt_good123
NEW=av_agt_new456

# infisical: `secrets get KEY` prints $D/store/KEY (rc $INF_GET_RC);
# `secrets set --file=X` copies X to $D/set.env (rc $INF_SET_RC).
cat >"$D/bin/infisical" <<'EOF'
#!/bin/sh
case "$2" in
  get) [ "${INF_GET_RC:-0}" = 0 ] || { echo "Response Code: 500" >&2; exit 1; }
       cat "$D/store/$3" 2>/dev/null; exit 0 ;;
  set) for a; do case "$a" in --file=*) cp "${a#--file=}" "$D/set.env" ;; esac; done
       exit "${INF_SET_RC:-0}" ;;
esac
EOF
# node.sh [--lan] <node> <cmd>: log $1, run the pod script here as `sh -s`
# would in the pod, then exit $NODE_RC if set (a stream that fails late).
cat >"$D/bin/node.sh" <<'EOF'
#!/bin/sh
echo "node $1" >>"$D/log"
sh -s && rc=0 || rc=$?
exit "${NODE_RC:-$rc}"
EOF
# wget: /v1/vaults is 200 only for bearer $OK (else 401), unless $WG_VAULTS
# forces a code; /v1/agents/* needs the owner session (else 401), then
# answers $WG_AGENT; /v1/status says initialized=$WG_INIT; logout is logged;
# WG_DOWN=1 refuses every connection.
cat >"$D/bin/wget" <<'EOF'
#!/bin/sh
[ -z "${WG_DOWN:-}" ] || { echo "wget: can't connect to remote host: Connection refused" >&2; exit 1; }
h= p=
for u; do [ "$p" = --header ] && h=$u; p=$u; done
bearer() { if [ "$h" = "Authorization: Bearer $1" ]; then echo "$2"; else echo 401; fi; }
st=200
case "$u" in
  */v1/vaults) st=${WG_VAULTS:-$(bearer av_agt_good123 200)} ;;
  */v1/agents/*) st=$(bearer av_sess_x "${WG_AGENT:-200}") ;;
  */v1/status) echo "{\"initialized\":${WG_INIT:-true}}"; exit 0 ;;
  */v1/auth/logout) echo logout >>"$D/log" ;;
esac
[ "$st" = 200 ] || { echo "wget: server returned error: HTTP/1.1 $st X" >&2; exit 1; }
echo '{}'
EOF
# agent-vault: register/login write a session (as upstream's first-user
# register does), login fails with AV_LOGIN_RC=1; `owner config set
# --invite-only` logs "invite"; rotate/create log and print $AV_OUT.
cat >"$D/bin/agent-vault" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "auth login" ] && [ "${AV_LOGIN_RC:-0}" != 0 ]; then echo "Error: invalid credentials" >&2; exit 1; fi
case "$1 $2" in
  "auth register" | "auth login") cat >/dev/null; echo "$2" >>"$D/log"; mkdir -p "$HOME/.agent-vault"
                echo '{"token":"av_sess_x","address":"a"}' >"$HOME/.agent-vault/session.json" ;;
  "owner config") [ "$3 $4" = "set --invite-only" ] && echo invite >>"$D/log" ;;
  "agent rotate" | "agent create") echo "$2" >>"$D/log"; printf '%b' "$AV_OUT" ;;
esac
EOF
chmod +x "$D/bin/"*

fails=0
# run <name> <want-rc> [env...]: fresh store (stored token $STORED, default
# $OK) and log; $ARGS goes to the script.
run() {
  name=$1 want=$2; shift 2
  rm -rf "$D/store" "$D/log" "$D/set.env"; mkdir "$D/store"; : >"$D/log"
  printf %s "${STORED:-$OK}" >"$D/store/AGENT_VAULT_TOKEN"
  printf %s ownerpw >"$D/store/AGENT_VAULT_OWNER_PASSWORD"
  rc=0
  # shellcheck disable=SC2086 # $ARGS is a flag list
  env D="$D" PATH="$D/bin:$PATH" AV_NODE_SH="$D/bin/node.sh" AV_OUT="$NEW" "$@" \
    sh "$HERE/agent-vault-bootstrap.sh" ${ARGS:-} >"$D/out" 2>&1 || rc=$?
  [ "$rc" = "$want" ] || { echo "FAIL $name: rc=$rc want $want"; cat "$D/out"; fails=$((fails + 1)); }
}
has() { grep -qx "$1" "$D/log" || { echo "FAIL $name: no '$1' in log"; fails=$((fails + 1)); }; }
hasnt() { ! grep -qx "$1" "$D/log" || { echo "FAIL $name: unexpected '$1'"; fails=$((fails + 1)); }; }
said() { grep -q "$1" "$D/out" || { echo "FAIL $name: output lacks '$1'"; fails=$((fails + 1)); }; }
wrote() { [ "$(cat "$D/set.env" 2>/dev/null)" = "AGENT_VAULT_TOKEN=$1" ] || { echo "FAIL $name: Infisical got the wrong write"; fails=$((fails + 1)); }; }
nowrite() { [ ! -e "$D/set.env" ] || { echo "FAIL $name: wrote to Infisical"; fails=$((fails + 1)); }; }

run "valid token is a no-op" 0;                    hasnt rotate; hasnt login; nowrite; said "nothing changed"
run "Infisical read failure aborts" 1 INF_GET_RC=1; hasnt rotate; nowrite
run "vault 5xx does not rotate" 1 WG_VAULTS=503;   hasnt rotate; nowrite
run "unreachable vault aborts" 1 WG_DOWN=1;        hasnt rotate; nowrite
run "refused token rotates" 0 WG_VAULTS=401;       has rotate; has invite; has logout; wrote "$NEW"
STORED=av_agt_other; run "another stored token is refused, rotates" 0; has rotate; wrote "$NEW"; STORED=
ARGS=--rotate; run "--rotate forces a rotation" 0; has rotate; wrote "$NEW"; ARGS=
run "missing agent is created" 0 WG_VAULTS=401 WG_AGENT=404; has create; hasnt rotate
run "uninitialized vault registers, skips the check" 0 WG_INIT=false WG_VAULTS=503 WG_AGENT=404; has register; hasnt login; has invite; has create; wrote "$NEW"
run "agent lookup 5xx aborts" 1 WG_VAULTS=401 WG_AGENT=500; hasnt rotate; hasnt create; nowrite
run "refused owner login is an incident" 1 WG_VAULTS=401 AV_LOGIN_RC=1; hasnt rotate; hasnt create; nowrite; said INCIDENT
run "rotate printing nothing is an error" 1 WG_VAULTS=401 AV_OUT=""; has rotate; nowrite; said "printed no token"
run "extra output is rejected" 1 WG_VAULTS=401 AV_OUT="$NEW\\nA new release is available"; nowrite; said "kept in"
run "stream failing after the token keeps it" 1 WG_VAULTS=401 NODE_RC=255; nowrite; said "kept in"
ARGS=--lan; run "--lan reaches node.sh as its own word" 0; has "node --lan"; ARGS=
run "Infisical write failure keeps the token" 1 WG_VAULTS=401 INF_SET_RC=1; said "new token is in"
! grep -q "$NEW" "$D/out" || { echo "FAIL: a token was printed"; fails=$((fails + 1)); }

[ "$fails" = 0 ] && echo "OK: agent-vault-bootstrap.sh" || exit 1
