# docs/

Runbooks for the bootstrap procedure. Each runbook covers a specific change workflow.

## Status

- [x] `runbook-k8s-bootstrap.md` — full kubespray procedure (kubespray `cluster.yml` against `inventory/ukubi/`)
- [x] `runbook-pg-bootstrap.md` — full Pigsty procedure (Patroni + etcd + pgBackRest)
- [x] `runbook-pve-postinstall.md` — post-install PVE configuration (run against `.200`/`.161`, both joined the corosync cluster)
- [x] `runbook-pg-ca-rotation-etcd-quorum.md` — Pigsty CA rotation (old CA's key unrecoverable) + 3-node etcd DCS quorum, per ADR-0029
- [x] `runbook-dns-cloudflare-migration.md` — moved the `bnei.dev` zone to Cloudflare (wildcard records + ACME DNS-01 for the `*.e2e.bnei.dev` cert), per [ADR-0033](adr/0033-dns-to-cloudflare-and-dns01-wildcard.md). **Run 2026-08-11.** Zone file `dns/bnei.dev.zone` is reconciled against live; mail also moved off Mailgun entirely (SMTP2GO outbound, Cloudflare Email Routing inbound) — see the runbook's "What actually happened"
- [x] `runbook-cluster-hardening-adr-0040.md` — etcd encryption at rest, API audit log, Cilium WireGuard encryption (ADR-0040 Phase 6). **Run 2026-08-18**, as two kubespray runs rather than the three the ADR planned (`--tags control-plane` cannot separate the two apiserver flags). All three verified live — `k8s:enc:secretbox:v1` in etcd, audit streams in Loki, `cilium_wg0` with 4 peers; see `bootstrap-test-notes.md` and the runbook's own corrections
- [x] `runbook-authentik-identity.md` — operating the authentik identity layer (ADR-0039): blueprints, the `platform-admins` group both ArgoCD and Grafana read, the four-step propagation chain that nothing hot-reloads, and the field shapes verified against the running 2026.8.0. **Native OIDC tier live 2026-08-19** (ArgoCD, Grafana, and `fleet` natively inside `core` per [ADR-0041](adr/0041-fleet-native-oidc-not-forwardauth.md)); **forwardAuth tier live 2026-08-21**, gating the e2e preview hosts and `wedding.bnei.dev/admin`. Alertmanager, pgweb and Proxmox still to move, and `basic-admin-auth` still to retire ([#183](https://github.com/MohammadBnei/infra-bootstrap/issues/183))
- [ ] `runbook-migration-pg.md` — cutover from source PG 16.4 (192.168.1.193) to target Pigsty cluster
- [ ] `runbook-migration-nfs-longhorn.md` — cutover from the legacy cluster's (.181/.191) NFS-backed PVs to Longhorn-backed PVs on ukubi-cluster; blocked on [ADR-0019](adr/0019-longhorn-rollout-specifics.md)

## Format

Each runbook has the structure:
1. Goal
2. Prereqs (Infisical auth, IPs assigned, hosts reachable)
3. Steps (exact commands)
4. Verification (sanity checks, expected output)
5. Rollback (how to undo)
