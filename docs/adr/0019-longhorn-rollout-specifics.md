# ADR-0019: Longhorn rollout specifics

**Status:** Proposed

## Context

ADR-0002 locks Longhorn as the K8s storage engine, but several rollout
details remain open:

- Per-VM disk sizing — blocked on inventorying the legacy NFS export's
  actual data volume at `.200:/home/mohammad/.local/share/k8s-nfs`.
- Default replica count — chart default is 3; needs confirming
  `k8s-cp-01` is actually schedulable for replicas and not just tainted
  control-plane-only.
- Whether `local-path-provisioner` (currently the interim default
  StorageClass) is removed outright once Longhorn is verified healthy,
  or kept installed as a non-default fallback.

## Decision

Not yet decided. Resolve before the first Longhorn sync — this also
gates writing the real `docs/runbook-migration-nfs-longhorn.md` steps
(currently a TODO placeholder).

## Consequences

Until resolved, `local-path-provisioner` remains the default
StorageClass as an interim stopgap (see `ARCHITECTURE.md` §7 Storage).
