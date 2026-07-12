# ADR-0002: Longhorn for K8s app PVs (over Ceph, over the NFS-server plan)

**Status:** Accepted
**Date:** 2026-07-12 (supersedes an earlier NFS-server plan)

## Context

K8s workloads need a default `StorageClass`. Three options were
weighed:

- **Ceph** — full-featured but operationally heavy for a 3-node homelab;
  not worth the Day-2 burden at this scale.
- **NFS server on server1 (`.200`)** — the original plan, exporting
  `/home/mohammad/.local/share/k8s-nfs`. Dropped 2026-07-12 in favor of
  in-cluster storage; that export still holds the *legacy* cluster's
  (`.181`/`.191`) live data, which needs a one-off migration-in — see
  ADR-0019 (Longhorn rollout specifics).
- **Longhorn** — in-cluster distributed block storage, no separate
  storage host, adequate for homelab scale and failure domains.

## Decision

Longhorn is the default `StorageClass` for K8s application PVs.

- Each K8s VM (`terraform/k8s-vms.tf`) gets a dedicated second disk
  (`scsi1`) reserved for Longhorn's data path, kept separate from the OS
  root disk (`scsi0`).
- Postgres is **not** on Longhorn — Pigsty data stays on local PVE host
  storage, unrelated to the K8s storage layer.
- Backup target for pgBackRest and other backups: 149GB HDD on server1
  (replaces the dead Ceph OSD it used to serve) — unaffected by this
  storage-engine change.

## Consequences

- **Known limitation, accepted knowingly:** all 3 K8s VMs currently run
  on the single active PVE host (`.165`). Longhorn's default 3-way
  replica count protects against VM/node failure, not physical-host
  failure, until `.200`/`.161` are reinstalled and joined.
- Ceph is off the table for this cluster (see ADR-0011-adjacent
  reasoning — not enough scale to justify it).
- The legacy NFS export's data still needs a one-off copy into
  Longhorn-backed PVCs during cutover — tracked as open work in
  ADR-0019, not yet a written runbook.
