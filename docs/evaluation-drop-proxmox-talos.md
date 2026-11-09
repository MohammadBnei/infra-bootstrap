# Evaluation: drop Proxmox, run Kubernetes on bare metal (Talos)

**Status:** exploration only. Not a decision and not an ADR. Nothing has
changed. If any option here goes ahead, it becomes an ADR first: it would
supersede [ADR-0008](adr/0008-reject-flatcar-vm-os.md) and amend
[ADR-0055](adr/0055-netbird-as-daily-ssh-path.md) and
[ADR-0034](adr/0034-in-cluster-oci-registry-zot-garage-backed.md) (see §7).

**Date:** 2026-11-09. Written from the repo only. No live `kubectl`, `pvesh`
or SSH scan was done, so every RAM figure here is an *allocation* taken from
`ARCHITECTURE.md` §1, not a measurement. §3 lists the commands that give the
real numbers.

**Input:** a handoff from a chat with the owner, proposing Talos on bare
metal + `siderolabs/talos` Terraform + KubeVirt + optionally CloudNativePG
in place of Proxmox + kubespray + Pigsty VMs. This document checks that
handoff against the repo and works through its six next steps.

---

## 0. Verdict

Don't rebuild yet. The repo shows three blockers the handoff didn't know about:

1. **No off-site restore path exists yet** (`ARCHITECTURE.md` §10/§11; the
   repo calls it "the current blocker"). A full cluster rebuild is the riskiest
   time to have every backup sitting on one LXC on `.165`. This must come first
   whichever option is chosen.
2. **`.165` dual-boots Windows for gaming.** Talos wipes its whole install
   disk. Before Talos can go on `.165`, we need to know how Windows boots today
   (its own NVMe, or a partition on the PVE disk).
3. **Several guests must stay outside Kubernetes by design.** `build-runner`
   needs `CAP_SYS_ADMIN`, and ADR-0034 forbids in-cluster builds. Garage is the
   backup target. Infisical's database is on Pigsty, so a cluster rebuild
   doesn't take secrets with it. On Talos each of these becomes a KubeVirt VM
   or moves into the cluster, and moving them in makes the failure-domain
   problem worse.

Recommended order (§8):

- **Now, no rebuild:** close the off-site backup gap, ship Postgres logs to
  Loki, and measure RAM.
- **Then:** if the measured win is modest, take most of it by going from 5 k8s
  VMs to 3 on Proxmox.
- **Talos later, only if the number justifies it**, through an ADR, one host
  at a time.

---

## 1. Corrections to the handoff

