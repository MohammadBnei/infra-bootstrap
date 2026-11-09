# Plan: the switch, then a Talos pilot on the two Esprimos

**Status:** draft v3, 2026-11-09. Not run.

- v2 came out of a first doubt cycle: two independent reviews, one against
  this repo's own facts and rules, one against upstream Talos 1.14 /
  Cilium / MetalLB / Longhorn docs.
- v3 adds the order of work, the Pi move and the headless install. A
  final review then corrected 14 more points (§6, v3 table).

§6 lists what each review changed. The *why* of the whole effort is in
[`evaluation-drop-proxmox-talos.md`](evaluation-drop-proxmox-talos.md).

**Scope:**

- Phase 0 keeps every machine-to-machine path off the Freebox.
- Phase 1 builds a **throwaway** Talos cluster on the two Fujitsu Esprimo
  G558s and runs the tests in §2. Their results decide whether the
  migration goes ahead.

**Out of scope:** the migration itself, and every ADR that changes prod.
Those come after the go/no-go (§5).

**Who runs what** (CLAUDE.md, `ansible-ops`): the operator does every action
on real hardware and the LAN. Claude prepares configs, patches, scripts and
checklists, and reviews the outputs.

**Storage stance (owner, 2026-11-09):** two requirements.

1. **RWO volumes for any app must not be tied to a node.** That means
   replicated block storage, which is what Longhorn is.
2. **RWX is mainly for agent-fleet**: the `agent-fleet-workspace` volume
   holding the clone cache and the irreplaceable `claude-home/` resume state.

So Longhorn stays as the default class, but slimmed down. It holds only
what needs to move between nodes:

| Data | Where |
| --- | --- |
| App volumes (RWO), fleet RWX | **Longhorn**, backed up to Garage (+ off-site) |
| Databases | CNPG on local disks (replicates itself) |
| Prometheus TSDB | local (regenerable) |
| Fleet per-session scratch | `local-path`, as today (agent-fleet ADR-0048) |
| Loki | candidate: Garage S3 backend, so Loki's own volume becomes small |

