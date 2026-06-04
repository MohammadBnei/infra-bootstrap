# Pigsty config

Pigsty config for the 2-data-node + 1-witness PostgreSQL cluster.

## Topology (per `infrastructure-desired.md`)

| Node | Type | Host | Role |
|---|---|---|---|
| pg-data-1 | LXC | proxmox PVE | Patroni primary/replica |
| pg-data-2 | LXC | server1 PVE | Patroni primary/replica |
| etcd-witness | bare metal | Pi 4 (.55) | Quorum vote only, no Postgres data |

## Status

- [ ] `pigsty.yml` finalized with real IPs and roles
- [ ] Patroni etcd cluster sized correctly (3 nodes: 2 data + 1 witness)
- [ ] pgBackRest configured with local + off-host (149GB HDD on server1) backup targets
- [ ] First `pigsty` dry-run against the config

## How to run

```bash
# install pigsty (one-time)
curl -fsSL https://repo.pigsty.io/get | bash

# auth with Infisical for secrets
infisical run --projectId=<infra-bootstrap-project-id> --env=dev -- \
  ./pigsty/pigsty deploy
```

## Notes

- PostgreSQL target version: 18
- Source (for migration) is PG 16.4 at `192.168.1.193` — see migration runbook
- See `docs/runbook-pg-bootstrap.md` for the full procedure
