# ADR-0070: A throwaway Talos pilot on the two Esprimos

**Status:** Proposed. Decides the pilot only. Nothing in prod changes
because of this ADR; each prod change the pilot could lead to gets its own
ADR after the go/no-go
([plan §5](../plan-talos-pilot-esprimo.md#5-gono-go)).
**Date:** 2026-11-09
**Related:**
- [`docs/evaluation-drop-proxmox-talos.md`](../evaluation-drop-proxmox-talos.md): why;
- [`docs/plan-talos-pilot-esprimo.md`](../plan-talos-pilot-esprimo.md): how;
- [ADR-0003](0003-cni-cilium-chaining-over-kube-proxy-replacement.md) and
  [ADR-0018](0018-cilium-ebpf-offload-flip.md) (Cilium mode);
- [ADR-0008](0008-reject-flatcar-vm-os.md) (OS);
- [ADR-0002](0002-storage-longhorn-over-ceph-nfs.md) and
  [ADR-0019](0019-longhorn-rollout-specifics.md) (Longhorn);
- [ADR-0034](0034-in-cluster-oci-registry-zot-garage-backed.md) (builds
  outside the cluster);
- [ADR-0055](0055-netbird-as-daily-ssh-path.md) (access);
- [ADR-0062](0062-fleet-github-app.md) (own Infisical project pattern).

## Context

The owner wants a lab that is lighter on RAM and easier to manage, and is
considering dropping Proxmox for Kubernetes on bare metal, with Talos Linux
as the OS. The evaluation found the idea worth testing but not yet
justified. The things that decide it need real numbers, not estimates:
- the RAM actually regained;
- whether Talos's API-only operation is easier day to day than Ubuntu +
  kubespray (the argument ADR-0008 used against Flatcar);
- whether the storage and networking stack this cluster depends on works
  on Talos;
- whether two refurbished mini PCs are reliable enough.

Two Fujitsu Esprimo G558s (i5, 32 GB, 1 TB SSD) were bought. They carry
nothing yet, which makes them a test bed at no risk to prod.

## Decision

**Run a disposable two-node Talos cluster on the Esprimos, kept separate
from prod, and judge the migration on its test results.** The pilot's
choices are made here, for the pilot only:

1. **Talos v1.14.x** with a custom Image Factory schematic: `intel-ucode`,
   `iscsi-tools`, `util-linux-tools`, kernel arg `net.ifnames=0`.
   Kubernetes pinned to prod's 1.35.4.
2. **Cilium replaces kube-proxy in the pilot** (`kubeProxyReplacement:
   true`, via KubePrism). This deliberately differs from prod's ADR-0003
   setup, to measure the simpler stack. **ADR-0003 and ADR-0018 are not
   changed:** prod keeps chaining mode until a separate ADR decides
   otherwise.
3. **MetalLB L2 stays.** Cilium's own L2 announcements are incompatible
   with `externalTrafficPolicy: Local`, which Traefik and NetBird STUN rely
   on. The pilot pool is a reserved slice outside prod's `.233-.250`.
4. **Longhorn stays the replicated storage class.** App volumes must not
   be tied to a node, and agent-fleet's workspace is RWX. Data lives on a
   Talos user volume at `/var/mnt/longhorn`; 2 replicas on 2 nodes.
5. **Prod ArgoCD stays out.** Add-ons are installed by one script,
   `talos/addons.sh`. A hand-made `Application` would bypass the registry
   (ADR-0004); multi-cluster Pattern C is a migration design item.
6. **Access via the Pi.** Laptop → NetBird SSH → `pihole` → `talosctl` /
   `kubectl` over the LAN. The Esprimos are not NetBird peers, and no mesh
   route reaches them, so ADR-0009 and ADR-0055 hold as written.
7. **Secrets in a dedicated Infisical project `talos-pilot`** with its own
   identity, following ADR-0062's pattern. Never committed; `talos/` holds
   no secrets, and `.gitignore` covers what talosctl and Terraform write
   locally.
8. **Pilot-only resources are capped and separate:** its own Garage bucket
   with `max_size`, created with `--tags bucket_ops`; its own MetalLB
   slice; its own DNS records.

## Consequences

- A new top-level directory `talos/` holds the schematic, config patches,
  add-on values and script. It is the start of the declarative source the
  migration would use, and it is deleted if the go/no-go says no.
- The pilot adds small, reversible prod changes, all listed in plan §4:
  cabling, DHCP reservations, DNS records, a Garage bucket, an Infisical
  project, tools on the Pi.
- The go/no-go depends on the plan's go-critical tests. A "go" opens a
  series of ADRs: a new OS ADR amending ADR-0008's Ubuntu clause,
  ADR-0003/0018, 0016, 0017, 0029, 0020, 0002/0019, 0027, 0040, 0043, 0055,
  0064, 0036/0026, 0034, and CNPG vs Pigsty. A "no-go" leaves everything as
  it is, and the Esprimos can join the current cluster instead.
- **Prerequisite for any migration, independent of this pilot:** an
  off-site backup with a rehearsed restore (`ARCHITECTURE.md` §10).
