# ADR-0019: Longhorn rollout specifics

**Status:** Accepted

## Context

ADR-0002 locks Longhorn as the K8s storage engine, but several rollout
details remained open:

- Per-VM disk sizing — blocked on inventorying the legacy NFS export's
  actual data volume at `.200:/home/mohammad/.local/share/k8s-nfs`.
- Default replica count — chart default is 3; needs confirming
  `k8s-cp-01` is actually schedulable for replicas and not just tainted
  control-plane-only.
- Whether `local-path-provisioner` (currently the interim default
  StorageClass) is removed outright once Longhorn is verified healthy,
  or kept installed as a non-default fallback.
- Backup target for Longhorn snapshots, since Stage 1 stands up baseline
  backups before any production traffic cutover.

## Decision

- **Per-VM disk sizing**: Stage 1 doesn't carry over legacy NFS data —
  user apps (and their data) are ported one at a time later, after their
  own repos exist. Inventorying the full legacy export isn't a Stage-1
  blocker anymore. `terraform/variables.tf`'s `k8s_nodes` map sets each
  node's `longhorn_disk_size_gb` to match its OS disk size for now
  (`k8s-cp-01`: 40GB, `k8s-worker-01`: 100GB) — sized for the platform
  apps + searxng/pgweb only. Revisit per app as each one's real data
  volume becomes known during its own migration.
- **Replica count**: stays at the chart default of 3.
  `inventory/ukubi/hosts.yaml` puts `k8s-cp-01` in both
  `kube_control_plane` and `kube_node` — kubespray only taints a
  control-plane node `NoSchedule` when it's control-plane-*only*, so
  `k8s-cp-01` is schedulable. With only 2 nodes in Stage 1, volumes will
  run degraded (2/3 replicas) until Stage 2 adds a 3rd schedulable node —
  expected and non-blocking, not a bug.
- **`local-path-provisioner`**: stays installed as a non-default
  fallback (already implemented in
  `gitops/platform/values/local-path-provisioner/values.yaml`), not
  removed outright.
- **Backup target**: Garage S3 (`s3.bnei.dev`), daily `RecurringJob`
  snapshot — see `gitops/platform/values/longhorn/values.yaml`. Depends
  on the Garage LXC being up and configured (`terraform/garage.tf` +
  `ansible/playbooks/garage-configure.yml`, both non-interactive — no
  manual step); the recurring job is configured either way and just
  won't succeed until Garage exists.

## Consequences

`docs/runbook-migration-nfs-longhorn.md` can now be written per-app at
migration time instead of needing a full upfront NFS inventory. Longhorn
volumes will show degraded (not unhealthy) until Stage 2 adds a 3rd
node — don't treat that as an incident during Stage 1.
