# ukubi-cluster kubespray inventory

This is the inventory kubespray reads to build the `ukubi-cluster`.

## Target topology (per `infrastructure-desired.md`)

| Node | Type | Host | IP | Resources |
| --- | --- | --- | --- | --- |
| k8s-cp-01 | VM | proxmox PVE | 192.168.1.201 | 2 vCPU / 4GB *(not yet created)* |
| k8s-worker-gpu | VM | proxmox PVE | 192.168.1.203 | 6 vCPU / 15GB (RTX 2070 SUPER passthrough) *(not yet created)* |
| k8s-worker-01 | VM | proxmox PVE | 192.168.1.202 | 4 vCPU / 8GB *(not yet created)* |

## Status

- [x] Target IPs assigned in design (`.201`, `.202`, `.203`)
- [ ] VMs created on proxmox PVE
- [ ] `inventory.ini` populated with real host entries
- [ ] `group_vars/all.yml` finalized (k8s version, CNI, addons)
- [ ] `group_vars/k8s_cluster.yml` finalized (API, network, scheduler)
- [ ] `group_vars/etcd.yml` reviewed
- [ ] Kubespray inventory ported to match the pinned `v2.31.0` submodule version (Q-D)
- [ ] First `kubespray` dry-run against the inventory

## How to run

```bash
git clone git@github.com:MohammadBnei/infra-bootstrap.git
cd infra-bootstrap
git submodule update --init --recursive

# kubespray lives in kubespray/ submodule
cd kubespray
ansible-playbook -i ../inventory/ukubi/inventory.ini cluster.yml \
  -e @../inventory/ukubi/group_vars/all.yml \
  --become --diff
```

## Notes

- CNI = Cilium in chaining mode (kube-proxy retained) because not all PVE hosts have eBPF hardware
- K8s version is `v1.35.4`
- `cluster.yml` is currently blocked: inventory var names are authored for kubespray v2.23 while the submodule is v2.31.0
- There is no coexisting new QEMU cluster yet; the legacy libvirt cluster is still the only running cluster
- See `docs/runbook-k8s-bootstrap.md` for the full procedure
