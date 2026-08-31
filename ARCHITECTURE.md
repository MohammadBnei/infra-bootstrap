# ARCHITECTURE

Target topology and specs — the **WHAT** — for the `ukubi` homelab
cluster. This is not a rationale doc: for *why* each choice was made,
see [`DECISION.md`](DECISION.md) and [`docs/adr/`](docs/adr/README.md).
For current *live* state (may diverge from this during migration), see
[`docs/infrastructure-actual.md`](docs/infrastructure-actual.md). For
how to actually run a layer day-to-day, see its component README
(`terraform/`, `gitops/`, `ansible/`, `inventory/ukubi/`).

---

## System at a glance

```mermaid
graph TD
    subgraph Proxmox["Proxmox — 3 PVE hosts"]
        TF[Terraform<br/>bpg/proxmox provider]
        VM1[k8s VMs]
        VM2[Postgres VMs]
        VM3[Garage LXC]
        TF --> VM1
        TF --> VM2
        TF --> VM3
    end

    subgraph K8s["ukubi-cluster (kubespray)"]
        Cilium[Cilium — chaining mode]
        KP[kube-proxy — ipvs]
        MetalLB[MetalLB — L2]
        Traefik[Traefik — IngressRoute + ACME]
        Cilium --> KP
        MetalLB --> Traefik
    end

    subgraph GitOps["GitOps (ArgoCD, Pattern C)"]
        Registry[apps/registry.yaml]
        AppSet[ApplicationSet — list generator]
        Apps[Platform + user Applications]
        Registry --> AppSet --> Apps
    end

    subgraph Pigsty["Pigsty"]
        PG1[pg01 .205 primary]
        PG2[pg02 .207 replica]
        PG1 -- streaming replication --> PG2
    end

    subgraph Obs["Observability"]
        Alloy["Alloy — DaemonSet<br/>(black box, see §9)"]
        Loki[Loki — log store]
        Alloy --> Loki
    end

    VM1 --> K8s
    Apps --> Traefik
    K8s --> GitOps
    VM2 --> Pigsty
    Apps -. reads/writes .-> Pigsty
    Apps -. container logs .-> Alloy
```

---

## 1. Physical Hosts

| Host | IP | Target OS | Role |
| --- | --- | --- | --- |
| **proxmox** (bnei) | 192.168.1.165 | PVE 9.2.3 (keep) | Primary PVE host: K8s VMs + Postgres VMs + Garage LXC |
| **server1** | 192.168.1.200 | PVE 9.2 (reinstalled, joined corosync cluster) | PVE host: future K8s/PG placement |
| **ex-laptop** | 192.168.1.161 | PVE 9.2 (reinstalled, joined corosync cluster) | 3rd PVE node, sleep-risk mitigation open ([ADR-0013](docs/adr/0013-pve-node-161-sleep-risk-mitigation.md)) |
| **Pi 4** | 192.168.1.55 | Debian 13 trixie (fresh) | Pi-hole / local DNS helper |

### proxmox PVE (192.168.1.165) — 32GB RAM, 12 threads, 2× NVMe 1TB

| VM/LXC | Type | vCPU | RAM | Disk | Notes |
| --- | --- | --- | --- | --- | --- |
| pg02 | VM (Q35, OVMF) | 2 | 4GB | 40GB | Pigsty PG **replica** as of 2026-08-15 — was Leader until `.165` went down during the switch replacement and Patroni promoted `.205`. `192.168.1.207` + etcd DCS member (`etcd-1` of 3), stays on `.165`. Rejoined via `patronictl reinit` + a replication-slot drop; **streaming, lag 0, verified**. [ADR-0029](docs/adr/0029-postgres-automatic-failover-3-node-etcd-quorum.md) |
| k8s-cp-01 | VM (Q35, OVMF) | 2 | 4GB | 40GB | Control plane + etcd + worker, Ubuntu 24.04 |
| k8s-worker-01 | VM (Q35, OVMF) | 6 | 15GB | 100GB | Ubuntu 24.04, RTX 2070 SUPER PCIe passthrough |
| garage-storage | LXC | 2 | 2GB | 200GB | S3-compatible, NVMe-backed |

Full eBPF hardware support (AMD Ryzen). ~3GB PVE overhead reserved.

### server1 PVE (192.168.1.200, reinstalled) — 32GB RAM, 6 threads, NVMe 476GB (149GB HDD removed pre-reinstall, ext4 root + `local-lvm`, no dedicated ZFS pool — [ADR-0024](docs/adr/0024-server1-single-disk-ext4-no-dedicated-zfs.md))

| VM/LXC | Type | vCPU | RAM | Disk | Notes |
| --- | --- | --- | --- | --- | --- |
| pg01 | VM (Q35, OVMF) | 2 | 4GB | 40GB | Pigsty PG **leader/primary** as of 2026-08-15 (promoted automatically when `.165` went down — see §HA), `192.168.1.205` — migrated off `.165` 2026-07-30 via live migration ([ADR-0029](docs/adr/0029-postgres-automatic-failover-3-node-etcd-quorum.md)); hit a kernel panic on first boot here, recovered cleanly with a reboot |
| nfs-storage | VM (Q35, OVMF) | 1 | 1GB | 320GB (20 root + 100 `scsi1` + 200 `scsi2`) | Two independent exports on two disks: `scsi1` → `/export/templates`, shared PVE storage for cross-host VM template cloning ([ADR-0026](docs/adr/0026-nfs-shared-pve-storage-cross-host-clone.md), never mounted by K8s); `scsi2` → `/export/k8s`, backing the unreplicated `nfs` StorageClass ([ADR-0036](docs/adr/0036-nfs-storage-class-for-k8s.md)). Separate disks so a runaway PVC can't starve PVE's template storage |
| k8s-worker-02 | VM (Q35, OVMF) | 6 | 16GB | 60GB | First cross-host K8s worker (Stage 2 Phase C), `192.168.1.203` — resized 4→6 vCPU/8→16GB 2026-07-30, server1 had most of its RAM idle |
| k8s-cp-02 | VM (Q35, OVMF) | 2 | 4GB | 40GB | 2nd control-plane + etcd member, `192.168.1.204` — [ADR-0017](docs/adr/0017-second-control-plane-member.md) |
| k9s-dashboard | LXC (VMID 102) | 1 | 1GB | 8GB | Ops convenience box, `192.168.1.110` — a human SSHes in and drives `kubectl`/`k9s` against the live cluster. Carries a **cluster-admin kubeconfig on disk**, which is why it holds its own dedicated SSH keypair and why cluster credentials are never materialised on the workstation instead ([`k8s-ops`](.claude/skills/k8s-ops/SKILL.md)) |
| build-runner | LXC (VMID 103) | 4 | 4GB | 40GB | Image builds, `192.168.1.111` — `nesting=1`, buildah run as root via scoped sudo. Deliberately outside the cluster: buildah cannot extract layers without `CAP_SYS_ADMIN` ([ADR-0034](docs/adr/0034-in-cluster-oci-registry-zot-garage-backed.md)). Disk is the number to watch — `vfs` storage copies layers, and a weekly `podman system prune` timer is the only thing reclaiming them |

CPU **lacks** eBPF hardware support — one reason Cilium chaining mode is
locked cluster-wide (see [ADR-0003](docs/adr/0003-cni-cilium-chaining-over-kube-proxy-replacement.md)).

