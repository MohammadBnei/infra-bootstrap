# Infrastructure — Desired State

> **Source of truth** for the target architecture.
> Last updated: 2026-06-04
> Owner: hermesagent (this AI)

This document describes the **target, to-be** state of the homelab infrastructure.
For the current state, see [`infrastructure-actual.md`](./infrastructure-actual.md).

---

## 1. Guiding Principles

1. **K8s nodes are QEMU VMs, never LXC** — for kernel isolation, GPU passthrough, CNI compat, debuggability
2. **Other services (Postgres, Garage, etcd) run as LXC** — lighter, no need for full VM
3. **Always-on quorum with off-host witness** — Pi 4 provides 3rd vote for HA
4. **Pigsty for Postgres orchestration** — production-grade HA, backups, monitoring out of the box
5. **NFS for shared storage, not Ceph** — homelab scale doesn't need Ceph complexity
6. **Single flat LAN** — Freebox Revolution has no VLANs; IP allocation by role, not by subnet
7. **Single cutover event** — downtime is allowed; cleaner than rolling migration

---

## 2. Physical Hosts

| Host | IP | Target OS | Role |
|---|---|---|---|
| **proxmox** (bnei) | 192.168.1.165 | KEEP PVE 9.2.3 | PVE host: GPU worker VM + standard K8s VMs + Postgres LXC + Garage LXC |
| **server1** (server) | 192.168.1.200 | **REINSTALL PVE 9.2** | PVE host: K8s worker VM + Postgres LXC + NFS server (host-level) |
| **ex-laptop** | 192.168.1.161 | **REINSTALL Debian 13 (trixie)** | Cold spare, fresh OS, no libvirt/KVM |
| **Pi 4** | 192.168.1.55 | **REINSTALL Debian 13 (trixie) — fresh** | etcd witness + Pi-hole (clean install, no pre-existing PG) |

### Why this layout
- **2 PVE hosts** for K8s + DBs (postgres quorum with off-host witness)
- **Pi 4** as off-host etcd witness — independent hardware, power source
- **ex-laptop** kept as cold spare (15GB is too tight for active role, but useful for emergencies)
- **Backup target**: 149GB HDD on server1 (replacing dead Ceph OSD)
- **Fresh installs** on ex-laptop and Pi 4 — no legacy state to migrate, clean slate for target roles

---

## 3. PVE Hosts — Resource Allocation

### proxmox PVE (192.168.1.165)
**Total: 32GB RAM, 12 threads, 2× NVMe 1TB**

| VM/LXC | Type | vCPU | RAM | Disk | Notes |
|---|---|---|---|---|---|
| postgres-data-1 | LXC | 2 | 4GB | 40GB | Pigsty, primary/replica |
| k8s-cp-01 | VM (Q35, OVMF) | 2 | 4GB | 40GB | Ubuntu 24.04 |
| k8s-worker-gpu | VM (Q35, OVMF) | 6 | 16GB | 100GB | RTX 2070 SUPER PCIe passthrough |
| k8s-worker-01 | VM (Q35, OVMF) | 4 | 8GB | 60GB | Ubuntu 24.04 |
| garage-storage | LXC | 2 | 2GB | 200GB | S3-compatible, on NVMe |

**Reserved for host:** ~3GB PVE overhead, ~1GB buffer
**PVE host has full eBPF hardware support** (AMD Ryzen)

### server1 PVE (192.168.1.200, after reinstall)
**Total: 32GB RAM, 6 threads, NVMe 476GB + HDD 149GB**

| VM/LXC | Type | vCPU | RAM | Disk | Notes |
|---|---|---|---|---|---|
| postgres-data-2 | LXC | 2 | 4GB | 40GB | Pigsty, replica |
| k8s-worker-02 | VM (Q35, OVMF) | 4 | 8GB | 60GB | Ubuntu 24.04 |
| (NFS server) | host-level | — | — | — | Existing NFS export maintained |

**Reserved for host:** ~3GB PVE overhead, ~1GB buffer
**Note:** server1 CPU lacks eBPF hardware support — Cilium runs in chaining mode (with kube-proxy) on this host

