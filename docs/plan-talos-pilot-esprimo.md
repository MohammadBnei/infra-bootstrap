# Plan: the switch, then a Talos pilot on the two Esprimos

**Status:** draft, 2026-11-09. Not run. Nothing here touches the production
cluster except Phase 0 (re-cabling) and three small, reversible additions
listed in §4. The *why* is in
[`evaluation-drop-proxmox-talos.md`](evaluation-drop-proxmox-talos.md); this
file is the *how* for the first two steps only.

**Scope:**

- Phase 0 puts every machine on one switch.
- Phase 1 builds a **throwaway** Talos cluster on the two new Fujitsu
  Esprimo G558s and runs a list of tests (§2) whose results decide whether
  the migration goes ahead.

**Out of scope:** the migration itself (moving apps, server1, `.165`, Postgres)
and any ADR. Those come after the pilot's go/no-go (§5), and the ADRs are
written before the migration, not during it.

**Who runs what** (CLAUDE.md, `ansible-ops`): the operator does every action
on real hardware and the LAN. Claude prepares configs, patches, commands and
checklists, and reviews the outputs.

---

## 0. Phase 0: one switch for every machine

**Goal:** no cluster traffic crosses the Freebox's built-in switch, so a
Freebox reboot only cuts the internet.

1. **Buy:** gigabit, 8 ports, metal, fanless. Prefer an "easy smart" model
   (TL-SG108E / GS308E class) so the VLAN option survives if it becomes the
   main switch.
2. **Place it** next to the Freebox and the TL-SG108E. The target layout:
   - one uplink to the Freebox;
   - the patch-panel run to the room switch (`.165` + Pi);
   - server1, ex-laptop, Esprimo 1, Esprimo 2.

   Whether the new switch takes over from the TL-SG108E or sits beside it
   depends on how many ports are left after counting. Either works, as long
   as there is **one** cable to the Freebox.
3. **Move one host at a time.** Plug in the two Esprimos first, since they
   carry nothing yet. Then ex-laptop, then server1. After each move, wait for:
   - `kubectl get nodes`: all `Ready`;
   - `patronictl list`: leader + replica `streaming`, lag 0;
   - `etcdctl endpoint health` on the Patroni DCS: 3/3.

   **Never move server1 and ex-laptop together.** Each holds an etcd voter in
   both quorums (k8s, Patroni).
4. **Verify:**
   - every port shows the `1000M` LED;
   - `iperf3` server1 ↔ ex-laptop and server1 ↔ `.165` reach ~940 Mbit/s.
5. **Prove the point:** reboot the Freebox on purpose (a quiet evening).
   Expected:
   - internet goes down;
   - `kubectl get nodes`, `patronictl list` and Pi-hole resolution of
     `*.bnei.lan` keep working from the LAN;
   - no Patroni failover, no etcd leader churn beyond noise.
6. **Record it:** update `ARCHITECTURE.md` §3 "Physical links" with the real
   cabling.

**Rollback:** move the cables back. No configuration changed anywhere.

---

## 1. Phase 1: Talos pilot on the Esprimos

### 1.1 Decisions to fill in before starting

| Item | Proposal | Owner decides |
| --- | --- | --- |
| Hostnames (one name per machine, they keep it after the pilot) | `esprimo-1`, `esprimo-2` | ☐ |
| LAN addresses | `.21`, `.22` (the `.20-.49` hosts range). Check the Freebox lease table and `arping` first | ☐ |
| Pilot MetalLB pool | `.45-.49`, **outside** prod's `.233-.250`, so the two MetalLBs can never fight over an address | ☐ |
| Pilot API endpoint | `https://192.168.1.21:6443`: one control plane, no VIP in the pilot | ☐ |
| Talos version | Latest stable that supports **Kubernetes 1.35.x**; pin k8s to prod's `1.35.4` | ☐ |
| Where Talos secrets live | Infisical, project `infra-bootstrap-1-ge1`, env `dev`, new folder `/talos-pilot`: `talosctl gen secrets` bundle + talosconfig. **Never committed** | ☐ |
| Where config lives | `talos/` at repo root: machine-config patches (YAML, no secrets) and Cilium/MetalLB values | ☐ |

