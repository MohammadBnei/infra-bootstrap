# Runbook — Postgres/Pigsty bootstrap

Full Pigsty procedure per `docs/README.md`'s index.

> ⚠️ **`pg01` (`192.168.1.205`) and `pg02` are real, `terraform import`ed,
> `prevent_destroy` production Postgres** — see `terraform/imported.tf`
> and `ARCHITECTURE.md` §6. This runbook describes the **disaster-recovery
> / fresh-rebuild procedure**: deploying Pigsty from scratch onto a new
> pair of data VMs. Do not point any of these steps at the live `.205`/pg02
> pair without deliberate intent to rebuild production — Pigsty's own
> `pgsql.yml` initializes a cluster and will happily overwrite an existing
> one if pointed at it.

## 1. Goal

Deploy Pigsty (PostgreSQL primary/replica, PgBouncer, pgBackRest — no
witness node, no automatic failover, per `DECISION.md` §2) from scratch
onto a pair of data VMs.

## 2. Prereqs

- **Target VM specs** — `ARCHITECTURE.md` §6: `pg01` primary, `pg02`
  replica, 2 vCPU / 4GB / 40GB each per the current topology. `pg02`'s
  eventual home is `server1` once it's reinstalled as PVE; today both are
  on the primary `.165` host.
- **HA floating VIP**: `192.168.1.232` (vip-manager) — excluded from the
  MetalLB pool alongside `.230`/`.231` (`ARCHITECTURE.md` §3).
- **Backup target**: 149GB HDD on `server1` for pgBackRest, off-host from
  the primary's local backup (`ARCHITECTURE.md` §10 has the full backup
  matrix — 7 daily / 4 weekly / 3 monthly, PITR 7 days).
- **Infisical secrets needed at this phase** (`docs/secrets.md` has the
  full table with generators/consumers — this is just the relevant
  subset): `PG_SUPERUSER_PASSWORD`, `PG_REPLICATION_PASSWORD`,
  `PG_BACKREST_REPO_PASSWORD`, `PGBACKREST_S3_ACCESS_KEY` /
  `PGBACKREST_S3_SECRET`, `DBUSER_META_PASSWORD`, `DBUSER_VIEW_PASSWORD`,
  `DBUSER_INFISICAL_PASSWORD`, `DBUSER_ORY_PASSWORD`,
  `GRAFANA_ADMIN_PASSWORD`, `HAPROXY_ADMIN_PASSWORD`, `PGADMIN_PASSWORD`.
  Per `docs/secrets.md`'s "Bootstrap order," these are agent-generated
  (random 32B) except where noted, and Pigsty reads them via
  `infisical export` rather than the values being committed anywhere.

## 3. Steps

Pigsty is vendored in `pigsty/` with its own `pigsty/CLAUDE.md`/
`pigsty/README.md` — this runbook names the files and order, and
deliberately defers flag-level detail to Pigsty's own docs rather than
re-deriving its CLI (keeps this runbook from drifting as Pigsty is
upgraded independently of this repo).

1. **Configure the cluster** — `pigsty/pigsty.yml` is the config source
   of truth: node IPs (`pg01`/`pg02`), cluster/group name, the HA VIP
   (`192.168.1.232`), and the pgBackRest repo target (server1's HDD). See
   `pigsty/pigsty.yml`'s own structure and `pigsty/README.md` for the
   config schema — not re-derived here.
2. **`pigsty/deploy.yml`** — infra bring-up (repos, monitoring stack,
   HAProxy, etc.) on the target nodes.
3. **`pigsty/pgsql.yml`** — initializes the actual Postgres cluster
   (primary + streaming replica, PgBouncer, pgBackRest wiring).

`pigsty/CLAUDE.md`'s own permission model classifies both `deploy.yml`
and `pgsql.yml` as "REQUIRES USER CONFIRMATION — Cluster lifecycle
operations," and explicitly forbids running init/remove playbooks
unattended even in an otherwise-permissive mode. This runbook is written
for a human operator to run these commands directly — but if an agent is
walking someone through this doc, that confirmation gate still applies;
don't let "the runbook says to run it" substitute for the explicit "yes,
I confirm" `pigsty/CLAUDE.md` requires.

## 4. Verification

```bash
pig pg list           # confirm primary/replica roles are correct
patronictl list        # cluster member status
```

Check streaming replication lag is ~0 between `pg01` and `pg02` before
considering the cluster ready for traffic.

## 5. Rollback

Rollback here means **restore from pgBackRest to a sandbox VM**, not
undo-in-place on a live cluster — consistent with this runbook's
disaster-recovery framing. If a fresh `pgsql.yml` run against new VMs
goes wrong, the practical reset is destroying those VMs via Terraform
(they aren't the `imported.tf`/`prevent_destroy` production pair) and
re-running this runbook from Step 1.

## Previous

Kubernetes/GitOps bootstrap: [`docs/runbook-k8s-bootstrap.md`](runbook-k8s-bootstrap.md).
