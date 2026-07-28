# ADR-0026: NFS-backed shared PVE storage for cross-host VM template cloning

**Status:** Accepted
**Date:** 2026-07-28

## Context

Stage 2 (ARCHITECTURE.md §11 Phase 3) needs Terraform to clone K8s worker
VMs onto `server1`/`ex-laptop`, not just `.165`. The golden template
(VMID 9001, `terraform/template.tf`) lives on `.165`'s `local-lvm` — a
non-shared PVE storage. Checked against `bpg/terraform-provider-proxmox`'s
actual clone implementation (`proxmoxtf/resource/vm/vm.go`,
`vmCreateClone`): when the source VM's disks aren't on shared storage, the
provider still supports cross-host cloning, but only via an automatic
clone-then-migrate workaround (`docs/adr/0020`'s `--with-local-disks`
migrate) — the new VM briefly exists on `.165` before relocating. That
works, but it's slower and adds an unnecessary hop for every future
cross-host worker.

Options considered:
- **Do nothing, rely on the clone+migrate fallback.** Zero new
  infrastructure, already provider-native. Rejected as the primary path
  because it doesn't scale cleanly to repeated future provisioning and
  masks a real capability gap (no actual shared storage in the cluster,
  despite ADR-0020 already assuming live migration works).
- **Ceph.** Already rejected for K8s app PVs (ADR-0002) on operational-
  weight grounds for a 3-node homelab; the same reasoning applies here —
  not worth the Day-2 burden for what's only needed to speed up template
  distribution.
- **NFS**, hosted as a new dedicated instance on `server1` (user's
  choice — `.165` already carries `pg01`/`k8s-cp-01`/`k8s-worker-01`/
  `garage-storage`; `server1` has NVMe headroom and no other tenant yet).
  Chosen.

**Scope note — this is not ADR-0002 revisited:** ADR-0002 rejected an NFS
server on `server1` specifically as the backing store for *K8s app PVs*
(replaced by Longhorn). This NFS export is PVE-internal storage for VM
template cloning/migration only — it is never mounted into the K8s
cluster, never exposed as a StorageClass or PV backend. Same host, same
underlying protocol, different layer and different problem.

**LXC vs VM for the NFS server itself:** an LXC (mirroring
`garage-storage`'s pattern) was the first instinct, but
`nfs-kernel-server` needs kernel-level `nfsd`, which isn't reliably
namespaced inside a container. Confirmed via `terraform providers
schema -json` that `proxmox_virtual_environment_container`'s `features`
block only controls what a container may *mount as a client* (`fuse`,
`mount`, `nesting`) — no AppArmor/privilege escape hatch is exposed to
make an in-container `nfsd` reliable, and hand-patching that outside
Terraform would silently break on any container recreate. A lightweight
cloud-init VM avoids the entire problem class at negligible extra
overhead.

## Decision

A new VM, `nfs-storage` (`terraform/nfs.tf`), on `server1`, built directly
from the Ubuntu cloud image (not cloned from VMID 9001 — cloning from a
template that isn't yet on shared storage to bootstrap the very storage
meant to fix that would be circular). Terraform creates a bare VM with a
raw second disk; `ansible/playbooks/nfs-configure.yml` formats it,
installs `nfs-kernel-server`, and exports it to the 3 PVE cluster members
only (`.165`/`server1`/`ex-laptop`) with `no_root_squash` (PVE mounts NFS
storage as root).

The export is registered as a PVE storage pool named `shared-templates`
via `pvesm add nfs ...`, automated as a second play in
`nfs-configure.yml` (idempotent, only runs if not already present) —
cluster-wide config via corosync (ADR-0020), so this only ever runs once
regardless of node count. Content types `images` (VM disks) and
`snippets` (cloud-init vendor-data, see Consequences).

`terraform/template.tf`'s golden template disk + cloud-init drive move
onto `shared-templates` via a new `template_shared_storage_id` variable —
kept separate from `template_storage_id`, which stays the coalesce
fallback for `k8s_nodes` entries that don't set their own `datastore_id`,
so this change doesn't silently try to move `k8s-cp-01`/`k8s-worker-01`'s
already-working `local-lvm` disks.

`terraform/k8s-vms.tf`'s `clone` block now sets `node_name =
var.pve_node_name` (the source node), which is what lets the provider
detect shared storage and take its direct-clone path instead of the
clone-then-migrate fallback.

## Consequences

- `server1` gains a 4th tenant (after the future `pg02` migration, still
  a separate later step) — modest footprint (1 vCPU / 1GB / 120GB total).
- **Non-obvious second fix, found the hard way:** `terraform/cloud-init.tf`'s
  `k8s_vm_vendor_data` snippet (qemu-guest-agent install + Longhorn-disk
  auto-format) lives on `.165`'s local `snippets` storage. Every PVE node
  has its own separately-named `local` storage, so a `server1`-hosted
  `k8s_nodes` entry would resolve `vendor_data_file_id` against
  `server1`'s own (empty) local storage at boot and silently lose the
  snippet. The obvious fix — repoint the existing resource's
  `datastore_id` at `shared-templates` — turned out to be wrong: a real
  `terraform plan` showed `vendor_data_file_id` is `ForceNew`, so moving
  it would mark every VM referencing it, including the already-live
  `k8s-cp-01`/`k8s-worker-01`, "must be replaced" (destroy the running
  control plane). Fixed instead with a second, separate resource
  (`k8s_vm_vendor_data_shared`, identical content) that only cross-host
  `k8s_nodes` entries reference — same shared-storage fix, without
  touching what already-live VMs point at. `clone.node_name` hit the
  identical ForceNew trap and got the identical fix: conditional on
  whether the entry is actually cross-host, `null` (== omitted,
  unchanged) otherwise.
- **Third fix, also found by testing, not foreseen in this ADR's original
  design:** `nfs-storage`'s own `agent.enabled = true` made `terraform
  apply` hang waiting for a qemu-guest-agent handshake — nothing installs
  the agent before first boot on a VM built straight from a cloud image
  with no vendor-data. Fixed with a small dedicated
  `nfs_vm_vendor_data` snippet (guest-agent install only, no Longhorn
  logic) applied at create time, not deferred to `nfs-configure.yml`.
- The template's disk move (`template_storage_id` → shared storage) is a
  real, if low-risk, change to already-tracked state (VMID 9001) —
  nothing already cloned from it is affected retroactively.
- `shared-templates` is scoped to the golden template only for now, not
  general K8s VM disk storage — widening that scope (e.g. for real live
  migration of already-running VMs) is a bigger step with its own
  tradeoffs, deferred until actually needed.
- Ceph stays off the table (ADR-0002, this ADR) — no change to that
  position.
