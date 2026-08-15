# Infrastructure — Actual State

> **Source of truth** for what is currently running.
> Last updated: 2026-08-04
> Owner: hermesagent (this AI)
>
> **Stale-sections flag (2026-07-28, §2/§3 K8s-nodes part resolved
> 2026-07-30):** `server1` and `ex-laptop` were both reinstalled to PVE
> and joined the corosync cluster with `.165` (see ADR-0024,
> `ansible/inventories/proxmox/hosts.yml`). A full OS reinstall wipes
> whatever ran directly on the prior Debian 12/libvirt install — §2's
> "K8s nodes" row and §3's node table are now confirmed live (real QEMU
> `ukubi-cluster` nodes, not the old libvirt ones). **Resolved
> 2026-07-30 (this pass):** §3's K8s cluster is now the real 3-CP/etcd
> HA topology, confirmed live via `kubectl get nodes` + kube-vip; §4's
> Postgres/etcd is now a real 3-node DCS quorum, confirmed live via
> `etcdctl`/`patronictl` (ADR-0029). §5's old `server1` NFS export and
> §7's old HAProxy entry are both gone (server1's reinstall wiped the
> host they ran on) — kept below only as a historical record, clearly
> marked; do not rely on either.
>
> **2026-08-04 pass:** refreshed against `gitops/`, ADR-0026 (`nfs-storage`
> shared template storage), ADR-0030 (Garage S3 external exposure), and
> the ArgoCD app inventory — this pass is a doc/git-record reconciliation
> (ADRs, `gitops/`, `docs/bootstrap-test-notes.md`), not a fresh live
> `kubectl`/`ssh` scan; anything not re-verified live still says so
> inline.

This document describes the **current, as-is** state of the homelab infrastructure.
For the target architecture, see [`../ARCHITECTURE.md`](../ARCHITECTURE.md).

---

## 1. Physical Hosts

| Host | IP | OS | Kernel | CPU | RAM | Disks | GPU | Role |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **proxmox** (bnei) | 192.168.1.165 | PVE 9.2.3 (Debian 13) | 7.0.6-2-pve | AMD Ryzen 5 3600X (6C/12T) | 31GB | 2× NVMe 1TB + 2× SATA SSD 1TB | NVIDIA RTX 2070 SUPER (PCI 0b:00.0) | PVE host |
| **server1** (server) | 192.168.1.200:2222 | PVE 9.2 (reinstalled, ext4 root + `local-lvm`, no ZFS — [ADR-0024](adr/0024-server1-single-disk-ext4-no-dedicated-zfs.md)) | TBD (PVE default) | Intel i5-8500 (6C/6T) | 31GB | NVMe 476GB (root); 149GB HDD physically removed pre-reinstall | Intel UHD 630 | PVE host, joined corosync cluster with `.165` |
| **ex-laptop** | 192.168.1.161:2222 | PVE 9.2 (reinstalled) | TBD (PVE default) | Intel i7-5500U (2C/4T) | 15GB | SSD 238GB (root, `zfs-exlaptop` pool per ADR-0014) | Intel HD 5500 + AMD R7 M265 | PVE host, joined corosync cluster with `.165` |
| **Pi 4** (raspberry) | 192.168.1.55 | Debian 13 (trixie) | 6.12.62+rpt-rpi-v8 | Cortex-A72 (4C/4T) | **1.8GB** | microSD 238GB (mmcblk0) | none | Test/dev node: PG 18 + Docker |

### Network

- LAN: `192.168.1.0/24`
- Gateway: `192.168.1.254` (Freebox Revolution)
- DNS: `192.168.1.254` (Freebox), fallback `8.8.8.8`
- All hosts on single flat LAN — no VLANs
- IP range partially occupied by existing devices (no clean reservation possible)

#### Link speeds — `.165` is at 100 Mbps, and it is the estate's bottleneck

**Measured 2026-08-15** (`ethtool`). No link speed had ever been recorded for
any host here before this.

| Host | Link | NIC |
| --- | --- | --- |
| **proxmox `.165` (bnei)** | **100 Mb/s** | onboard Realtek RTL8168H (`r8169`) |
| server1 | 1000 Mb/s | RTL8153 USB 3 adapter, negotiated 5 Gb/s on the USB side; onboard NIC (`nic1`) has no carrier |
| ex-laptop | not yet measured | |

