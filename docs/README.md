# docs/

Runbooks for the bootstrap procedure. Each runbook covers a specific change workflow.

## Status

- [x] `runbook-k8s-bootstrap.md` — full kubespray procedure (kubespray `cluster.yml` against `inventory/ukubi/`)
- [x] `runbook-pg-bootstrap.md` — full Pigsty procedure (Patroni + etcd + pgBackRest)
- [x] `runbook-pve-postinstall.md` — post-install PVE configuration (run against `.200`/`.161`, both joined the corosync cluster)
- [x] `runbook-pg-ca-rotation-etcd-quorum.md` — Pigsty CA rotation (old CA's key unrecoverable) + 3-node etcd DCS quorum, per ADR-0029
- [x] `runbook-dns-cloudflare-migration.md` — moved the `bnei.dev` zone to Cloudflare (wildcard records + ACME DNS-01 for the `*.e2e.bnei.dev` cert), per [ADR-0033](adr/0033-dns-to-cloudflare-and-dns01-wildcard.md). **Run 2026-08-11.** Zone file `dns/bnei.dev.zone` is reconciled against live; mail also moved off Mailgun entirely (SMTP2GO outbound, Cloudflare Email Routing inbound) — see the runbook's "What actually happened"
- [ ] `runbook-migration-pg.md` — cutover from source PG 16.4 (192.168.1.193) to target Pigsty cluster
- [ ] `runbook-migration-nfs-longhorn.md` — cutover from the legacy cluster's (.181/.191) NFS-backed PVs to Longhorn-backed PVs on ukubi-cluster; blocked on [ADR-0019](adr/0019-longhorn-rollout-specifics.md)

## Format

Each runbook has the structure:
1. Goal
2. Prereqs (Infisical auth, IPs assigned, hosts reachable)
3. Steps (exact commands)
4. Verification (sanity checks, expected output)
5. Rollback (how to undo)
