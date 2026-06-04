# Ansible playbooks

Custom playbooks for things kubespray and pigsty don't cover:
- PVE post-install (after a fresh PVE install, before any VMs)
- VM provisioning on PVE (create VMs/LXCs from inventory)
- K8s node prereqs (kernel modules, sysctl, containerd) — usually handled by kubespray but useful to have standalone for ad-hoc nodes

## Layout

| Path | Contents |
|---|---|
| `playbooks/pve-postinstall.yml` | Configure a fresh PVE host (repos, NTP, sysctl, SSH keys, no-subscription repo if needed) |
| `playbooks/vm-provision.yml` | Create QEMU VMs and LXC containers from a host_vars-driven spec |
| `playbooks/k8s-node-prereqs.yml` | Standalone K8s-node prereq setup (kernel modules, cgroup, containerd) |
| `inventories/proxmox/` | Proxmox host inventory |

## Status

- [ ] First playbook: `pve-postinstall.yml` drafted
- [ ] `vm-provision.yml` drafted
- [ ] `k8s-node-prereqs.yml` drafted (may not be needed if kubespray covers it)

## How to run

```bash
infisical run --projectId=<infra-bootstrap-project-id> --env=dev -- \
  ansible-playbook -i ansible/inventories/proxmox/hosts.yml \
    ansible/playbooks/pve-postinstall.yml
```

## See also

- [docs/runbook-pve-postinstall.md](../docs/runbook-pve-postinstall.md)