### Pi 4 (192.168.1.55) — fresh Debian 13 install
**Total: 1.8GB RAM, 4 cores @ 1.5GHz, microSD 238GB**

| Service | Notes |
|---|---|
| etcd-witness | Patroni quorum, no Postgres data, ~80MB RAM |
| Pi-hole | Local DNS, authoritative for `*.bnei.lan`, ~50MB RAM |
| node_exporter | Optional, for monitoring, ~10MB RAM |

**Clean install approach:** start from a bare Raspberry Pi OS / Debian 13 image, install only the services that have a role. No pre-existing test setup to migrate.

#### Pi 4 resource budget (1GB free)
- etcd-witness: ~80MB RAM, ~50MB disk
- Pi-hole: ~50MB RAM, ~10MB disk
- node_exporter (optional): ~10MB RAM
- **Total: ~140MB** — leaves 800MB+ headroom, safe

#### What gets wiped (intentional, no data loss)
- The pre-existing PostgreSQL 18.1 install on the Pi 4 — **failed install, no data** (confirmed by user)
- Docker, containerd (not needed on the Pi 4)
- All accumulated configs and data
- Clean slate for etcd-witness + Pi-hole deployment
- **No migration concerns** — there is no production data on the Pi 4

### ex-laptop (192.168.1.161) — fresh Debian 13 install
- **No active role** — kept as cold spare / emergency node
- **Fresh Debian 13 (trixie)** — no libvirt/KVM, no K8s node4 VM
- Can be repurposed for backup verification, DR drill, or emergency replacement
- Minimal install: SSH server, node_exporter (optional), no other services

---

## 4. Kubernetes Cluster (Desired)

**Cluster name:** `ukubi-cluster` (preserve name)
**Topology:** 1 control plane + 3 workers (single CP accepted for homelab)
**K8s version:** Latest stable (currently 1.31+)
**Container runtime:** containerd
**Deploy method:** kubespray (wraps kubeadm; idempotent, multi-node aware, handles the off-eBPF + kube-proxy chaining out of the box)
**CNI:** Cilium in **chaining mode with kube-proxy** (because not all nodes have eBPF)
**Ingress:** Traefik
**LoadBalancer:** MetalLB
**TLS:** cert-manager + Let's Encrypt (`*.bnei.dev`)
**GitOps:** ArgoCD pointing at `github.com/MohammadBnei/k8s-cluster`

### Nodes (target)
| Node | Type | Host | IP (planned) | Resources | Notes |
|---|---|---|---|---|---|
| k8s-cp-01 | VM | proxmox | TBD | 2 vCPU / 4GB | Control plane (sole) |
| k8s-worker-gpu | VM | proxmox | TBD | 6 vCPU / 16GB | GPU passthrough, NVIDIA device plugin |
| k8s-worker-01 | VM | proxmox | TBD | 4 vCPU / 8GB | Standard workloads |
| k8s-worker-02 | VM | server1 | TBD | 4 vCPU / 8GB | Standard workloads, no eBPF |

### CNI Decision: Cilium chaining mode
- **Reason:** Only proxmox PVE has eBPF hardware support. Other nodes (server1 CPU) lack it.
- **Solution:** Run Cilium with `bpf.masquerade=false` and chain with kube-proxy. No kube-proxy-replacement.
- **Alternative considered:** Flannel (simpler, but no L7 policy, no Hubble). Rejected for observability loss.
- **Alternative considered:** Calico (no eBPF needed). Rejected because Cilium already in repo.

### GPU support
- RTX 2070 SUPER at PCI `0b:00.0` passed through to `k8s-worker-gpu`
- All 4 functions passed with `multifunction=on` (GPU + Audio + USB + USB-C)
- NVIDIA driver + container toolkit installed inside the VM
- NVIDIA Device Plugin deployed via Helm
- GPU workloads scheduled via taints/tolerations

### App stack (preserved from existing repo)
- argocd (gitops)
- cert-manager (TLS)
- traefik (ingress)
- prometheus + grafana (monitoring)
- infisical + secrets-operator
- cilium + hubble
- coredns-cache
- deployment-monitor-operator
- dozzle (logs)
- jaeger (tracing)
- searxng
- n8n, openweb-ui, firecrawl, wekan, editableblog, dream-analyst, ukubi-ai
- api, metricsAPI
- redis, pgweb

