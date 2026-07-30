# ADR-0028: `ex-laptop` also has no dedicated ZFS pool

**Status:** Accepted
**Amends:** [ADR-0014](0014-pve-storage-layout-zfs-vs-local-zfs.md) (the
`ex-laptop`/`zfs-exlaptop` portion) and corrects [ADR-0024](0024-server1-single-disk-ext4-no-dedicated-zfs.md)'s
consequences section, which asserted `ex-laptop` "keeping its SSD 238GB
as a dedicated ZFS pool" — confirmed live (2026-07-30, user-reported) that
this is not the case.

## Context

ADR-0014 decided a dedicated `zfs-exlaptop` ZFS pool on `.161`'s SSD
238GB. ADR-0024 (server1's single-disk amendment) explicitly stated the
`ex-laptop` half of ADR-0014 was unaffected and still stood. Neither was
ever confirmed against the live host — this repo's own discipline
(`terraform/README.md`, ADR-0014's own consequences) requires storage
pool names to be confirmed via `pvesm status`, never assumed from a prior
plan.

While drafting the `k8s-cp-03` Terraform entry (2nd/3rd control-plane
members, `ARCHITECTURE.md` §2 / ADR-0017), the user confirmed live that
`ex-laptop`'s datastore is `local-lvm`, same as `server1` and `.165` — no
`zfs-exlaptop` pool exists.

## Decision

Treat `ex-laptop` as `local-lvm`-only, matching `server1`'s ADR-0024
outcome. No further action to create the pool — this is a statement of
actual state, not a plan to reconcile it.

## Consequences

- `terraform.tfvars`'s `k8s-cp-03` entry sets `datastore_id = "local-lvm"`
  explicitly (same reasoning as ADR-0024's bullet for `server1`: falling
  back to `.165`'s `template_storage_id` via `coalesce` would be wrong for
  a cross-host VM).
- No ZFS snapshot/clone convenience on any of the 3 PVE hosts now — all
  three are plain `local-lvm`. This is a uniform simplification, not a
  regression specific to `ex-laptop`.
- `ARCHITECTURE.md` §1's `ex-laptop` row (SSD 238GB, no storage pool
  detail given there yet) should reflect `local-lvm` if/when that section
  is next touched.
