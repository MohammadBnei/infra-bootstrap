# ukubi-cluster kubespray inventory

This is the inventory kubespray reads to build `ukubi-cluster`.

## Target topology (MISSION §3)

| Node | IP | VMID | vCPU | RAM | Role |
|---|---|---|---|---|---|
| `k8s-cp-01` | 192.168.1.201 | 201 | 2 | 4GB | control plane + etcd + worker |
| `k8s-worker-01` | 192.168.1.202 | 202 | 4 | 8GB | worker + RTX 2070 SUPER PT (GPU passthrough on this VM directly, no separate GPU worker) |

**OS:** Ubuntu 24.04 cloud-init, user `core`, SSH key `~/.ssh/id_k8s_vms`.

## Current status (2-VM test run)

- [x] `hosts.yaml` populated (IPs still placeholders — fill before running)
- [x] `group_vars/` created and ported to kubespray v2.31.0 variable names (Q-D resolved)
- [x] `~/.ssh/id_k8s_vms` generated
- [ ] VMs created and IPs filled in `hosts.yaml`
- [ ] Public key deployed to VMs (`~/.ssh/id_k8s_vms.pub` → `core` user)
- [ ] `ansible -i hosts.yaml all -m ping` passes
- [ ] `cluster.yml` first run (2 nodes: cp-01 + worker-01)
- [ ] Stage 2 workers on `.200`/`.161` added later via `scale.yml` (not `cluster.yml` — see Notes below)

## How to run

```bash
git clone git@github.com:MohammadBnei/infra-bootstrap.git
cd infra-bootstrap
git submodule update --init --recursive

# 1. Fill in IPs in inventory/ukubi/hosts.yaml

# 2. Verify reachability
ansible -i inventory/ukubi/hosts.yaml all -m ping

# 3. Run kubespray from the submodule
cd kubespray
ansible-playbook -i ../inventory/ukubi/hosts.yaml cluster.yml --become --diff
```

## Notes

- CNI: Cilium in chaining mode (`cilium_kube_proxy_replacement: false`, `cilium_enable_portmap: true`), kube-proxy retained in IPVS mode with `strict_arp: true` (required for MetalLB L2)
- MetalLB: L2, pool `192.168.1.233-250`, Traefik VIP reserved at `.233` (`.230`-`.232` excluded from the pool — `.232` is Pigsty's HA floating VIP)
- Hubble: enabled with TLS
- ArgoCD: installed via `helm + kubectl apply -f gitops/bootstrap/` after kubespray (not a kubespray addon)
- cert-manager: NOT installed — Traefik built-in ACME (HTTP-01) is the cert engine
- GPU: `k8s-worker-01` gets `hostpci` passthrough directly (no separate GPU-only worker) — `nvidia_accelerator_enabled: true` and `nvidia_gpu_nodes` are set on it as part of the initial `cluster.yml` run
- Future workers on `.200`/`.161` (once they join the PVE cluster — see `docs/adr/0020-pve-corosync-cluster.md`) are added the same way: `scale.yml`, worker-only, no control-plane/etcd role. Treat `.161`'s worker as lower-trust capacity until ADR-0013's sleep-risk mitigation is confirmed in production — best-effort workloads only, no critical-path scheduling, via node labels/taints once it's added.