### ex-laptop PVE (192.168.1.161, after reinstall) — 15GB RAM, 4 threads, SSD 238GB, `local-lvm` only ([ADR-0028](docs/adr/0028-ex-laptop-no-dedicated-zfs-pool.md) — no dedicated ZFS pool)

| VM/LXC | Type | vCPU | RAM | Disk | Notes |
| --- | --- | --- | --- | --- | --- |
| k8s-cp-03 | VM (Q35, OVMF) | 2 | 4GB | 40GB | 3rd control-plane + etcd member, `192.168.1.206` — [ADR-0017](docs/adr/0017-second-control-plane-member.md) |
| pg-etcd-witness | VM (Q35, OVMF) | 1 | 1GB | 10GB | 3rd Patroni DCS/etcd-only member, `192.168.1.197` — no PG data, dedicated VM (not co-located on k8s-cp-03) so PG quorum survives k8s control-plane restarts — [ADR-0029](docs/adr/0029-postgres-automatic-failover-3-node-etcd-quorum.md) |

Sleep-risk mitigation applied and confirmed ([ADR-0013](docs/adr/0013-pve-node-161-sleep-risk-mitigation.md)) — still deliberately kept a
*minority* etcd/CP voter (not the majority), so losing this host never
costs quorum even though it's the least-trusted of the 3.

### Pi 4 (192.168.1.55) — fresh Debian 13 install, 1.8GB RAM, 4 cores, microSD 238GB

| Service | Notes |
| --- | --- |
| Pi-hole | Static IP (pinned via `nmcli`, was DHCP-dynamic), authoritative for `bnei.lan`, ~50MB RAM — see §3 DNS below |
| node_exporter | Optional, ~10MB RAM |

Clean install — no pre-existing state to migrate (the prior failed PG18
install on this Pi 4 held no data).

---

## 2. Kubernetes Cluster

- **Cluster name:** `ukubi-cluster`. DNS domain: `cluster.local`.
- **Topology:** 3 control-plane/etcd members, live and joined
  2026-07-30 ([ADR-0017](docs/adr/0017-second-control-plane-member.md)) —
  deliberately **not** 2 (etcd quorum at N=2 is still 2, strictly worse
  than 1 member). Placement is the whole point: 2 members on the stable
  hosts (server1, ex-laptop), `k8s-cp-01` (`.165`, the host that gets
  rebooted for gaming) kept a minority voter, so losing it never costs
  quorum. Fronted by a kube-vip VIP, `192.168.1.180`/`k8s.bnei.lan` —
  [ADR-0016](docs/adr/0016-k8s-endpoint-naming.md), confirmed live (API
  server cert SANs carry both, `kubectl` against the VIP works). The
  worker carries the GPU passthrough directly — no separate
  `k8s-worker-gpu` VM.
- **K8s version:** v1.35.4. **Container runtime:** containerd.
- **CNI:** Cilium, chaining mode, kube-proxy retained (`ipvs`,
  `kube_proxy_strict_arp: true`) — see [ADR-0003](docs/adr/0003-cni-cilium-chaining-over-kube-proxy-replacement.md).
- **OS:** Ubuntu 24.04 cloud-init, template VMID 9001, user `core`.

### Nodes (current — confirmed live 2026-07-30 via `kubectl get nodes`)

| Node | Host | IP | Resources | Notes |
| --- | --- | --- | --- | --- |
| k8s-cp-01 | `.165` | 192.168.1.201 | 2 vCPU / 4GB | Control plane + etcd (minority voter) |
| k8s-cp-02 | server1 | 192.168.1.204 | 2 vCPU / 4GB | Control plane + etcd |
| k8s-cp-03 | ex-laptop | 192.168.1.206 | 2 vCPU / 4GB | Control plane + etcd |
| k8s-worker-01 | `.165` | 192.168.1.202 | 6 vCPU / 15GB | Standard workloads + GPU passthrough, NVIDIA device plugin |
| k8s-worker-02 | server1 | 192.168.1.203 | 6 vCPU / 16GB | Standard workloads, first cross-host worker (Stage 2 Phase C) |

### GPU passthrough

RTX 2070 SUPER at PCI `0b:00.0` on the hypervisor, presented to the guest
at `01:00.0-3`, all 4 functions passed with `multifunction=on` (GPU + Audio +
USB + USB-C). NVIDIA driver + container toolkit inside the VM; NVIDIA Device
Plugin as a GitOps platform app.

GPU workloads are scheduled by **`runtimeClassName: nvidia` plus an
`nvidia.com/gpu` resource request** — *not* taints/tolerations. The node is
deliberately untainted: `nvidia.com/gpu` is a countable resource, so exactly
one pod holds the GPU either way, and a taint would only strand the node's CPU
and RAM. The `nvidia` containerd runtime is registered as a **non-default**;
making it the node default would inject the whole GPU into any pod built on an
`nvidia/cuda:*` base image without it requesting one, which is the accidental
multi-tenancy ADR-0011 rejects. See ADR-0043.

### Self-drain on `k8s-cp-01`/`k8s-worker-01`

A real, ungraceful `.165` outage (2026-07-30, see
`docs/bootstrap-test-notes.md`) proved that Kubernetes' default
node-eviction timer reschedules pods but never force-detaches CSI
(Longhorn) volumes from a node it can't confirm is gone — a
`ReadWriteOnce` PVC's pod got stuck `Multi-Attach error` until the node
came back. Fix: `ansible/playbooks/self-drain-configure.yml` installs
`drain-self.service`/`uncordon-self.service` on both nodes hosted on
`.165` — each node cordons + evicts *itself* on its own graceful
shutdown (triggered by Proxmox's ACPI `qmshutdown` signal, which already
waits up to 180s per VM), and uncordons itself once it rejoins the
cluster on boot. Uses a dedicated, least-privilege kubeconfig
(`node-drainer` ServiceAccount, `gitops/bootstrap/node-drainer-rbac.yaml`
— cordon/evict/read-daemonsets only), not `k8s-cp-01`'s own
`admin.conf`, for a smaller blast radius and one consistent identity
across both nodes. Only fires on a graceful, systemd-initiated
shutdown/reboot (not a hard power-cut) — accepted, since switching to
Windows on this host normally goes through a real `reboot`.

An earlier version ran a single credential on `.165` itself (the
hypervisor), draining both nodes from outside — abandoned after
confirming live that ordering it against Proxmox's own guest-shutdown
service was backwards (systemd stops in the *reverse* of start order),
and that racing a host-level Proxmox service is inherently more fragile
than each node just draining itself using its own shutdown sequence.

### App stack

The deployed app list is **not** duplicated here — it changes
independently of cluster architecture. See
[`gitops/apps/registry.yaml`](gitops/apps/registry.yaml), the live
source of truth per GitOps Pattern C ([ADR-0004](docs/adr/0004-gitops-pattern-c-registry-applicationset.md)).

### CNI chaining relationship

```mermaid
graph LR
    Pod[Pod traffic] --> Cilium[Cilium — CNI, L3/L4/L7 policy, Hubble]
    Cilium -- chained, not replacing --> KubeProxy[kube-proxy — ipvs, strict-arp]
    KubeProxy --> Service[K8s Service VIP]
```

---

## 3. Networking

### Topology

- Single flat LAN `192.168.1.0/24` (Freebox has no VLANs).
- Gateway: Freebox `192.168.1.254`.
- IP allocation by role, not subnet: `.1` Freebox · `.20-.49` hosts ·
  `.50-.99` static infra · `.100-.199` VMs/LXCs · `.200-.254` Freebox DHCP.