**`.165`'s NIC is gigabit hardware running at 100.** `ethtool` reports
`1000baseT/Full` in both *Supported* and *Advertised* link modes, and the error
counters are clean — `tx_errors 0`, `rx_errors 0`, `align_errors 0`,
`tx_underrun 0`.

**Cause, confirmed.** `.165` does not reach the Freebox directly. Its path is
`.165` → patch cable → wall socket → in-wall run → patch cable → **a TP-Link
device (`.100`)** → Freebox. `server1` and `ex-laptop` have no such hop, which
is exactly why they are at gigabit.

`ethtool nic0 | grep -A6 "Link partner"` names the culprit:

```
Link partner advertised link modes:  10baseT/Half 10baseT/Full
                                     100baseT/Half 100baseT/Full
```

**No `1000baseT/Full`.** The device terminating `.165`'s copper is 100 Mb/s
hardware. That also exonerates the wiring: a 2-pair run would still show the
partner advertising gigabit — autonegotiation rides a single pair — and merely
fail to reach it. This partner cannot do gigabit at all.

`.100` does not answer ARP from `.165` (`ip neigh` → `INCOMPLETE`), so it has no
reachable management address on this subnet. Irrelevant to the fault: a switch
or powerline adapter is transparent at layer 2 and imposes its port speed
whether or not it is manageable.

**Fix: replace it with an unmanaged gigabit switch** — TP-Link TL-SG105 (~€15)
or TL-SG108 (~€20), fanless, no configuration. Anything else hanging off that
device is capped at 100 Mb/s today and gains from the swap too.

Then re-check `ethtool nic0 | grep Speed`. If it is **still** 100 afterwards,
the in-wall run is 2-pair — it has never been tested above 100 Mb/s, because
nothing in the path has ever offered gigabit. Re-terminate if all four pairs are
physically present, otherwise pull a new Cat6.

**Why this one link matters more than any other.** `.165` hosts `k8s-cp-01`,
**`k8s-worker-01`**, `pg02` (the current Patroni **leader**) and the
`garage-storage` LXC (S3 for registry blobs and backups). Everything measured
so far crosses it:

- `agent-fleet`'s ADR-0048 §4 benchmarked Longhorn RWX and the `nfs`
  StorageClass at an identical **10 MB/s ≈ 80 Mbps** — 100BASE-TX after TCP
  overhead — against **1069 MB/s** node-local. The benchmark pod ran on
  `k8s-worker-01`, a `.165` guest.
- A PVE **VM migration** between hosts hits the same ~10 MB/s ceiling, and
  shares no code with Longhorn or NFS — no replicas, no fsync, no `sync`
  export. Three unrelated workloads, one shared link.
- One of three **etcd voters** (`k8s-cp-01`) sits behind it, and etcd is
  latency-sensitive.
- **Longhorn replica rebuilds** run at 10 MB/s — a 100 GB replica is ~2.8 h.

What this does *not* mean: it is not an argument for different storage. The
same disks measured 1069 MB/s the same day, so `nfs` (ADR-0036) remains worth
having for RWX-without-a-share-manager and capacity relief, but it is **not**
a performance lever and should not be proposed as one.

**Correction, recorded deliberately.** The first version of this section said
server1 and ex-laptop were the 100 Mbps hosts, on USB adapters with no usable
onboard NIC — from recollection, before anyone ran `ethtool`. `lsusb` then
showed server1's adapter is a *gigabit* RTL8153 on a 5 Gb/s port, and `ethtool`
put it at 1000 Mb/s. The real 100 Mbps host was the one assumed to be fine.
ADR-0048 §4 had named `ethtool` on the PVE hosts as the check that would settle
this and it went unrun for a day; the wrong answer was committed in the
meantime.

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
  - VMID 301 `garage-storage` (2 vCPU / 2GB / 200GB, Debian 13, IP
    192.168.1.199) — running, configured (Garage v2.3.0, single-node
    layout applied). Five buckets + per-bucket S3 keys, all driven from
    `garage-configure.yml`'s `garage_buckets` list:
    `k8s-longhorn-backup`, `pg-backup`, `agent-fleet-files`,
    `ente-photos`, and `zot-registry` (40GB quota — the registry is the
    only one that grows purely as a CI side effect, and this LXC's 200GB
    is shared with the backup buckets, ADR-0034)
