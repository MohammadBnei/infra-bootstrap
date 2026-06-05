# ukubi — kubespray inventory

Greenfield kubespray inventory for the new **ukubi** cluster on 3 proxmox
PVE QEMU VMs. The previous ukubi-cluster (libvirt VMs on `server1`) is
being decommissioned; this new build is the successor.

The new build uses a **distinct apiserver endpoint** (`k8s-proxmox-gpu.bnei.lan`)
and distinct node IPs (`.201-.203`) so the two clusters can coexist during
the migration window without colliding on certificates, kubeconfigs, or DNS.
Once the libvirt cluster is fully drained, the endpoint and SANs can be
re-aligned to `k8s.bnei.lan` so external clients don't need to reconfigure
— that's a follow-up, not part of this PR.

## Overview

This bootstrap builds **ukubi** — a single control-plane, single-etcd,
chaining-mode Cilium + kube-proxy cluster on 3 QEMU VMs (`k8s-cp-01`,
`k8s-worker-01`, `k8s-worker-gpu`) on proxmox PVE (node `bnei`). The
cluster name `ukubi` is the inventory label; the Kubernetes internal
DNS domain stays `cluster.local` (kubespray default) so kubelets from the
old libvirt cluster could in principle be moved across without renaming
services. Distinct certs, distinct apiserver endpoint, distinct DNS name
keep the two clusters from interfering while both run side by side.

## Fleet

| Hostname         | IP            | Role                                | vCPU | RAM  | Disk | OS                        | VMID (PVE `bnei`) |
|------------------|---------------|-------------------------------------|------|------|------|---------------------------|-------------------|
| `k8s-cp-01`      | 192.168.1.201 | control plane + etcd + worker       | 2    | 4GB  | 40GB | Ubuntu 24.04 cloud-init   | 201               |
| `k8s-worker-01`  | 192.168.1.202 | worker                              | 4    | 8GB  | 60GB | Ubuntu 24.04 cloud-init   | 202               |
| `k8s-worker-gpu` | 192.168.1.203 | worker (RTX 2070 SUPER passthrough) | 6    | 15GB | 100GB| Ubuntu 24.04 cloud-init   | 203               |

Proxmox cloud-init template (`ubuntu-24.04-ci-template`, VMID 9000) bakes
the SSH user as `core` (NOT `ubuntu`). SSH key: `~/.ssh/id_k8s_vms`
(overridable via `K8S_VM_SSH_KEY_FILE` env var in `group_vars/all/all.yml`).

## Layout

```
inventory/ukubi/
├── README.md
├── hosts.yaml
├── group_vars/
│   ├── all/
│   │   └── all.yml
│   └── k8s_cluster/
│       ├── addons.yml
│       ├── k8s-cluster.yml
│       └── k8s-net-cilium.yml
└── credentials/
    ├── .gitignore   (already created — gitignores *.creds)
    └── .gitkeep     (already created — tracks the empty dir)
```

`credentials/kubeadm_certificate_key.creds` is auto-generated on the
first `cluster.yml` run via `lookup('password', ...)`.

## Key design decisions

- **Kubernetes 1.35.4** — matches the old libvirt ukubi-cluster apiserver
  so kubelet joins don't drift across minor versions during migration.
- **Single CP + single etcd member, stacked** — `etcd_deployment_type:
  kubeadm` (static pod managed by kubelet). Adding a second etcd member
  later means re-running `cluster.yml` (NOT `scale.yml` — that one
  doesn't include the control-plane join role).
- **Cilium chaining + kube-proxy** — `cilium_kube_proxy_replacement:
  false` and `cilium_enable_portmap: true` together produce chaining
  mode. kube-proxy keeps doing service-IP routing; Cilium does BPF
  policy + Hubble observability. Same pattern as the old libvirt
  cluster.
- **No `loadbalancer_apiserver_localhost`** — single CP, no dedicated
  workers to host the localhost nginx LB. `loadbalancer_apiserver.address`
  points at k8s-cp-01 itself.
- **MetalLB L2** — IP range `192.168.1.230-192.168.1.250`, well clear
  of node IPs (`.201-.203`) and the reserved API VIP (`.180`).
  `metallb_config.speaker.tolerations` lets the speaker run on the
  control plane.
- **Addon split** (locked): kubespray owns MetalLB / cert-manager /
  Gateway API CRDs / krew. ArgoCD owns Traefik, the NVIDIA device
  plugin, and all app workloads. Anything ArgoCD owns is explicitly
  `false` in `addons.yml` to prevent two managers from fighting.
- **GPU: kubespray skips the driver install** — the host on
  `k8s-worker-gpu` already has the driver, and the kubespray
  driver-install DaemonSet re-runs on every `cluster.yml`. The device
  plugin (`nvidia.com/gpu` capacity) is deployed by ArgoCD/Helm
  post-join.
- **TLS SANs** — `.201`, `.202`, `.203`, `k8s-proxmox-gpu.bnei.lan`,
  `k8s-proxmox-gpu.bnei.dev`. The reserved API VIP (`.180`) and the
  legacy libvirt IPs (`.181`, `.191`) are intentionally excluded — the
  test cert is separate from the libvirt one. Re-align these SANs to
  match the libvirt cluster's certs (and switch the endpoint to
  `k8s.bnei.lan`) once the libvirt cluster is fully drained and this
  one is promoted to primary.

