# ukubi-cluster kubespray inventory

This is the inventory kubespray reads to build the `ukubi-cluster`.

## Target topology (per `infrastructure-desired.md`)

| Node | Type | Host | IP (TBD) | Resources |
|---|---|---|---|---|
| k8s-cp-01 | VM | proxmox PVE | TBD | 2 vCPU / 4GB |
| k8s-worker-gpu | VM | proxmox PVE | TBD | 6 vCPU / 16GB (RTX 2070 SUPER passthrough) |
| k8s-worker-01 | VM | proxmox PVE | TBD | 4 vCPU / 8GB |
| k8s-worker-02 | VM | server1 PVE | TBD | 4 vCPU / 8GB |

## Status

- [ ] `inventory.ini` populated with real IPs
- [ ] `group_vars/all.yml` finalized (k8s version, CNI, addons)
- [ ] `group_vars/k8s_cluster.yml` finalized (API, network, scheduler)
- [ ] `group_vars/etcd.yml` reviewed
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
- K8s version pinned in `group_vars/all.yml` — update both here and the k8s-cluster repo
- See `docs/runbook-k8s-bootstrap.md` for the full procedure