- Running VMs (Postgres):
  - VMID 207 `pg02` (2 vCPU / 4GB / 40GB) — IP: 192.168.1.207 — Pigsty PG 18
    **Leader/primary** (current live role — see ADR-0029, roles flipped
    from the original static pg01/pg02 naming at some point via
    unattended Patroni failover) + Redis + etcd DCS member (`etcd-1` of
    3). `pg01` (VMID 205) is **no longer on this host** — migrated to
    server1 2026-07-30, see §2/§4.
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
| PVE nodes | 3 (proxmox .165, server1 .200, ex-laptop .161) | All reinstalled/joined the corosync cluster — see ADR-0020, ADR-0024 |
| K8s nodes | 5 QEMU VMs, **joined and confirmed live 2026-07-30 via `kubectl get nodes`** | 3 control-plane+etcd (`k8s-cp-01` `.165`/minority voter, `k8s-cp-02` server1, `k8s-cp-03` ex-laptop) + 2 workers (`k8s-worker-01` `.165`+GPU, `k8s-worker-02` server1) — real 3-CP/etcd HA per ADR-0017, fronted by kube-vip VIP `192.168.1.180`/`k8s.bnei.lan` (ADR-0016) |
| Postgres | QEMU VMs split across 2 hosts | pg02 VMID 207 (.207, on `.165`) — **Leader**; pg01 VMID 205 (.205, migrated to server1 2026-07-30) — Replica. See §4 |
| Postgres DCS (etcd) | 3-node quorum, **live 2026-07-30** | `etcd-1`/.207 (`.165`), `etcd-2`/.205 (server1), `etcd-3`/pg-etcd-witness `.197` (ex-laptop, VMID 303, etcd-only, no PG data) — ADR-0029 |
| Garage | LXC on proxmox PVE (.165) | VMID 301, running, configured (v2.3.0, 192.168.1.199) |
| Container registry | Zot, in-cluster (ns `zot`) | **Live 2026-08-13.** `registry.bnei.lan:5000`, MetalLB `.234` (pinned), blobs in Garage's `zot-registry` bucket (40GB quota). Plain HTTP, no IngressRoute — LE cannot issue for `.lan`; nodes trust it via `containerd_registries_mirrors`. Anonymous pull, htpasswd push. `editable-blog:0.37.9` pulled from it and serving — ADR-0034 |
| Image builds | `build-runner` LXC on server1 | **Live 2026-08-13.** VMID 103, `192.168.1.111`, `nesting=1`. GitHub Actions runner labelled `self-hosted,ukubi-build`, buildah run as root via scoped sudo. Outside the cluster because buildah cannot extract layers without `CAP_SYS_ADMIN` — ADR-0034 |

---

## 3. Kubernetes Cluster (Current)

**Cluster name:** `ukubi-cluster`
**API endpoint:** kube-vip VIP `192.168.1.180` / `k8s.bnei.lan` (ADR-0016) —
confirmed live: API server cert SANs carry both, `kubectl` against the
VIP works.
**K8s version:** v1.35.4
**Container runtime:** containerd
**CNI:** Cilium, chaining mode, kube-proxy retained (`ipvs`,
`kube_proxy_strict_arp: true` — ADR-0003)
**GitOps:** ArgoCD, Pattern C
**Manifests repo:** `gitops/` in this repo (`github.com/MohammadBnei/infra-bootstrap`) — every ArgoCD Application/ApplicationSet source in `gitops/bootstrap/` points at `infra-bootstrap` directly. The `k8s-cluster/` submodule is a separate, older repo (still has `cert-manager`/Proxmox-LAN manifests) and is **not** what `ukubi-cluster`'s ArgoCD reads from.

### Nodes (current — confirmed live 2026-07-30 via `kubectl get nodes`)