## Run

Greenfield bootstrap only — run `cluster.yml` (NOT `scale.yml`; that one
is for adding nodes to an existing cluster and doesn't include the
control-plane join role).

Pre-flight:

```bash
# Confirm the 3 VMs are running on proxmox PVE
cv4pve-cli get vms --output json | jq '.[] | select(.name | test("k8s-")) | {name, vmid, status, node}'

# Confirm SSH + sudo work with the per-host key/user
ssh -i ~/.ssh/id_k8s_vms core@192.168.1.201 'hostname && sudo -n true && echo OK'
ssh -i ~/.ssh/id_k8s_vms core@192.168.1.202 'hostname && sudo -n true && echo OK'
ssh -i ~/.ssh/id_k8s_vms core@192.168.1.203 'hostname && sudo -n true && echo OK'
```

Bootstrap (the standard kubespray invocation; a `bin/run-kubespray.sh`
wrapper is a follow-up — not part of this PR):

```bash
cd infra-bootstrap
git submodule update --init --recursive
cd kubespray
ansible-playbook -i ../inventory/ukubi/hosts.yaml cluster.yml \
  --become --diff
```

After the first run, the kubeconfig is at `inventory/ukubi/artifacts/admin.conf`:

```bash
KUBECONFIG=/home/hermes/infra-bootstrap/inventory/ukubi/artifacts/admin.conf \
  kubectl get nodes -o wide
# Expect:
#   k8s-cp-01       Ready    control-plane,etcd,master,worker
#   k8s-worker-01   Ready    <none>
#   k8s-worker-gpu  Ready    <none>
```

## Post-join follow-ups

1. **NVIDIA device plugin** — deploy via ArgoCD/Helm (the
   `nvidia-device-plugin` chart). Verify with
   `kubectl describe node k8s-worker-gpu | grep nvidia.com/gpu` (should
   show 1 allocatable).
2. **ArgoCD install** — the App-of-Apps root lives in
   `MohammadBnei/k8s-cluster`. Initial install: `kubectl apply -n
   argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/...`
   (then hand off to GitOps).
3. **Traefik ingress** — deployed by ArgoCD, not kubespray
   (`ingress_nginx_enabled: false`). Fronts Services of type
   LoadBalancer / ClusterIP.
4. **Pi-hole DNS entries** — add A records:
   - `k8s-proxmox-gpu.bnei.lan` → `192.168.1.201`
   - `*.k8s-proxmox-gpu.bnei.lan` → `192.168.1.201` (or skip — usually
     just the apiserver is needed; Services get their own DNS via
     MetalLB L2).
5. **kubeconfig distribution** — copy `artifacts/admin.conf` to
   `~/kubeconfig-ukubi-new` (don't overwrite the live
   libvirt-ukubi kubeconfig at `~/kubeconfig` until you're ready to
   cut over).
6. **Update `docs/infrastructure-actual.md`** — flip the "old ukubi on
   libvirt" bullet to "ukubi on proxmox" once both clusters are stable,
   and add the 3 new node hostnames / IPs / roles.

## Open questions / risks

- **Single control plane = no HA.** The CP VM is a single point of
  failure. Acceptable for the new build; revisit by adding a second
  CP+etcd node (re-run `cluster.yml` against the new inventory, since
  `scale.yml` doesn't include the control-plane join role).
- **Endpoint alignment to `k8s.bnei.lan` is deferred.** This build
  uses `k8s-proxmox-gpu.bnei.lan` and `k8s-proxmox-gpu.bnei.dev` for
  test-cluster isolation. Once the libvirt cluster is fully drained,
  re-issue the apiserver cert with the old SANs and update the
  `apiserver_loadbalancer_domain_name` to `k8s.bnei.lan` so external
  clients don't need a reconfigure.
- **`cluster.local` default DNS domain.** Preserves kubelet join
  compatibility but means Services from this cluster collide with
  Service FQDNs from the libvirt cluster in DNS caches and in any
  tool that doesn't namespace by cluster. Acceptable while workloads
  are segregated; revisit by switching to `cluster.ukubi.local`
  (requires `cluster_name` change + cert rotation).
- **MetalLB L2 IP range assumption.** The pool `192.168.1.230-.250`
  is on the same L2 broadcast domain as the node IPs. If the Freebox
  or any switch in the path starts filtering gratuitous ARPs, MetalLB
  announcements will silently break. Validate with
  `kubectl logs -n metallb-system -l component=speaker` after first
  LoadBalancer Service.
- **No kubespray submodule bump.** The pinned submodule is
  `v2.23.0-1497`; the design intent target is v2.31. Some of the
  variable names used in the locked choices (`cilium_chaining_mode`,
  `kube_proxy_replace`) do not exist in v2.23 — this inventory
  translates them to the v2.23 equivalents (`cilium_enable_portmap:
  true`, `cilium_kube_proxy_replacement: false`). A submodule bump to
  v2.31 is a separate PR (do not combine with inventory changes).
- **No GPU validation yet.** The device plugin is post-join. Until
  ArgoCD deploys it, `kubectl describe node k8s-worker-gpu` won't show
  `nvidia.com/gpu` capacity.
