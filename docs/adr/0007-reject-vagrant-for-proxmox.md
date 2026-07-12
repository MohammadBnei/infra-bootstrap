# ADR-0007: Reject Vagrant for Proxmox provisioning

**Status:** Rejected

## Context

Vagrant was considered as a way to script Proxmox VM creation.

## Decision

Rejected. VM provisioning is manual `qm importdisk` + `qm clone` + `qm
set --ipconfig0 --sshkeys`, wrapped by Terraform (`bpg/proxmox`
provider, see `terraform/README.md`) and Ansible — not Vagrant.

## Consequences

No Vagrantfile anywhere in this repo. Terraform is the IaC layer for
Proxmox VM/LXC lifecycle.
