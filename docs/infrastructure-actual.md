# Infrastructure — Actual State

> **Source of truth** for what is currently running.
> Last updated: 2026-07-14
> Owner: hermesagent (this AI)

This document describes the **current, as-is** state of the homelab infrastructure.
For the target architecture, see [`../ARCHITECTURE.md`](../ARCHITECTURE.md).

---

## 1. Physical Hosts

| Host | IP | OS | Kernel | CPU | RAM | Disks | GPU | Role |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **proxmox** (bnei) | 192.168.1.165 | PVE 9.2.3 (Debian 13) | 7.0.6-2-pve | AMD Ryzen 5 3600X (6C/12T) | 31GB | 2× NVMe 1TB + 2× SATA SSD 1TB | NVIDIA RTX 2070 SUPER (PCI 0b:00.0) | PVE host |
| **server1** (server) | 192.168.1.200:2222 | Debian 12 (bookworm) | 6.12.12+bpo-amd64 | Intel i5-8500 (6C/6T) | 31GB | NVMe 476GB (root) + HDD 149GB (Ceph OSD leftover) | Intel UHD 630 | libvirt/KVM host |
| **ex-laptop** | 192.168.1.161:2222 | Debian 12 (bookworm) | 6.1.0-41-amd64 | Intel i7-5500U (2C/4T) | 15GB | SSD 238GB (root) | Intel HD 5500 + AMD R7 M265 | libvirt/KVM host |
| **Pi 4** (raspberry) | 192.168.1.55 | Debian 13 (trixie) | 6.12.62+rpt-rpi-v8 | Cortex-A72 (4C/4T) | **1.8GB** | microSD 238GB (mmcblk0) | none | Test/dev node: PG 18 + Docker |

### Network

- LAN: `192.168.1.0/24`
- Gateway: `192.168.1.254` (Freebox Revolution)
- DNS: `192.168.1.254` (Freebox), fallback `8.8.8.8`
- All hosts on single flat LAN — no VLANs
- IP range partially occupied by existing devices (no clean reservation possible)

### Proxmox host details

- Hostname: `bnei`
- Bridge: `vmbr0` (192.168.1.165/24, gateway .254)
- NIC renamed: `nic0` (physical), `nic1` (unused)
- IOMMU: AMD-Vi **enabled and working** (verified 2026-07-14: 16 IOMMU
  groups exist; before this date it was disabled in BIOS and `lspci`'s
  "IOMMU available" claim was actually false — 0 groups existed). Enabled
  under AMD CBS → NBIO Common Options.
- Storage: LVM with `pve` volume group, `local-lvm` thinpool
- Running LXCs:
  - VMID 101 `hermesagent` (2 vCPU / 4GB / 19GB) — this AI
  - VMID 301 `garage-storage` (2 vCPU / 2GB / 200GB) — running, not yet configured
- Running VMs (Postgres):
  - VMID 205 `pg01` (2 vCPU / 4GB / 40GB) — IP: 192.168.1.205 — Pigsty PG 18 primary
  - VMID 207 `pg02` (2 vCPU / 4GB / 40GB) — IP: 192.168.1.207 — Pigsty PG 18 replica + Redis
- Template: VMID 9001 `ubuntu-24.04-ci-template` (Golden cloud-init
  template, rebuilt 2026-07-12 with qemu-guest-agent fix — see
  docs/bootstrap-test-notes.md). VMID 9000 is the original hand-created
  template, now an unmanaged spare, not deleted.
- ceph-fuse 19.2.3-pve4 (client only, no active cluster)

#### GPU passthrough (2026-07-14)

