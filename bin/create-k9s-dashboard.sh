#!/usr/bin/env bash
# create-k9s-dashboard.sh — one-shot: terraform-create the k9s-dashboard
# LXC (fetching PVE_API_TOKEN/PVE_SSH_PRIVATE_KEY from Infisical the same
# way terraform/README.md's "Running Terraform" section does), then
# ansible-configure it (kubectl + k9s + cluster-admin kubeconfig).
# Idempotent — safe to re-run.
#
# The dedicated SSH keypair for this box is treated the same way: Infisical
# (SSH_K9S_DASHBOARD_KEY, see docs/secrets.md) is the source of truth, not
# just this laptop's ~/.ssh — this box carries a live cluster-admin
# kubeconfig, so its key's blast radius is the whole cluster. First run
# with nothing in Infisical yet pushes whatever's on disk (or generates
# fresh); every run after that pulls from Infisical and overwrites local.
#
# Prerequisites (not automated here, see terraform/README.md /
# ansible/README.md — same "confirm, don't guess" discipline as the rest
# of this repo):
#   - terraform/terraform.tfvars filled in, including k9s_dashboard_ip /
#     k9s_dashboard_container_storage (copy from terraform.tfvars.example)
#   - Infisical CLI authenticated in this shell: source ~/.hermes/cache/inf-env.sh
#   - KUBECTL_VERSION / K9S_VERSION / K9S_SHA256 env vars set — see
#     ansible/playbooks/k9s-dashboard-configure.yml's header comment for
#     where each value comes from
#
# Usage:
#   export KUBECTL_VERSION=v1.35.4 K9S_VERSION=v0.50.6 K9S_SHA256=<sha256>
#   bin/create-k9s-dashboard.sh [-y|--yes]   # -y skips terraform's apply prompt
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFISICAL_PROJECT_ID="8a3fa54f-be22-488a-bf51-55158f65c0f2"
INFISICAL_ENV="dev"
SSH_KEY="$HOME/.ssh/id_k9s_dashboard"
INVENTORY_FILE="$REPO_ROOT/ansible/inventories/k9s-dashboard/hosts.yml"

AUTO_APPROVE=()
for arg in "$@"; do
  case "$arg" in
  -y | --yes) AUTO_APPROVE=(-auto-approve) ;;
  *)
    echo "Unknown argument: $arg" >&2
    exit 1
    ;;
  esac
done

# -------------------------------------------------------------------------
# Preflight
# -------------------------------------------------------------------------
for cmd in terraform ansible-playbook infisical ssh ssh-keygen; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing required command: $cmd" >&2
    exit 1
  }
done

if [[ ! -f "$REPO_ROOT/terraform/terraform.tfvars" ]]; then
  echo "terraform/terraform.tfvars not found — copy terraform.tfvars.example and fill it in first (k9s_dashboard_ip / k9s_dashboard_container_storage in particular)." >&2
  exit 1
fi

for var in KUBECTL_VERSION K9S_VERSION K9S_SHA256; do
  if [[ -z "${!var:-}" ]]; then
    echo "$var is not set — see ansible/playbooks/k9s-dashboard-configure.yml's header comment for where to get it." >&2
    exit 1
  fi
done

if ! infisical secrets get PVE_API_TOKEN --projectId="$INFISICAL_PROJECT_ID" --env="$INFISICAL_ENV" --plain >/dev/null 2>&1; then
  echo "Infisical CLI not authenticated in this shell — run: source ~/.hermes/cache/inf-env.sh" >&2
  exit 1
fi

# -------------------------------------------------------------------------
# SSH key: Infisical is the source of truth (see header comment above)
# -------------------------------------------------------------------------
if infisical secrets get SSH_K9S_DASHBOARD_KEY --projectId="$INFISICAL_PROJECT_ID" --env="$INFISICAL_ENV" --plain >"$SSH_KEY.tmp" 2>/dev/null \
  && [[ -s "$SSH_KEY.tmp" ]]; then
  echo "==> Fetched k9s-dashboard SSH key from Infisical"
  mv "$SSH_KEY.tmp" "$SSH_KEY"
  chmod 600 "$SSH_KEY"
else
  rm -f "$SSH_KEY.tmp"
  if [[ -f "$SSH_KEY" ]]; then
    echo "==> No SSH key in Infisical yet — pushing the already-deployed local one"
  else
    echo "==> No SSH key in Infisical yet — generating one ($SSH_KEY)"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -C k9s-dashboard -N ""
  fi
  infisical secrets set --projectId="$INFISICAL_PROJECT_ID" --env="$INFISICAL_ENV" --type=shared \
    "SSH_K9S_DASHBOARD_KEY=$(cat "$SSH_KEY")" >/dev/null