- Bridge: `vmbr0` on each PVE host, no NAT, no internal libvirt network.

**Physical links — the LAN is flat logically, but *not* uniform physically:**

| Host | Path to Freebox | `nic0` link speed |
|---|---|---|
| **proxmox** (`.165`) | room switch → structured cabling → TL-SG108E | 1000Mb/s |
| server1 (`.200`) | direct to Freebox | 1000Mb/s |
| ex-laptop (`.161`) | direct to Freebox | 1000Mb/s |

`.165` is the **only** host behind the switch; the other two are plugged
straight into the Freebox. Their speeds therefore say nothing about
`.165`'s path — different cabling, so a measurement on one never
generalizes to the other.

**The switch is a TP-Link `TL-SG108E`** (8-port **Gigabit** Easy Smart,
management UI at `192.168.0.100`, off-subnet). It is *not* the bottleneck:
its other ports light the `1000M` LED, and the per-port `1000M` /
`10M/100M` LED pair is the fastest way to read link speed without SSH.
Being an Easy Smart model it also supports **802.1Q VLANs, LACP, and port
mirroring** — available today, unused so far, and the only way to segment
this LAN given the Freebox has no VLANs.

`.165` does not reach the `TL-SG108E` directly. There is a **second switch
in the room** (shared with the Pi 4, `192.168.1.55`), and beyond it
**in-wall structured cabling terminated on a `C5e` patch panel** (ports
labeled per room: `Router salon`, `M. Amine`, `Bur Linda`, `CH 5 DTE`,
`CH 5 Ghe`, `ALI`, `LINDA`):

```
.165 NIC → patch cable → ROOM SWITCH (gigabit, replaced 2026-08-15)
         → patch cable → wall socket → in-wall run
         → C5e patch panel → patch cable → TL-SG108E → Freebox
```

**Resolved 2026-08-15.** `.165` sat at **100Mb/s** because the room switch
was a **10/100 fast-ethernet unit** — it physically could not do gigabit,
so no cabling change would ever have helped. Replaced with a gigabit
switch; unmanaged is fine there, since VLAN capability already exists at
the rack on the `TL-SG108E`. Verified `nic0` at 1000Mb/s **and** `iperf3`
to `.200` at **942 Mbit/s** — line rate, ~10× the previous ceiling.

The `iperf3` result also clears the rest of the chain: the in-wall run and
the `C5e` punch-down carry all four pairs correctly. Nothing else on the
path is capped.

Two things worth keeping from how long this took to find:

- **Ethernet negotiates per segment.** `ethtool nic0` reports *only* the
  link to whatever the host is directly plugged into. Everything past the
  first hop is invisible to it — which is why the wall run and the patch
  panel were suspected at length despite being downstream of the reading.
- **Never read link speed off `vmbr0`.** See the box below.

Why this was worth chasing: `.165` carries `pg02` (the Postgres
**leader**, streaming to `pg01` on `.200`), `etcd-1`, `k8s-cp-01`,
`k8s-worker-01`, and the Garage LXC that backs both Longhorn backups and
the Zot registry's blobs. All of that had been crossing the LAN at
~12 MB/s. Full diagnostic trail in `docs/bootstrap-test-notes.md`.

> **Never read link speed off `vmbr0`.** A Linux bridge has no PHY and
> reports a synthetic `10000Mb/s`. Query the physical NIC (`nic0`), or
> enumerate real devices via `/sys/class/net/*/device` — bridges, `veth`,
> and `tap` have no `device` symlink.

### MetalLB

- **Mode:** L2 only (Freebox blocks BGP — see `DECISION.md` §2).
- **IP range:** `192.168.1.233-192.168.1.250`. **Reserved ingress VIP:**
  `.233` (pinned via `metallb.universe.tf/loadBalancerIPs` on Traefik's
  Service). `.230-.232` excluded from the pool — `.232` is Pigsty's HA
  floating VIP (vip-manager), `.230`/`.231` kept clear alongside it.
  **Second pinned address:** `.234` (zot OCI registry, ADR-0034) — the only
  other Service here that isn't reached through Traefik, because `.lan` is a
  name Let's Encrypt can't issue for. Pinned for the same reason as `.233`:
  a DNS record and every node's containerd config both name it.
> **Don't `ping` a MetalLB VIP.** The speaker answers ARP and forwards
> TCP; no interface actually holds the address, so ICMP goes unanswered
> even when the service is perfectly healthy. Test with `curl`. A `404`
> on Traefik's bare VIP is the *correct* healthy response — no
> `IngressRoute` matches a raw IP. See `docs/bootstrap-test-notes.md`
> trap 5.

- **Speaker:** tolerates `node-role.kubernetes.io/control-plane:NoSchedule`.
- **Controller:** 2 replicas, pod anti-affinity keyed on
  `app=metallb,component=controller` / `topologyKey=kubernetes.io/hostname`.

### DNS

**Authority:** Pi-hole on the Pi 4 (`192.168.1.55`,
`ansible/playbooks/pihole-configure.yml`), authoritative for `bnei.lan`
per `DECISION.md` §2. Triggered once there were enough real internal
hostnames (kube-vip's endpoint, the pg/garage/nfs/k9s-dashboard VMs) that
raw IPs stopped being convenient. `bnei.dev` stays external — Cloudflare,
wildcard A records (ADR-0033) — unrelated to this.

**Static IP:** Pi-hole's own address is pinned via `nmcli` (was
DHCP-dynamic — a real risk once other things depend on it staying put),
self-contained on the Pi rather than a Freebox DHCP reservation.

**Two separate consumers, deliberately configured differently:**
- **The LAN generally** (PVE hosts, laptops, phones) — inherits DNS from
  whatever the Freebox hands out. Pointing the Freebox itself at Pi-hole
  (as its own upstream and/or the DHCP-advertised server) is the
  low-effort, high-coverage fix for this tier — one-time change, covers
  every device including ones added later, operator-applied (not
  automatable from this repo).
- **The K8s cluster's CoreDNS** — forwards upstream via
  `upstream_dns_servers` (`inventory/ukubi/group_vars/all/settings.yml`):
  Pi-hole first, `1.1.1.1` as fallback. Set **explicitly** rather than
  inherited from the node's own resolv.conf/Freebox — DB connectivity
  (pods resolving the Pigsty VIP by name) depends on this, not worth an
  extra Freebox-relay hop for something this critical. Confirmed live via
  a `cluster.yml` re-run after the 3-CP join.

### Records