Real 3-control-plane/etcd HA topology (ADR-0017) — deliberately not 2
(etcd quorum at N=2 is still 2, strictly worse than 1 member).
Placement: 2 members on the stable hosts (server1, ex-laptop),
`k8s-cp-01` (`.165`, the host that gets rebooted for gaming) kept a
deliberate minority voter, so losing it never costs quorum.

| Node | Role | IP | Host | Notes |
| --- | --- | --- | --- | --- |
| k8s-cp-01 | control-plane + etcd | 192.168.1.201 | `.165` | joined, active, minority voter |
| k8s-cp-02 | control-plane + etcd | 192.168.1.204 | server1 | joined, active |
| k8s-cp-03 | control-plane + etcd | 192.168.1.206 | ex-laptop | joined, active |
| k8s-worker-01 | worker + GPU | 192.168.1.202 | `.165` | joined, active — RTX 2070 SUPER passthrough |
| k8s-worker-02 | worker | 192.168.1.203 | server1 | joined, active — resized 4→6 vCPU, 8→16GB 2026-07-30 |

### Workloads

- **GitOps:** ArgoCD (Pattern C — registry + `list`-generator ApplicationSets)
- **Ingress:** Traefik + `IngressRoute` only (no cert-manager, no Gateway API, no plain Ingress)
- **TLS:** Traefik built-in ACME (HTTP-01 → switched to TLS-ALPN-01, see `docs/bootstrap-test-notes.md` 2026-07-28)
- **LoadBalancer:** MetalLB, L2 only, pool `192.168.1.233-250`
- **Monitoring:** Prometheus + Grafana
- **Logging:** Loki + Grafana Alloy (see §10)
- **Networking:** Cilium (chaining) + Hubble, kube-vip (control-plane VIP), CoreDNS forwarding to Pi-hole for `bnei.lan`
- **Secrets:** Infisical
- **Storage:** Longhorn is the default StorageClass (ADR-0002/0019), backed
  up to Garage S3 (`backupTarget: s3://k8s-longhorn-backup@garage/`,
  daily `RecurringJob`) — see §5/§6. `local-path-provisioner` stays
  installed alongside as a non-default fallback, not the primary any more.
- **Apps:** see `gitops/apps/registry.yaml` (user apps) and
  `gitops/bootstrap/platform-common-apps.applicationset.yaml` (platform-common
  apps: searxng, pgweb, ente-museum, ente-web) for the live source of
  truth, not duplicated here — changes independently of cluster architecture.

### Known issues

- **GPU support live** — `k8s-worker-01` carries the RTX 2070 SUPER via
  direct PCI passthrough (no separate GPU-only VM).
- **CI/CD:** self-hosted GitHub Actions runner in-cluster, RBAC-scoped
  to `vos`/`vos-dev` only (ADR-0022/0023).
- **`.165` self-drain automation:** `k8s-cp-01`/`k8s-worker-01` (both
  hosted on `.165`, which dual-boots into Windows for gaming) each run
  `drain-self.service`/`uncordon-self.service`
  (`ansible/playbooks/self-drain-configure.yml`) that cordon+evict/uncordon
  themselves around their own graceful shutdown/boot, using a scoped
  `node-drainer` ServiceAccount (`gitops/bootstrap/node-drainer-rbac.yaml`
  — cordon/evict/read-daemonsets only, never cluster-admin). Verified live
  2026-07-30; not yet re-proven through a full end-to-end `.165` reboot
  with all three fixes (redesign + RBAC + Proxmox `down_delay`) in place —
  see `docs/bootstrap-test-notes.md`.

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
| pg02 | 207 | 192.168.1.207 | proxmox `.165` | Pigsty **Leader/primary** (current live role, ADR-0029 — roles flipped from the original static pg01/pg02 naming via an unattended Patroni failover at some point) + etcd DCS member (`etcd-1` of 3) |
| pg01 | 205 | 192.168.1.205 | server1 `.200` | Replica, streaming, lag 0 — migrated off `.165` 2026-07-30; etcd DCS member (`etcd-2` of 3) + Redis (relocated here 2026-07-30, see below) |
| pg-etcd-witness | 303 | 192.168.1.197 | ex-laptop `.161` | etcd DCS member only (`etcd-3` of 3), no PG data — provisioned + joined 2026-07-30 |

