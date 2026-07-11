# Auth comes entirely from env vars injected by the `infisical run` wrapper —
# see README.md. Never put PROXMOX_VE_API_TOKEN / PROXMOX_VE_SSH_PRIVATE_KEY
# in this file or in a committed .tfvars.
provider "proxmox" {
  endpoint = var.pve_endpoint
  insecure = var.pve_insecure

  # api_token read from PROXMOX_VE_API_TOKEN env var (bpg provider default).

  ssh {
    # Linux/PAM account on the PVE host, NOT the terraform@pve PVE-realm
    # API user — see README.md "Prerequisites" for why these differ.
    username = "root"
    # private_key read from PROXMOX_VE_SSH_PRIVATE_KEY env var.
  }
}
