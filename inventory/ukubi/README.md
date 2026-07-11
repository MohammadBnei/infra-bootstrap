# ukubi-cluster kubespray inventory

This is the inventory kubespray reads to build `ukubi-cluster`.

## Target topology (MISSION §3)

| Node | IP | VMID | vCPU | RAM | Role |
|---|---|---|---|---|---|
| `k8s-cp-01` | 192.168.1.201 | 201 | 2 | 4GB | control plane + etcd + worker |
| `k8s-worker-01` | 192.168.1.202 | 202 | 4 | 8GB | worker |
| `k8s-worker-gpu` | 192.168.1.203 | 203 | 6 | 15GB | worker + RTX 2070 SUPER PT |

**OS:** Ubuntu 24.04 cloud-init, user `core`, SSH key `~/.ssh/id_k8s_vms`.

## Current status (2-VM test run)

- [x] `hosts.yaml` populated (IPs still placeholders — fill before running)
- [x] `group_vars/` created and ported to kubespray v2.31.0 variable names (Q-D resolved)
- [x] `~/.ssh/id_k8s_vms` generated
- [ ] VMs created and IPs filled in `hosts.yaml`
- [ ] Public key deployed to VMs (`~/.ssh/id_k8s_vms.pub` → `core` user)
- [ ] `ansible -i hosts.yaml all -m ping` passes
- [ ] `cluster.yml` first run (2 nodes: cp-01 + worker-01)
- [ ] `k8s-worker-gpu` added later via second `cluster.yml` run

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
- MetalLB: L2, pool `192.168.1.230-250`, Traefik VIP reserved at `.230`
- Hubble: enabled with TLS
- ArgoCD: installed via `helm + kubectl apply -f gitops/bootstrap/` after kubespray (not a kubespray addon)
- cert-manager: NOT installed — Traefik built-in ACME (HTTP-01) is the cert engine
- k8s-worker-gpu: add to `hosts.yaml` (kube_node only) and re-run `cluster.yml` — set `nvidia_accelerator_enabled: true` and populate `nvidia_gpu_nodes` in k8s-cluster.yml at that time
