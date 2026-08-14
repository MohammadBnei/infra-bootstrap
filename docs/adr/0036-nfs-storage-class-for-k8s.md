# ADR-0036: A second, unreplicated `nfs` StorageClass on the existing `nfs-storage` VM

**Status:** Accepted
**Date:** 2026-08-14
**Amends:** [ADR-0026](0026-nfs-shared-pve-storage-cross-host-clone.md) (narrows
its "never mounted into the K8s cluster" scope note to the
`/export/templates` share specifically, not the `nfs-storage` VM as a whole)

## Context

`ukubi-cluster` has two StorageClasses today:

- **`longhorn`** — default, `defaultReplicaCount: 3`, backed by each K8s VM's
  `scsi1` disk, snapshotted daily and backed up to Garage
  (`gitops/bootstrap/longhorn-daily-snapshot-recurringjob.yaml`).
- **`local-path`** — non-default fallback kept by
  [ADR-0019](0019-longhorn-rollout-specifics.md), a `hostPath` under
  `/opt/local-path-provisioner`.

Two gaps neither one covers:

**1. ReadWriteMany.** The only RWX available is a Longhorn RWX volume, which
works by starting a `share-manager` pod that re-exports the volume over NFS —
every consumer then does a host-level `mount -t nfs` against that pod (this is
why `ansible/playbooks/k8s-node-prereqs.yml` installs `nfs-common` at all).
So RWX today is *already NFS*, with a pod-shaped single point of failure and
an extra hop in front of it. `agent-fleet` is the current and only consumer
(a 30Gi workspace PVC plus a shared PVC, `agent-fleet/docs/adr/0010`).

**2. Capacity arithmetic.** The K8s node disks are 100 / 40 / 40 / 100 / 100
GB (`terraform/terraform.tfvars`). At 3 replicas, usable Longhorn capacity is
roughly a third of the raw total *and* is bounded by the two 40GB control
plane nodes — a replica has to fit somewhere. Any bulk data that is cheaply
regenerable (build caches, media, scraped artifacts) pays a 3× tax on the
scarcest disks in the estate for a durability guarantee it does not need.

Meanwhile `nfs-storage` (`192.168.1.198`, a VM on `server1`) already exists,
already runs `nfs-kernel-server`, and already has NVMe headroom on `server1`
that nothing else is using. It was built by ADR-0026 purely as PVE shared
storage for cross-host template cloning, and that ADR's scope note said the
export is *"never mounted into the K8s cluster, never exposed as a
StorageClass or PV backend."* That sentence is what this ADR amends.

## Decision

Add a **second, non-default StorageClass named `nfs`**, backed by a
**separate disk and a separate export** on the existing `nfs-storage` VM.

1. **Dedicated disk, not a subdirectory.** `terraform/nfs.tf` grows a third
   disk (`scsi2`, raw), formatted and mounted at `/export/k8s` by
   `ansible/playbooks/nfs-configure.yml`. `scsi1` (`/export/templates`) stays
   exactly what ADR-0026 made it. The point of separation is blast radius: a
   runaway PVC must not be able to fill the storage that PVE cross-host
   cloning depends on. The VM's 1 vCPU / 1GB stays as ADR-0026 sized it —
   `nfsd` is kernel threads and extra RAM only buys page cache, which does
   little for streamed bulk data on `sync` exports. Resize when a
   measurement says to, not pre-emptively.

2. **Separate export, separate client list.** `/export/k8s` is exported to
   the five K8s nodes only; `/export/templates` keeps its own list of the
   three PVE hosts (ADR-0020). Neither list is widened. Both keep
   `rw,no_root_squash,sync,no_subtree_check` — `no_root_squash` is required
   for the CSI driver to create and chown per-volume subdirectories, and
   `sync` is kept over the faster `async` because an unreplicated store is
   the wrong place to also gamble on the server's page cache surviving a
   crash.

3. **Addressed by DNS name, not IP, on both ends.** The export client list
   uses `k8s-cp-0N.bnei.lan` / `k8s-worker-0N.bnei.lan` and the StorageClass
   points at `nfs-storage.bnei.lan` — Pi-hole is the authoritative resolver
   for `bnei.lan` (DECISION.md §2) and already holds every one of those
   records. This follows the `registry.bnei.lan` precedent from
   [ADR-0034](0034-in-cluster-oci-registry-zot-garage-backed.md), where a
   `.lan` hostname is pinned in node-level config precisely so the address
   behind it can move.

   This requires `nfs-storage` itself to resolve `bnei.lan`, which it
   currently cannot: `terraform/nfs.tf`'s `initialization.dns` block sets
   only `domain`, no `servers`. It gains `servers = [var.pihole_ip]`, the
   same fix `terraform/build-runner.tf:113` already carries after
   `k9s-dashboard` hit exactly this failure (`docs/bootstrap-test-notes.md`).

   ADR-0026's existing PVE client list stays as literal IPs. It is live and
   working, converting it buys nothing for this change, and a mistake there
   breaks cross-host VM cloning — out of scope on purpose, not an oversight.

