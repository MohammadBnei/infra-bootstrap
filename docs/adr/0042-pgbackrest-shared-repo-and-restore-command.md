# ADR-0042: pgBackRest repo moves to Garage S3, and replicas gain a `restore_command`

**Status:** Proposed
**Date:** 2026-08-25
**Related:** [ADR-0029](0029-postgres-automatic-failover-etcd-quorum.md) (automatic
failover is accepted behaviour — this ADR is about what happens *after* one),
[ADR-0030](0030-expose-garage-s3-externally.md) (the Garage instance this uses)

## Context

On 2026-08-25 `pg-proxmox-1` (`192.168.1.205`) was found stuck as a replica in
`state=starting`, `lag=unknown`, `tl=None`. The cluster had been running on a
single node. Its Postgres log showed one line repeating every five seconds:

```
FATAL: could not receive data from WAL stream: ERROR: requested WAL segment
       0000001F0000003200000078 has already been removed
LOG:   waiting for WAL to become available at 32/78000018
```

The leader had recycled the WAL the replica needed. A replica in that state
**cannot recover on its own, ever** — it retries forever. `docs/bootstrap-test-notes.md`
already predicted the shape: *"this will recur after every ungraceful failover
with timeline divergence … a human must run `reinit` each time."* This was the
second occurrence; the first was 2026-08-15, in the opposite direction.

The obvious fix — give the replica a `restore_command` so it fetches the missing
segment from the pgBackRest archive — **does not work as configured**, and the
reason is the actual finding:

**`repo1-path=/pg/backup` is a node-local directory.** Each node has its own
independent pgBackRest repository. Their contents have diverged:

| Node | WAL archive range it holds |
|---|---|
| `.207` (current leader) | `0000001B00000018000000C4` → `0000001F00000033000000AF` (timeline 31) |
| `.205` | `0000001E0000003000000085` → `0000001E0000003200000077` (timeline **30**) |

The missing segment is on timeline 31. It exists — in `.207`'s repo, which
`.205` cannot read. A `restore_command` on `.205` would query a repo that has no
timeline-31 WAL at all.

Three consequences follow from one root cause:

1. **Backups do not survive the node.** `.205` sits on `server1`, which was
   isolated for 23h40m on 2026-08-24. Losing that VM loses every backup it holds.
2. **The archive splits at every failover.** Neither repo holds a complete
   history, so neither is a reliable PITR source across a role change.
3. **No replica can ever self-heal**, which is why a human `reinit` is the only
   remedy — the fragility this ADR exists to remove.

A Garage bucket and key for exactly this were provisioned on **2026-07-26** and
have never been used. `ansible/playbooks/garage-configure.yml` says so in the
entry itself: *"provisional — not fixed anywhere else yet, rename freely once
pigsty's `pgbackrest_repo` config is written."* It was never written;
`pigsty/pigsty.yml`'s `pgbackrest_repo` block is entirely commented out, so
Pigsty falls back to its `local` default.

## Decision

1. **Point pgBackRest at the existing Garage S3 bucket `pg-backup`** as a single
   repository shared by both nodes, using the `pgbackrest-backup-key` already in
   Infisical as `PGBACKREST_S3_ACCESS_KEY`/`_SECRET`. This is a `pigsty.yml`
   change (`pgbackrest_method` + `pgbackrest_repo`), not an edit to `pigsty/`,
   which stays vendored and untouched.

2. **Set `restore_command` on the cluster** so a replica that falls behind
   fetches missing WAL from the shared archive instead of wedging:
   `pgbackrest --stanza=pg-proxmox archive-get %f %p`. This is only meaningful
   once Decision 1 lands — with node-local repos it is worse than useless,
   because it would appear to be configured while pointing at the wrong archive.

3. **Interim, and independent of the above: alert on it.** A Grafana rule,
   `postgres-replica-not-streaming`, fires when `patroni_replica == 1` and
   `patroni_postgres_streaming == 0` for 10 minutes. This ships now, because the
   worst part of the incident was not that it happened but that it was silent
   for over a day and was found by accident.

4. **Do not raise `max_slot_wal_keep_size` (currently 18GB) as the fix.** It
   moves the threshold at which the same failure occurs; it does not remove it.

## Consequences

- Backups stop being tied to the life of a single VM, which is the durability
  property that is missing today.
- Replica recovery after an ungraceful failover becomes automatic rather than a
  manual `patronictl reinit`.
- **Postgres backups gain a dependency on Garage** (`192.168.1.199`, a single
  LXC on one PVE host). If Garage is down, `archive-push` queues — bounded by
  `archive-push-queue-max=4GiB`, already set — and WAL accumulates on the
  primary until it drains. That is a real new failure mode and is the main cost
  of this decision. Garage already carries Longhorn's backups, so it is not a
  new trust dependency, only a wider one.
- Migration is not free: the stanza must be created against the new repo and a
  new full backup taken before the old local repos can be retired. **Existing
  local backups must be kept until the first S3 full backup verifies.**
- `create_replica_methods` is currently `[basebackup]` only. Adding `pgbackrest`
  is a sensible follow-up once the shared repo exists, but is deliberately not
  decided here — a re-clone from S3 has different bandwidth characteristics than
  one from the leader on the LAN, and that deserves its own measurement.

## Alternatives considered

- **Raise `max_slot_wal_keep_size`.** Rejected as *the* fix per Decision 4;
  it buys time proportional to the increase and nothing else. May still be worth
  doing separately.
- **A shared NFS repo** on `nfs-storage.bnei.lan` instead of S3. Rejected:
  ADR-0036 states plainly that the `nfs` class is unreplicated and never backed
  up. Putting the backup repository on unbacked-up storage inverts the point.
- **`remove_data_directory_on_diverged_timelines: true`.** Would automate the
  reinit, but lets Patroni destroy a replica's data directory unattended.
  `docs/bootstrap-test-notes.md` already weighed and rejected this; the safe
  default is worth keeping once self-healing (Decision 2) makes the destructive
  path rare.
- **Do nothing and keep running `reinit` by hand.** This is the status quo, and
  it has now cost two incidents. It also leaves backups non-durable, which is the
  part that does not announce itself until it matters.

## Rollout

Not yet run. Requires a Pigsty run against `pg-proxmox`, which per `CLAUDE.md` is
the operator's action, not an unattended one. Order matters:

1. Write `pgbackrest_repo` into `pigsty/pigsty.yml` (Infisical-referenced
   credentials, never literal values).
2. `pgbackrest stanza-create` against the S3 repo, then a full backup, and
   **verify it** before touching the local repos.
3. Add `restore_command` (Decision 2) — it is a normal GUC on PG12+, so it can
   go through Patroni's DCS config and needs a reload, not a restart.
4. Prove it: stop a replica, let the leader recycle past it, restart it, and
   confirm it catches up from the archive with no `reinit`. Until that test
   passes, this ADR is unproven, not implemented.