fi
ssh-keygen -y -f "$SSH_KEY" >"${SSH_KEY}.pub"

# -------------------------------------------------------------------------
# 1. Terraform: bare, SSH-reachable LXC
# -------------------------------------------------------------------------
echo "==> terraform apply (k9s-dashboard LXC)"
infisical run --projectId="$INFISICAL_PROJECT_ID" --env="$INFISICAL_ENV" -- \
  bash -c 'PROXMOX_VE_API_TOKEN="$PVE_API_TOKEN" \
           PROXMOX_VE_SSH_PRIVATE_KEY="$PVE_SSH_PRIVATE_KEY" \
           terraform -chdir="'"$REPO_ROOT"'/terraform" "$@"' _ \
  apply \
  -target=proxmox_download_file.k9s_dashboard_lxc_template \
  -target=proxmox_virtual_environment_container.k9s_dashboard \
  "${AUTO_APPROVE[@]}"

K9S_IP="$(terraform -chdir="$REPO_ROOT/terraform" output -raw k9s_dashboard_ip)"
echo "==> k9s-dashboard is at $K9S_IP"

infisical secrets set --projectId="$INFISICAL_PROJECT_ID" --env="$INFISICAL_ENV" --type=shared \
  "SSH_K9S_DASHBOARD_HOST=$K9S_IP" "SSH_K9S_DASHBOARD_PORT=22" "SSH_K9S_DASHBOARD_USER=root" >/dev/null

# -------------------------------------------------------------------------
# 2. Point the ansible inventory at it, wait for SSH, trust its host key
# -------------------------------------------------------------------------
cat >"$INVENTORY_FILE" <<EOF
# Single, hand-maintained host — k9s-dashboard is one static, ops-only LXC
# (see terraform/k9s-dashboard.tf), not a fleet. Regenerated by
# bin/create-k9s-dashboard.sh from terraform's k9s_dashboard_ip output —
# safe to hand-edit, just stays in sync automatically on the next run.
#
# ansible_ssh_common_args forces a real handshake (ControlPath=none) and
# auto-trusts a first-seen host key — needed because this box's IP gets
# reused across recreate/destroy cycles, and a global ~/.ssh/config
# ControlMaster (if the operator has one, e.g. "Host * / ControlPersist 8h")
# would otherwise silently reuse a stale multiplexed socket from a
# previous, different container at the same IP, skip the handshake
# entirely, and leave known_hosts never actually populated — which then
# makes THIS task's own ssh connection fail outright (confirmed by testing).
all:
  hosts:
    k9s-dashboard:
      ansible_host: $K9S_IP
      ansible_user: root
      ansible_ssh_private_key_file: ~/.ssh/id_k9s_dashboard
      ansible_ssh_common_args: "-o ControlPath=none -o StrictHostKeyChecking=accept-new"
EOF

echo "==> Waiting for SSH on $K9S_IP"
ssh -o ControlPath=none -o ControlMaster=no -q "root@$K9S_IP" -O exit 2>/dev/null || true
ssh-keygen -R "$K9S_IP" >/dev/null 2>&1 || true
ssh_up=0
for _ in $(seq 1 30); do
  if ssh -o ControlPath=none -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 -o BatchMode=yes \
    -i "$SSH_KEY" "root@$K9S_IP" true 2>/dev/null; then
    ssh_up=1
    break
  fi
  sleep 2
done
if [[ "$ssh_up" -ne 1 ]]; then
  echo "SSH on $K9S_IP never came up after 60s — check the container (pct status/console on the PVE host) before re-running." >&2
  exit 1
fi

# -------------------------------------------------------------------------
# 3. Ansible: install kubectl/k9s, mint the cluster-admin kubeconfig
# -------------------------------------------------------------------------
echo "==> ansible-playbook (kubectl/k9s install + kubeconfig)"
ansible-playbook \
  -i "$REPO_ROOT/inventory/ukubi/hosts.yaml" \
  -i "$INVENTORY_FILE" \
  "$REPO_ROOT/ansible/playbooks/k9s-dashboard-configure.yml"

cat <<EOF

Done. Connect with:
  ssh -i $SSH_KEY root@$K9S_IP
  k9s
EOF
