# ADR-0014: PVE storage layout — ZFS pool vs `local-zfs` directory

**Status:** Accepted (both host-specific portions since amended — server1 by [ADR-0024](0024-server1-single-disk-ext4-no-dedicated-zfs.md): the 149GB HDD assumed below was physically removed before reinstall, so `server1` never got a dedicated ZFS pool. ex-laptop by [ADR-0028](0028-ex-laptop-no-dedicated-zfs-pool.md): confirmed live 2026-07-30 that `ex-laptop` also has no `zfs-exlaptop` pool, contrary to what this ADR and ADR-0024's own consequences section assumed — it's on `local-lvm` like the other two hosts.)

## Context

Proxmox VM disk storage can be laid out as a dedicated ZFS pool
(snapshots, simple cloning) or as the simpler `local-zfs` directory
storage (easier initial setup, harder to snapshot/clone VM disks later).
This affects how VM provisioning is scripted in `terraform/`.

## Decision

Dedicated ZFS pool, one per new host: `zfs-server1` on `.200`'s NVMe
476GB, `zfs-exlaptop` on `.161`'s SSD 238GB (naming convention set in
`ansible/inventories/proxmox/hosts.yml`). Created and registered as PVE
storage by `ansible/playbooks/pve-postinstall.yml` (play 3), before
Terraform ever references it as a `datastore_id`. `.200`'s separate 149GB
HDD stays out of the pool, reserved for a possible future pgBackRest
target.

## Consequences

- `terraform/variables.tf`'s `k8s_nodes` object type gained an optional
  `datastore_id` field per node (defaulting to `.165`'s
  `template_storage_id` via `coalesce` in `k8s-vms.tf`) so new-host worker
  entries can point at their own ZFS pool once confirmed via `pvesm status`.
- The exact pool names must be confirmed live (never guessed) before
  filling in `terraform.tfvars` — see `terraform/terraform.tfvars.example`.
