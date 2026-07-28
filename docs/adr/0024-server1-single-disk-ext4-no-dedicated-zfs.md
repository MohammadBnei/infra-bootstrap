# ADR-0024: `server1` reinstalled single-disk, ext4 root, no dedicated ZFS pool

**Status:** Accepted
**Amends:** [ADR-0014](0014-pve-storage-layout-zfs-vs-local-zfs.md) (server1 portion only — the `ex-laptop`/`zfs-exlaptop` decision in ADR-0014 is unaffected and still stands)

## Context

ADR-0014 decided a dedicated `zfs-server1` ZFS pool on `.200`'s NVMe
476GB, keeping the separate 149GB HDD out of the pool as a future backup
target. That plan assumed two physical disks.

Before the PVE reinstall happened, the 149GB HDD was physically removed
from `server1` — it no longer has two disks, just the NVMe 476GB.

## Decision

Installed PVE on the NVMe with the graphical installer's default
filesystem (ext4 + `local`/`local-lvm`), matching how the primary host
`.165` is already laid out (`ARCHITECTURE.md` §7 — `.165` also has no
ZFS). No dedicated `zfs-server1` pool was created; `ansible/playbooks/
pve-postinstall.yml`'s ZFS-pool play stays a no-op for `server1`
(`zfs_pool_device` left empty in `ansible/inventories/proxmox/hosts.yml`,
which the play already guards on).

## Consequences

- `server1` has no separate VM-storage pool — VM disks land on
  `local-lvm` like `.165`, no fast ZFS snapshot/clone there.
- The 149GB HDD backup target described in `ARCHITECTURE.md` §7 no longer
  exists on this host; a backup target is now an open question (not
  reopened here — flag separately if/when needed).
- `terraform/variables.tf`'s optional per-node `datastore_id` (added for
  ADR-0014) simply isn't set for `server1`; it falls back to `.165`'s
  `template_storage_id` via the existing `coalesce`, which is wrong for a
  cross-host VM — any `server1`-targeted Terraform VM must set
  `datastore_id: local-lvm` explicitly.
- `ex-laptop`'s `zfs-exlaptop` pool (ADR-0014) is untouched by this — that
  host has since been reinstalled to PVE and joined the corosync cluster
  too, keeping its SSD 238GB as a dedicated ZFS pool (unlike `server1`,
  which lost its second disk before reinstall).