---

## 5. Database (Desired)

**Stack:** PostgreSQL 18 + Pigsty 3.x (Patroni + etcd + PgBouncer + pgBackRest)

### Topology
- **2 data nodes** + **1 off-host witness** = 3-node etcd quorum
- Witness on Pi 4 (off-host) ensures quorum survives any single PVE host failure

| Node | Type | Host | Role |
|---|---|---|---|
| postgres-data-1 | LXC | proxmox PVE | Patroni primary/replica |
| postgres-data-2 | LXC | server1 PVE | Patroni primary/replica |
| etcd-witness | bare metal | Pi 4 | Quorum vote only, no data |

### Pigsty provides
- Patroni for automatic failover
- 3-node etcd cluster (2 data + 1 witness)
- Streaming replication (default) or logical (if needed)
- pgBackRest for backups (PITR-capable)
- PgBouncer for connection pooling
- Built-in Grafana dashboards
- pg_exporter for Prometheus
- Auto DNS-based service discovery (no hardcoded IPs)

### Migration from current
- Source: standalone PG 16.4 at 192.168.1.193 (~7.2GB)
- Method: Pigsty bootstrap with source as initial primary, then add replicas
- Cutover: brief read-only window (~5 min), update K8s secrets, restart pods
- Rollback: source VM kept running read-only for 1 week

### Backups (pgBackRest)
- **Local:** on each data LXC
- **Off-host:** to 149GB HDD on server1 (dedicated backup target)
- **Schedule:** daily full + WAL archiving continuous
- **Retention:** 7 daily, 4 weekly, 3 monthly
- **PITR:** any point in last 7 days

---

## 6. Storage (Desired)

### NFS (K8s PVs only)
- **Server:** server1 (host-level, after PVE install)
- **Export:** same path as current (`/home/mohammad/.local/share/k8s-nfs`)
- **Used by:** K8s ReadWriteMany PVs for application data
- **Postgres NOT on NFS** — local on each data LXC

### Garage (object storage)
- **Where:** LXC on proxmox PVE, NVMe-backed
- **Size:** 200GB allocated
- **API:** S3-compatible
- **Endpoint:** `s3.bnei.dev` via Traefik
- **Replaces:** MinIO (archived Jan 2026)
- **Single node initially** — can scale to 2-3 nodes later
- **Why Garage:** Rust single-binary, lightweight, designed for self-hosting, MIT-licensed, active dev

### Backup target
- **149GB HDD on server1** — wipe old Ceph OSD, format as ext4 or ZFS
- **Used by:** pgBackRest off-host, Proxmox backups, Velero (K8s PV backups if added)

### Proxmox storage
- `local` (directory): unchanged
- `local-lvm` (LVM-thin): VM disks, thin-provisioned
- **Future:** consider ZFS for new local storage pool (better snapshots)

---

## 7. Networking

### Topology
- **Single flat LAN:** `192.168.1.0/24` (Freebox has no VLANs)
- **Gateway:** Freebox (192.168.1.254)
- **No reservations** — existing devices already occupy IPs; new nodes use free addresses on the LAN

### IP allocation (by role, not subnet)
- `.1` Freebox
- `.20-.49` Hosts (proxmox, server1, ex-laptop, Pi 4)
- `.50-.99` Static infra (NFS, etcd cluster, postgres primary, witness, garage)
- `.100-.199` VMs and LXCs (K8s nodes, Postgres LXCs, services)
- `.200-.254` Freebox DHCP (workstations, mobile, IoT)

Specific IPs assigned during implementation, not pre-allocated.

### Bridges
- `vmbr0` on each PVE host (LAN bridge)
- LXC/VM network: bridged via `vmbr0` (no NAT, no internal libvirt network)

### inter-PVE
- All on the same LAN segment, no dedicated link
- (Future improvement: dedicated 10GbE link for storage traffic — not in scope for now)

---

## 8. DNS (Desired)