**Resolved 2026-07-30**: the DB tier's single-point-of-failure on `.165`
is closed. `pg01` moved to server1 (live migration), and DCS is now a
real 3-node etcd quorum (`etcd-1`/`.207`, `etcd-2`/`.205`,
`etcd-3`/`.197`) — `floor(3/2)+1` = 2, tolerates any single member
(and therefore `.165` itself) going down. See ADR-0029 and
`docs/bootstrap-test-notes.md`'s 2026-07-30 entries for the full
incident/fix history (including two real quorum-loss incidents during
`.205`'s join, both recovered via `etcdutl snapshot restore`).

### HA status

- **Replication:** streaming replication active (Leader `.207` → Replica `.205`), lag 0
- **Topology:** primary/replica + **real 3-node etcd DCS quorum** (ADR-0029)
- **Failover:** automatic via Patroni + etcd (accepted behavior — reverses the earlier "no automatic failover" stance, see `DECISION.md` §2)
- **Not yet done**: the actual end-to-end proof (stop `.207`, confirm `.205` promotes + the VIP follows + DCS survives on 2 of 3) hasn't been performed

### Monitoring: VictoriaMetrics, not Prometheus

Pigsty's bundled metrics backend on pg01 is **VictoriaMetrics v2.24.0**
(this is Pigsty v4's default — earlier Pigsty versions used classic
Prometheus), not classic Prometheus. It implements the same HTTP API
(`/api/v1/query`, `/api/v1/status/buildinfo`, etc.), so anything that
speaks to a Prometheus datasource — Grafana's `prometheus` datasource
type included — works against it unmodified.

Reachable directly over the LAN, no auth: `http://192.168.1.205/vmetrics`
(behind Pigsty's own nginx portal on `:80`; port `9090` itself is not
exposed — confirmed via `nc`, connection refused). Also worth noting: only
the `home` domain (`i.pigsty`) is actually configured in
`infra_portal` — the `p.pigsty`/`g.pigsty` per-service vhosts Pigsty's
docs describe are **not** set up on this install, so any `Host` header
lands on the same catch-all backend. The path (`/vmetrics`) is what
routes correctly, not the hostname.

The k8s cluster's own Grafana (`gitops/platform/values/grafana/values.yaml`)
now has this wired up as a second, non-default datasource (`uid:
ds-prometheus`, matching Pigsty's own fixed datasource UID — see
`pigsty/roles/infra/templates/grafana/datasource.yml.j2:26`), plus
Pigsty's own vendored `pgsql-overview` dashboard
(`pigsty/files/grafana/pgsql/pgsql-overview.json`, copied verbatim since
its panels already hardcode that same `ds-prometheus` UID). So both
cluster and Postgres/Pigsty metrics are now visible from one Grafana.

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

### Redis

**Relocated 2026-07-30** from pg02 (`192.168.1.207`, on `.165`) to pg01's
VM (`192.168.1.205`, server1). It's a single Redis instance, no
replica/Sentinel/cluster mode — real usage is ArgoCD's `externalRedis`
cache (`gitops/bootstrap/argocd-application.yaml`), not "purpose TBD" as
previously noted here. The old placement was a real gap: `.207`/`.165`
is the host that gets rebooted for gaming, and ArgoCD's sync pipeline
degrades/errors without Redis reachable — unlike Postgres (which now
survives `.165` reboots via the 3-node etcd quorum above), losing Redis
meant ArgoCD couldn't sync/deploy anything for the outage window (running
app pods were unaffected — Kubernetes itself doesn't need ArgoCD to keep
serving traffic).

**Still no real failover** — this is a relocation (off the reboot-prone
host), not HA. Consumers should resolve `redis.bnei.lan` (Pi-hole DNS,
`ansible/playbooks/pihole-configure.yml`), not a hardcoded IP, so the
next host move is a DNS-record change only.

Persistence: RDB snapshots every 1200s (`redis_aof_enabled: false`) — an
ungraceful reboot of Redis's host can still lose up to ~20 minutes of
writes, acceptable for a cache workload.

### Users

25 roles in Pigsty convention (`dbuser_*` per app) + Supabase roles + replication roles. Migrated from source cluster.

### Extensions

Standard set: pg_stat_statements, pg_trgm, pg_repack, postgres_fdw, etc. (17 total)