```text
A    proxmox.bnei.lan        → 192.168.1.165
A    server1.bnei.lan        → 192.168.1.200
A    ex-laptop.bnei.lan      → 192.168.1.161
A    pi4.bnei.lan            → 192.168.1.55
A    postgres-1.bnei.lan     → 192.168.1.205  (pg01 VM — current live Leader/Primary as of 2026-08-15; on server1, migrated 2026-07-30, ADR-0029/patronictl)
A    postgres-2.bnei.lan     → 192.168.1.207  (pg02 VM — current live Replica, on .165, ADR-0029. Names never tracked roles; always confirm with patronictl)
A    postgres.bnei.lan       → 192.168.1.232  (Pigsty HA floating VIP — apps/tests should use this, not postgres-1/2 directly)
A    pg-etcd-witness.bnei.lan → 192.168.1.197  (ex-laptop — 3rd etcd DCS member, live 2026-07-30, ADR-0029)
A    garage.bnei.lan         → 192.168.1.199
A    registry.bnei.lan       → 192.168.1.234  (zot OCI registry — a MetalLB LoadBalancer address, not a host; pinned in gitops/platform/values/zot/values.yaml and named by every node's containerd config, so both ends move together — ADR-0034)
A    nfs-storage.bnei.lan    → 192.168.1.198
A    k9s-dashboard.bnei.lan  → 192.168.1.110
A    build-runner.bnei.lan   → 192.168.1.111  (image build runner LXC — ADR-0034)
A    k8s.bnei.lan            → 192.168.1.180  (kube-vip control-plane VIP, confirmed live — see ADR-0016)
A    k8s-cp-01.bnei.lan      → 192.168.1.201
A    k8s-cp-02.bnei.lan      → 192.168.1.204
A    k8s-cp-03.bnei.lan      → 192.168.1.206
A    k8s-worker-01.bnei.lan  → 192.168.1.202
A    k8s-worker-02.bnei.lan  → 192.168.1.203
```

`bnei.dev` is hosted at **Cloudflare** (registration stays at Squarespace),
with **wildcard A records** all pointing at the public IP the Freebox
port-forwards 80/443 from to Traefik's MetalLB VIP — see
[ADR-0033](docs/adr/0033-dns-to-cloudflare-and-dns01-wildcard.md) and
`docs/runbook-dns-cloudflare-migration.md`:

```
A    bnei.dev           → 82.65.231.50   (apex)
A    *.bnei.dev         → 82.65.231.50   argocd, grafana, infisical,
                                         alertmanager, pgweb, s3, fleet,
                                         proxmox, blog, dreamer, searxng,
                                         ente, e2e
A    *.ente.bnei.dev    → 82.65.231.50   api.ente, album.ente
A    *.e2e.bnei.dev     → 82.65.231.50   agent-fleet per-task previews
MX   bnei.dev           → 10 mxa/mxb.mailgun.org
TXT  bnei.dev           → v=spf1 include:mailgun.org ~all
TXT  smtp._domainkey    → (DKIM)
```

**Adding a new app hostname needs no DNS change** — the wildcard covers it.
Three wildcards rather than one because DNS wildcards match exactly one label
(RFC 4592), so `*.bnei.dev` does not cover `api.ente.bnei.dev`.

**The apex and `*.bnei.dev` are proxied (orange cloud) as of 2026-08-18** —
[ADR-0038](docs/adr/0038-cloudflare-proxy-dns01-and-origin-lock.md). This was
impossible until `le` moved to DNS-01: Cloudflare's proxy terminates TLS at its
edge, so a TLS-ALPN-01 challenge on 443 is answered by Cloudflare and never
reaches Traefik, and the renewal fails silently up to 90 days later. DNS-01
validates over a TXT record and does not care who terminates 443.

Three things stay **grey (DNS-only)**, each for a specific reason:

| Record | Why it stays grey |
|---|---|
| `fleet.bnei.dev` | ConnectRPC streaming; Cloudflare Free returns 524 when the origin sends nothing for 100s |
| `s3.bnei.dev` | Garage SigV4 signs the encoded path, and Cloudflare normalizes URI paths — untested, and a mismatch reads as an auth bug |
| `*.ente.bnei.dev` | Two labels deep. Free Universal SSL covers the apex plus **one** wildcard level, so a proxied record here serves no certificate at all |

Both explicit A records override the proxied wildcard — an explicit record always
beats a wildcard, the same mechanism the SMTP2GO CNAMEs rely on.

*Previously: manual per-host A records, no wildcard, on Google Cloud DNS
nameservers (`ns-cloud-d*.googledomains.com`) — described loosely in these docs
as "Squarespace DNS", which is where the records were edited but not what
answered queries.*

Endpoint naming (`k8s-proxmox-gpu.bnei.lan` vs `k8s.bnei.lan`) is resolved
in favor of `k8s.bnei.lan` — see
[ADR-0016](docs/adr/0016-k8s-endpoint-naming.md). This list is declared,
reconciled-every-run state (`pihole_hosts_records` in
`ansible/playbooks/pihole-configure.yml`) — add a line there (and here)
as each new host is actually provisioned, never speculatively.

---

## 4. Ingress & TLS

**WHAT:** Traefik in-cluster (Helm + ArgoCD), Service `LoadBalancer` via
MetalLB, `IngressRoute` for all app HTTPS routing, native ACME **DNS-01 via
Cloudflare** (resolver `le`), `acme.json` on a PVC (RWX or `replicas: 1`,
never `emptyDir`).

> **Changed 2026-08-18 ([ADR-0038](docs/adr/0038-cloudflare-proxy-dns01-and-origin-lock.md), Proposed):**
> `le` was TLS-ALPN-01 until this change. Cloudflare's proxy terminates TLS at
> its edge, so a TLS-ALPN-01 challenge on 443 is answered by Cloudflare and
> never reaches Traefik — any proxied host stops renewing, silently, until the
> cert expires ~90 days later. DNS-01 validates over a TXT record and does not
> care who terminates 443, so it is the prerequisite for proxying anything.
> The resolver keeps its name and its `/data/acme.json` storage, so no
> `IngressRoute` changed and no existing cert was re-issued.
>
> Confirmed live on 2026-08-18: with `*.api.voconsteroid.com` **proxied**,
> `dev.api.voconsteroid.com` returned no certificate at all — Cloudflare's free
> Universal SSL covers the apex and first-level subdomains only, so a
> second-level name has nothing to present. This is why ADR-0038 renames the
> deep hostnames (`ente-api`, `ente-album`, `<id>-e2e`, `dev-api`) rather than
> buying Advanced Certificate Manager.

A **second resolver `le-dns`** (ACME DNS-01 via Cloudflare, own storage at
`/data/acme-dns.json`) issues the `*.e2e.bnei.dev` wildcard cert that
agent-fleet's per-task preview subdomains ride on — TLS-ALPN-01 structurally
cannot issue a wildcard. Every other host stays on `le`; no existing cert is
re-issued. See [ADR-0033](docs/adr/0033-dns-to-cloudflare-and-dns01-wildcard.md).

Why (Gateway API reversal, cert-manager rejection): see
[ADR-0001](docs/adr/0001-ingress-traefik-ingressroute-over-gateway-api.md).
cert-manager stays banned; only the DNS-01 half of that ADR is amended.

> **Doc note:** the challenge type has changed twice. ADR-0001 and parts of
> these docs say "HTTP-01"; it was **TLS-ALPN-01** from the 2026-07-28 Freebox
> cutover (LE's external HTTP-01 validation on port 80 never reached Traefik's
> challenge handler — suspected transparent ISP proxy — while 443 was already
> proven), and is **DNS-01** since 2026-08-18 (ADR-0038), because Cloudflare's
> proxy answers 443 at its edge. If DNS-01 ever needs backing out, TLS-ALPN-01
> is the fallback and HTTP-01 is not — and backing out means un-proxying every
> record first. See `docs/bootstrap-test-notes.md`.

```mermaid
sequenceDiagram
    participant C as Client
    participant FB as Freebox (port-forward)
    participant MLB as MetalLB VIP (.233)
    participant TR as Traefik (IngressRoute + ACME)
    participant SVC as K8s Service
    participant POD as App Pod

    C->>FB: HTTPS request to *.bnei.dev
    FB->>MLB: forward to VIP
    MLB->>TR: L2-announced traffic
    TR->>TR: TLS terminate (ACME DNS-01 cert, resolver le)
    TR->>SVC: route by IngressRoute match
    SVC->>POD: forward to pod
    POD-->>C: response
```

