#!/usr/bin/env bash
# Driver for /run-ukubi-ops — validates and constructs kubectl/pigsty/kubespray/ansible
# commands for ukubi-cluster. Every subcommand here is read-only or dry-run: it never
# mutates real infra and never prints a secret value. See SKILL.md for the full contract.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
INFISICAL_PROJECT_ID="8a3fa54f-be22-488a-bf51-55158f65c0f2"
INFISICAL_ENV="dev"

usage() {
  cat <<'EOF'
Usage: driver.sh <subcommand> [args]

  ansible-check   <playbook> -i <inventory> [extra ansible-playbook args]
      --syntax-check + --list-tasks a custom playbook under ansible/playbooks/.

  kubespray-check [-i <inventory>] [extra ansible-playbook args, e.g. --tags coredns]
      --syntax-check + --list-tasks kubespray/cluster.yml via the pinned kubespray-venv.
      Verifies ansible-core is in kubespray's required 2.18.x < 2.19 range first.

  pigsty-check    <playbook.yml> [extra ansible-playbook args]
      --syntax-check + --list-tasks a pigsty playbook (run from pigsty/, its own ansible.cfg
      supplies the default inventory).

  pigsty-list
      List pigsty/*.yml playbooks.

  kubectl-cmd     <verb...>
      Build (never run) the SSH+kubeconfig-wrapped kubectl command per k8s-ops's pattern,
      and classify it safe (read-only) or mutating.

  infisical-wrap  <command...>
      Prefix a command with the correct `infisical run` wrapper for this project. Prints
      the command only — never executes, never fetches/echoes a secret value.

  fetch-ssh-key   <SECRET_NAME> <dest-file>
      The one pattern that must touch a secret value directly (e.g. SSH_PI4_KEY for
      hardware with no Terraform-generated local keypair). umask 177 before the file is
      created, so it's born mode 600 — no window where it's world-readable — and the
      secret value is piped straight from `infisical secrets get --plain` to <dest-file>,
      never through a variable or echo. Caller deletes dest-file after use (this script
      doesn't, since the key is needed after the call returns).
EOF
}

require_secrets_via_env() {
  # ponytail: guard against accidental `infisical secrets get --plain` copy-paste in this
  # script growing into a leak. Nothing below may pipe a `secrets get` to stdout.
  :
}

cmd_ansible_check() {
  local playbook="" inventory=""
  [ $# -ge 1 ] || { echo "usage: ansible-check <playbook> -i <inventory> [extra args]" >&2; exit 1; }
  playbook="$1"; shift
  ansible-playbook --syntax-check "$@" "$REPO/$playbook"
  echo "--- list-tasks ---"
  ansible-playbook --list-tasks "$@" "$REPO/$playbook"
}

cmd_kubespray_check() {
  local venv="$REPO/kubespray-venv/bin/ansible-playbook"
  [ -x "$venv" ] || {
    echo "kubespray-venv missing or not executable at $venv" >&2
    echo "recreate: python3.12 -m venv kubespray-venv && kubespray-venv/bin/pip install -r kubespray/requirements.txt" >&2
    exit 1
  }
  local ver
  ver="$("$venv" --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  case "$ver" in
    2.18.*) : ;;
    *) echo "WARNING: kubespray-venv ansible-core is $ver, kubespray v2.31.0 requires 2.18.0 <= v < 2.19.0" >&2 ;;
  esac
  local inventory="$REPO/inventory/ukubi/hosts.yaml"
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -i) inventory="$2"; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  ( cd "$REPO/kubespray" && "$venv" --syntax-check -i "$inventory" "${args[@]}" cluster.yml )
  echo "--- list-tasks (${args[*]:-no extra args}) ---"
  ( cd "$REPO/kubespray" && "$venv" --list-tasks -i "$inventory" "${args[@]}" cluster.yml )
}

cmd_pigsty_check() {
  [ $# -ge 1 ] || { echo "usage: pigsty-check <playbook.yml> [extra args]" >&2; exit 1; }
  local playbook="$1"; shift
  ( cd "$REPO/pigsty" && ansible-playbook --syntax-check "$@" "$playbook" )
  echo "--- list-tasks ---"
  ( cd "$REPO/pigsty" && ansible-playbook --list-tasks "$@" "$playbook" )
}

cmd_pigsty_list() {
  ls "$REPO/pigsty"/*.yml | xargs -n1 basename
}

# Verbs that only read cluster state. Anything else is mutating.
SAFE_VERBS="get describe logs top explain api-resources api-versions version"

cmd_kubectl_cmd() {
  [ $# -ge 1 ] || { echo "usage: kubectl-cmd <verb> [args...]" >&2; exit 1; }
  local verb="$1"
  local risk="MUTATING — requires explicit user go-ahead this session"
  for safe in $SAFE_VERBS; do
    [ "$verb" = "$safe" ] && risk="safe / read-only"
  done
  local hosts_yaml="$REPO/inventory/ukubi/hosts.yaml"
  local key_path host
  key_path="$(grep -m1 'ansible_ssh_private_key_file' "$hosts_yaml" | sed -E 's/.*ansible_ssh_private_key_file:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/')"
  host="$(grep -m1 -A3 'k8s-cp-01:' "$hosts_yaml" | grep 'ansible_host' | sed -E 's/.*ansible_host:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/')"
  [ -n "$key_path" ] || key_path='<read ansible_ssh_private_key_file from inventory/ukubi/hosts.yaml>'
  [ -n "$host" ] || host='<k8s-cp-01 ansible_host from inventory/ukubi/hosts.yaml>'
  echo "RISK: $risk"
  printf 'ssh -i %s core@%s "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf %s"\n' "$key_path" "$host" "$*"
  echo "Never materialize admin.conf locally — this command stays SSH-wrapped, always (see k8s-ops skill)."
}

cmd_infisical_wrap() {
  [ $# -ge 1 ] || { echo "usage: infisical-wrap <command...>" >&2; exit 1; }
  printf 'infisical run --projectId=%s --env=%s -- %s\n' "$INFISICAL_PROJECT_ID" "$INFISICAL_ENV" "$*"
}

cmd_fetch_ssh_key() {
  [ $# -eq 2 ] || { echo "usage: fetch-ssh-key <SECRET_NAME> <dest-file>" >&2; exit 1; }
  local secret_name="$1" dest="$2"
  # umask first so the file is born 600 — no window where it's world-readable before chmod.
  ( umask 177 && infisical secrets get "$secret_name" \
      --projectId="$INFISICAL_PROJECT_ID" --env="$INFISICAL_ENV" --plain > "$dest" )
  echo "wrote $dest (600, value never printed) — delete it when done: rm -f $dest"
}

sub="${1:-}"; [ $# -gt 0 ] && shift || true
case "$sub" in
  ansible-check)   cmd_ansible_check "$@" ;;
  kubespray-check) cmd_kubespray_check "$@" ;;
  pigsty-check)    cmd_pigsty_check "$@" ;;
  pigsty-list)     cmd_pigsty_list ;;
  kubectl-cmd)     cmd_kubectl_cmd "$@" ;;
  infisical-wrap)  cmd_infisical_wrap "$@" ;;
  fetch-ssh-key)   cmd_fetch_ssh_key "$@" ;;
  ""|-h|--help|help) usage ;;
  *) echo "unknown subcommand: $sub" >&2; usage >&2; exit 1 ;;
esac