agent-fleet's ADR-0048 measured the RWX volume at 10 MB/s on today's VMs,
so T7 re-measures it on bare metal. If Longhorn's numbers disappoint,
Piraeus/LINSTOR (DRBD, with a Talos extension) is the replicated-block
alternative to benchmark next. Ceph stays banned. Sharing agent tooling
without installing onto RWX is tracked in agent-fleet
[#363](https://github.com/MohammadBnei/agent-fleet/issues/363).

**Order of work.** Cabling comes before Talos. Every cable move gets
checked on its own, so a failure has exactly one suspect. The pilot then
runs on the network it will live on, with the Pi (DNS + jump host) already
in its final place.

| Step | What | Prod impact | Done when |
| --- | --- | --- | --- |
| **Prep** | §0.1 prerequisites (incl. Freebox DHCP reservations), §1.1 decisions, §1.2 hardware session per Esprimo, ADR-0070 + `talos/` PR, Infisical project, Pi tools (§1.7) | none | checklists done |
| **Switch** | New switch, one cable to the TL-SG108E. Esprimos cabled but **left off mains power** until *Talos* | none | `1000M` LEDs |
| **Move ex-laptop** | §0.3 | one etcd voter per quorum blips | §0.3 checks pass |
| **Move Pi** | §0.3 | **LAN-wide DNS gap while the Pi is off**, not just the cluster | §0.3 checks + DNS checks pass |
| **Move server1** | §0.3: switchover to pg02, move, **switch back to pg01** | short blip; leader moved twice | §0.3 checks pass |
| **Speed** | `iperf3`, update `ARCHITECTURE.md` §3 | none | ~940 Mbit/s |
| **Talos** | Power on the Esprimos; install (§1.5), add-ons (§1.6) | none | T1 passes |
| **Tests** | T1–T20, T23 (§2). Freebox reboot (§0.5) one evening; T18's WAN pull another | planned Freebox / WAN outages | results table filled in |
| **Soak, then rebuild** | T21 (7 days) **after** the disruptive tests, then T22 last | none | go/no-go (§5) |

**Never move two of ex-laptop, the Pi and server1 at the same time.**

---

## 0. Phase 0: keep machine-to-machine traffic off the Freebox

**Today** (`ARCHITECTURE.md` §3):

- `.165` and the Pi go room switch → wall → patch panel → TL-SG108E →
  Freebox. They're already off the Freebox's built-in switch.
- **server1 and ex-laptop plug straight into the Freebox.**
- **The Pi has to move physically** to sit with the others (owner,
  2026-11-09).

**Design:**

- The TL-SG108E keeps its **single** uplink to the Freebox and its
  patch-panel run. Neither cable moves.
- The new switch hangs off the TL-SG108E by **one** cable, never with a
  second cable to the Freebox: there's no spanning tree to save a loop,
  and a loop takes down the LAN and both etcd quorums.
- server1, ex-laptop, the Pi and both Esprimos go on the new switch.

**`.165` stays** behind the room switch and patch panel. Moving its path
would cut pg02/etcd-1, k8s-cp-01, k8s-worker-01 and Garage all at once. If
it ever has to move, that's its own step with its own switchover plan, not
part of this phase. Only the Pi's own cable leaves that room switch.

### 0.1 Prerequisites

1. **USB network adapters:** server1 and ex-laptop connect through `r8152`
   USB dongles. On 2026-08-24 a dongle drop isolated server1 for 23h40m,
   because `nic0` re-enumerated and nothing re-attached it to `vmbr0`
   (`bootstrap-test-notes.md`, 2026-08-25).
   - The udev rejoin rule is on server1 only, and its `RUN` part was never
     tested in place. ex-laptop doesn't have it.
   - Install the same rule on ex-laptop first, and put it in a playbook
     (`pve-postinstall.yml`) so it stops being hand-applied.
   - **Unplug only at the switch end, never at the dongle.** After each
     move, check that `bridge link` still shows `nic0` as a port of
     `vmbr0`.
   - Keep a screen and keyboard within reach.
2. **A way in that doesn't need the internet:** LAN SSH keys, or the k9s
   hub. NetBird SSH needs an authentik JWT, and authentik is behind
   Cloudflare.
3. **Alertmanager silence** for the work window (and for 0.5's Freebox
   reboot).
4. **Freebox DHCP range:** read it in the Freebox UI.
   `ARCHITECTURE.md` §3 says `.200-.254`, but that range holds server1, the
   k8s VMs and the MetalLB pool. Either the doc or the Freebox is wrong; fix
   whichever it is before choosing pilot addresses (§1.1).
5. **Freebox DHCP reservations for both Esprimo MACs** (MACs from §1.2),
   outside every static and MetalLB range. Maintenance mode then always
   comes up on a known address: §1.5 needs no `nmap`, and T22's Terraform
   rebuild knows where to apply.
6. **IP-based access ready for the Pi move:** a kubeconfig pointing at
   `https://192.168.1.180:6443`, and SSH by IP to the hosts. While the Pi is
   off, every DHCP client on the LAN, including the operator laptop, has no
   DNS at all.

### 0.2 Buy

Gigabit, 8 ports, metal, fanless. An "easy smart" model (TL-SG108E /
GS308E class) keeps the VLAN option for a later lab/household split.

### 0.3 Moves: one at a time, checks in between

**Switch.** Power it on, connect it to the TL-SG108E only. Cable the
Esprimos but keep them **off mains power**. With the stick in and "power on
after AC loss" set, they would boot straight into maintenance mode: an
unauthenticated config API on the LAN, for all of Phase 0.

**Move ex-laptop** (k8s-cp-03, pg-etcd-witness, hermesagent): move, then
run the checks.

**Move Pi** (Pi-hole; NetBird peer `pihole`). The Freebox hands out the Pi
as **the** DNS server over DHCP (`bootstrap-test-notes.md`), so while it's
off the network:

- **Every DHCP client on the LAN has no DNS**, internet names included:
  the operator laptop (so NetBird login fails too) and household devices.
- **Hosts with the Pi as their only nameserver** lose everything:
  - build-runner (`terraform/build-runner.tf`);
  - nfs-storage (`terraform/nfs.tf`);
  - the k9s hub (`terraform/k9s-dashboard.tf`). §0.1.2's fallback way in
    can't resolve `infisical.bnei.dev` then, so Infisical-wrapped commands
    fail there.
- **In the cluster** CoreDNS falls back to `1.1.1.1`, which answers "no
  such name" for:
  - `postgres.bnei.lan`, `redis.bnei.lan`: new connections fail; open ones
    keep working;
  - `registry.bnei.lan`: image pulls from zot fail, so a pod restarting in
    the window can't start;
  - `nfs-storage.bnei.lan`: a pod on the `nfs` class that restarts can't
    mount. If nfs-storage itself reboots in the window, its hostname-based
    exports deny every client (ADR-0036);
  - `garage.bnei.lan`: Longhorn backups and pgBackRest fail.

How:
- pick a quiet window **away from backup schedules**: no CI runs, no
  ArgoCD syncs, no agent sessions starting;
- use the IP-based access from §0.1.6;
- if the new position allows it, move only the network cable and keep the
  Pi powered: seconds instead of a microSD reboot;
- its address is pinned (`nmcli`), so nothing needs reconfiguring.

Extra checks afterwards:
- `dig @192.168.1.55 registry.bnei.lan` from a node;
- `crictl pull registry.bnei.lan:5000/<image>` on a node, which tests
  containerd's own resolver path;
- `dig postgres.bnei.lan` from a pod;
- NetBird SSH to `pihole` works;
- no pod stuck in `ImagePullBackOff` / `ErrImagePull` from the window;
- the next Longhorn and pgBackRest backups succeed.

**Move server1** (pg01 = Patroni **leader**, k8s-cp-02, k8s-worker-02,
nfs-storage, Redis, k9s hub, build-runner):
1. `patronictl switchover` to pg02 (on `.165`), so the leader isn't the
   machine being unplugged. The `.232` VIP follows.
2. Move the cable, run the checks.
3. **Switch back to pg01**, then re-run the timeline/LSN check. This step
   is mandatory: otherwise the leader stays on `.165`, the host rebooted
   for gaming (ADR-0029).

**Never move two of ex-laptop, the Pi and server1 together.** ex-laptop
and server1 each hold a voter in both etcd quorums, and the Pi is the
cluster's DNS.

**Checks after each move** (all must pass before the next):

| Check | Pass |
| --- | --- |
| `kubectl get nodes` | all `Ready` |
| `patronictl list` | **same timeline (TL) on leader and replica**, replica `Receive LSN` advancing between two runs, lag ~0. "`streaming`" alone isn't enough: 2026-08-15 left a replica that looked healthy and was 61 GiB behind |
| leader `/patroni` endpoint | lists a connected standby |
| Patroni DCS `etcdctl endpoint health` | 3/3 |
| **Kubernetes etcd**: `etcdctl endpoint health --cluster` on a control plane | 3/3: `Ready` nodes don't prove the member rejoined |
| `curl -k https://192.168.1.180:6443/healthz` | `ok` through the kube-vip VIP |
| `pvecm status` | quorate, 3 nodes |
| `bridge link` on the moved host | `nic0` master of `vmbr0` |
| `curl` on `.233` and `.234` | `404` from Traefik, an answer from zot. **Not `ping`**: MetalLB VIPs don't answer ICMP (trap 5) |
| Longhorn | `kubectl -n longhorn-system get volumes.longhorn.io`: all `healthy` |
| Garage | `garage status` healthy, S3 reachable |

### 0.4 Speed

- Every port shows the `1000M` LED.
- `iperf3` server1 ↔ ex-laptop and server1 ↔ `.165` reach ~940 Mbit/s.

### 0.5 Freebox reboot test (quiet evening, once the pilot is up)

Shows that the cluster no longer needs the Freebox to talk to itself. It
runs during *Tests*, once the pilot is up, so the pilot is checked too.
**T18 does not use this reboot:** a Freebox reboot is only a few minutes of
WAN outage, too short to read a cold boot. T18 has its own window (§2).

**Expected to break, and that's fine:**
- the internet;
- new NetBird SSH sessions (no authentik through Cloudflare);
- NetBird's blackbox probe (silenced);
- Alertmanager → Discord;
- Pi-hole resolution of internet names (`bnei.lan` still resolves);
- ACME renewals, which retry later.

**Must keep working, checked over LAN SSH:**
- `kubectl get nodes`;
- `patronictl list` (no failover);
- `curl` on `.233`;
- Pi-hole answers for `*.bnei.lan`;
- no etcd leader churn beyond noise.

### 0.6 Record

Update `ARCHITECTURE.md` §3 "Physical links" with the real cabling and the
real Freebox DHCP range.

**Rollback:** move the cables back. The config changes are the udev rule
(on ex-laptop, via a playbook that runs on all three PVE hosts) and two
Patroni switchovers, which end where they started.

---

## 1. Phase 1: Talos pilot on the Esprimos

### 1.0 ADR first

`DECISION.md` §5: an architecturally significant proposal gets an ADR
first. The PR that creates `talos/` also adds
**`docs/adr/0070-talos-pilot.md`, Status: Proposed**, scoped to the pilot
only. It says explicitly:
- the pilot runs Cilium in place of kube-proxy on a throwaway cluster
  **without** flipping prod (ADR-0003 / ADR-0018 stay as they are);
- nothing in it changes prod's locked decisions.

### 1.1 Decisions to fill in before starting

| Item | Proposal | Owner |
| --- | --- | --- |
| Hostnames (permanent, one name per machine) | `esprimo-1`, `esprimo-2` | ☐ |
| LAN addresses | `.21`, `.22` (hosts block). Check against the real Freebox DHCP range (0.1.4) and `arping` | ☐ |
| Pilot MetalLB pool | 5 addresses outside prod's `.233-.250` and outside Freebox DHCP. **Recorded as reserved in `ARCHITECTURE.md` §3 before use**, so nothing else takes them. Candidate `.45-.49` breaks allocation by role (hosts block); the alternative is a slice the owner names | ☐ |
| API endpoint | `https://192.168.1.21:6443`. One control plane during most tests; T14 briefly adds a second | ☐ |
| Versions | **Talos v1.14.x** (supports k8s 1.33–1.37), `--kubernetes-version 1.35.4` pinned to match prod; the 1.14 default would be 1.37.0 | ☐ |
| Secrets | **A dedicated Infisical project `talos-pilot` with its own machine identity**, following ADR-0062's `fleet-github-app` pattern. Not a folder: `docs/secrets.md` says the main project has no folders, and the in-cluster operator identity can read that whole project (free plan, no custom roles). It holds the `talosctl gen secrets` bundle and the admin talosconfig | ☐ |
| Where tools and credentials live | **The Pi only** (`pihole`), mode `0600`. Not the workstation: `ARCHITECTURE.md` §1 keeps cluster credentials off it. This makes the Pi a more valuable target, the same trade-off the k9s hub already makes | ☐ |
| Terraform state (T22) | On the Pi, outside the repo. It contains the secrets bundle in plaintext. It can be thrown away, because the bundle is in Infisical | ☐ |
| Repo layout | `talos/`: schematic, config patches (no secrets), add-on values, `addons.sh`, `terraform/`. `.gitignore` for `secrets.yaml`, `talosconfig`, `kubeconfig`, `*.tfstate*` in the same PR | ☐ |

### 1.2 Hardware prep (operator, per Esprimo)

This is the **only** session that needs a screen and keyboard. Everything
after it is done over the network (§1.5).

1. Boot a live Ubuntu USB and record:
   - `lscpu`;
   - `free -g`;
   - `lspci -k`: the network card and its driver. **An Intel I219
     (`e1000e`) is likely**, and server1's onboard I219 hung ("Tx unit
     hang") about every two days, hence T21;
   - `ip link`: the **MAC address**, for the DHCP reservation (§0.1.5);
   - `lsblk -o NAME,MODEL,SERIAL,SIZE`: the SSD's model and serial, for the
     install-disk selector (§1.3).
2. **SSD health:** `smartctl -a`. Record power-on hours, wear and
   reallocated sectors. If wear is high, swap the disk or make that machine
   worker-only.
3. **Update the BIOS first**, before wiping anything, in case Fujitsu's
   flash tool needs the installed OS.
4. **Wipe the SSD** from the live session: `wipefs -a /dev/<disk>`, then
   `blkdiscard /dev/<disk>`. Refurbished units often ship with Windows,
   which would boot first under the boot order below.
5. **BIOS settings:**
   - UEFI only;
   - power on after AC loss **on**;
   - Wake-on-LAN on. It also needs `wakeOnLan: [magic]` in the machine
     config's `EthernetConfig` (§1.4);
   - **boot order: internal disk first, then USB.** The blank disk falls
     through to USB. Once Talos is installed, the disk wins by itself:
     upstream confirms an existing installation boots even with the ISO
     present. The stick can stay in, and no boot menu is ever needed;
   - Secure Boot off for the pilot.
6. **Plug in the Talos USB stick** (ISO built from the §1.3 schematic) and
   leave it in. It is also the **recovery path**: a full `talosctl reset`
   wipes the whole disk, ESP included, and the machine comes back only
   because the stick is still there. Unplug screen and keyboard; leave the
   machine off mains power until *Talos* (order of work).
7. **One local-API smart plug per Esprimo** (T9, T11, T12).
8. **ADR-0003's premise, measured where it matters:** run
   `bpftool feature probe kernel` on server1 and ex-laptop now, on their
   PVE hosts (install `bpftool` there first if missing; a §4 change). The result settles whether "server1 lacks eBPF support" was
   ever true. The pilot only proves Cilium-without-kube-proxy on the
   Esprimos, and server1 is meant to be a control plane later.

### 1.3 Image

The Talos **Image Factory** schematic goes in `talos/schematic.yaml`:

- extensions: `siderolabs/intel-ucode`, `siderolabs/iscsi-tools`,
  `siderolabs/util-linux-tools`;
- kernel arg `net.ifnames=0`. The NIC is `eth0`, so Cilium's
  `devices: [eth0]` carries over. Fine on single-NIC machines; upstream
  prefers `LinkAliasConfig` for multi-NIC boxes, which matters later for
  `.165`.

**Getting the schematic ID:** `POST` `talos/schematic.yaml` to
`https://factory.talos.dev/schematics`. It returns the ID, and the ISO and
installer URLs are built from it. Record the ID in `talos/schematic.yaml`'s
header comment so the upgrade `--image` always matches.

**The installer must be the schematic's installer.**
`talosctl gen config` defaults `--install-image` to the *empty* schematic,
and `--install-disk` to `/dev/sda`. Booting from the custom ISO alone would
install a system without the extensions and kernel arg. So:

- `--install-image factory.talos.dev/metal-installer/<schematic-id>:v1.14.x`;
- a disk selector by the model/serial recorded in §1.2 (cross-check with
  `talosctl get disks --insecure -n <ip>` in maintenance mode), or 1.14's
  `UnattendedInstallConfig`;
- **every `talosctl upgrade` passes `--image` with the same schematic**,
  or the extensions disappear (checked in T10).

### 1.4 Machine config: Talos 1.14 document form

1.14 split the old single `v1alpha1` config into separate documents, and
its Cilium guide uses them. Patches go in `talos/patches/`, one file per
document. **Every rendered config is checked with `talosctl validate`
before applying.**

| Document | Content | Why |
| --- | --- | --- |
| `KubeFlannelCNIConfig` | `$patch: delete` | No built-in CNI; Cilium is installed instead |
| `KubeProxyConfig` | `enabled: false` | Cilium replaces kube-proxy |
| `KubeNetworkConfig` | pods `10.233.64.0/18`, services `10.233.0.0/18` | Same address ranges as prod (hardcoded in `common-app-chart`, origin-lock, NetBird config, ukubi-game policy) |
| `KubeNodeConfig` (CP) | remove the `node-role.kubernetes.io/control-plane` taint and the `node.kubernetes.io/exclude-from-external-load-balancers` label; `nodeIP.validSubnets: [192.168.1.0/24]` | Control plane runs workloads, and MetalLB can announce from it |
| `LinkConfig`, `HostnameConfig` | static `eth0` address, gateway `.254`; hostname | Explicit link config turns off Talos's default DHCP, so there's no second address |
| `EthernetConfig` | `wakeOnLan: [magic]` on `eth0` | The BIOS setting alone may not keep WoL armed |
| `ResolverConfig` | nameserver **`192.168.1.55` only**. Host DNS stays at its default (on, forwarding cluster DNS to the host); don't also set the old `v1alpha1` field, the two are mutually exclusive | Prod hit about 50% NXDOMAIN on `bnei.lan` with `.55` + `1.1.1.1` until `policy: sequential` (`settings.yml`) |
| `RegistryMirrorConfig` | `registry.bnei.lan:5000` → `http://registry.bnei.lan:5000` | zot over plain HTTP, as prod |
| `VolumeConfig` EPHEMERAL | `maxSize` (e.g. 200 GiB). **In the first apply and in Terraform**: it only takes effect when the volume is first created | Leaves room on the single SSD |
| `UserVolumeConfig` `longhorn` | rest of the system disk. Talos mounts it at **`/var/mnt/longhorn`** and passes it to the kubelet itself, so no `extraMounts` | Longhorn data off EPHEMERAL |
| `KubeletConfig` | `rotate-server-certificates: true`; graceful shutdown periods | metrics-server needs a valid kubelet serving cert; drain on shutdown |
| `SecurityProfileConfig` | `workloadIsolation` left at the 1.14 default (**true**). T8 checks Longhorn's iSCSI works under it; fallback `false`, recorded | 1.14 runs kubelet and pods in a separate namespace, and upstream warns about iscsid |
| Metrics | etcd metrics on **2381** (prod's port, set deliberately; 1.14 defaults to 2383); controller-manager / scheduler `bind-address: 0.0.0.0` | Same Prometheus targets as prod |
| Logging | service logs: `machine.logging.destinations`, `json_lines` over **TCP**. Kernel logs: a `KmsgLogConfig` document | `destinations` carries service logs only |
| `SysctlConfig` | `user.max_user_namespaces` > 0 | T19 (user namespaces) |

### 1.5 Install, headless, from the Pi

0. **Secrets, once, on the Pi:**
   - `talosctl gen secrets -o secrets.yaml`;
   - store it in the `talos-pilot` Infisical project **base64-encoded**
     (multi-line values are unverified in the CLI);
   - render the configs with `talosctl gen config ... --with-secrets`,
     `--install-image` (§1.3) and the patches;
   - store the generated `talosconfig` the same way.

   On every later session, fetch them from Infisical into `0600` files and
   delete those after use.
1. Power on Esprimo 1 (plug it into mains). It boots the Talos USB into
   **maintenance mode** on its DHCP reservation (§0.1.5) and waits for a
   config. If the reservation is missing, find it with
   `nmap -p 50000 --open 192.168.1.0/24`.
2. Optional: `talosctl get disks --insecure -n <dhcp-ip>` to confirm the
   install disk.
3. ```bash
   talosctl apply-config --insecure -n <dhcp-ip> -f esprimo-1.yaml
   ```
   Talos installs itself on the SSD with the **schematic installer**
   (§1.3), reboots from disk and comes back on `.21`. The extensions are
   checked with `talosctl get extensions` (T1) once step 5 has pointed
   talosctl at the cluster.
4. Same for Esprimo 2 (worker config, `.22`).
5. Point talosctl at the cluster:
   ```bash
   talosctl config endpoints 192.168.1.21
   ```
   ```bash
   talosctl config nodes 192.168.1.21 192.168.1.22
   ```
   Then `talosctl bootstrap -n 192.168.1.21` (once, on the control plane
   only), then `talosctl kubeconfig`. Nodes stay `NotReady` until Cilium is
   installed (§1.6).
6. Add the `esprimo-1/2` records to `bnei-lan-records.yml` now that the
   static addresses are live (§4).

**After this, no physical access is needed again:**
- **Always `talosctl reset --reboot`.** Without `--reboot`, reset shuts the
  node down, and getting it back needs a smart-plug cycle.
- A default reset (`--wipe-mode all`) wipes the whole disk. The node then
  reboots from the stick into maintenance mode on its reserved address.
  That is how T22 rebuilds.
- T13 is not a rebuild: it wipes EPHEMERAL only and keeps the node's
  identity.
- `talosctl upgrade` is remote.

PXE network boot is possible, but needs DHCP boot options the Freebox
doesn't offer (proxy-DHCP on the Pi, the only DNS server). It isn't worth
it for two machines.

### 1.6 Add-ons: one script, run from the Pi

`talos/addons.sh` (helm, pinned chart versions, values files in `talos/`).
It's a script and not hand-typed commands, so T22's rebuild covers it. Prod
ArgoCD stays out of the pilot: a hand-made `Application` would be the
forbidden "bypass the registry" pattern, and multi-cluster Pattern C is a
migration design item (§5).

1. **Namespaces first:** `metallb-system` and `longhorn-system` labelled
   `pod-security.kubernetes.io/enforce=privileged`. Talos enforces
   `baseline` everywhere except `kube-system`, and these two get rejected
   otherwise.
2. **Cilium** (same version line as prod):
   - `kubeProxyReplacement: true`, `k8sServiceHost: localhost`,
     `k8sServicePort: 7445` (KubePrism);
   - `ipam.mode: kubernetes`;
   - Talos capability sets, `cgroup.autoMount.enabled: false`,
     `cgroup.hostRoot: /sys/fs/cgroup`, exactly as in the 1.14 Cilium guide;
   - `devices: [eth0]`;
   - WireGuard encryption;
   - Hubble + relay + UI, metrics `[dns, drop, tcp, flow, icmp]`. The `dns`
     metric may stay empty without an L7 DNS policy; note it, don't chase it;
   - `l2announcements.enabled: false`;
   - `defaultLBServiceIPAM: none` (unverified flag), so Cilium's own LB IPAM
     never competes with MetalLB;
   - **`bpf.masquerade` left off**: a documented known issue breaks CoreDNS
     when it's on together with host-DNS forwarding.
3. **kubelet-serving-cert-approver**, right after Cilium. With
   `rotate-server-certificates: true`, `kubectl logs`/`exec` fail until
   it's running, which is exactly when the next add-ons get debugged.
4. **MetalLB:** `IPAddressPool` (the reserved slice) + `L2Advertisement`.
5. **Longhorn:**
   - `defaultSettings.defaultDataPath=/var/mnt/longhorn`;
   - default replica count **2** (two nodes);
   - backup target a new Garage bucket `talos-pilot-longhorn` with its own
     key and a **`max_size`** (e.g. 20 GB). Garage is one LXC with 180G
     capacity, shared with prod backups.
   - Create the bucket by editing `garage_buckets` in
     `garage-configure.yml` and running **only `--tags bucket_ops`**, from
     the k9s hub. A full run rewrites `GARAGE_ROOT_TOKEN` and every bucket
     key in Infisical.
   - **The new bucket's key lands in the prod Infisical project**
     (`garage-configure.yml` writes there). Copy it into `talos-pilot` for
     the pilot's use, and remove it from prod when the pilot ends (§3, §4).
6. **metrics-server.**
7. **Test workloads:**
   - `traefik/whoami` behind a `LoadBalancer` with
     `externalTrafficPolicy: Local`;
   - a counter pod on a Longhorn RWO PVC;
   - two writer pods on one Longhorn RWX PVC, one per node;
   - an image pulled from zot.

### 1.7 Access path

Laptop → NetBird SSH → `pihole` → tools over the LAN. The Esprimos are not
NetBird peers and no route reaches them through the mesh (ADR-0009/0055
hold as written).

**Tools on the Pi (arm64):**
- `talosctl`, matching the Talos v1.14.x patch;
- `kubectl` within one minor of 1.35 (1.34–1.36);
- `helm`, `terraform`, `infisical`;
- the `cilium` and `hubble` CLIs, `k9s`;
- `nmap`, `socat`, `wakeonlan`, `fio` (or run fio in a pod).

Installing them is a prod change on the only DNS server (§4); keep it to
static binaries in `/usr/local/bin`, no new services.

---

## 2. Tests

Each test is recorded as **pass / fail / note** in a results table appended
here. **G** marks a go-critical test (§5).

| # | Test | Pass when |
| --- | --- | --- |
| T1 **G** | Install, bootstrap, Cilium | Both nodes `Ready`; `talosctl get extensions` lists the three extensions; installed on the intended disk; `cilium status` OK with `KubeProxyReplacement: True`; no kube-proxy pods |
| T2 **G** | WireGuard, Hubble, MTU | `cilium-dbg encrypt status`: WireGuard, 1 peer. Hubble flows visible. **A 10 MB POST across nodes and a large image pull both succeed**, covering the VXLAN + WireGuard MTU hazard noted in `k8s-net-cilium.yml` |
| T3 **G** | MetalLB, client IP | `curl` to the pool IP from the laptop shows the **laptop's** IP. The announcing node is the one running the pod. Move the pod: the announcement follows within seconds. The control-plane node announces when it holds the pod |
| T4 **G** | Registry | Pod pulls from `registry.bnei.lan:5000` |
| T5 **G** | DNS | **500 lookups** of `registry.bnei.lan` from a pod: zero NXDOMAIN. `kubernetes.default` and an internet name resolve. A `CiliumNetworkPolicy` modelled on ukubi-game's allows egress to `k8s-app: kube-dns` (**not** a host address: pods talk to CoreDNS, and CoreDNS alone forwards to `169.254.116.108`). Note the rewrite the three prod policies with `169.254.25.10` will need |
| T6 **G** | Longhorn RWO | PVC binds, 2 replicas healthy. Backup to the pilot bucket; delete the PVC; restore; counter intact |
| T7 **G** | Longhorn RWX, fleet-shaped | Two pods on two nodes append to the same file for 10 min, no errors or corruption. Then reproduce agent-fleet's workspace use: a `git clone` of a real repo into the RWX volume, read from a second node, and `fio` sequential and random throughput. **Compare to ADR-0048's 10 MB/s.** Record the share-manager pod's RAM. Kill the node running the share-manager: record how long the mount is unavailable on the other node |
| T7b **G** | Longhorn RWO, not tied to a node | Hard-cut the node holding a pod with an RWO volume: the pod restarts on the other node with its data. Record the time, with and without `node-down-pod-deletion-policy` |
| T8 **G** | Workload isolation | T6/T7 pass with `workloadIsolation: true`; if not, they pass with `false` and the reason is recorded |
| T9 **G** | Graceful node loss | `talosctl shutdown` on the worker: pods evicted, the RWO volume reattaches on Esprimo 1, no `Multi-Attach`. Bring it back with Wake-on-LAN (tests WoL) or a smart-plug cycle |
| T10 **G** | Upgrades | `talosctl upgrade --image <same schematic, newer patch>`, worker then CP; then `talosctl rollback` on one node; then `talosctl upgrade-k8s` one patch. After each: extensions still present; **Longhorn volume data intact**; workloads up. Record API downtime during the CP upgrade |
| T11 | Hard power loss, worker | Smart-plug cut. Record what the RWO volume does: with Longhorn's `node-down-pod-deletion-policy` set, and without (needing the `node.kubernetes.io/out-of-service` taint by hand, as today). Power back: the machine boots by itself and rejoins |
| T12 **G** | Hard power loss, control plane | Smart-plug cut on Esprimo 1. Running pods keep serving; API down. Power back: cluster recovers with no manual step |
| T13 **G** | etcd disaster recovery (not a rebuild) | `talosctl etcd snapshot`, copied off the node. `talosctl reset --graceful=false --reboot --system-labels-to-wipe=EPHEMERAL`, wait for etcd `Preparing`, `talosctl bootstrap --recover-from=<snapshot>`. Cluster state back; **Longhorn user volume survived the EPHEMERAL wipe** |
| T14 | Growing etcd | Reset Esprimo 2 and re-join it as a **second control plane** (etcd 1 → 2), check members, then `etcd leave` and return it to worker. Rehearses the migration's 1 → 3 path. A shared control-plane VIP can't be tested properly with 2 members; that waits for the migration's third member |
| T15 **G** | Remote debugging without SSH | From the laptop via the Pi: `talosctl logs kubelet`, `dmesg`, `dashboard`, `pcap`; `kubectl debug node/esprimo-2 --profile=sysadmin --image=nicolaka/netshoot` in a `privileged`-labelled `debug` namespace. Note anything workload isolation hides |
| T16 | Read-only role | An `os:reader` talosconfig reads logs, dmesg and memory, and is **refused** `reboot`, `reset`, `apply-config`, `upgrade` and `pcap` |
| T17 | Logs off the node | Service logs (TCP `json_lines`) and kernel logs (`KmsgLogConfig`) from **both** nodes reach a `socat` TCP listener on the Pi |
| T18 **G** | No internet | **Pull the Freebox's fiber/WAN cable for ~30 minutes** (LAN, gateway and DHCP stay up). The pilot keeps serving; **cold-boot one Esprimo while the WAN is down** and record time sync (default NTS server is `time.cloudflare.com`), discovery (`discovery.talos.dev`) and boot completion. If boot blocks, set a LAN time source and/or disable discovery in the config |
| T19 | User namespaces | A pod with `hostUsers: false` runs `buildah bud` on a small Dockerfile without `privileged`. This is evidence for the build-runner decision against ADR-0034 |
| T20 **G** | Real apps | `helm template` 2–3 real `common-app-chart` releases from `gitops/` and apply them: they're admitted under Talos's `baseline` Pod Security, or the fix is recorded. Prod has no Pod Security labels today, so this finds surprises early |
| T21 **G** | NIC soak | 7 days with `iperf3` load between the Esprimos (`hostNetwork` pods: there's no shell on Talos), **started after** T7, T9–T14 and T23 so reboots don't interrupt it and the load doesn't skew their numbers: no "Hardware Unit Hang" or link resets in `talosctl dmesg` |
| T22 **G** | Full rebuild from code | Both nodes `talosctl reset --reboot` (full wipe) → back in maintenance mode from the stick, on their DHCP reservations. Rebuild with the **`siderolabs/talos` Terraform provider** (`talos/terraform/`, secrets from the `talos-pilot` Infisical project), then `addons.sh`. Time it end to end. Fits in an evening |
| T23 | RAM | Idle footprint per node with the add-ons and nothing else (`talosctl memory`, `kubectl top node`), plus Longhorn's share alone. Run the prod measurement queries from the evaluation §3 at the same time. Together they give the real RAM-gain number |

T22 runs last: everything learned by hand has to survive being rebuilt
from code.

---

## 3. Risks during the pilot

| Risk | Guard |
| --- | --- |
| Pilot MetalLB answers ARP for a prod IP | Pool outside prod's range, recorded as reserved; no pilot Service pins an address outside it |
| Pilot overlay ranges overlap prod's | Overlay addresses never leave the nodes (VXLAN/WireGuard between pilot nodes; pod-to-LAN traffic is masqueraded to the node IP). Check with `tcpdump` on a prod node during T3 that no `10.233.*` source address appears |
| Pilot fills Garage | Separate bucket with `max_size`; `--tags bucket_ops` only |
| Pilot secrets readable by prod identities | Separate Infisical project and identity. One exception: the pilot's Garage key is written to the prod project by `garage-configure.yml` (§1.6.5); it's a pilot-only key with a capped bucket |
| Esprimos boot into maintenance mode during Phase 0 | Kept off mains power until *Talos* |
| Pi becomes more valuable to an attacker (DNS + cluster credentials + Terraform state) | Static binaries only; credentials fetched per session and deleted; the same trade-off the k9s hub already makes |
| Terraform state leaks the CA | State on the Pi only, gitignored, disposable |
| Esprimos take a DHCP lease in maintenance mode | Expected; the static config replaces it. DNS records are added only once the static addresses are live (the records file accepts real, assigned IPs only) |
| Refurbished SSD or NIC fails | Pilot is disposable; SMART check (1.2) and NIC soak (T21) |

---

## 4. What changes in prod (complete list)

| Change | How | Undo |
| --- | --- | --- |
| Cables for server1, ex-laptop, the Pi, the Esprimos | Phase 0 | Move back |
| udev rejoin rule on ex-laptop, in a playbook | `pve-postinstall.yml`. The playbook targets **all three PVE hosts**: run it limited (`-l ex-laptop`) or review its diff for the other two | Remove the file, reload udev |
| Two Patroni switchovers (pg01 → pg02 → pg01) with the `.232` VIP | `patronictl switchover` | They end where they started |
| Freebox DHCP reservations for the Esprimo MACs | Freebox UI | Delete reservations |
| Tools, credentials and Terraform state on the Pi (prod DNS server) | static binaries in `/usr/local/bin`; `0600` files | Delete |
| `bpftool` on server1/ex-laptop PVE hosts, if missing | `apt` | Remove |
| Pilot Garage key in the prod Infisical project | side effect of `garage-configure.yml` | Delete with the bucket |
| Alertmanager silences | for the windows | Expire |
| `ARCHITECTURE.md` §3: real cabling, real DHCP range, reserved pilot pool | PR | Revert |
| `esprimo-1/2` host records | `bnei-lan-records.yml` + `pihole-configure.yml` run **from the k9s hub** (a heavy run, ADR-0055), after the static IPs are live | Remove records, re-run |
| Garage bucket `talos-pilot-longhorn` + key, `max_size` | `garage-configure.yml --tags bucket_ops`, from the k9s hub | Delete bucket and key |
| Infisical project `talos-pilot` + identity | Infisical UI | Delete project |
| ADR-0070 (Proposed), `talos/`, `.gitignore` entries | PR | Revert |

Nothing in `gitops/`, `inventory/`, `terraform/` (Proxmox) or `pigsty/`
changes.

---

## 5. Go/no-go

**Go** for the migration if all **G** tests pass, T23 shows a RAM gain the
owner considers worth it, and T22 fits in an evening.

**Before the migration starts** (each its own PR):

1. **Off-site backup with a rehearsed restore** (evaluation §0). Not
   optional.
2. **ADRs.** Supersede, amend or mark as no longer applying, as each needs:

   | ADR | What changes |
   | --- | --- |
   | New OS ADR | Talos. Amends ADR-0008's "Ubuntu 24.04 remains" clause. ADR-0008 rejects Flatcar, so it isn't superseded; its "Day-2 friction" argument gets answered with T10/T15/T22 results |
   | 0003 + 0018 | Cilium replaces kube-proxy, with the 1.2.8 `bpftool` evidence |
   | 0016 | kube-vip `.180` → Talos VIP |
   | 0017 | Control-plane placement: Esprimo 1, Esprimo 2, server1; `.165` worker only |
   | 0029 | Patroni DCS placement, or CNPG |
   | 0020 | corosync gone |
   | 0002 / 0019 | Longhorn stays; data path, replica count across 4–5 nodes, `.165` excluded from replicas or not |
   | 0027 | Alloy pipeline + Talos service/kernel logs instead of journald |
   | 0040 | Hardening baseline on Talos: etcd encryption, audit path, Pod Security labels (Decision 6, never built) |
   | 0043 | GPU on Talos: NVIDIA extensions replace the Ubuntu-only playbook |
   | 0055 | Talos nodes aren't SSH peers; the Pi is the hop. If the k9s hub is retired, re-home its `:49222` break-glass |
   | 0064 | Guest probes for guests that no longer exist |
   | 0036 / 0026 | The NFS VM goes; Longhorn RWX (T7) or an in-cluster NFS pod replaces the `nfs` class; template export gone |
   | 0034 | build-runner: user-namespace pod (T19) vs one KubeVirt VM |
   | CNPG vs Pigsty | Includes the `infisicaldb` circularity |

3. **ArgoCD multi-cluster inside Pattern C** (a destination per registry
   entry).
4. **Two clusters on one LAN:** temporary API VIP, pool split, the
   `.233` / `.234` / `.235` handovers, containerd mirror ordering.

**No-go** leaves everything as it is. The Esprimos can join the current
cluster as kubespray workers (bare-metal Ubuntu, or PVE nodes) instead.

---

## 6. What the doubt cycles changed

### v1 → v2

| Finding | Source | Change |
| --- | --- | --- |
| The `.165`/Pi patch-panel move was in the layout but missing from the move order, and it cuts five services at once | repo review | Design no longer moves it (§0) |
| server1/ex-laptop uplinks are USB `r8152` dongles; the rejoin rule exists on server1 only, untested in place | repo review, `bootstrap-test-notes.md` 2026-08-25 | 0.1.1 |
| Freebox reboot also breaks NetBird login, the NetBird probe, Discord alerts | repo review, ADR-0055 | 0.1.2–3, 0.5 lists |
| Loop risk while re-cabling | repo review | Single-uplink design |
| "streaming" is not proof of a healthy replica | repo review, 2026-08-15 incident | Check table in 0.3 |
| Infisical has no folders; identities see the whole project; Terraform state holds the CA | repo review, `docs/secrets.md` | Dedicated project (1.1) |
| Garage bucket creation rewrites every key unless `--tags bucket_ops`; shared 180G capacity | repo review | 1.6.5, §4 |
| `.55` + `1.1.1.1` caused ~50% NXDOMAIN in prod | repo review, `settings.yml` | `.55` only; T5 does 500 lookups |
| Likely I219 NIC with a known hang history | repo review | `lspci -k`, T21 |
| ADR before `talos/` | repo review, `DECISION.md` §5 | 1.0 |
| KPR premise is about server1, not the Esprimos | repo review | 1.2.8 |
| ADR list incomplete; ADR-0008 can't be "superseded" | repo review | §5 table |
| DHCP range in `ARCHITECTURE.md` contradicts the address plan | repo review | 0.1.4 |
| `gen config` installs the empty schematic; upgrades need `--image` | upstream review | 1.3, T10 |
| Longhorn data path is `/var/mnt/longhorn`, no `extraMounts` | upstream review, Talos Longhorn guide | 1.4, 1.6.5 |
| Pod Security `baseline` rejects MetalLB/Longhorn | upstream review | 1.6.1, T20 |
| 1.14 uses separate config documents (`KubeProxyConfig`, `KubeFlannelCNIConfig`, …) | upstream review, 1.14 what's-new | §1.4 rewritten |
| `reset` + `--recover-from` procedure was wrong | upstream review, disaster-recovery doc | T13 |
| `destinations` carries service logs only; kernel needs `KmsgLogConfig`; `nc -lu` sees one peer | upstream review | 1.4, T17 |
| Pods use CoreDNS, not host DNS | upstream review | T5 |
| metrics-server needs rotated kubelet serving certs | upstream review | 1.4, 1.6.3 |
| 1.14 workload isolation vs iscsid | upstream review | 1.4, T8 |
| EPHEMERAL `maxSize` only on first provisioning | upstream review | 1.4 |
| `bpf.masquerade` + host-DNS forwarding known issue | upstream review | 1.6.2 |
| `os:reader` is also refused `pcap` | upstream review | T16 |
| etcd metrics port changed to 2383 in 1.14 | upstream review | 1.4 |
| k8s default would be 1.37.0 | upstream review | 1.1 pin |
| Missing: no-internet boot, CP power loss, user namespaces, volume survives upgrade/wipe, etcd growth, real apps, scripted add-ons, MTU | both | T12, T14, T18–T22, T2 |

### v2 → v3 (final review)

| Finding | Change |
| --- | --- |
| `reset` without `--reboot` shuts the node down; a full reset wipes the ESP; the stick is the recovery path; T13 isn't a rebuild | §1.2.6, §1.5, T13, T22 |
| Full rebuilds come back on unknown DHCP addresses | Freebox reservations (§0.1.5, §4), T22 |
| The Pi gap is **LAN-wide**: DHCP clients, Pi-only hosts (build-runner, nfs-storage, k9s hub), NFS mounts, backups to `garage.bnei.lan` | §0.3 *Move Pi*, §0.1.6, `crictl pull` check |
| No Kubernetes etcd / API check after moves | §0.3 checks table |
| Switching back to pg01 was optional, leaving the leader on the gaming host | Mandatory, with re-check |
| Esprimos plugged in early would sit in maintenance mode all of Phase 0 | Off mains power until *Talos* |
| A Freebox reboot is too short for T18 | T18 pulls the WAN for 30 min instead |
| Missing install details: `config endpoints`, disk selector, schematic ID, secrets flow, Pi tools | §1.2, §1.3, §1.5, §1.7 |
| T7b (owner's storage requirement) and T12 not go-critical | Marked **G** |
| T21's soak overlapped disruptive tests | Starts after them; `hostNetwork` iperf3 |
| §4 incomplete (Pi tools, bpftool, Garage key in prod Infisical, reservations, playbook scope) | §4, §3 |
| Serving-cert approver installed too late | Right after Cilium (§1.6.3) |
| BIOS update after the wipe; WoL needs config; T9 power-back unspecified | §1.2.3, §1.4 `EthernetConfig`, T9 |
| Order-table numbers didn't match §0.3; §6 labels; `LinkConfig`/`HostnameConfig` | Named steps; this table; §1.4 |

**Still unverified** (marked in place, to settle during the pilot):
- MetalLB honouring the exclude-LB label (removed anyway);
- `defaultLBServiceIPAM`;
- Longhorn's `node-down-pod-deletion-policy` behaviour;
- whether the Terraform provider handles 1.14's documents;
- the G558's exact NIC;
- whether the Infisical CLI round-trips multi-line values (base64 used instead);
- the node-side resolver chain for containerd (checked with `crictl pull`).