### Local DNS — Pi-hole on Pi 4
- **Authoritative for:** `bnei.lan` zone (internal hostnames)
- **Forwards external:** to 8.8.8.8 / Cloudflare
- **Freebox DHCP** points to Pi 4 as primary DNS

### Public DNS
- `bnei.dev` managed by external registrar (Cloudflare, etc.)
- Wildcard `*.bnei.dev` for public services
- Cert-manager + Let's Encrypt for TLS

### Records (target)
```
A    proxmox.bnei.lan        → 192.168.1.165
A    server1.bnei.lan        → 192.168.1.200
A    pi4.bnei.lan            → 192.168.1.55
A    postgres-1.bnei.lan     → <assigned>
A    postgres-2.bnei.lan     → <assigned>
A    etcd-witness.bnei.lan   → 192.168.1.55
A    nfs.bnei.lan            → 192.168.1.200
A    garage.bnei.lan         → <assigned>
A    k8s-cp-01.bnei.lan      → <assigned>
A    *.bnei.dev              → public IP / router
```

---

## 9. Identity & Access

### Proxmox
- API tokens per host (already exists for proxmox)
- New token needed for server1 (after PVE install)

### SSH
- Per-host keys for each VM/LXC
- Bastion pattern: hermesagent LXC → all hosts/VMs

### K8s
- New service accounts per app
- Infisical for app secrets (already in stack)

### TLS
- Wildcard cert `*.bnei.dev` via cert-manager + Let's Encrypt
- Internal certs via internal CA (for Postgres, etcd, etc.)

---

## 10. Observability (Desired)

- **Prometheus + Grafana** in K8s (existing setup)
- **pg_exporter** on Postgres (via Pigsty)
- **node_exporter** on every host (Pi 4, ex-laptop, PVE hosts)
- **Hubble** for Cilium L3/L4 observability
- **Loki + Promtail** for centralized logging (consider adding)
- **Alertmanager** for critical alerts (Postgres down, disk full, etc.)

---

## 11. Backup Strategy (Desired)

| Data | Method | Target | Frequency | Retention |
|---|---|---|---|---|
| Postgres (full + WAL) | pgBackRest | local + 149GB HDD on server1 | daily + continuous WAL | 7d/4w/3m |
| K8s manifests | Git | github.com/MohammadBnei/k8s-cluster | on commit | indefinite |
| K8s PVs | Velero (if added) | NFS or Garage | daily | 7 daily |
| Proxmox config | cron + tar | NFS or backup HDD | daily | 7 daily |
| Pi-hole config | restic | NFS or backup HDD | daily | 7 daily |
| `/home/mohammad` | restic | NFS or backup HDD | daily | 7 daily |

**Backup verification:** monthly restore test to a sandbox VM.

---

## 12. Out of Scope (Explicitly)

- **Ceph** shared storage — NFS sufficient for homelab scale
- **Multi-region / DR** — single-site homelab
- **GPU multi-tenancy** — single GPU, single node
- **Service mesh** (Linkerd/Istio) — not needed
- **External managed Postgres** — self-hosted only
- **Wireguard / Tailscale** — not in design (existing remote access pattern unchanged)
- **GitOps for Proxmox** — Proxmox managed manually + via cv4pve-cli

---

## 13. Migration Cutover Order (Reference)

The full phased migration plan lives in a separate document (to be created when execution starts). Reference order:

1. **Phase 0:** Backups, Pi 4 setup, source Postgres dump
2. **Phase 1:** Build new K8s cluster on proxmox PVE only (1 CP + 3 workers, GPU ready)
3. **Phase 2:** Migrate K8s workloads via ArgoCD reconciliation
4. **Phase 3:** Reinstall server1 as PVE
5. **Phase 4:** Build new Postgres cluster (Pigsty) — 2 data LXC + Pi 4 witness
6. **Phase 5:** Postgres cutover (apps point at new cluster)
7. **Phase 6:** Deploy Garage on proxmox PVE
8. **Phase 7:** Finalize Pi-hole + local DNS
9. **Phase 8:** Validate, decommission old infrastructure

---

_This document is the design intent. Actual state may diverge temporarily during migration. Always update both this and `infrastructure-actual.md` when changes are made._