### 1.2 Hardware prep (operator, per Esprimo)

1. **Inventory:**
   - `lscpu` model (from a live USB, e.g. Ubuntu);
   - RAM 32 GB seen;
   - NIC model.
2. **SSD health before wiping:** `smartctl -a` from the live USB. They're
   refurbished; record power-on hours, wear level, reallocated sectors.
   **No-go for etcd if wear is high**: swap the disk or make that machine
   worker-only.
3. **BIOS** (Fujitsu): update firmware first, then set:
   - UEFI only;
   - power on after AC loss = **on**;
   - Wake-on-LAN on;
   - boot order USB → SSD;
   - Secure Boot **off** for the pilot (Talos supports Secure Boot with its
     own signed image; that's a later decision);
   - C-states / power saving left at defaults.
4. **One smart plug per Esprimo** (local-API model, no cloud), for the
   remote hard-reset test (T9).

### 1.3 Image

Talos **Image Factory** schematic, recorded in `talos/schematic.yaml`:

- extensions:
  - `siderolabs/intel-ucode`;
  - `siderolabs/iscsi-tools` and `siderolabs/util-linux-tools` (Longhorn);
- kernel arg `net.ifnames=0` (NIC is `eth0` everywhere, so Cilium's
  `devices: [eth0]` carries over).

`.165` will later need its own schematic (`amd-ucode` + NVIDIA). That's not
part of the pilot.

Boot both machines from a USB stick made from the schematic's ISO. They
come up in maintenance mode, waiting for a config.

### 1.4 Machine config (patches in `talos/patches/`)

`talosctl gen config ukubi-pilot https://192.168.1.21:6443 --with-secrets <bundle>`,
then patches:

| Patch | Content | Why |
| --- | --- | --- |
| `cluster-network.yaml` | `cni.name: none`; podSubnets `10.233.64.0/18`; serviceSubnets `10.233.0.0/18`; `proxy.disabled: true` | Same address ranges as prod (hardcoded in `common-app-chart`, origin-lock, NetBird config, ukubi-game policy). Cilium takes over kube-proxy's job |
| `scheduling.yaml` | `allowSchedulingOnControlPlanes: true` | Every node runs workloads |
| `cp-lb-label.yaml` (CP only) | delete label `node.kubernetes.io/exclude-from-external-load-balancers` | Otherwise MetalLB never announces from control-plane nodes |
| `network-<host>.yaml` | static `eth0` address, gateway `.254`, nameservers `192.168.1.55` then `1.1.1.1`, hostname | Same DNS path as prod |
| `registries.yaml` | mirror `registry.bnei.lan:5000` → `http://registry.bnei.lan:5000` | Pull from zot over plain HTTP, like prod |
| `disks.yaml` | cap `EPHEMERAL`; `UserVolumeConfig` named `longhorn` on the system disk; kubelet `extraMounts` → `/var/lib/longhorn` | Single-SSD machine: Longhorn needs its own space. **Verify the exact schema for the chosen Talos version** |
| `metrics.yaml` | etcd `listen-metrics-urls`, controller-manager / scheduler `bind-address: 0.0.0.0` | Same Prometheus targets as prod |
| `kubelet.yaml` | `nodeIP.validSubnets: [192.168.1.0/24]`; graceful shutdown grace periods | Correct node IP; drain on shutdown |
| `hostdns.yaml` | `hostDNS.enabled` + `forwardKubeDNSToHost` (usually already default) | Replaces NodeLocal DNS |

Apply: Esprimo 1 as **controlplane**, Esprimo 2 as **worker**, then
`talosctl bootstrap` on Esprimo 1 and `talosctl kubeconfig`. Nodes stay
`NotReady` until Cilium is installed. That's expected.

### 1.5 Cluster add-ons (installed with `helm` from the Pi, not ArgoCD)

Prod ArgoCD stays out of the pilot. Pointing it at a second cluster needs a
registry/ApplicationSet change (Pattern C, ADR-0004), and a hand-made
`Application` would be the forbidden "bypass the registry" pattern. That's a
migration-phase design item (§5).

1. **Cilium.** Same version line as prod; values in `talos/cilium-values.yaml`:
   - `kubeProxyReplacement: true`, `k8sServiceHost: localhost`,
     `k8sServicePort: 7445` (KubePrism);
   - `ipam.mode: kubernetes`;
   - Talos capability set + `cgroup.autoMount.enabled: false` +
     `cgroup.hostRoot: /sys/fs/cgroup` (from Talos's Cilium guide);
   - `devices: [eth0]`;
   - `encryption.enabled: true`, `type: wireguard`;
   - Hubble + relay + UI, metrics `[dns, drop, tcp, flow, icmp]`;
   - `l2announcements.enabled: false`.
2. **MetalLB** (Helm): `IPAddressPool` `.45-.49` + `L2Advertisement`.
3. **Longhorn** (Helm): data path `/var/lib/longhorn`, default replica count
   **2** (only 2 nodes); backup target a **new, separate** Garage bucket
   `talos-pilot-longhorn` with its own key (`garage-ops`). Never prod's
   `k8s-longhorn-backup`.
4. **metrics-server** (for `kubectl top`).
5. **Test workloads:**
   - `traefik/whoami` behind a `LoadBalancer` with `externalTrafficPolicy:
     Local`;
   - one stateful pod on a Longhorn RWO PVC writing a counter file;
   - one image pulled from `registry.bnei.lan:5000`.

### 1.6 Access path

Laptop → NetBird SSH → `pihole` → `talosctl` / `kubectl` / `k9s` over the
LAN. Install the arm64 builds on the Pi. Before T12, keep the pilot's admin
talosconfig and kubeconfig on the Pi and the workstation only, mode `0600`.

---

## 2. Tests: what the pilot must show

Each test is **pass / fail / note** in a results table appended to this file.

| # | Test | Pass when |
| --- | --- | --- |
| T1 | Install from USB, bootstrap, Cilium | Both nodes `Ready`; `cilium status` OK; `KubeProxyReplacement: True`; no kube-proxy pods |
| T2 | WireGuard + Hubble | `cilium-dbg encrypt status` shows WireGuard with 1 peer; Hubble flows visible; Hubble metrics endpoint answers |
| T3 | MetalLB + client IP | `curl http://<pool-ip>` from the laptop: whoami shows the **laptop's** IP (eTP Local works). The announcing node (`arping`, MetalLB speaker logs) is the one running the pod. Move the pod to the other node: the announcement follows within seconds. The control-plane node announces when it holds the pod (label removal works) |
| T4 | Registry | Pod pulls an image from `registry.bnei.lan:5000` |
| T5 | DNS | Pods resolve `kubernetes.default`, `registry.bnei.lan` (Pi-hole) and an internet name. A `CiliumNetworkPolicy` modelled on ukubi-game's DNS rule works with the **Talos host DNS address instead of `169.254.25.10`**: note the exact address/identity it needs |
| T6 | Longhorn | PVC binds, 2 replicas healthy. Backup to `talos-pilot-longhorn` succeeds; delete the PVC; restore; counter file intact |
| T7 | Graceful node loss | `talosctl shutdown` on the worker: pods evicted, Longhorn volume moves and reattaches on Esprimo 1 without `Multi-Attach` |
| T8 | Upgrades | `talosctl upgrade` to a newer Talos patch, worker then CP. Then `talosctl rollback` on one node. Then `talosctl upgrade-k8s` one patch. Test workloads survive each; record API downtime during the CP upgrade (single CP) |
| T9 | Hard power loss | Smart-plug cut on the worker. Record what happens to the RWO volume: expected stuck until the node returns or the `node.kubernetes.io/out-of-service` taint is added by hand, same as today. Power returns → machine boots by itself (BIOS AC setting) and rejoins |
| T10 | etcd disaster | `talosctl etcd snapshot` copied off the node. `talosctl reset` the CP. `talosctl bootstrap --recover-from=<snapshot>`. Cluster state back, workloads re-adopted |
| T11 | Remote debugging, no SSH | From the laptop via the Pi: `talosctl logs kubelet`, `dmesg`, `dashboard`, `pcap`; `kubectl debug node/esprimo-2 --profile=sysadmin --image=nicolaka/netshoot` in a `debug` namespace labelled `privileged` |
| T12 | Read-only role | A talosconfig with `os:reader` can read logs and state, and is **refused** `reboot`, `reset`, `apply-config` |
| T13 | Logs off the node | `machine.logging.destinations` pointed at a temporary listener on the Pi (`nc -lu`): kernel + service logs arrive as JSON. The real Alloy/Loki wiring is a migration item |
| T14 | Full rebuild from git + Infisical | Both nodes `reset` to maintenance mode. Rebuild **using the `siderolabs/talos` Terraform provider** (`talos/terraform/`, secrets from Infisical), then the add-ons. Time it, end to end |
| T15 | RAM | Idle footprint per node with Cilium, MetalLB, Longhorn, metrics-server and nothing else: `talosctl memory`, `kubectl top node`, Prometheus if deployed. In parallel, run the prod measurement queries from the evaluation §3. Together they give the real RAM-gain number |

T14 is last on purpose: everything learned by hand in T1–T13 has to survive
being rebuilt from code.

---

## 3. Risks during the pilot and their guards

| Risk | Guard |
| --- | --- |
| Pilot MetalLB answers ARP for a prod IP | Pool `.45-.49`, outside prod's range; no Service in the pilot uses `loadBalancerIP`/annotations pointing elsewhere |
| Pilot overlay ranges overlap prod's | Overlay addresses never leave the node (VXLAN/WireGuard between pilot nodes only), so the same ranges in both clusters don't collide on the LAN. Pod-to-LAN traffic is masqueraded to the node IP. Check with `tcpdump` on one prod node during T3 that no `10.233.*` source address shows up |
| Pilot touches prod storage | Separate Garage bucket and key; prod buckets untouched |
| Pilot touches prod DNS | Only additions: `esprimo-1/2` records in `bnei-lan-records.yml`. No change to existing records |
| Pilot touches ArgoCD | It doesn't (§1.5) |
| A refurbished SSD dies | Pilot is disposable; SMART check in §1.2 |
| Talos secrets leak | Infisical only; `.gitignore` entries for `talos/**/secrets.yaml`, `talosconfig`, `kubeconfig` in the same PR that creates `talos/` |

---

## 4. What changes in prod (complete list)

1. Cables (Phase 0).
2. `ansible/playbooks/vars/bnei-lan-records.yml`: two new host records, then
   a `pihole-configure.yml` run.
3. Garage: one new bucket + key for the pilot (`garage-ops`).
4. Infisical: a `/talos-pilot` folder.

Each is reversible in minutes. Nothing in `gitops/`, `inventory/`,
`terraform/` (the Proxmox part) or `pigsty/` changes.

---

## 5. After the pilot: go/no-go

**Go** for the migration if:

- T1–T12 and T14 pass;
- T15 shows a RAM gain the owner considers worth it;
- the T14 rebuild fits in an evening.

**Before the migration starts** (each one is its own PR):

- Off-site backup with a rehearsed restore (evaluation §0). Not optional.
- ADRs:
  - superseding **ADR-0003** (Cilium replaces kube-proxy) and resolving
    **ADR-0018**;
  - superseding **ADR-0008** (OS), answering its "Day-2 friction" argument
    with T8/T11/T14 results;
  - amending **ADR-0055** (Talos nodes aren't SSH peers; access via the Pi)
    and **ADR-0017** (CP placement: Esprimo 1, Esprimo 2, server1; `.165`
    worker only);
  - a decision on build-runner (pod with user namespaces vs one KubeVirt VM)
    against **ADR-0034**;
  - CNPG vs keeping Pigsty, with the `infisicaldb` circularity solved.
- ArgoCD multi-cluster design inside Pattern C (a `destination` per registry
  entry).
- The two-clusters-on-one-LAN plan:
  - temporary VIP for the new API;
  - pool split;
  - the `.233` / `.234` / `.235` handovers;
  - containerd/registry mirror ordering.

**No-go** keeps everything as it is. The Esprimos can then join the
*current* cluster as kubespray workers instead. The pilot cost an evening of
cabling and a few of testing.