### Next steps

- **Done** (2026-07-30): PG data tier split across `.165`/server1, 3-node etcd DCS quorum live. See ADR-0029.
- **Still open**: the real end-to-end failover proof (stop `.207`, confirm promotion + VIP + DCS survive) — next session's priority.

---

## 5. Storage (Current)

### Longhorn (K8s PV storage, current)

- **Default StorageClass** on `ukubi-cluster` (ADR-0002 over Ceph/NFS,
  rollout specifics in ADR-0019) — every PVC without an explicit
  `storageClassName` (Traefik's `acme.json`, `common-app-chart` app PVCs)
  binds here.
- **Backup target:** Garage S3 (`s3://k8s-longhorn-backup@garage/`, see
  §6), credentials via `gitops/bootstrap/longhorn-backup-secret.yaml`,
  daily snapshot via `gitops/bootstrap/longhorn-daily-snapshot-recurringjob.yaml`.
- `local-path-provisioner` remains installed as a non-default fallback,
  not the primary.

### `nfs` StorageClass (ADR-0036 — **live 2026-08-14**)

- Second non-default class via `csi-driver-nfs` (chart 4.13.4, `kube-system`,
  ArgoCD wave 0), backed by a second export on the `nfs-storage` VM:
  `nfs-storage.bnei.lan:/export/k8s`, its own 50GB `scsi2` disk, `ext4`,
  label `nfsk8s`. Unreplicated, **no backup and none planned**, RWX-capable — regenerable
  data only.
- `csi-nfs-controller` (4/4, snapshotter deliberately disabled) + a
  `csi-nfs-node` DaemonSet pod on all 5 nodes.
- Verified end-to-end on bring-up: a 1Gi RWX PVC bound, two pods on
  *different* nodes (`k8s-worker-01`/`k8s-worker-02`) each read the other's
  writes, the data landed at `/export/k8s/pvc-<uid>/` on `.198`, and
  deleting the PVC removed that subdirectory (`reclaimPolicy: Delete`
  confirmed, 0 PVs leaked).
- `longhorn` remains the default class — confirmed via `kubectl get sc`
  after the rollout.

### nfs-storage (Proxmox shared template storage, current — ADR-0026)

- **VM** on server1 (`192.168.1.198`, `nfs-storage.bnei.lan`), built via
  `terraform/nfs.tf` + `ansible/playbooks/nfs-configure.yml` — exports
  `shared-templates`, a PVE storage backend reachable identically from
  every PVE host, so Terraform's Proxmox provider can direct-clone the
  golden VM template (VMID 9001) cross-host instead of falling back to a
  clone-then-`qm migrate --with-local-disks` copy over the LAN.
- **The `/export/templates` share is not mounted by K8s at all** — purely
  a Proxmox-level cross-host clone fix (used live to clone `k8s-worker-02`
  onto server1, see `docs/bootstrap-test-notes.md` 2026-07-28), unrelated
  to the dead K8s-PV NFS export below. That stays true under ADR-0036: the
  `nfs` StorageClass uses a *separate* disk and a *separate* export
  (`/export/k8s`) on the same VM, with its own client list.

### NFS — K8s PV export (dead, historical record only)

*Confirmed gone: this ran on server1's pre-reinstall OS, wiped when
server1 was reinstalled to PVE (ADR-0024). Superseded by Longhorn above
for K8s PVs — do not resurrect.*

*"Do not resurrect" means this box, this export, and
`nfs-subdir-external-provisioner` as the **default** class. It is not a ban
on NFS-backed PVs generally — ADR-0036 deliberately adds one as a
non-default class on the purpose-built `nfs-storage` VM.*

- **Server:** server1 (192.168.1.200)
- **Export:** `/home/mohammad/.local/share/k8s-nfs` → `192.168.1.200/24`
- **Used by:** K8s cluster (NFS subdir provisioner for PVs)
- **Service:** NFSv4 (rpcbind, nfs-mountd, nfs-idmapd running)

### Ceph (dead)

- **OSD present** on server1 HDD (`/dev/ceph-dfb021ce.../osd-block-...`)
  — pre-reinstall state, not re-verified since, likely gone with the rest
  of that OS install.
- **No active cluster** — no monitors, no mgr, no OSDs daemon running
- **Leftover** from previous attempt
- **Reclaimable** — HDD can be wiped and repurposed

### Proxmox storage

- `local` (directory): `/var/lib/vz`
- `local-lvm` (LVM-thin): for VM disks on proxmox PVE
- `shared-templates` (NFS via `nfs-storage`): cross-host template cloning
  only, see above. `nfs-storage`'s *other* export (`/export/k8s`, ADR-0036)
  is deliberately **not** a PVE storage pool — K8s reaches it directly via
  `csi-driver-nfs`.

---

## 6. Object Storage

- **Garage v2.3.0** — LXC `garage-storage` (VMID 301, 192.168.1.199),
  single-node layout, S3 API on port 3900 (LAN-only from Garage's own
  bind), admin API on 3903 (localhost-only)
- **Externally exposed since 2026-08-02** at `s3.bnei.dev` via a Traefik
  redirector (`gitops/redirectors/garage-s3.yaml`, `ExternalName` Service
  + IngressRoute, `tls.certResolver: le`) — ADR-0030. Auth is Garage's own
  S3 SigV4 signing only, no anonymous read; the admin API (3903) is
  deliberately not part of this exposure.
- Buckets: `k8s-longhorn-backup` (Longhorn snapshot target, ADR-0019, see
  §5), `pg-backup` (pgBackRest target, provisional name — not yet wired
  into pigsty's `pgbackrest_repo` config)
- Provisioned entirely via `terraform/garage.tf` (bare LXC) +
  `ansible/playbooks/garage-configure.yml` (install/config/secrets,
  config-driven bucket/key provisioning) — no manual CLI step, replaces
  the old MinIO deployment (archived Jan 2026)

---

## 7. Network Services (Current)

### DNS

- **External/WAN:** Freebox (192.168.1.254) — basic, no wildcards, no internal zones. `bnei.dev` stays external — hosted at **Cloudflare** (registration at Squarespace), **wildcard A records** (`*.bnei.dev`, `*.ente.bnei.dev`, `*.e2e.bnei.dev` + apex), all DNS-only/grey-cloud — unrelated to the below. See [ADR-0033](adr/0033-dns-to-cloudflare-and-dns01-wildcard.md) and `runbook-dns-cloudflare-migration.md`. *Previously served by `ns-cloud-d*.googledomains.com` (Google Cloud DNS) with manual per-host A records — these docs called that "Squarespace DNS", which is where records were edited but not what answered queries.*
- **Local resolver, live since 2026-07-30**: Pi-hole on the Pi 4
  (`192.168.1.55`, static IP pinned via `nmcli`, `ansible/playbooks/pihole-configure.yml`),
  authoritative for `bnei.lan` (`DECISION.md` §2). Two consumers,
  differently configured: the LAN generally still gets DNS from the
  Freebox; in-cluster pods resolve `bnei.lan` via CoreDNS/nodelocaldns
  forwarding to Pi-hole first (`policy: sequential`, not the default
  random — random upstream selection silently broke this once, see
  `docs/bootstrap-test-notes.md` 2026-07-30).
- **Records** (`pihole_hosts_records` in `pihole-configure.yml`, mirrors
  `ARCHITECTURE.md` §3): all PVE hosts, Postgres nodes + HA VIP
  (`postgres.bnei.lan` → `.232`), `pg-etcd-witness.bnei.lan`,
  `redis.bnei.lan` (added 2026-07-30, so future Redis host moves are a
  DNS-record change only — see §4/§6), `garage.bnei.lan`,
  `nfs-storage.bnei.lan`, `k9s-dashboard.bnei.lan`, `k8s.bnei.lan`
  (kube-vip control-plane VIP, `.180`), all 5 K8s node names.

### Load Balancer / Reverse Proxy

*(Historical record only — confirmed gone: this ran on server1's
pre-reinstall OS, wiped by the PVE reinstall/ADR-0024. Traefik +
IngressRoute + MetalLB is the current, only reverse-proxy/LB path — see
`gitops/README.md`.)*

- **HAProxy on server1** (port 8000, 8443)
  - Fronting the existing K8s services
  - SPICE ports 5900/5901 for libvirt VMs

### Firewall

- Freebox basic firewall
- iptables on each host (default policies)

---

## 8. Backup (Current)

- **K8s PVs (Longhorn): backed up** — daily snapshot `RecurringJob` to
  Garage S3 (`k8s-longhorn-backup` bucket, see §5/§6). The remaining gaps
  below are still real.
- **Postgres: not backed up externally** — `pg-backup` bucket exists in
  Garage (§6) but is not yet wired into pigsty's `pgbackrest_repo` config
  — still local-only per Pigsty's default.
- **K8s manifests:** in git (`gitops/` in this repo — see §3's
  manifests-repo correction; not the `k8s-cluster` submodule)
- **Proxmox config:** not backed up
- **`/home/mohammad`:** not backed up

**Partial gap** — K8s PV data now has a real backup path; Postgres and
host-level config/data still don't.

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
- Access to `MohammadBnei/infra-bootstrap` (this repo) and
  `MohammadBnei/k8s-cluster` (legacy)

---

## 10. Observability (Current)

- **Prometheus + Grafana** running in K8s (in `ukubi-cluster`)
- **Pigsty's own stack (VictoriaMetrics, not classic Prometheus)** on
  `.205` (the `infra` node) — `pg_exporter` on both Postgres VMs,
  `node_exporter`/`node_monitor` (vector for logs) on every Pigsty-managed
  node including `pg-etcd-witness`, all confirmed `up` via
  `/api/v1/targets` (2026-07-30, ADR-0029 rollout). Wired into the K8s
  cluster's own Grafana as a second datasource (`ds-prometheus` UID) —
  see §4.
- **Centralized logging is live**: Loki (SingleBinary, filesystem storage)
  + Grafana Alloy (DaemonSet, tails every node's container logs directly
  off `/var/log/pods` — hostPath file tailing, not the kubelet API, since
  2026-07-29/PR #67) — see ADR-0027 and ARCHITECTURE.md §9. Grafana's
  "App Logs" dashboard gives namespace/level/text-search filtering over
  it; `common-app-chart`'s `logAlerts:` values block lets a user app
  declare its own Loki-based alert rules, picked up dynamically by
  Grafana's alerts sidecar. A cluster-wide starter alert (log error-rate
  spike) routes to the same Discord contact point Alertmanager uses.
- **Alertmanager** (part of the `kube-prometheus-stack` release) routes
  to Discord via a Slack-formatted webhook
  (`gitops/bootstrap/alertmanager-discord-secret.yaml`, `/slack`-suffixed
  Discord webhook URL — same trick as the log-alert contact point above),
  exposed at `alertmanager.bnei.dev`
  (`gitops/bootstrap/alertmanager-ingressroute.yaml`, gated by the shared
  `basic-admin-auth` Middleware).

---

## 11. Open Items / Gaps

1. **ex-laptop k8s-03 LXC** — was destroyed (was a failed LXC K8s attempt, never joined cluster)
2. ~~**Pi 4** — present in user's network but not yet inventoried~~ — **RESOLVED** (see Pi 4 section above; PG 18 already installed)
3. ~~**Server1 K8s VM details** — node1 (192.168.1.181) is on server1 but exact VM specs unknown~~ — **MOOT**: that pre-reinstall libvirt VM no longer exists (server1's full PVE reinstall wiped it, ADR-0024); current server1 K8s VMs are `k8s-cp-02`/`k8s-worker-02`, specs in §3.
4. ~~**Existing apps** — many apps run on ukubi-cluster, need to enumerate before migration~~ — **RESOLVED**: app inventory now lives in `gitops/apps/registry.yaml` (user apps) + `platform-common-apps.applicationset.yaml` (platform-common apps), see §3.
5. **Backup target** — off-host K8s-PV backup exists now (Longhorn → Garage S3, §8); Postgres and host-level config/data still have none.
6. **Freebox features** — has admin access but limited capabilities (Revolution model)

---

## 12. Out of Scope (Current)

- Multi-region / DR
- Service mesh
- GPU multi-tenancy
- External managed services

---

*This document evolves as the actual state changes. Always update this file when making infrastructure changes — it is the source of truth for what exists.*
