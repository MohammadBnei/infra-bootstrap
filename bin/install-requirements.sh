#!/usr/bin/env bash
# install-requirements.sh — install everything needed to run the bootstrap configs
# Run once on a fresh machine (Mac, Linux). Idempotent.

set -euo pipefail

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

# 6. kubespray Python requirements
echo "Installing kubespray Python requirements..."
pip3 install --user -r kubespray/requirements.txt

echo
echo "Done. Next steps:"
echo "  1. infisical login"
echo "  2. See docs/runbook-k8s-bootstrap.md for the kubespray procedure"
