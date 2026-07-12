# ADR-0014: PVE storage layout — ZFS pool vs `local-zfs` directory

**Status:** Proposed

## Context

Proxmox VM disk storage can be laid out as a dedicated ZFS pool
(snapshots, simple cloning) or as the simpler `local-zfs` directory
storage (easier initial setup, harder to snapshot/clone VM disks later).
This affects how VM provisioning is scripted in `terraform/`.

## Decision

Not yet decided. Affects VM provisioning — resolve before scripting
further Terraform storage config beyond what's already provisioned for
`.165`.

## Consequences

Pending — no downstream effects committed yet.