| Handoff said | Repo says | Where |
| --- | --- | --- |
| K8s nodes "assumed" to be Proxmox VMs | **Confirmed.** 5 QEMU VMs (Q35/OVMF, Ubuntu 24.04 cloud-init): 3 CP+etcd, 2 workers | `ARCHITECTURE.md` §1–2, `inventory/ukubi/hosts.yaml` |
| Hardware: old laptop, server, old gaming PC | Right, plus a **Pi 4** (`.55`, Pi-hole, authoritative `bnei.lan`) that is not a PVE node. The gaming PC is `.165` (Ryzen, 32 GB, 12 threads, 2× 1 TB NVMe, RTX 2070 SUPER) and **still dual-boots Windows** | `ARCHITECTURE.md` §1, ADR-0017 |
| No PgBouncer, no pgBackRest | **Wrong.** PgBouncer runs (most newer users set `pgbouncer: false`, but the pooler is up). pgBackRest has been live since 2026-08-26: daily full + WAL to Garage `pg-backup`, `retention_full: 2` | `pigsty/pigsty.yml`, ADR-0042 |
| No MinIO | Right. Garage replaced it | `ARCHITECTURE.md` §7 |
| Pigsty on pg01, pg02, pg-etcd-witness | Right. Leader is **pg01 `.205` on server1** (roles flipped after the 2026-08-15 failover). Also on pg01: **Redis** (ArgoCD's `externalRedis`) and **Pigsty's infra node** (the VictoriaMetrics behind Grafana's `ds-prometheus`) | `pigsty/pigsty.yml` `infra:`/`redis-main:` |
| Postgres logs don't reach Loki | Right. Pigsty nodes ship logs with their own `vector` (`node_monitor`), not Alloy. This can be fixed **without CNPG** (§6) | `docs/infrastructure-actual.md`, ADR-0029 |
| "Terraform via Proxmox provider" | Right (`bpg/proxmox`, 17 resources). It also builds the kubespray inventory, so Terraform and kubespray are coupled | `terraform/hosts-inventory.tf` |

Things the handoff left out, and that drive the trade-off:

- **NetBird SSH rollout (ADR-0055)**, 14 hosts enrolled 2026-10-11, including
  all 5 k8s nodes. Talos has no SSH, so k8s nodes drop out of that model and
  `ansible/scripts/node.sh` stops working for them.
- **Self-drain on `.165`** (`self-drain-configure.yml`). It exists because a
  Longhorn RWO volume once stuck on an ungraceful node loss. Talos has to
  reproduce it with kubelet graceful node shutdown.
- **21 databases** on one Patroni cluster, using **timescaledb**
  (`shared_preload_libraries`), **pgvector** and **postgis**.

---

## 2. Topology as committed (step 1)

| Host | Physical | Guests (vCPU / RAM) | Allocated | Unallocated (before host overhead) |
| --- | --- | --- | --- | --- |
| `.165` proxmox | 12 thr / 32 GB | k8s-cp-01 2/4, k8s-worker-01 6/15 (GPU), pg02 2/4, garage-storage LXC 2/2 | 12 vCPU / 25 GB | ~7 GB, ~3 GB of it reserved for PVE |
| `.200` server1 | 6 thr / 32 GB | k8s-cp-02 2/4, k8s-worker-02 6/16, pg01 2/4 (+Redis, +Pigsty infra), nfs-storage 1/1, k9s-dashboard LXC 1/1, build-runner LXC 4/4 | **16 vCPU on 6 threads** / 30 GB | ~2 GB |
| `.161` ex-laptop | 4 thr / 15 GB | k8s-cp-03 2/4, pg-etcd-witness 1/1, hermesagent LXC 2/4 | 5 vCPU / 9 GB | ~6 GB |
| **Total** | **22 thr / 79 GB** | 5 k8s VMs = **43 GB**; 3 PG VMs = 9 GB; 1 NFS VM; 4 LXCs = 11 GB | **~64 GB** | ~15 GB, ~5–6 GB of it PVE overhead |

Notes:

- server1 is the most constrained host on CPU (16 vCPU on 6 threads) and
  nearly full on RAM. ex-laptop has the most idle RAM.
- `.165` going down (every gaming reboot) removes **19 GB of k8s node RAM**
  out of 43 GB, plus the GPU, one k8s etcd voter, one Patroni etcd voter and
  Garage. That is 44% of k8s capacity. On bare metal it would be 32 GB of
  ~74 GB, about the same share: **Talos doesn't make gaming reboots any
  cheaper.**

---

## 3. RAM: what can be estimated vs measured (step 2)

What a bare-metal move gets back, roughly in order of size (estimates, not
measurements):

| Source | Estimate | Why |
| --- | --- | --- |
| RAM stranded inside fixed VM allocations (allocated, unused, and unavailable to any other guest) | **unknown: the number that decides this** | Needs measuring, see below |
| 5 k8s nodes → 3: two fewer sets of per-node DaemonSets + kubelet/containerd/system-reserved (Cilium agent, kube-proxy, Alloy, node-exporter, Longhorn instance-manager + CSI, NVIDIA plugin where relevant) | ~1–2 GB | Also available **without** dropping Proxmox (Option B) |
| Per-VM guest OS (~9 VMs × ~250–400 MB idle Ubuntu) | ~2–3 GB | But PG/NFS/witness/build-runner don't go away; they become pods or KubeVirt VMs |
| PVE host overhead (pve-cluster, corosync, pveproxy, ZFS ARC if any) | ~3–5 GB across 3 hosts | `.165` documents ~3 GB reserved; server1/ex-laptop use `local-lvm`, so no ZFS ARC there |
| Talos's own footprint | −0.3–0.5 GB per host | Smaller than Ubuntu+kubelet, but not zero |

**Realistic range: about 6–12 GB of 79 GB**, and most of the uncertainty is
the first row. Measure before deciding:

```bash
# On any PVE host: per-guest allocated (maxmem) vs used (mem), whole cluster
pvesh get /cluster/resources --type vm --output-format json \
  | jq -r '.[] | [.node, .name, .type, (.maxmem/1073741824|floor), (.mem/1073741824*10|floor/10)] | @tsv'
```

```bash
# On each PVE host: host-level overhead
free -g; systemctl status pve-cluster corosync pveproxy --no-pager | grep Memory
```

PromQL against `ds-platform-prometheus` (node_exporter runs on k8s VMs and PVE
hosts). Use a 7-day max, not a snapshot. Only the peak matters, and a quiet
evening will undercount:

```promql
max_over_time((node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)[7d:5m]) / 2^30
```

```promql
sum by (node) (kube_pod_container_resource_requests{resource="memory"}) / 2^30
```

The second query shows requests per node. If requests are near allocation
while real use is low, the fix is right-sizing requests, not removing a layer.

---

## 4. What is Proxmox-specific (step 3)

Retired or rewritten if Proxmox goes:

| Area | Files | Fate under Talos |
| --- | --- | --- |
| VM/LXC provisioning | `terraform/*.tf` (bpg/proxmox, 17 resources), `template.tf`, `cloud-init.tf` | Replaced by `siderolabs/talos` (machine configs, bootstrap, kubeconfig). First boot of each host is manual (USB/PXE) |
| Inventory generation | `terraform/hosts-inventory.tf` → `inventory/ukubi/hosts.yaml` | Gone with kubespray |
| Cluster install | `kubespray/` submodule, `inventory/ukubi/` (incl. `containerd_registries_mirrors` for zot) | `talosctl`; the zot mirror moves to `machine.registries.mirrors` |
| Host config | `pve-postinstall.yml` (incl. ADR-0013 lid/suspend masking), `k8s-node-prereqs.yml`, `gpu-node-configure.yml`, `self-drain-configure.yml` | Talos machine config + system extensions (`nvidia-open-gpu-kernel-modules`, `nvidia-container-toolkit`, `iscsi-tools`, `util-linux-tools` for Longhorn). Lid handling must be **re-tested** on ex-laptop: Talos has no logind |
| Control-plane VIP | kube-vip on `.180`/`k8s.bnei.lan` (ADR-0016) | Talos built-in L2 VIP, same address |
| Shared template storage | nfs-storage `/export/templates` (ADR-0026) | Gone: only PVE cloning used it |
| Corosync cluster | ADR-0020 | Gone |
| Node access | NetBird SSH peers (ADR-0055), `node.sh`, k9s hub, per-host LAN keys | **k8s nodes leave the SSH model**; access is the `talosctl` API + machine-config PKI. ADR-0055 needs an amendment |
| Hypervisor monitoring | blackbox `pveproxy:8006` probes, `target=~"pve-.*"` rules | Replaced by node-level alerts |
| CNI | Cilium chaining + kube-proxy IPVS (ADR-0003) | Works as is (`cni: none`, install via existing path). ADR-0003's reason (server1 CPU) is unchanged |
| Storage | Longhorn on each VM's `scsi1` disk | Longhorn on a Talos user volume / dedicated partition. Disk layout must be planned per host (server1 has a single 476 GB NVMe) |

Untouched: everything in `gitops/` (ArgoCD, Traefik, MetalLB pool, Pattern C),
Cloudflare/DNS, authentik blueprints, Infisical projects, Pi 4.

---

## 5. What must stay a VM vs can become a pod (step 4)

| Guest | Today | Under Talos | Notes |
| --- | --- | --- | --- |
| k8s-cp-0{1,2,3}, k8s-worker-0{1,2} | VMs | Bare-metal nodes (3, all CP+worker) | |
| pg01, pg02 | Pigsty VMs | **CNPG pods** or **KubeVirt VMs running Pigsty** | §6 |
| pg-etcd-witness | VM | Gone with CNPG (it uses the k8s API as DCS). With Pigsty-in-KubeVirt it stays | |
| Redis (on pg01) | Pigsty module | Pod (Bitnami/valkey chart via common-app-chart) | ArgoCD `externalRedis` points at `redis.bnei.lan`, a DNS change |
| Pigsty infra node (VictoriaMetrics, on pg01) | Pigsty module | Gone with CNPG; Grafana's `ds-prometheus` + vendored Pigsty dashboards go too, replaced by CNPG PodMonitor + its dashboard | |
| garage-storage | LXC | Garage Helm chart (pod) **or** KubeVirt VM | **In the cluster, it is the backup target living inside what it backs up.** Off-site backup (§0, 1) must exist first. It is also on every pod start's critical path (zot blobs) |
| nfs-storage | VM | `/export/k8s` → an in-cluster NFS server pod, or retire the `nfs` class into Longhorn RWX. `/export/templates` → gone | ADR-0036's "unreplicated, never backed up" stays true either way |
| build-runner | LXC (`nesting=1`, buildah as root) | **KubeVirt VM** | ADR-0034 forbids running builds in pods; a VM keeps the boundary. Needs `/dev/kvm` on the host; KubeVirt on Talos works but is another platform component to run |
| k9s-dashboard | LXC, holds cluster-admin kubeconfig | Retire, or a KubeVirt VM | Its job (ops hub off-LAN) partly becomes `talosctl` + kubeconfig over NetBird from a laptop |
| hermesagent | LXC on ex-laptop, holds Proxmox token + Infisical identity | KubeVirt VM, or pod | Its Proxmox token loses its purpose |
| Windows | dual-boot on `.165` | Still dual-boot, on its own disk (open question) | KubeVirt Windows is possible but not for gaming (GPU is taken by the k8s node) |

So "Kubernetes as the only control plane" in practice means **3 bare-metal
nodes plus KubeVirt carrying 2–4 VMs** (build-runner for sure; Garage and
hermesagent probably). KubeVirt is a whole extra platform layer, not a
small add-on. Harvester-style operation is the actual target.

---

## 6. Pigsty → CloudNativePG (step 5)

| Factor | Finding |
| --- | --- |
| Size | 21 databases (`meta`, `infisicaldb`, `authentik`, `netbirddb`/`netbirdeventsdb`/`netbirdidpdb`, `agentfleetdb`, `vos-monolith(-dev)`, `entedb`, `wirddb`, `bridge`, …). **Data volume not in repo:** run `SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY 2 DESC;` on `.205` |
| Extensions | **timescaledb** (preloaded, vos-monolith), **pgvector** (several), **postgis** (meta). CNPG's stock images ship pgvector; **timescaledb is not in them** (licence), so it needs either a custom image built on `build-runner` → zot, or CNPG's image-volume extension mechanism. Verify against the CNPG version chosen |
| Backup path | CNPG Barman Cloud plugin → Garage S3 works. Same failure domain as today unless §10 is closed |
| Migration | CNPG `bootstrap.initdb.import` (logical, per-DB) or a `pg_basebackup` external-cluster replica. 21 DBs × consumer cutover = a downtime plan per app; the authentik one carries the `core_default_app_access` trap (`runbook-authentik-identity.md`: a restore silently reverts it) |
| Users/roles | Pigsty declares them in `pigsty.yml` with Infisical-sourced passwords (`runbook-wird-admin-db-role.md` grants etc.). Rewrite as CNPG `managed.roles` + `Database` CRs, with secrets from Infisical operator |
| **Bootstrap circularity** | `infisicaldb` lives on Pigsty, *outside* the cluster. Today a cluster rebuild leaves secrets intact. With CNPG, Infisical's database is inside the cluster being rebuilt, and the restore needs Garage credentials that come from Infisical. That needs a break-glass copy of the restore credentials, or Infisical's DB stays external |
| Log gap | CNPG logs go to stdout → Alloy → Loki with no extra work. **But the gap can be closed now** by repointing Pigsty's `vector` with a Loki sink, or by running Alloy on the 3 PG VMs. That's a small change; rebuilding the cluster just to fix it doesn't pay |
| Failover track record | Patroni failover has been proven live twice (2026-08-15). CNPG would start over with no proof |

Verdict on PG: CNPG is reasonable, **but it doesn't have to ship with the OS
change**, and it shouldn't. Moving PG and moving the hosts at the same time
means two migrations sharing one rollback window. If Talos goes ahead, the
lower-risk first step is Pigsty inside KubeVirt VMs (data moves via Patroni
replica add/remove, no schema work). CNPG would follow later.

---

## 7. Conflicts with locked decisions

None of the target stack is on the forbidden list (cert-manager, Gateway API,
Ceph, Flatcar, …). These need an ADR before any work starts:

- **ADR-0008 (Flatcar rejected).** The stated reason ("less Day-2 friction
  than adopting a new OS family") applies just as much to Talos. A Talos ADR
  has to answer it directly, not avoid it.
- **ADR-0055.** k8s nodes stop being NetBird SSH peers. Talos API access over
  the mesh is a different access model and needs its own design.
- **ADR-0034.** build-runner's isolation argument has to hold up inside
  KubeVirt (VM boundary: yes, but now it shares a kernel host with k8s nodes).
- **ADR-0029.** The Patroni DCS placement logic goes away with CNPG.
- **ADR-0013, 0014, 0020, 0024, 0026, 0028.** PVE-only; marked Superseded.
- `ARCHITECTURE.md` §11 states the convergence ordering ("restore path that
  leaves the failure domain" before anything else) "should not be reordered
  for convenience". A platform rebuild is exactly that kind of reordering.

---

## 8. Options and recommendation (step 6)

**Option A — no rebuild, do these regardless:**

1. Off-site backup for Postgres, Longhorn and `/home`, with a rehearsed
   restore (§10). This blocks every other option and Forgejo (ADR-0035).
2. Postgres VM logs → Loki (Alloy on pg01/pg02/witness, or a Loki sink on
   Pigsty's vector). This feeds the Ukubi game's Loki.
3. Measure RAM (§3).

**Option B — consolidate on Proxmox (cheap, reversible):** go from 5 k8s VMs
to 3, one CP+etcd+worker VM per host, sized from the §3 numbers. That gets the
DaemonSet and guest-OS savings and frees stranded slack, and keeps snapshots,
LXCs, dual-boot, the NetBird SSH model, kubespray know-how and the PG
setup. ADR-0017's placement still holds (one voter per host). Done with
kubespray `remove-node.yml` + VM resize, one node at a time; no greenfield
`cluster.yml`. Probably gets **half or more** of the bare-metal RAM win.

**Option C — Talos bare metal (the handoff's proposal):** worth doing only if
§3 shows the remaining win after B is large, *and* A.1 is done, *and* the
`.165` dual-boot has a clean answer. Rough sequence, one host at a time:

1. Prereqs: off-site restore rehearsed; Windows on its own disk on `.165`;
   build-runner/Garage/hermesagent target decided (KubeVirt vs pod); Talos +
   KubeVirt rehearsed on a spare machine or a nested VM first.
2. **ex-laptop first** (least load, least trusted). Its loss costs a k8s etcd
   voter and the Patroni witness: move the witness role first (e.g. to a
   small VM on server1 temporarily; the Pi 4's microSD is a poor etcd disk),
   then remove `k8s-cp-03` from the kubespray cluster. **Old cluster now
   has 2 etcd voters: zero fault tolerance until the end.** Bring up a
   1-node Talos cluster on ex-laptop; register it in ArgoCD as a second
   destination.
3. Move stateless apps first by changing their destination in
   `registry.yaml`/the ApplicationSet. Stateful apps go through Longhorn
   backup → Garage → restore.
4. **server1 next** (biggest RAM, but holds pg01 leader, nfs-storage,
   build-runner, k9s): Patroni switchover to pg02, rebuild PG/build-runner
   as KubeVirt VMs on the Talos side, join server1 as Talos CP #2.
5. **`.165` last** (GPU, Garage, pg02, the remaining old CP). Garage data
   copied to its new home before the LXC goes. Join as CP #3; add NVIDIA
   extensions; re-test the gaming-reboot drain.
6. Retire kubespray inventory, `terraform/` bpg resources, PVE playbooks;
   supersede the ADRs in §7.

The whole time, two clusters run side by side with reduced fault tolerance.
That is the main cost of Option C, and the snapshot rollback net that
Proxmox provides today is gone during the risky part.

**Recommendation: A now, then B, then decide on C with real numbers.**
Talos's real advantages (immutable OS, atomic upgrades, no config drift) are
real, but they come at a price for this lab specifically: SSH/NetBird access
model, dual-boot, KubeVirt for the build boundary, and Infisical circularity.
The RAM argument alone doesn't cover that until the measurements say it does.

---

## 9. Open questions for the owner

1. How does Windows boot on `.165` today: its own NVMe, or a partition next
   to PVE? (Blocks any Talos plan for that host.)
2. The §3 measurements, especially the 7-day peak of used RAM per k8s VM vs
   allocation.
3. Postgres data size per database (§6 query).
4. Is losing VM snapshots acceptable before Option C's first step, or is a
   rehearsed off-site restore the replacement?
5. Which pain is driving this: RAM, upgrade toil, config drift, or
   wanting one control plane for its own sake? Options A and B answer the
   first one; only C answers the last.