4. **`csi-driver-nfs` as the provisioner**, installed as a wave-0 platform
   app (one element in `gitops/bootstrap/platform.applicationset.yaml`, one
   values file), in `kube-system` alongside `metrics-server`. Its bundled
   external-snapshotter is disabled — kubespray owns the snapshot CRDs.

5. **The class is `nfs`, and it is not default.** `longhorn` remains the
   default class ([ADR-0002](0002-storage-longhorn-over-ceph-nfs.md) is
   unchanged); nothing gets moved onto `nfs` implicitly. `reclaimPolicy:
   Delete`, `volumeBindingMode: Immediate`, mount options `nfsvers=4.1,hard,
   timeo=600,retrans=2,noatime`. `hard` is deliberate: a `soft` mount turns a
   server hiccup into silent truncated reads, whereas `hard` blocks until the
   server returns.

6. **Scope: expendable data only.** `nfs` is for volumes whose loss is an
   inconvenience, not an incident — RWX scratch space and bulk regenerable
   data. Anything whose loss matters stays on `longhorn`.

## Alternatives considered

- **`local-path`, which already exists.** The obvious "we already have a
  lighter class" answer. Rejected: it is RWO-only and node-pinned — the pod
  can never reschedule to another node without abandoning its data — so it
  addresses neither gap. It stays installed, unchanged.
- **A second Longhorn StorageClass with `numberOfReplicas: 1`.** Cheapest
  possible change (a single `StorageClass` manifest, no new components).
  Rejected: it still consumes the scarce node disks this is meant to relieve,
  and it still gives no real RWX — a 1-replica RWX volume is the same
  `share-manager` pod with the replica count turned down.
- **Static in-tree `nfs:` PersistentVolumes, no driver at all.** Kubernetes
  mounts NFS natively; a hand-written PV needs zero new software. Rejected:
  the requirement is a StorageClass, i.e. dynamic provisioning — this would
  mean creating a directory on `.198` and a PV manifest by hand for every
  volume forever.
- **A subdirectory of the existing `/export/templates` disk.** Zero Terraform
  change. Rejected — see Decision 1; it couples K8s PVC growth to PVE's
  ability to clone VMs.
- **`nfs-subdir-external-provisioner`** (what the legacy `.181`/`.191` cluster
  used, `k8s-cluster/install-all.sh:31`). Rejected: effectively unmaintained
  and superseded upstream by `csi-driver-nfs`; no reason to re-adopt the thing
  ADR-0002 already moved away from.
- **Ceph.** Still off the table, same reasoning as ADR-0002 and ADR-0026.

## Consequences

Named explicitly so they are not later mistaken for oversights:

- **`server1` is now a hard dependency for any `nfs`-backed workload.** If it
  goes down, every `nfs` PVC blocks (`hard` mounts, by choice) until it comes
  back. Longhorn survives a single node loss; this class does not. This is the
  price of the class and the reason it is not the default.
- **No backup.** `longhorn` PVs get daily snapshots into Garage; `/export/k8s`
  gets nothing. A restic/rsync job to the Garage S3 endpoint is the obvious
  follow-up and is deliberately **not** part of this change — until it exists,
  Decision 5's scope restriction is the whole safety story.
- `server1`'s local-lvm loses the size of the new disk. Confirm free space with
  `pvesm status` before choosing it.
- **Pi-hole becomes a dependency of the NFS authorization path.** Hostnames
  in `/etc/exports` are resolved when `exportfs` loads them, so a Pi-hole
  outage is harmless while things are running but denies every client if
  `nfs-storage` reboots during one. Accepted because the cluster already
  can't pull images without Pi-hole (`registry.bnei.lan` is in every node's
  containerd config, ADR-0034) — this widens an existing dependency rather
  than creating a new failure domain.
- `no_root_squash` now extends to the five K8s nodes. A pod would still need
  host network access plus `CAP_SYS_ADMIN` to abuse it directly, but the
  export is one more thing that trusts the node boundary.
- `nfs-common` is already installed cluster-wide for Longhorn RWX
  (`k8s-node-prereqs.yml`), so there is no new node prerequisite.
- **`agent-fleet` is not migrated by this ADR.** Its existing Longhorn RWX
  volumes keep working; moving them is a data copy with its own downtime
  window, tracked separately.
- ADR-0026's `shared-templates` PVE pool, its export, its client list, and its
  disk are all untouched. This ADR adds a sibling; it does not rework the
  original.