RTX 2070 SUPER, PCI `0b:00`, all 4 functions (VGA `.0`, Audio `.1`, USB
`.2`, USB-C `.3`) bound to `vfio-pci`, sharing IOMMU group 2 along with
their upstream PCIe bridge. Enforced on every boot by
`vfio-pci-bind-gpu.service` (`/usr/local/bin/vfio-pci-bind-gpu.sh`) — the
plain `options vfio-pci ids=...` in `/etc/modprobe.d/vfio.conf` alone
only wins the driver-claim race for some of the 4 functions on a given
boot, so the service force-unbinds/rebinds all 4 via `driver_override`
after boot. The host runs **no NVIDIA driver at all** — a prior attempt
installed one directly on the host (plus `pve-nvidia-vgpu-helper`, a
vGPU/mediated-device helper) which was the wrong approach for this
design and has been purged; see
[ADR-0011](../docs/adr/0011-reject-multi-region-dr-service-mesh.md) for
why GPU multi-tenancy (vGPU) is rejected here. Secure Boot is enabled and
untouched — it was never the actual blocker (see
`docs/bootstrap-test-notes.md`'s 2026-07-14 entry for the full story).

The PVE PCI Resource Mapping `gpu` exists
(`node=bnei,path=0000:0b:00,id=10de:1e84,iommugroup=2`), and
`terraform/k8s-vms.tf`'s `hostpci0` block on `k8s-worker-01` is
re-enabled (not yet merged/applied). **Not yet attached to any VM** —
`k8s-worker-01` doesn't exist yet, so the GPU is passthrough-ready but
idle.

Raw PCI/VFIO passthrough is exclusive by construction: the GPU can be
attached to only one VM at a time. Once `k8s-worker-01` holds it,
Proxmox refuses to start any other VM/LXC against the same mapping — this
is deliberately not vGPU-style sharing across multiple VMs.

### Pi 4 (raspberry) details

- Hostname: `raspberry`
- IP: `192.168.1.55` (DHCP-assigned, NOT `.170` as initially planned)
- OS: **Debian 13 (trixie)** on aarch64
- Kernel: 6.12.62+rpt-rpi-v8 (Raspberry Pi kernel)
- CPU: Cortex-A72, 4 cores @ 1.5GHz max, 1 thread per core
- RAM: **1.8GB total** (2GB Pi 4 model) — 770MB used, ~1GB available
- Storage: 238GB microSD (mmcblk0p2 ext4, 210GB free)
- Swap: 1.8GB zram (compressed)
- Network: eth0 only (wlan0 down, no wireless in use)
- DNS: 8.8.8.8 / 1.1.1.1 (direct, not via Freebox)

#### Running services on Pi 4

- **PostgreSQL 18.1 (main cluster, port 5432)** — **failed install, no data**
  - Data directory: `/var/lib/postgresql/18/main`
  - Installed from PGDG repo (`postgresql-18-18.1-1.pgdg13+2`)
  - Cluster started but never used; safe to wipe without data loss concerns
- **Docker** + **containerd** — container runtime present (to be removed on reinstall)
- **kubectl v1.32.3** client only (no kubelet)
- NetworkManager, ssh, cron, avahi, bluetooth
- No kubelet, no etcdctl, no pigsty, no NFS exports

#### Pi 4 — what it means for design

- PG 18 install exists but is empty (failed install) — **no migration needed for that data**
- Only **1GB free RAM** — enough for Pi-hole / lightweight DNS duties
- No GPU, no IPMI, no BMC
- 238GB microSD is enough for DNS cache + small logs
- Off-host power/network (separate power brick, separate network drop) — useful for lightweight infra helpers
- **Reinstall plan:** full wipe, fresh Debian 13, install Pi-hole if kept in service

---

## 2. Container & VM Runtime

| Layer | Actual | Notes |
| --- | --- | --- |
| PVE nodes | 1 (proxmox .165 only) | server1 + ex-laptop still Debian 12 + libvirt — PVE reinstall pending |
| K8s nodes | libvirt LXCs on server1 (.200) + ex-laptop (.161) | No new QEMU K8s VMs created yet |
| Postgres | QEMU VMs on proxmox PVE (.165) | pg01 VMID 205 (.205) + pg02 VMID 207 (.207) |
| Garage | LXC on proxmox PVE (.165) | VMID 301, running, not configured |

---

## 3. Kubernetes Cluster (Current)

**Cluster name:** `ukubi-cluster`
**API endpoint:** `https://192.168.1.181:6443`
**K8s version:** v1.35.4
**Container runtime:** containerd 2.2.3
**CNI:** Cilium (with Hubble)
**GitOps:** ArgoCD
**Manifests repo:** github.com/MohammadBnei/k8s-cluster

### Nodes (current)

| Node | Role | IP | OS | Where it runs |
| --- | --- | --- | --- | --- |
| node1 | control-plane + worker | 192.168.1.181 | Debian 12 | libvirt VM on server1 *(legacy — will be decommissioned after PVE reinstall)* |
| node4 | control-plane + worker | 192.168.1.191 | Debian 12 | libvirt VM on ex-laptop *(legacy — will be decommissioned after PVE reinstall)* |

**Status:** Legacy cluster is the only running cluster — all apps healthy. No new QEMU K8s VMs created yet (persistently). The kubespray v2.23/v2.31 mismatch (Q-D) that previously blocked new-cluster provisioning was fixed 2026-07-12 — see `docs/bootstrap-test-notes.md`; multiple full `cluster.yml` smoke-test bootstraps (07-12 through 07-14) have since run clean end-to-end, but each was test/teardown, not a permanent cutover.

### Workloads

- **GitOps:** ArgoCD (multiple pods)
- **Ingress:** Traefik
- **TLS:** cert-manager + Let's Encrypt (legacy; new cluster will use Traefik ACME HTTP-01)
- **LoadBalancer:** MetalLB
- **Monitoring:** Prometheus + Grafana
- **Networking:** Cilium + Hubble
- **Secrets:** Infisical
- **Storage:** NFS subdir provisioner (mounted from server1)
- **Apps:** openweb-ui, n8n, firecrawl, wekan, editableblog, dream-analyst, ukubi-ai, etc.

### Known issues

- **No dedicated workers** — workloads run on control-plane nodes (libvirt VMs acting as both CP + worker)
- **No GPU support yet** — `k8s-worker-01` (the new cluster's GPU
  passthrough target, see "GPU passthrough" under Proxmox host details
  above) doesn't exist yet; the host side is passthrough-ready
- **Legacy runtime** — K8s nodes are libvirt VMs on .200/.161; new cluster will use QEMU VMs on PVE
- **New cluster not yet cut over** — kubespray v2.23/v2.31 mismatch (Q-D) fixed 2026-07-12; smoke tests pass but no permanent cluster exists yet

### Access (current)

- SA token: `ukubi-sa` in namespace `ukubi-system`
- Token expires: 2036-08-12
- Kubeconfig saved at `/home/hermes/kubeconfig`
- `kubectl` v1.36.1 installed at `/tmp/kubectl`

---

## 4. Database (Current)

**Stack:** PostgreSQL 18 managed by Pigsty. Migration from PG 16.4 at `.193` complete (2026-07). Source VM decommissioned.

### Nodes

| Node | VMID | IP | Host | Role |
| --- | --- | --- | --- | --- |
| pg01 | 205 | 192.168.1.205 | proxmox .165 | Pigsty primary |
| pg02 | 207 | 192.168.1.207 | proxmox .165 | Pigsty replica + Redis |

Both VMs are QEMU on the same PVE host (.165) — **single point of failure for the DB tier until pg02 moves to server1 PVE.**

### HA status

- **Replication:** streaming replication active (master → replica)
- **Topology:** simple primary/replica, no witness node
- **Failover:** manual only; no quorum-based automatic failover

### Migrated databases (from source .193 ~7.2GB)

| Database | Approx size | Owner | Used by |
| --- | --- | --- | --- |
| vos-monolith | 3.2GB | dbuser_vocOn | Vosk-On (speech recognition) |
| vos-monolith-dev | 3.1GB | dbuser_vocOn | Vosk-On dev |
| openwebdb | 481MB | dbuser_openwebui | OpenWebUI |
| n8ndb | 74MB | dbuser_n8n | n8n |
| infisicaldb | 60MB | dbuser_infisical | Infisical secrets |
| editableblogdb | 34MB | dbuser_blog | Blog app |
| n8nuserdb | 24MB | dbuser_n8n | n8n users |
| meta | 21MB | postgres | Meta (legacy) |
| metabase_db | 20MB | metabase_user | Metabase analytics |
| mongodb | 12MB | dbuser_mongo | MongoDB-style data |
| dream_analyst_db | 11MB | dbuser_dreamAnalyst | Dream Analyst app |
| (4 more, ~9MB each) | | | Metabase, Jaeger, etc. |

### Additional services on pg02

- **Redis** — co-located on pg02 (192.168.1.207); purpose TBD

### Users

25 roles in Pigsty convention (`dbuser_*` per app) + Supabase roles + replication roles. Migrated from source cluster.

### Extensions

Standard set: pg_stat_statements, pg_trgm, pg_repack, postgres_fdw, etc. (17 total)

### Next steps

- After server1 (.200) PVE reinstall: migrate pg02 to server1 (splits data tier across 2 hosts)

---

## 5. Storage (Current)

### NFS

- **Server:** server1 (192.168.1.200)
- **Export:** `/home/mohammad/.local/share/k8s-nfs` → `192.168.1.200/24`
- **Used by:** K8s cluster (NFS subdir provisioner for PVs)
- **Service:** NFSv4 (rpcbind, nfs-mountd, nfs-idmapd running)

### Ceph (dead)

- **OSD present** on server1 HDD (`/dev/ceph-dfb021ce.../osd-block-...`)
- **No active cluster** — no monitors, no mgr, no OSDs daemon running
- **Leftover** from previous attempt
- **Reclaimable** — HDD can be wiped and repurposed

### Proxmox storage

- `local` (directory): `/var/lib/vz`
- `local-lvm` (LVM-thin): for VM disks on proxmox PVE

---

## 6. Object Storage

- **None currently deployed**
- User wants MinIO replacement (MinIO was archived Jan 2026)
- Plan: Garage (Deuxfleurs, Rust, S3-compatible)

---

## 7. Network Services (Current)

### DNS

- **Primary:** Freebox (192.168.1.254) — basic, no wildcards, no internal zones
- **Local resolver:** None — relies on Freebox

### Load Balancer / Reverse Proxy

- **HAProxy on server1** (port 8000, 8443)
  - Fronting the existing K8s services
  - SPICE ports 5900/5901 for libvirt VMs

### Firewall

- Freebox basic firewall
- iptables on each host (default policies)

---

## 8. Backup (Current)

- **No structured backup strategy**
- Postgres: not backed up externally
- K8s manifests: in git (github.com/MohammadBnei/k8s-cluster)
- Proxmox config: not backed up
- /home/mohammad, K8s PVs: not backed up

**Critical gap.** Identified in the discovery scan.

---

## 9. Identity & Access

### Proxmox

- API user: `hermes@pve`
- Role: `PVEVMAdmin` (VM lifecycle, GPU passthrough)
- Token saved at `/home/hermes/.proxmox_api`
- `cv4pve-cli` v2.2.1 installed and configured for `bnei` context

### SSH

- Access from LXC 101 (hermesagent) to:
  - server1: `mohammad@192.168.1.200:2222`
  - ex-laptop: `mohammad@192.168.1.161:2222`
- K8s VMs SSH key: `~/.ssh/id_k8s_vm` (user: `ubuntu`)
- SSH on LXC 101: standard port 22

### K8s

- Service account: `ukubi-sa` in `ukubi-system`
- Token expires 2036

### GitHub

- Token in `~/.config/gh/hosts.yml`
- Access to `MohammadBnei/k8s-cluster` repo

---

## 10. Observability (Current)

- **Prometheus + Grafana** running in K8s (in `ukubi-cluster`)
- **pg_exporter** running on Postgres VM (user `dbuser_monitor`)
- **No node-level monitoring** on hosts (no node_exporter)
- **No centralized logging**

---

## 11. Open Items / Gaps

1. **ex-laptop k8s-03 LXC** — was destroyed (was a failed LXC K8s attempt, never joined cluster)
2. ~~**Pi 4** — present in user's network but not yet inventoried~~ — **RESOLVED** (see Pi 4 section above; PG 18 already installed)
3. **Server1 K8s VM details** — node1 (192.168.1.181) is on server1 but exact VM specs unknown
4. **Existing apps** — many apps run on ukubi-cluster, need to enumerate before migration
5. **Backup target** — no off-host backup location
6. **Freebox features** — has admin access but limited capabilities (Revolution model)

---

## 12. Out of Scope (Current)

- Multi-region / DR
- Service mesh
- GPU multi-tenancy
- External managed services

---

*This document evolves as the actual state changes. Always update this file when making infrastructure changes — it is the source of truth for what exists.*
