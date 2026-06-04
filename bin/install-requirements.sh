#!/usr/bin/env bash
# install-requirements.sh — install everything needed to run the bootstrap configs
# Run once on a fresh machine (Mac, Linux). Idempotent.

set -euo pipefail

# Resolve repo root from this script's location, so it works from any cwd.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 1. Homebrew (Mac only — skip if Linux)
if [[ "$(uname)" == "Darwin" ]] && ! command -v brew >/dev/null 2>&1; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# 2. Python + pip (needed for ansible)
if ! command -v python3 >/dev/null 2>&1; then
  echo "Installing Python 3..."
  if [[ "$(uname)" == "Darwin" ]]; then brew install python; else sudo apt install -y python3 python3-pip; fi
fi

# 3. Ansible (latest)
if ! command -v ansible >/dev/null 2>&1; then
  echo "Installing Ansible..."
  python3 -m pip install --user ansible
fi

# 4. Ansible collections used by kubespray
if ! ansible-galaxy collection list 2>/dev/null | grep -q community.general; then
  echo "Installing ansible collections..."
  ansible-galaxy collection install community.general ansible.posix
fi

# 5. Infisical CLI
if ! command -v infisical >/dev/null 2>&1; then
  echo "Installing Infisical CLI..."
  curl -fsSL https://infisical.com/install.sh | bash
fi

# 6. Infisical auth cache: lay down the wrapper script in the user cache dir
CACHE_DIR="${HOME}/.hermes/cache"
mkdir -p "$CACHE_DIR"
chmod 700 "$CACHE_DIR"
install -m 600 "$REPO_ROOT/bin/inf-env.sh" "$CACHE_DIR/inf-env.sh"
echo "Installed: $CACHE_DIR/inf-env.sh"

# 7. Prompt for the secret credentials. They are NEVER in git — the user
#    must place them manually (typically from 1Password or by secure copy
#    from the agent LXC at 192.168.1.181).
if [[ ! -f "$CACHE_DIR/inf-cid" ]] || [[ ! -f "$CACHE_DIR/inf-csec" ]]; then
  cat <<'EOF'

!! Missing Infisical credentials. !!

This script does NOT create the client_id and client_secret files. They
must be placed manually at:

  ~/.hermes/cache/inf-cid    (the client_id, 36 bytes)
  ~/.hermes/cache/inf-csec   (the client_secret, 65 bytes)
  mode 0600 on both

Get them from one of:
  - 1Password vault "Infisical - hermes-agent"
  - The agent LXC: scp hermes@192.168.1.181:.hermes/cache/inf-{cid,csec} ~/.hermes/cache/

After placing them, re-run this script to verify the smoke test.
EOF
  exit 0
fi
chmod 600 "$CACHE_DIR/inf-cid" "$CACHE_DIR/inf-csec"

# 8. Smoke test: confirm the wrapper logs in and the CLI sees the project
echo "Smoke-testing Infisical auth..."
if ! source "$CACHE_DIR/inf-env.sh" >/dev/null 2>&1; then
  echo "!! Failed to log in. Check ~/.hermes/cache/inf-{cid,csec} contents. !!" >&2
  exit 1
fi
PROJ_FILE="$CACHE_DIR/inf-proj.id"
if [[ -f "$PROJ_FILE" ]]; then
  PROJ=$(cat "$PROJ_FILE")
  if ! infisical export --projectId="$PROJ" --env=dev --format=json >/dev/null 2>&1; then
    echo "!! Logged in but failed to read project $PROJ. Check Machine Identity role. !!" >&2
    exit 1
  fi
  echo "Infisical OK (project $PROJ reachable, env=dev)."
else
  echo "Infisical login OK. (No project id cached — that's fine, see docs/secrets.md.)"
fi

# 9. kubespray Python requirements
echo "Installing kubespray Python requirements..."
pip3 install --user -r "$REPO_ROOT/kubespray/requirements.txt"

cat <<'EOF'

Done. Next steps:
  1. In every shell where you'll use Infisical:
         source ~/.hermes/cache/inf-env.sh
     (add this line to your ~/.zshrc or ~/.bashrc to make it permanent.)
  2. See docs/runbook-k8s-bootstrap.md for the kubespray procedure.
  3. See docs/secrets.md for the secret schema.
EOF