---

## 5. GitOps / ArgoCD

**WHAT:** ArgoCD (Helm-installed, not a kubespray addon — see
[ADR-0005](docs/adr/0005-argocd-install-helm-not-kubespray-addon.md)),
Pattern C app delivery ([ADR-0004](docs/adr/0004-gitops-pattern-c-registry-applicationset.md)).
Full operational detail — bootstrap sequence, wave ordering, credential
chain, how to add an app — lives in [`gitops/README.md`](gitops/README.md),
not repeated here.

```mermaid
graph TD
    Registry[apps/registry.yaml] --> AppSet[ApplicationSet — list generator]
    Chart[platform/common-app-chart] --> AppSet
    AppSet --> App1[Application: app A]
    AppSet --> App2[Application: app B]
    App1 --> Render[Helm render: Deployment + Service + IngressRoute]
    App2 --> Render
    Render --> Cluster[Cluster resources, synced automated+prune+selfHeal]
```

**CI/CD:** a self-hosted GitHub Actions runner (`myoung34/github-runner`)
runs in-cluster as its own standalone Application
(`gitops/bootstrap/actions-runner-application.yaml`,
`gitops/platform/actions-runner/`) — GitHub-hosted runners can't reach the
cluster's LAN-only K8s API, and a VPN was already rejected (ADR-0009). RBAC
is scoped per-namespace (`vos`/`vos-dev` today), never cluster-wide. It's
the execution target for `common-app-chart`'s `hooks:`/`oneOffJobs:`
(ArgoCD sync hooks + a ledger-driven reusable workflow for one-time
scripts — ADR-0022 / ADR-0023).

---

## 6. Database / Pigsty

- **Stack:** PostgreSQL + Pigsty (primary/replica + PgBouncer + pgBackRest).
- **Topology:** 2 PG data VM nodes, primary/replica, **automatic failover
  via Patroni + etcd accepted** (reverses the earlier "no automatic
  failover" stance — see `DECISION.md` §2, [ADR-0029](docs/adr/0029-postgres-automatic-failover-3-node-etcd-quorum.md)).
  **DCS is a real, live 3-node etcd quorum** (as of 2026-07-30): the 2
  data-node hosts plus a dedicated witness-only VM on ex-laptop,
  mirroring the k8s 3-CP/etcd placement logic (ADR-0017). `floor(3/2)+1`
  = 2 — tolerates any single member going down.

| Node | Host | Role (live, confirmed 2026-07-30) |
| --- | --- | --- |
| pg02 (`192.168.1.207`) | proxmox PVE (`.165`) | **Replica** as of 2026-08-15 (was Leader), etcd DCS member (`etcd-1`) |
| pg01 (`192.168.1.205`) | server1 (`.200`) | Replica, streaming, lag 0 — migrated off `.165` via live migration; etcd DCS member (`etcd-2`) |
| pg-etcd-witness (`192.168.1.197`) | ex-laptop | etcd DCS member only (`etcd-3`), no PG data |

Roles are the opposite of pg01/pg02's original static naming — a Patroni
failover already promoted `.207` at some point before anyone checked live
state, which is exactly the behavior ADR-0029 now accepts rather than
fights. **Redis relocated 2026-07-30** from `.207`/`.165` (zero HA, sat on
the host that gets rebooted for gaming, took ArgoCD's `externalRedis`
cache down with it) to pg01's VM (`.205`, server1) — consumers resolve
`redis.bnei.lan` (Pi-hole DNS), not a hardcoded IP, so future moves are a
DNS-record change only. Migration from the original source (`.193`, PG
16.4) is complete; source VM decommissioned.

`pg01`'s migration to server1 (2026-07-30) hit a kernel panic on first
boot on the new host — the VM was an old, hand-built import (not one of
this repo's cloud-init clones), and a real Proxmox live migration doesn't
give the guest a fresh boot to reset any host-specific state. Recovered
cleanly with a reboot; confirmed healthy afterward (`patronictl list`:
`streaming`, timeline matches the leader, lag 0). See
`docs/bootstrap-test-notes.md`'s 2026-07-30 entry.

**Historical note, now resolved**: DCS was briefly a single etcd node
(`.207`, on `.165`) mid-rollout, and that gap was confirmed live, not
just theoretical — stopping `.207` for an unrelated maintenance task
(guest agent install) took the sole DCS node down with it, and `.205`
sat healthy-but-unable-to-promote for the whole outage because Patroni
had no DCS to coordinate through. The Pigsty VIP (`.232`, what every
client actually connects to) follows the Patroni Leader and can only
move there via etcd — so **client-facing access went down with `.207`,
not just internal replication state**, even though `.205` was fully
healthy the entire time. See `docs/bootstrap-test-notes.md`'s 2026-07-30
entries. The 3-node quorum above closes this gap — a single host going
down (any of the 3) no longer takes DCS with it.

**Proven for real 2026-08-15**, unplanned: `.165` went down during the
room switch replacement, taking the then-Leader `.207` and `etcd-1` with
it. **`.205` promoted automatically and the `.232` VIP followed** — the
VIP's new MAC was visible from a plain `arp -a` on the LAN, and DCS
quorum survived on `etcd-2`/`etcd-3`. That is exactly the end-to-end test
this ADR was written to enable, executed involuntarily and passed.

**Replica rejoin took two manual steps**, 2026-08-15: `.207` came back on
timeline 27 and never self-healed (`remove_data_directory_on_diverged_timelines:
false`), so it needed `patronictl reinit`; that restored the data but left
replication dead, because reinit reuses the old slot and this one was
`wal_status=lost`. Dropping the slot let Patroni recreate it. Now
`streaming`, `wal_status=reserved`, **lag 0** — verified. See
`docs/bootstrap-test-notes.md`.

```mermaid
graph LR
    subgraph Pigsty
        P1[pg01 .205 — leader, on server1] -- streaming replication --> P2[pg02 .207 — replica, on .165]
        P1 --> Bouncer[PgBouncer]
        P1 --> Exporter[pg_exporter → Grafana]
        P1 -.->|etcd DCS| E1[.207 etcd-1]
        P2 -.->|etcd DCS| E2[.205 etcd-2]
        W[pg-etcd-witness .197, ex-laptop] -.->|etcd DCS| E3[.197 etcd-3]
        E1 <-.-> E2
        E2 <-.-> E3
        E1 <-.-> E3
    end
    P1 -- pgBackRest, local --> LocalBackup[local disk, each VM]
    P1 -.->|pgBackRest, off-host target: open| Open["pg-backup Garage bucket exists,<br/>not yet wired into pgbackrest_repo — see §7"]
```

**Backups:** 7 daily / 4 weekly / 3 monthly, PITR 7 days — see §10 below
for the full backup matrix across all data types.

---

## 7. Storage

### Longhorn (K8s app PVs)

Default StorageClass, in-cluster, distributed across each K8s VM's
dedicated `scsi1` disk. Replica count 3 (chart default) — was degraded
(2/3) with only `k8s-cp-01`/`k8s-worker-01` schedulable; now 5 nodes are
schedulable (`k8s-cp-01/02/03`, `k8s-worker-01/02`, all `worker: true`
per `terraform/variables.tf`'s `k8s_nodes` map), so full 3/3 replication
is achievable — not yet re-verified live post-join (check
`kubectl get volumes.longhorn.io -A` before relying on this). Postgres is **not** on
Longhorn — local on each data VM. Why Longhorn over Ceph/NFS:
[ADR-0002](docs/adr/0002-storage-longhorn-over-ceph-nfs.md). Rollout
specifics (sizing, replica count on `k8s-cp-01`, `local-path-provisioner`
fate, backup target): [ADR-0019](docs/adr/0019-longhorn-rollout-specifics.md)
(Accepted).

### `nfs` StorageClass (unreplicated, RWX)

Second, **non-default** StorageClass — `csi-driver-nfs` provisioning
subdirectories under `nfs-storage.bnei.lan:/export/k8s` (the `scsi2` disk
on the `nfs-storage` VM, separate from ADR-0026's PVE template export).
Exists for two things Longhorn does badly here: real ReadWriteMany without
a `share-manager` pod in the path, and bulk regenerable data that isn't
worth 3× replication on the 40GB control-plane disks.

**Unreplicated, and never backed up.** It lives and dies with `server1`,
and mounts are `hard` — if that host is down, `nfs` PVCs block rather than
return truncated reads. There is no backup for this class and none planned
(decided 2026-08-14, §10), so "only put data there that can be lost and
regenerated" is not advice pending a safety net — it *is* the safety net.
Everything else stays on Longhorn. A PVC with no `storageClassName` still
gets Longhorn — opting in is always explicit.
[ADR-0036](docs/adr/0036-nfs-storage-class-for-k8s.md).

`local-path` remains a third, node-pinned RWO fallback (ADR-0019).

### Garage (object storage)

LXC on proxmox PVE, NVMe-backed, 200GB allocated, S3-compatible API at
`s3.bnei.dev` via Traefik (live — `gitops/redirectors/garage-s3.yaml`,
[ADR-0030](docs/adr/0030-expose-garage-s3-externally.md); also reachable
LAN-only at `garage.bnei.lan:3900`). Single node initially, can scale to
2-3 nodes later. Replaces MinIO (archived Jan 2026).

### Container registry (Zot)

Zot in-cluster at `registry.bnei.lan:5000` — a MetalLB `LoadBalancer` on a
**pinned** `.234`, deliberately **no `IngressRoute`**: `.lan` is a name
Let's Encrypt cannot issue for, so there is no certificate to route TLS
with. Nodes trust it over plain HTTP via `containerd_registries_mirrors`
(`inventory/ukubi/group_vars/all/settings.yml`); the pinned address, the
Pi-hole record and that containerd entry all name the same IP and must move
together. Anonymous pull, htpasswd-authenticated push.

Blobs live in Garage's `zot-registry` bucket (40GB quota — the LXC's 200GB
is shared with `k8s-longhorn-backup`, `pg-backup`, `agent-fleet-files` and
`ente-photos`, and an unbounded registry starves the backup system). The
pod itself is stateless: `dedupe: false` plus an `emptyDir` staging
directory, so no durable state lives in the cluster.

**Note the coupling this creates:** Garage is now on the critical path of
every pod start, and its LXC sits on `.165` — the host rebooted for gaming,
which drains pods onto cache-cold nodes at the same moment the registry
backend disappears. Accepted and bounded rather than unnoticed; see
[ADR-0034](docs/adr/0034-in-cluster-oci-registry-zot-garage-backed.md).

Images are built on the **`build-runner` LXC** (`.111`, VMID 103), not in
the cluster: buildah cannot extract image layers without `CAP_SYS_ADMIN`,
and the only in-cluster way to grant that is a privileged pod executing
app-repo `Dockerfile`s. Builds therefore cannot touch a Kubernetes node at
all, which is stronger isolation than the pod design it replaced.

### Proxmox storage

- `local` (directory): unchanged.
- `local-lvm` (LVM-thin): VM disks, thin-provisioned.
- ZFS pool vs `local-zfs` directory for new storage: open, see
  [ADR-0014](docs/adr/0014-pve-storage-layout-zfs-vs-local-zfs.md).
- `shared-templates` (NFS, hosted on the `nfs-storage` VM on `server1`):
  cluster-wide shared storage for the golden K8s template's disk +
  cloud-init vendor-data, so Terraform's cross-host VM cloning takes a
  direct-clone path instead of clone-then-migrate — see
  [ADR-0026](docs/adr/0026-nfs-shared-pve-storage-cross-host-clone.md).
  Scoped strictly to PVE-internal VM template storage, **not** mounted
  into K8s (that's Longhorn, above) — a different problem from the NFS
  server ADR-0002 already rejected for K8s app PVs.

### Backup target

Still open, but a candidate now exists: `garage-configure.yml` already
provisions a `pg-backup` bucket + S3 keys in Garage (§7 above), it's just
not wired into pigsty's `pgbackrest_repo` config yet. The original plan
— the 149GB HDD on server1 slated to replace the dead Ceph OSD — was
physically removed before server1's reinstall
([ADR-0024](docs/adr/0024-server1-single-disk-ext4-no-dedicated-zfs.md))
and is dropped in favor of Garage.

---

## 8. Identity & Access

### authentik (the identity layer)

Single sign-on for everything the cluster fronts, deployed as a **platform** app
(upstream chart, sync wave 5, `authentik.bnei.dev`) and backed by the Pigsty
Postgres cluster. Decided in
[ADR-0039](docs/adr/0039-authentik-identity-layer.md), amended for `fleet` by
[ADR-0041](docs/adr/0041-fleet-native-oidc-not-forwardauth.md). Operational
reference: [`docs/runbook-authentik-identity.md`](docs/runbook-authentik-identity.md).

Four access tiers:

| Tier | Mechanism | Status |
|---|---|---|
| Public | none | — |
| Native OIDC | the app is an OIDC relying party | **Live.** ArgoCD, Grafana, and agent-fleet `core` |
| forwardAuth | Traefik `Middleware/authentik-forwardauth` in front of the route | **Live.** e2e preview hosts, `wedding.bnei.dev/admin`. Alertmanager, pgweb and Proxmox still to move |
| Critical | adds a WebAuthn passkey policy | Not built |

Three properties that are load-bearing rather than incidental:

- **Nothing is created by clicking.** Every provider, application, group and
  policy is a blueprint in git. A blueprint carrying an OAuth2 client secret is
  an `InfisicalSecret` whose *template is the blueprint*; one carrying no
  credential is a plain `ConfigMap`. `/authentik-oidc` is the procedure.
- **One group, `platform-admins`**, read by both ArgoCD (`role:admin` over a
  `role:readonly` default) and Grafana (`role_attribute_path`, defaulting to
  `Viewer`). Deliberately not authentik's built-in `authentik Admins` — that
  would make "can administer the IdP" and "can administer the cluster" the same
  claim. Both expressions fail closed.
- **Local admins are kept** on ArgoCD and Grafana. ArgoCD is what deploys
  authentik; if its only login path ran through authentik, an authentik failure
  would be recoverable through nothing but raw `kubectl`. This is what makes the
  whole layer revertible.

`fleet.bnei.dev` is the one host that federates *natively* rather than through
the middleware, because a Traefik middleware cannot gate a worker pod calling
`agent-fleet-core.agent-fleet.svc:8080` on the pod network — the request never
passes through Traefik at all. `core` must not trust `X-authentik-*` headers.

**mTLS is structurally unavailable** as a "special device access" mechanism:
Cloudflare terminates TLS at the edge, so a client certificate can never reach
Traefik. Passkeys are the answer instead.

### Proxmox

API tokens per host (exists for proxmox; new token needed for server1
after PVE install).

### SSH

Per-host keys for each VM/LXC. Bastion pattern: hermesagent LXC → all
hosts/VMs.

### K8s

New service accounts per app; Infisical for app secrets.

### TLS

Per-hostname certs via Traefik ACME **DNS-01 via Cloudflare** (§4 above,
resolver `le` — TLS-ALPN-01 until ADR-0038). Each `*.bnei.dev` host gets its
own cert on first request, `certResolver: le` on its `IngressRoute`.

On-demand issuance is worth knowing about: Traefik orders on the first TLS
handshake for an unseen SNI and serves a self-signed default meanwhile. DNS-01
propagation makes that window 30–120s, and under Cloudflare's `strict` SSL mode
a self-signed origin cert returns HTTP 526.

**Both are resolved as of 2026-08-18.** `le-dns` issues a `*.bnei.dev` wildcard
(SAN `bnei.dev`) served as Traefik's default TLS store certificate, so an
unseen hostname is covered from its first handshake and never presents
`TRAEFIK DEFAULT CERT`. Per-host certs from `le` still win for their own SNI —
the wildcard is a fallback, not a replacement. With that in place both zones
moved to **Full (strict)**, verified by creating a brand-new hostname and
getting 301 rather than 526.

> **Caveat for `voconsteroid.com`:** that zone is also `strict`, but the origin
> wildcard covers `*.bnei.dev` only. Its two hosts have valid per-host certs,
> so it is safe today — but a *new* `voconsteroid.com` hostname WILL return 526
> for its issuance window, unlike a new `bnei.dev` one. Add a second default
> store entry, or expect the window.

**One wildcard exists:** `*.e2e.bnei.dev`, issued by the second resolver
`le-dns` (ACME DNS-01 via Cloudflare) — TLS-ALPN-01 and HTTP-01 structurally
cannot issue a wildcard, only DNS-01 can. That is why ADR-0001's DNS-01
rejection got a narrow carve-out in
[ADR-0033](docs/adr/0033-dns-to-cloudflare-and-dns01-wildcard.md) once
`bnei.dev` moved to Cloudflare. The wildcard is what makes agent-fleet's
per-task preview subdomains viable at all: LE allows 50 new certs per
registered domain per 7 days, shared across every `bnei.dev` host, so
per-session certs would have exhausted issuance domain-wide.

> **Flag:** an earlier draft of this section proposed "internal certs
> via internal CA (for Postgres, etcd, etc.)". That needs reconciling
> against [ADR-0006](docs/adr/0006-reject-infisical-as-ssh-tls-ca.md)
> (Infisical rejected as a CA) — it isn't necessarily the same proposal
> (a non-Infisical internal CA wasn't explicitly ruled out), but it was
> never resolved. [ADR-0040](docs/adr/0040-cluster-internal-hardening-baseline.md)
> closed one half of it — pod-to-pod confidentiality is Cilium's transparent
> WireGuard, not a CA — but explicitly left the rest open. Treat as an open
> question, not a locked decision, until a fresh ADR settles it.

---

## 9. Observability

- Prometheus + Grafana in K8s (existing).
- pg_exporter on Postgres (via Pigsty).
- node_exporter on every host (Pi 4, ex-laptop, PVE hosts).
- Hubble for Cilium L3/L4 observability, exporting flow metrics
  `[dns, drop, tcp, flow, icmp]` to Prometheus. `http` is deliberately
  excluded — L7 means Hubble parses application payloads, a different
  privacy and performance posture that needs its own decision
  ([ADR-0040](docs/adr/0040-cluster-internal-hardening-baseline.md) Decision 4).
  Note `cilium_enable_hubble_metrics: true` alone is a no-op; the list is
  what turns it on.
- Loki + Grafana Alloy for centralized logging (implemented — Loki
  SingleBinary mode with filesystem storage, Alloy DaemonSet shipping
  container logs from every node; Alloy chosen over Promtail since it's
  Grafana's OTel-Collector-based agent, needed anyway for planned OTLP
  traces/metrics — see [ADR-0027](docs/adr/0027-logging-loki-alloy-over-clickhouse-promtail.md)).
  A first Grafana-native alert rule (log error-rate spike, routed to
  Discord) exists as a starting point — see
  `gitops/platform/values/grafana/values.yaml`'s `alerting:` key; more
  targeted rules still need to be authored. Grafana's "App Logs" dashboard
  gives namespace/level/text-search filtering over Loki. User apps can
  declare their own log alert rules from their own repo via
  `common-app-chart`'s `logAlerts:` values block (picked up dynamically by
  Grafana's alerts sidecar) — no platform-repo edit needed per app.
- Alertmanager for critical alerts, routed to a Discord channel webhook via
  its native `slack_configs` receiver (see
  `gitops/platform/values/prometheus/values.yaml`). Postgres-down/disk-full
  rules still need to be authored — the receiver/route plumbing is what's
  implemented so far.

### Whitebox: Alloy's log-tailing pipeline

The "Alloy" box in the diagram above is a DaemonSet — one pod per node,
config in `gitops/platform/values/alloy/values.yaml`. Internally it's a
5-stage pipeline, entirely file-based (no Kubernetes API calls to read log
content — only to read pod *metadata*):

```mermaid
graph TD
    DK["discovery.kubernetes<br/>role=pod — watches ALL pods cluster-wide<br/>(metadata only: namespace, name, uid, labels)"]
    DR["discovery.relabel<br/>1. keep only __meta_kubernetes_pod_node_name == K8S_NODE_NAME<br/>2. derive namespace/pod/container/app/job labels<br/>3. build __path__ from pod uid + container name"]
    LFM["local.file_match<br/>expands __path__ globs into concrete<br/>file targets, watches for create/delete"]
    LSF["loki.source.file<br/>tails matched files from position markers"]
    LP["loki.process<br/>stage.cri {} — strips CRI framing<br/>('&lt;time&gt; &lt;stream&gt; &lt;flag&gt; &lt;content&gt;')"]
    LW["loki.write<br/>pushes to platform-loki:3100"]

    DK --> DR --> LFM --> LSF --> LP --> LW
```

Why this shape, in order:

1. **Node-local filtering first** (`discovery.relabel` step 1). Every
   Alloy pod's `discovery.kubernetes` sees every pod in the cluster, but a
   given node can only read log files that physically exist on its own
   disk — so each Alloy instance immediately drops every target that
   isn't scheduled locally, using `K8S_NODE_NAME` (injected by the Alloy
   chart itself into every pod, not a value this repo sets) matched
   against `__meta_kubernetes_pod_node_name`.
2. **Path construction, not API lookup** (`discovery.relabel` step 3).
   kubelet writes container logs to a fixed, predictable path for every
   pod on containerd:
   `/var/log/pods/<namespace>_<pod-name>_<pod-uid>/<container>/*.log`.
   Alloy reconstructs this path directly from Kubernetes metadata
   (`__meta_kubernetes_pod_uid` + `__meta_kubernetes_pod_container_name`,
   globbing the `<namespace>_<pod-name>_` prefix) rather than asking the
   API "give me this pod's logs." The whole node's `/var/log` is mounted
   into the Alloy container read-only via the chart's `alloy.mounts.varlog:
   true` (a hostPath volume) for this to be readable at all.
3. **`local.file_match` + `loki.source.file`, not `loki.source.kubernetes`.**
   This is the deliberate part: an earlier version of this pipeline used
   `loki.source.kubernetes`, which proxies log reads through the kubelet
   API instead of the filesystem. When a pod is deleted — this cluster's
   CI-driven app namespaces redeploy constantly — that component's tailer
   could leak instead of tearing down, then loop forever against a
   container containerd had already garbage-collected, forwarding the
   kubelet's literal `unable to retrieve container logs for
   containerd://<id>` error text into Loki as if it were real application
   output (see ADR-0027's 2026-07-29 update, PR #67). File-based tailing
   doesn't have this failure mode: when a pod is deleted, its log file
   simply stops existing, `local.file_match` drops the target cleanly,
   and there's no API error body to ever misinterpret as log content.
4. **`stage.cri` restores what the kubelet API used to do implicitly.**
   Raw kubelet log files are CRI-framed (`2026-07-29T11:02:04Z stdout F
   {"level":"info",...}` — timestamp, stream, partial/full flag, then the
   actual line). `loki.source.kubernetes` stripped this automatically as
   part of its API response; reading the file directly exposes it, so
   `loki.process`'s `stage.cri {}` strips it back down to the real log
   line + a `stream` label before `loki.write` pushes it to Loki.

---

## 10. Backup Strategy

| Data | Method | Target | Frequency | Retention |
| --- | --- | --- | --- | --- |
| Postgres (full + WAL) | pgBackRest | local only; off-host target open — `pg-backup` Garage bucket provisioned but not yet wired into `pgbackrest_repo`, see §7 | daily + continuous WAL | 7d / 4w / 3m |
| K8s manifests | Git | `gitops/` in `github.com/MohammadBnei/infra-bootstrap` (this repo — not the legacy `k8s-cluster` submodule) | on commit | indefinite |
| K8s PVs (`longhorn` class) | Longhorn snapshots (+ Velero if added) | Garage (S3) | daily | 7 daily |
| K8s PVs (`nfs` class) | *none, by design* | nothing, and none planned — decided 2026-08-14. The class only ever holds regenerable data, so a restore path would go unused; that scope restriction is the entire safety story, with no second line of defence ([ADR-0036](docs/adr/0036-nfs-storage-class-for-k8s.md)) | — | — |
| Container images | *none, by design* | rebuildable from git + `build-runner` — losing the `zot-registry` bucket costs a rebuild, not data ([ADR-0034](docs/adr/0034-in-cluster-oci-registry-zot-garage-backed.md)) | — | — |
| `build-runner` LXC | *none, by design* | rebuildable from `terraform/build-runner.tf` + `ansible/playbooks/build-runner-configure.yml`; holds no state worth keeping | — | — |
| Proxmox config | cron + tar | open, see §7/ADR-0024 | daily | 7 daily |
| Pi-hole config | restic | open, see §7/ADR-0024 | daily | 7 daily |
| `/home/mohammad` | restic | open, see §7/ADR-0024 | daily | 7 daily |
| Forgejo (`/var/lib/forgejo`) | **not yet — prerequisite, see below** | git repos are filesystem-only; PRs/issues/CI history exist nowhere else and do **not** push-mirror ([ADR-0035](docs/adr/0035-self-hosted-forgejo-authoritative-github-mirror.md)) | — | — |

Backup verification: monthly restore test to a sandbox VM.

### The gap: every path terminates inside the same failure domain

**This is the largest known divergence from `VISION.md`, and it is stated
here rather than discovered during a restore.**

Read the table by destination rather than by row and the shape is plain:
Longhorn PVs land in Garage; Garage is an LXC on `.165`; Postgres is local
only; Proxmox, Pi-hole and `/home` are open. **Nothing leaves the house.** A
fire, a theft, or a `.165` disk failure takes the primary and its backup
together — which is not a backup story, it is a copy.

`VISION.md` principle 8 states the requirement directly: *"the restore path
must survive the system failing entirely — so it cannot live only inside the
cluster."* Its implications section names this as the **prerequisite before
autonomy**, and it sits between the registry (done) and self-hosted git (not
started) in that ordering — deliberately, because moving git into the house
before a restore path exists would concentrate more into one failure domain,
not less.

Two things made this sharper rather than softer since it was written:

- **Garage now carries a double load.** It is both the backup *target* and, since [ADR-0034](docs/adr/0034-in-cluster-oci-registry-zot-garage-backed.md), on the critical path of every pod start. Losing it is simultaneously an outage and the loss of the thing that would recover from an outage.
- **GitHub is currently the only copy that leaves the failure domain** — for `gitops/` and app repos. That is an accident of not having migrated yet, not a designed restore path, and [ADR-0035](docs/adr/0035-self-hosted-forgejo-authoritative-github-mirror.md) would convert it into a deliberate one (mirror as restore path). Which is exactly why that ADR is gated on this row being filled first.

**Target:** at least one off-site (or at minimum off-`.165`, off-premises)
destination for Postgres, Longhorn PV backups, and `/home`, with a rehearsed
restore — not merely a configured one. Until that exists, `docs/adr/0035`
stays `Proposed` and unsupervised operation stays bounded.

## 11. Migration Path

Full phased plan (execution detail lives in `docs/bootstrap-test-notes.md`
and the runbooks under `docs/` — see `docs/README.md`'s status table for
which ones still remain):

```mermaid
graph TD
    P0[Phase 0: Backups, Pi 4 setup, source Postgres dump]
    P1[Phase 1: Build new K8s cluster on proxmox PVE only]
    P2[Phase 2: Migrate K8s workloads via ArgoCD + one-off NFS-to-Longhorn PV copy]
    P3[Phase 3: Reinstall server1 as PVE]
    P4[Phase 4: Finish Postgres HA layout - Pigsty 2 data VM]
    P5[Phase 5: Postgres cutover]
    P6[Phase 6: Deploy Garage on proxmox PVE]
    P7[Phase 7: Finalize Pi-hole + local DNS]
    P8[Phase 8: Validate, decommission old infrastructure]

    P0 --> P1 --> P2 --> P3 --> P4 --> P5 --> P6 --> P7 --> P8
```

### Where this is now

Phases 0-8 above describe the *migration onto* this hardware, and that arc
is substantially done. What follows is no longer migration but convergence,
and its ordering comes from `VISION.md`'s implications section rather than
from this diagram:

| Step | State |
| --- | --- |
| **Registry in-cluster, before git** | **Done** — Zot + `build-runner`, [ADR-0034](docs/adr/0034-in-cluster-oci-registry-zot-garage-backed.md). `editable-blog` cut over and pulling from it |
| **A restore path that leaves the failure domain** | **Not started — the current blocker.** See §10's gap. Gates everything below it |
| **Then git, mirrored** | Designed, `Proposed` — [ADR-0035](docs/adr/0035-self-hosted-forgejo-authoritative-github-mirror.md). Deliberately *not* started: moving git in-house before a restore path exists concentrates more into one failure domain |
| **Give drift detection somewhere to write** | Not started — `mission-drift` produces prose, not proposed tasks |

The ordering is not arbitrary and should not be reordered for convenience:
each step is what makes the next one safe to take.

---

*This document is design intent. Actual state may diverge temporarily
during migration — see `docs/infrastructure-actual.md`. Update both
this file and `infrastructure-actual.md` when real changes land.*
